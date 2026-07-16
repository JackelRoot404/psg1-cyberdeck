#!/usr/bin/env bash
# PSG1 keepalive — runs on a jumpbox to undo what PlaySolana firmware (the native
# SvalGuard service) does at every boot: it disables Termux/Tailscale/sshd/etc.
# This re-enables them and brings sshd + always-on VPN back. Idempotent; safe to
# run every few minutes.
#
# Reaches the deck over USB *and/or* the network, finding it in three steps:
#
#   1. USB — auto-detected whenever the deck is docked.
#   2. PSG1_ADB_TARGETS — explicit "ip:port" endpoints, tried first on the network.
#   3. Discovery — if neither answers, sweep the local /24s for the deck's WiFi MAC
#      and connect to it. Survives DHCP drift, a router reset, or the deck moving
#      to a new network. Set PSG1_DISCOVER=0 to switch it off.
#
#   crontab -e:
#   PATH=/usr/local/bin:/usr/bin:/bin
#   */5 * * * * PSG1_ADB_TARGETS="192.168.x.y:5555 100.64.x.y:5555" \
#               timeout 240 /path/psg1_keepalive.sh >>/path/psg1_keepalive.log 2>&1
#
# The `timeout 240` is a whole-script backstop so a wedged adb can never let cron
# stack ticks; individual calls are bounded separately. PATH matters — cron's
# default is too bare to find adb.
#
# Network adb needs persist.adb.tcp.port=5555 set once on the deck (survives
# reboots — see PSG1_CYBERDECK_OPS.md). Post-reboot recovery works over the LAN
# path; the tailnet endpoint can't reach the deck until Tailscale is re-enabled,
# so it's a fallback, not the recovery path.
#
# IDENTITY: an ip:port is an address, not an identity — a lease can move and leave
# some other device answering on :5555. Every network transport is checked against
# the deck's serial before we touch it, and disconnected if it doesn't match. USB
# transports are self-identifying (the transport name *is* the serial).

set -u

PACKAGES=(
  com.termux
  com.termux.boot
  com.termux.api
  com.tailscale.ipn
  moe.shizuku.privileged.api
  eu.faircode.netguard
  com.wireguard.android
  app.lawnchair
)

EXPECT_SERIAL="${PSG1_SERIAL:-PS01-2549-001-A2-002791}"
# Per-SSID MAC: Android randomises by default, so this is only valid for the
# network it was read on. On a new SSID, read the deck's MAC there and pass it in.
EXPECT_MAC="${PSG1_MAC:-78:be:81:2a:28:1a}"
ADB_PORT="${PSG1_ADB_PORT:-5555}"
DISCOVER="${PSG1_DISCOVER:-1}"
CONNECT_TIMEOUT="${PSG1_CONNECT_TIMEOUT:-5}"
CMD_TIMEOUT="${PSG1_CMD_TIMEOUT:-15}"

ts="$(date '+%Y-%m-%d %H:%M:%S')"

# Start the server explicitly: otherwise the first adb call emits "daemon not
# running; starting now" on stderr and cron's 2>&1 dumps it into the log.
adb start-server >/dev/null 2>&1

# Is this transport actually our deck? Bounded — a half-dead transport can stall.
#   0 = yes   1 = no, a different device   2 = couldn't ask (timeout/error/empty)
# 1 and 2 must stay distinct: "not the deck" is a claim about the device, "couldn't
# ask" is a claim about the link. Conflating them makes a transient adb hiccup look
# like a serial mismatch and gets the real deck disconnected with a false accusation.
is_deck() {
  local s
  s="$(timeout 10 adb -s "$1" shell getprop ro.serialno 2>/dev/null | tr -d '\r\n')"
  [ -n "$s" ] || return 2
  [ "$s" = "$EXPECT_SERIAL" ]
}

# First live transport that really is the deck; USB sorts first via adb's ordering.
live_deck() {
  local t
  for t in $(adb devices 2>/dev/null | awk '$2=="device"{print $1}'); do
    is_deck "$t" && { printf '%s\n' "$t"; return 0; }
  done
  return 1
}

