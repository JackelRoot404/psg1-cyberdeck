#!/usr/bin/env bash
# PSG1 keepalive — runs on a jumpbox plugged into the PSG1 via USB ADB.
# Re-enables packages that PlaySolana firmware disables at every boot.
# Idempotent. Safe to run every few minutes.
#
# Install with crontab -e:
#   */5 * * * * /path/to/psg1_keepalive.sh >>/path/to/psg1_keepalive.log 2>&1

set -u

# Packages that PlaySolana firmware disables at every reboot.
# Add/remove as needed for your install.
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

# Only act if ADB sees the device
if ! adb devices | grep -q "device$"; then
  exit 0  # device not connected, no work to do
fi

ts="$(date '+%Y-%m-%d %H:%M:%S')"
needed_action=0

for pkg in "${PACKAGES[@]}"; do
  state="$(adb shell "dumpsys package $pkg 2>/dev/null | grep -m1 'enabled=' | grep -oE 'enabled=[0-9]'" 2>/dev/null | tr -d '\r')"
  # Re-enable on any non-enabled state. pm disable-user (the usual disable
  # path on this device) sets enabled=3, which an old {0,2,4} allowlist missed.
  # Empty state = package not installed for this user → skip it.
  if [ -n "$state" ] && [ "$state" != "enabled=1" ]; then
    echo "[$ts] re-enabling $pkg (was $state)"
    adb shell "pm enable $pkg" >/dev/null
    needed_action=1
  fi
done

# Restore always-on VPN if it was cleared
aov="$(adb shell 'settings get global always_on_vpn_app' 2>/dev/null | tr -d '\r')"
if [ "$aov" != "com.tailscale.ipn" ]; then
  echo "[$ts] restoring always-on VPN (was: $aov)"
  adb shell "settings put global always_on_vpn_app com.tailscale.ipn" >/dev/null
  needed_action=1
fi

# Restore private DNS to opportunistic if it got changed.
# IMPORTANT: don't use strict DoT (e.g. one.one.one.one) while Tailscale is
# active — Android marks the VPN's network as PrivateDnsBroken and DNS dies
# for many apps including Termux's pkg manager.
pdm="$(adb shell 'settings get global private_dns_mode' 2>/dev/null | tr -d '\r')"
if [ "$pdm" != "opportunistic" ] && [ "$pdm" != "off" ]; then
  echo "[$ts] restoring private DNS to opportunistic (was: $pdm)"
  adb shell "settings put global private_dns_mode opportunistic" >/dev/null
  needed_action=1
fi

if [ $needed_action -eq 0 ]; then
  # Silent on no-op so the log doesn't fill up
  exit 0
fi
