#!/usr/bin/env bash
# psg1_desktop.sh — open the PSG1's proot-Linux XFCE desktop from the jumpbox.
#
# One command: ensures the VNC desktop is running on the PSG1 (proot Debian/Ubuntu
# + XFCE + TigerVNC), tunnels it to the jumpbox over adb, and launches a viewer.
# Runs the desktop in a proot-distro guest, which shares Android's kernel — so it
# is NOT a VM, has no emulation overhead, and renders at native A76 speed. This is
# the right way to get a *usable* Linux GUI on the PSG1, because the stock kernel
# ships without KVM (see PSG1_CYBERDECK_OPS.md → "Running your own Linux").
#
# Prereqs (one-time — see PSG1_CYBERDECK_OPS.md → "GUI desktop over VNC"):
#   * PSG1 reachable over adb (USB), Termux sshd up on port 8022
#   * the jumpbox SSH pubkey in TERMUX's ~/.ssh/authorized_keys
#       (/data/data/com.termux/files/home/.ssh/ — NOT a proot guest's authorized_keys)
#   * a proot-distro guest installed with:
#       apt install -y --no-install-recommends xfce4 xfce4-terminal xfce4-settings \
#         dbus-x11 dbus tigervnc-standalone-server tigervnc-common \
#         fonts-dejavu-core x11-xserver-utils
#   * a VNC viewer on the jumpbox (e.g. `apt install tigervnc-viewer`)
#
# Config via env:
#   DISTRO=debian     proot-distro guest name (default: debian)
#   GEOM=1280x720     desktop resolution (e.g. GEOM=1920x1080)
#   TERMUX_USER=      Termux app user u0_aNNN (default: auto-detected)
#   PSG1_SERIAL=      adb serial (default: first 'device' in `adb devices`)
#   SSH_FWD=18022     local port forwarded to Termux sshd (device 8022)
#   VNC_PORT=5901     VNC port (display :1)
set -euo pipefail

DISTRO="${DISTRO:-debian}"
GEOM="${GEOM:-1280x720}"
SSH_FWD="${SSH_FWD:-18022}"
VNC_PORT="${VNC_PORT:-5901}"

# --- find the PSG1 over adb ---------------------------------------------------
SERIAL="${PSG1_SERIAL:-$(adb devices | awk '$2=="device"{print $1; exit}')}"
[ -n "$SERIAL" ] || { echo "No adb device found (check 'adb devices' / USB cable)."; exit 1; }

# --- resolve the Termux app user (u0_aNNN) -----------------------------------
TUSER="${TERMUX_USER:-}"
if [ -z "$TUSER" ]; then
  uid=$(adb -s "$SERIAL" shell 'pm list packages -U 2>/dev/null' \
        | sed -n 's/.*com\.termux uid:\([0-9]\+\).*/\1/p' | head -1 | tr -d '\r')
  [ -n "$uid" ] || { echo "Couldn't detect Termux uid; set TERMUX_USER=u0_aNNN."; exit 1; }
  TUSER="u0_a$((uid-10000))"
fi
echo "PSG1=$SERIAL  termux=$TUSER  distro=$DISTRO  geom=$GEOM"

adb -s "$SERIAL" forward "tcp:$SSH_FWD" tcp:8022 >/dev/null
SSH=(ssh -p "$SSH_FWD" -o BatchMode=yes -o ConnectTimeout=10
     -o StrictHostKeyChecking=accept-new "$TUSER@localhost")

# --- start the desktop if it isn't already running ---------------------------
if "${SSH[@]}" 'tmux has-session -t vnc 2>/dev/null'; then
  echo "desktop already running (tmux session 'vnc')"
else
  echo "staging guest config + starting XFCE/VNC ..."
  # Guest-side setup, shipped as base64 to avoid nested-heredoc quoting through
  # ssh -> proot-distro -> bash. Writes xstartup to the NEW tigervnc config dir
  # (~/.config/tigervnc, required on tigervnc >=1.13 / Debian 13) and a start
  # script that holds the proot session open so Xvnc isn't reaped.
  GUEST=$(cat <<'GS'
#!/bin/bash
set -e
export USER=root HOME=/root
mkdir -p /root/.config/tigervnc
cat > /root/.config/tigervnc/xstartup <<'XS'
#!/bin/bash
unset SESSION_MANAGER DBUS_SESSION_BUS_ADDRESS
export XDG_RUNTIME_DIR=/tmp/xdg-root
mkdir -p "$XDG_RUNTIME_DIR"; chmod 700 "$XDG_RUNTIME_DIR"
export LANG=en_US.UTF-8
exec dbus-launch --exit-with-session startxfce4
XS
chmod +x /root/.config/tigervnc/xstartup
# a legacy ~/.vnc with no ~/.config/tigervnc makes tigervnc>=1.13 abort on every
# call ("Could not migrate ...") — remove it so the new config dir is used
rm -rf /root/.vnc
cat > /root/startvnc.sh <<'SV'
#!/bin/bash
export USER=root HOME=/root LANG=en_US.UTF-8
tigervncserver -kill :1 >/dev/null 2>&1
rm -f /tmp/.X1-lock /tmp/.X11-unix/X1 2>/dev/null
# no-auth is safe: -localhost binds loopback only; reached solely via the tunnel
tigervncserver :1 -geometry __GEOM__ -depth 24 -localhost yes -SecurityTypes None > /root/vnc-start.log 2>&1
exec sleep infinity
SV
chmod +x /root/startvnc.sh
GS
)
  GUEST="${GUEST/__GEOM__/$GEOM}"
  B64=$(printf '%s' "$GUEST" | base64 -w0)
  "${SSH[@]}" "echo $B64 | base64 -d | proot-distro login $DISTRO -- bash -s"
  "${SSH[@]}" "termux-wake-lock 2>/dev/null || true; \
               tmux new-session -d -s vnc 'proot-distro login $DISTRO -- bash /root/startvnc.sh'"
  sleep 8
  echo "desktop started"
fi

# --- tunnel the VNC port and launch a viewer ---------------------------------
adb -s "$SERIAL" forward "tcp:$VNC_PORT" "tcp:$VNC_PORT" >/dev/null
echo "VNC ready -> localhost:$VNC_PORT"
if command -v xtigervncviewer >/dev/null; then
  exec xtigervncviewer -SecurityTypes None "localhost:$VNC_PORT"
elif command -v vncviewer >/dev/null; then
  exec vncviewer "localhost:$VNC_PORT"
else
  echo "No VNC viewer on the jumpbox. Install tigervnc-viewer, then:"
  echo "  xtigervncviewer -SecurityTypes None localhost:$VNC_PORT"
fi