# Any transport stuck in adb's "offline" state?
has_offline() {
  adb devices 2>/dev/null | awk '$2=="offline"{f=1} END{exit !f}'
}

# Drop any network transport that answers adb but is provably a different device —
# a stale PSG1_ADB_TARGETS entry pointing at a reassigned lease is the likely cause,
# and is worth saying out loud rather than silently ignoring. Only a definite
# mismatch (rc=1) is grounds for disconnecting; rc=2 means we couldn't ask, which is
# not evidence of anything, so leave it be and let the next tick decide.
vet_transports() {
  local t
  for t in $(adb devices 2>/dev/null | awk '$2=="device" && $1 ~ /:/ {print $1}'); do
    is_deck "$t"
    if [ $? -eq 1 ]; then
      echo "[$ts] $t answers adb but is not the deck (serial mismatch) — disconnecting"
      adb disconnect "$t" >/dev/null 2>&1
    fi
  done
}

# Find the deck by MAC on the local /24s. Ping-sweeps to populate the neighbour
# table, then matches the MAC — so we only ever adb-connect to a host we've already
# identified, rather than probing :5555 across the subnet.
discover() {
  local addr base i ip
  for addr in $(ip -4 -o addr show scope global 2>/dev/null | awk '{split($4,a,"/"); if (a[2]==24) print a[1]}'); do
    base="${addr%.*}"
    for i in $(seq 1 254); do ping -c1 -W1 "$base.$i" >/dev/null 2>&1 & done
    wait
    ip="$(ip neigh show 2>/dev/null | awk -v m="$EXPECT_MAC" 'tolower($5)==tolower(m){print $1; exit}')"
    [ -n "$ip" ] || continue
    timeout "$CONNECT_TIMEOUT" adb connect "$ip:$ADB_PORT" >/dev/null 2>&1 || true
    if is_deck "$ip:$ADB_PORT"; then
      # Log to stderr: stdout is this function's return value. cron's 2>&1 still
      # lands it in the log.
      echo "[$ts] found the deck at $ip:$ADB_PORT by MAC ($EXPECT_MAC)" >&2
      printf '%s\n' "$ip:$ADB_PORT"
      return 0
    fi
    adb disconnect "$ip:$ADB_PORT" >/dev/null 2>&1
  done
  return 1
}

# (Re)connect configured endpoints; USB is auto-detected regardless.
read -r -a NET_TARGETS <<< "${PSG1_ADB_TARGETS:-}"
connect_targets() {
  local t
  [ "${#NET_TARGETS[@]}" -gt 0 ] || return 0
  # Bound it. An endpoint that black-holes rather than refusing makes a bare
  # `adb connect` hang on TCP SYN retries for >2 min — and the tailnet endpoint
  # black-holes in exactly the situation this script exists for, since Tailscale
  # is down after a reboot. Unbounded, every tick burned minutes and cron piled
  # the ticks up (observed 2026-07-15).
  for t in "${NET_TARGETS[@]}"; do timeout "$CONNECT_TIMEOUT" adb connect "$t" >/dev/null 2>&1 || true; done
}

connect_targets
vet_transports

SERIAL="$(live_deck || true)"

# When the deck reboots, its old TCP transport sticks at "offline" permanently:
# `adb connect` answers "already connected", disconnect+connect answers the same,
# and `adb reconnect offline` says "reconnecting" and changes nothing. Only a
# server restart clears it. The keepalive's own connects during the boot window
# are what create these, so every real reboot poisoned the server and the network
# path could never recover — measured in the 2026-07-15 reboot test, not theory.
#
# Only fires when nothing live was found, so a working USB session is never cut.
if [ -z "$SERIAL" ] && has_offline; then
  echo "[$ts] stale offline transport(s) — restarting adb server to clear them"
  adb kill-server >/dev/null 2>&1
  adb start-server >/dev/null 2>&1
  connect_targets
  vet_transports
  SERIAL="$(live_deck || true)"
fi

