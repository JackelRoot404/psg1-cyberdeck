#!/usr/bin/env bash
# PSG1 Linux VM — run a real, own-kernel Linux on the PSG1, off an SD card.
#
# Why a VM and not a flashed SD "boot disk":
#   The PSG1's RK3588S2 has an OTP-fused secure-boot key (PlaySolana's). The
#   BootROM rejects any loader/kernel not signed with that key, from ANY source
#   — eMMC, USB/MaskROM, or SD. So you cannot flash an SD and boot a custom OS
#   on the bare metal (see PSG1_NOTES.md "secure boot"). What you CAN do, with
#   no root and no unlock, is run a Linux guest with its own kernel in QEMU on
#   top of Android. The guest's disk image lives on the SD card, so the card
#   really does hold the OS — it's just booted by the hypervisor inside Android
#   instead of at power-on.
#
# Speed depends on whether the stock kernel exposes /dev/kvm:
#   * /dev/kvm present + usable -> hardware-accelerated, near-native (desktop-ok)
#   * otherwise                 -> TCG emulation: fine for a CLI/server Linux,
#                                  sluggish for a GUI. For a fast Linux DESKTOP
#                                  when there's no KVM, prefer proot-distro
#                                  Ubuntu + VNC instead (shares Android's kernel;
#                                  see PSG1_CYBERDECK_OPS.md).
#   This script auto-selects `-accel kvm:tcg`, so it runs either way.
#
# Run this IN TERMUX on a working PSG1 (not via the jumpbox — the VM runs on the
# device). NOTE: authored off-device; on first run verify the SD mount and the
# `ls -l /dev/kvm` result (the script prints both).
#
# Usage:
#   ./psg1_linux_vm.sh setup          # install deps, fetch image, create disk
#   ./psg1_linux_vm.sh run            # boot the VM (installer on first Alpine run)
#   ./psg1_linux_vm.sh run --no-cd    # boot from disk only (after install)
#   ./psg1_linux_vm.sh ssh            # ssh into the running guest
#   ./psg1_linux_vm.sh probe          # just report KVM / SD status
#
# Config via env:
#   DISTRO=alpine|debian   (default: alpine — tiny, boots fast even under TCG)
#   SD=/storage/XXXX-XXXX  (default: auto-detected)
#   VM_MEM=2048  VM_CPUS=4  DISK_GB=8   SSH_PORT=2222

set -euo pipefail

DISTRO="${DISTRO:-alpine}"
VM_MEM="${VM_MEM:-2048}"
VM_CPUS="${VM_CPUS:-4}"
DISK_GB="${DISK_GB:-8}"
SSH_PORT="${SSH_PORT:-2222}"

# Pinned image versions — bump these as newer releases land.
ALPINE_REL="3.20"
ALPINE_VER="3.20.3"
DEBIAN_CODENAME="bookworm"

log()  { printf '\033[1;36m[psg1-vm]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[psg1-vm]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[psg1-vm]\033[0m %s\n' "$*" >&2; exit 1; }

