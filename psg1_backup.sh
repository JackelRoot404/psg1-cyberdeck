#!/usr/bin/env bash
# psg1_backup.sh — snapshot the PSG1's hand-built state to the jumpbox.
#
# Backs up the eMMC-resident state that is NOT reconstructible from this repo:
#   * every proot-distro container (Debian desktop, Kali, ...) via `proot-distro backup`
#   * the Termux home dir (SSH keys, .bashrc, .termux/, the ~/vm wrapper)
#   * the VM disk image on the SD card (alpine.qcow2)
#   * the installed Termux package list
#
# Output: $DEST/psg1-backup-<timestamp>/  (default $HOME/psg1-backups).
# KEEP THIS LOCAL — it contains SSH private keys. Do not commit or upload.
#
# Runs on the jumpbox (needs adb + the Termux SSH key authorized). Large
# containers are slow to compress on the device — a multi-GB Kali can take
# 20-30 min. Config via env: DEST=, CARD=/storage/XXXX-XXXX, TERMUX_USER=,
# PSG1_SERIAL=, SSH_FWD=18022.
set -euo pipefail

DEST="${DEST:-$HOME/psg1-backups}"
CARD="${CARD:-/storage/F230-402C}"
SSH_FWD="${SSH_FWD:-18022}"

SERIAL="${PSG1_SERIAL:-$(adb devices | awk '$2=="device"{print $1; exit}')}"
[ -n "$SERIAL" ] || { echo "No adb device (check 'adb devices')."; exit 1; }

TUSER="${TERMUX_USER:-}"
if [ -z "$TUSER" ]; then
  uid=$(adb -s "$SERIAL" shell 'pm list packages -U 2>/dev/null' \
        | sed -n 's/.*com\.termux uid:\([0-9]\+\).*/\1/p' | head -1 | tr -d '\r')
  [ -n "$uid" ] || { echo "Couldn't detect Termux uid; set TERMUX_USER=u0_aNNN."; exit 1; }
  TUSER="u0_a$((uid-10000))"
fi

adb -s "$SERIAL" forward "tcp:$SSH_FWD" tcp:8022 >/dev/null
SSH=(ssh -p "$SSH_FWD" -o BatchMode=yes -o ConnectTimeout=10 -o ServerAliveInterval=20
     -o StrictHostKeyChecking=accept-new "$TUSER@localhost")

ts=$(date +%Y%m%d-%H%M)
out="$DEST/psg1-backup-$ts"; mkdir -p "$out"
echo "PSG1 backup ($TUSER) -> $out"

# --- proot-distro containers (created on-device, streamed to the jumpbox) -----
for c in $("${SSH[@]}" 'ls -1 $PREFIX/var/lib/proot-distro/containers/ 2>/dev/null'); do
  echo "  container $c (compressing on-device — may be slow for large rootfs)..."
  "${SSH[@]}" "proot-distro backup $c --output ~/.psgbk.tar.gz >/dev/null 2>&1" \
    && "${SSH[@]}" "cat ~/.psgbk.tar.gz" > "$out/proot-$c.tar.gz" \
    && "${SSH[@]}" "rm -f ~/.psgbk.tar.gz" \
    && echo "    -> proot-$c.tar.gz ($(du -h "$out/proot-$c.tar.gz" | cut -f1))" \
    || echo "    !! failed to back up $c"
done

# --- Termux home: keys + config, minus logs/cache ----------------------------
echo "  termux home (keys, config, wrapper)..."
"${SSH[@]}" 'cd ~ && tar czf - --exclude="*.log" --exclude=.cache --exclude=".psgbk.tar.gz" \
             --warning=no-file-changed .' > "$out/termux-home.tar.gz" 2>/dev/null
echo "    -> termux-home.tar.gz ($(du -h "$out/termux-home.tar.gz" | cut -f1))"

# --- VM disk image on the card -----------------------------------------------
if "${SSH[@]}" "test -f $CARD/alpine.qcow2" 2>/dev/null; then
  echo "  VM image (alpine.qcow2)..."
  "${SSH[@]}" "cat $CARD/alpine.qcow2" > "$out/alpine-vm.qcow2"
  echo "    -> alpine-vm.qcow2 ($(du -h "$out/alpine-vm.qcow2" | cut -f1))"
else
  echo "  (no VM image at $CARD/alpine.qcow2 — skipping)"
fi

# --- package list ------------------------------------------------------------
"${SSH[@]}" 'pkg list-installed 2>/dev/null' > "$out/termux-packages.txt"

# --- restore notes -----------------------------------------------------------
cat > "$out/README-restore.md" <<EOF
# PSG1 backup — $ts  (KEEP LOCAL: contains SSH private keys)

Restore (push the file to the device first, then run in Termux):
- proot container:  proot-distro restore proot-<name>.tar.gz   # destroys existing!
- termux home:      tar xzf termux-home.tar.gz -C ~
- VM image:         copy alpine-vm.qcow2 onto the SD card as alpine.qcow2
- packages:         xargs pkg install -y < termux-packages.txt  (or psg1_termux_setup.sh)
EOF

echo "done -> $out ($(du -sh "$out" | cut -f1))"
