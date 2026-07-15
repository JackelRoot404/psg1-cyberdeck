#!/usr/bin/env bash
# PSG1 keepalive — runs on a jumpbox to undo what PlaySolana firmware (the native
# SvalGuard service) does at every boot: it disables Termux/Tailscale/sshd/etc.
# This re-enables them and brings sshd + always-on VPN back. Idempotent; safe to
# run every few minutes.
#
# Reaches the deck over USB *and/or* the network. With persistent network adb
# enabled on the deck (persist.adb.tcp.port=5555 — see PSG1_CYBERDECK_OPS.md),
# set PSG1_ADB_TARGETS to the deck's "ip:port" endpoints and this can heal it
# after a reboot even undocked, as long as the jumpbox can reach it:
#
#   crontab -e:
#   */5 * * * * PSG1_ADB_TARGETS="192.168.x.y:5555 100.64.x.y:5555" \
#               /path/psg1_keepalive.sh >>/path/psg1_keepalive.log 2>&1
#
# Post-reboot recovery works over the LAN endpoint (Tailscale is disabled on boot,
# so the tailnet endpoint can't reach the deck until the LAN path re-enables it
# first) — so give the deck a STABLE LAN address (a DHCP reservation). With no
# network targets set it behaves as before: USB-only.

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

# (Re)connect any configured network endpoints; USB is auto-detected regardless.
read -r -a NET_TARGETS <<< "${PSG1_ADB_TARGETS:-}"
if [ "${#NET_TARGETS[@]}" -gt 0 ]; then
  for t in "${NET_TARGETS[@]}"; do adb connect "$t" >/dev/null 2>&1; done
fi

# Act on any live (authorized) transport — USB or network. None => deck not
# reachable right now (off, or on a network we can't see): nothing to do.
SERIAL="$(adb devices | awk '$2=="device"{print $1; exit}')"
[ -n "$SERIAL" ] || exit 0
ADB=(adb -s "$SERIAL")

ts="$(date '+%Y-%m-%d %H:%M:%S')"
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

# Restore always-on VPN if it was cleared
aov="$("${ADB[@]}" shell 'settings get global always_on_vpn_app' 2>/dev/null | tr -d '\r')"
if [ "$aov" != "com.tailscale.ipn" ]; then
  echo "[$ts] restoring always-on VPN (was: $aov)"
  "${ADB[@]}" shell "settings put global always_on_vpn_app com.tailscale.ipn" >/dev/null
  needed_action=1
fi

# Restore private DNS to opportunistic if it got changed.
# IMPORTANT: don't use strict DoT (e.g. one.one.one.one) while Tailscale is
# active — Android marks the VPN's network as PrivateDnsBroken and DNS dies
# for many apps including Termux's pkg manager.
pdm="$("${ADB[@]}" shell 'settings get global private_dns_mode' 2>/dev/null | tr -d '\r')"
if [ "$pdm" != "opportunistic" ] && [ "$pdm" != "off" ]; then
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