# --- locate the SD card ------------------------------------------------------
detect_sd() {
  [ -n "${SD:-}" ] && { echo "$SD"; return; }
  # Android mounts removable cards at /storage/XXXX-XXXX (a volume UUID).
  local c
  for c in /storage/*; do
    case "$(basename "$c")" in
      emulated|self|[0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f]-*) ;;
      *) continue ;;
    esac
    [ "$(basename "$c")" = "emulated" ] && continue
    [ "$(basename "$c")" = "self" ] && continue
    [ -w "$c" ] && { echo "$c"; return; }
  done
  return 1
}

# --- locate the aarch64 UEFI firmware qemu ships -----------------------------
find_uefi() {
  local f
  for f in \
    "$PREFIX/share/qemu/edk2-aarch64-code.fd" \
    "$PREFIX/share/qemu/QEMU_EFI.fd" \
    /usr/share/qemu/edk2-aarch64-code.fd; do
    [ -f "$f" ] && { echo "$f"; return; }
  done
  # last resort: search the qemu data dir
  f="$(find "$PREFIX/share/qemu" -maxdepth 1 -iname '*aarch64*code*.fd' 2>/dev/null | head -n1 || true)"
  [ -n "$f" ] && { echo "$f"; return; }
  return 1
}

kvm_status() {
  if [ -e /dev/kvm ] && [ -r /dev/kvm ] && [ -w /dev/kvm ]; then
    echo "usable"
  elif [ -e /dev/kvm ]; then
    echo "present-but-gated"
  else
    echo "absent"
  fi
}

probe() {
  log "SD card:   ${SD:-<not found>}"
  log "/dev/kvm:  $(ls -l /dev/kvm 2>/dev/null || echo 'absent')"
  case "$(kvm_status)" in
    usable)            log "-> FAST: hardware acceleration available (KVM)";;
    present-but-gated) warn "-> /dev/kvm exists but isn't accessible to this uid — will fall back to emulation (TCG). SELinux is permissive on the PSG1, so this is usually a Unix-permission gate, not SELinux.";;
    absent)            warn "-> SLOW: no KVM; QEMU will emulate (TCG). Fine for CLI Linux; for a fast desktop use proot-distro instead.";;
  esac
}

need_pkgs() {
  log "installing qemu + tools (idempotent)"
  pkg install -y qemu-system-aarch64-headless qemu-utils wget openssh xorriso >/dev/null 2>&1 \
    || pkg install -y qemu-system-aarch64-headless qemu-utils wget openssh xorriso
}

# --- per-distro asset fetch --------------------------------------------------
setup_alpine() {
  local iso="$SD/alpine-virt-$ALPINE_VER-aarch64.iso"
  local disk="$SD/alpine.qcow2"
  local url="https://dl-cdn.alpinelinux.org/alpine/v$ALPINE_REL/releases/aarch64/alpine-virt-$ALPINE_VER-aarch64.iso"
  [ -f "$iso" ]  || { log "downloading Alpine $ALPINE_VER"; wget -O "$iso" "$url"; }
  [ -f "$disk" ] || { log "creating $DISK_GB GB disk on SD"; qemu-img create -f qcow2 "$disk" "${DISK_GB}G"; }
  log "Alpine ready. First 'run' boots the installer ISO:"
  log "  at the login prompt type: root  (no password)"
  log "  then run: setup-alpine   (install target: /dev/vda, then poweroff)"
  log "  after install:  ./psg1_linux_vm.sh run --no-cd"
}

setup_debian() {
  local disk="$SD/debian-$DEBIAN_CODENAME-arm64.qcow2"
  local seed="$SD/seed.iso"
  local url="https://cloud.debian.org/images/cloud/$DEBIAN_CODENAME/latest/debian-12-generic-arm64.qcow2"
  [ -f "$disk" ] || { log "downloading Debian $DEBIAN_CODENAME cloud image"; wget -O "$disk" "$url"; qemu-img resize "$disk" "${DISK_GB}G"; }
  if [ ! -f "$seed" ]; then
    log "building cloud-init seed (user: psg1 / pass: psg1 — change after boot)"
    local d; d="$(mktemp -d)"
    cat >"$d/meta-data" <<EOF
instance-id: psg1-vm
local-hostname: psg1-linux
EOF
    cat >"$d/user-data" <<'EOF'
#cloud-config
users:
  - name: psg1
    sudo: ALL=(ALL) NOPASSWD:ALL
    groups: [sudo]
    lock_passwd: false
    plain_text_passwd: psg1
    shell: /bin/bash
ssh_pwauth: true
chpasswd: { expire: false }
EOF
    xorriso -as mkisofs -output "$seed" -volid cidata -joliet -rock "$d" >/dev/null 2>&1 \
      || die "seed build failed (need xorriso). Install it or use DISTRO=alpine."
    rm -rf "$d"
  fi
  log "Debian ready. 'run' boots straight to a login (psg1/psg1)."
}

# --- boot --------------------------------------------------------------------
run_vm() {
  local no_cd="${1:-}"
  local uefi; uefi="$(find_uefi)" || die "aarch64 UEFI firmware not found under \$PREFIX/share/qemu"
  local accel="kvm:tcg" cpu="max"
  [ "$(kvm_status)" = "usable" ] && { accel="kvm:tcg"; cpu="host"; }

  local -a args=(
    -accel "$accel" -M virt -cpu "$cpu" -smp "$VM_CPUS" -m "$VM_MEM"
    -bios "$uefi"
    -netdev "user,id=n0,hostfwd=tcp::${SSH_PORT}-:22"
    -device virtio-net-pci,netdev=n0
    -nographic
  )

  case "$DISTRO" in
    alpine)
      args+=(-drive "if=virtio,file=$SD/alpine.qcow2,format=qcow2")
      [ "$no_cd" != "--no-cd" ] && args+=(-cdrom "$SD/alpine-virt-$ALPINE_VER-aarch64.iso")
      ;;
    debian)
      args+=(-drive "if=virtio,file=$SD/debian-$DEBIAN_CODENAME-arm64.qcow2,format=qcow2")
      args+=(-drive "if=virtio,file=$SD/seed.iso,format=raw")
      ;;
    *) die "unknown DISTRO: $DISTRO (use alpine|debian)";;
  esac

  probe
  log "booting $DISTRO VM  (accel=$accel, ${VM_CPUS} vCPU, ${VM_MEM} MB)"
  log "ssh in from another Termux session:  ssh -p $SSH_PORT <user>@localhost"
  log "quit the VM console with:  Ctrl-a then x"
  exec qemu-system-aarch64 "${args[@]}"
}

# --- main --------------------------------------------------------------------
SD="$(detect_sd || true)"
[ -n "$SD" ] || warn "no writable SD card found under /storage — set SD=/storage/XXXX-XXXX"

case "${1:-run}" in
  probe) probe ;;
  setup)
    [ -n "$SD" ] || die "need an SD card for setup"
    need_pkgs
    case "$DISTRO" in alpine) setup_alpine;; debian) setup_debian;; *) die "unknown DISTRO: $DISTRO";; esac
    ;;
  run)
    [ -n "$SD" ] || die "need an SD card to run"
    run_vm "${2:-}"
    ;;
  ssh)
    exec ssh -p "$SSH_PORT" "${2:-root}@localhost"
    ;;
  *) die "usage: $0 {setup|run [--no-cd]|ssh [user]|probe}" ;;
esac