if [ -z "$SERIAL" ] && [ "$DISCOVER" != "0" ]; then
  SERIAL="$(discover || true)"
fi
# Nothing to do: deck is off, or on a network we can't see.
[ -n "$SERIAL" ] || exit 0

# Bound every payload call, not just the identity probe: the same half-dead
# transport that can stall is_deck stalls these too, and there are ~23 round trips
# below. cron's `timeout 240` is a backstop for the whole script, not a substitute.
ADB=(timeout "$CMD_TIMEOUT" adb -s "$SERIAL")
needed_action=0

for pkg in "${PACKAGES[@]}"; do
  state="$("${ADB[@]}" shell "dumpsys package $pkg 2>/dev/null | grep -m1 'enabled=' | grep -oE 'enabled=[0-9]'" 2>/dev/null | tr -d '\r')"
  # Re-enable on any non-enabled state. pm disable-user (the usual disable path
  # on this device) sets enabled=3, which an old {0,2,4} allowlist missed.
  # Empty state = package not installed for this user → skip it.
  if [ -n "$state" ] && [ "$state" != "enabled=1" ]; then
    echo "[$ts] re-enabling $pkg (was $state) via $SERIAL"
    "${ADB[@]}" shell "pm enable $pkg" >/dev/null
    needed_action=1
  fi
done

# Restore always-on VPN if it was cleared.
# The [ -n ] guard matters: a healthy read of an unset key returns the literal
# "null", never empty. Empty means the read FAILED — most likely the `settings`
# service isn't bound yet, which is the normal state in the post-reboot window this
# script exists for (adbd answers getprop long before system_server is up). Without
# the guard, "" != "com.tailscale.ipn" is true and we log a restore that never
# happened, then issue a write that also fails.
aov="$("${ADB[@]}" shell 'settings get global always_on_vpn_app' 2>/dev/null | tr -d '\r')"
if [ -n "$aov" ] && [ "$aov" != "com.tailscale.ipn" ]; then
  echo "[$ts] restoring always-on VPN (was: $aov)"
  "${ADB[@]}" shell "settings put global always_on_vpn_app com.tailscale.ipn" >/dev/null
  needed_action=1
fi

# Restore private DNS to opportunistic if it got changed.
# IMPORTANT: don't use strict DoT (e.g. one.one.one.one) while Tailscale is
# active — Android marks the VPN's network as PrivateDnsBroken and DNS dies
# for many apps including Termux's pkg manager.
pdm="$("${ADB[@]}" shell 'settings get global private_dns_mode' 2>/dev/null | tr -d '\r')"
if [ -n "$pdm" ] && [ "$pdm" != "opportunistic" ] && [ "$pdm" != "off" ]; then
  echo "[$ts] restoring private DNS to opportunistic (was: $pdm)"
  "${ADB[@]}" shell "settings put global private_dns_mode opportunistic" >/dev/null
  needed_action=1
fi

# Bring Termux sshd back up after a reboot. Termux:Boot is skipped when the
# package is disabled during the boot window, so once com.termux is enabled we
# cold-start it: the fresh login session sources ~/.bashrc, whose guard line
# (re)starts sshd. Only acts when sshd is actually down, so steady state is a no-op.
tstate="$("${ADB[@]}" shell "dumpsys package com.termux 2>/dev/null | grep -m1 'enabled=' | grep -oE 'enabled=[0-9]'" 2>/dev/null | tr -d '\r')"
sshd_listen="$("${ADB[@]}" shell 'ss -ltn 2>/dev/null | grep :8022' 2>/dev/null | tr -d '\r')"
if [ "$tstate" = "enabled=1" ] && [ -z "$sshd_listen" ]; then
  echo "[$ts] Termux sshd not listening — cold-starting Termux so its ~/.bashrc guard restarts sshd"
  "${ADB[@]}" shell 'input keyevent KEYCODE_WAKEUP; am start -n com.termux/.app.TermuxActivity' >/dev/null 2>&1
  needed_action=1
fi

if [ $needed_action -eq 0 ]; then
  exit 0  # silent on no-op so the log doesn't fill up
fi
