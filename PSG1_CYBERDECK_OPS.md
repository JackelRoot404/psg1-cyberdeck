# PSG1 Cyberdeck — Operational Notes

How my PSG1 is configured day-to-day after the cyberdeck conversion. Companion to `PSG1_NOTES.md` (which covers the reverse-engineering side).

## Quick reference (substitute your own values for placeholders)

- **PSG1 LAN IP:** `<PSG1_LAN_IP>` (wlan0, DHCP)
- **PSG1 Tailscale IP:** `<PSG1_TS_IP>` (from your tailnet, 100.64.x.x/10)
- **ADB jumpbox:** `<jumpbox-user>@<jumpbox-ip>` — a small Linux box plugged into the PSG1 via USB, running adb + a keepalive script
- **Build:** `PlaySolana/PSG1/PSG1:15/AP4A.241205.013.C1/playsolana-...:user/dev-keys`
- **Private DNS:** `opportunistic` (NOT strict DoT — strict DoT clashes with Tailscale's MagicDNS and breaks app DNS via `PrivateDnsBroken` on the VPN agent)

## Termux

- ~250 packages installed natively (rust, node, python, nvim, tmux, htop, gh, ripgrep, fd, fzf, bat, eza, starship, zoxide, jq, gnupg, openssh, proot-distro, termux-api)
- **Termux user is `u0_a<N>`** for some N — randomized per install; check with `whoami`
- Sshd on **port 8022**, key auth only, password auth disabled
- Authorized keys: the SSH pubkeys for the jumpbox + my laptop
- **From the jumpbox:** `ssh -p 8022 u0_a<N>@<PSG1_LAN_IP>`
- **From anywhere via Tailscale:** `ssh -p 8022 u0_a<N>@<PSG1_TS_IP>`
- **Over adb, no LAN/tailnet needed:** `adb forward tcp:18022 tcp:8022` then `ssh -p 18022 u0_a<N>@localhost`. The jumpbox key must live in **Termux's** `~/.ssh/authorized_keys` (`/data/data/com.termux/files/home/.ssh/`), *not* a proot guest's home — an easy mix-up if you add the key from inside `proot-distro login`.
- **After `pkg upgrade`, restart sshd.** Upgrading openssh swaps the binary under the running daemon; the old sshd keeps listening but new connections die at `kex_exchange_identification: Connection closed` (socket accepted, no banner sent). Fix: `pkill sshd; sshd`.
- Auto-starts on **device reboot** via `~/.termux/boot/10-sshd` (needs Termux:Boot). After just-restarting the Termux app, run `sshd` manually.
- Wake lock via `~/.termux/boot/00-wakelock` so sshd survives doze

### Re-running the setup
```sh
bash /sdcard/psg1_termux_setup.sh
```
Idempotent — safe to run any time. Updates packages, fixes config drift, re-adds keys if removed.

### Quick package-name → binary-name reference (Termux gotcha)
| Package | Binary |
|---|---|
| openssh | sshd, ssh, ssh-keygen |
| ripgrep | rg |
| neovim | nvim |
| rust | rustc, cargo |
| termux-api | termux-battery-status, termux-clipboard-get, termux-vibrate, etc. |
| nodejs-lts | node, npm, npx |

## Claude Code CLI

- **The breakage:** Claude Code `v2.1.113+` stopped shipping as pure JavaScript and now installs a **glibc-native binary**. Termux is Android/**bionic** libc, so that binary won't run — `claude` dies with `Error: claude native binary not installed`. A routine `pkg upgrade` or `npm update -g` is enough to pull the broken build and "break" a previously-working CLI. (Tracked upstream: anthropics/claude-code#50270.)
- **Termux path (pinned pure-JS).** `2.1.112` is the last pure-JS release and runs natively in Termux. The setup script installs and pins it (§9); to repair by hand:
  ```sh
  npm uninstall -g @anthropic-ai/claude-code
  npm install -g @anthropic-ai/claude-code@2.1.112
  claude --version
  ```
  If `2.1.112` has aged out of the registry, run `npm view @anthropic-ai/claude-code versions` and pick the highest `2.1.11x` **below 113**.
- **Stop the silent re-break.** `export DISABLE_AUTOUPDATER=1` (added to `~/.bashrc` by the setup script) keeps the in-app updater from pulling a native build behind your back. Also don't run `npm update -g @anthropic-ai/claude-code`.
- **Current-version path (glibc via chroot).** To run an up-to-date Claude Code, install it inside the Ubuntu chroot, where glibc is available:
  ```sh
  proot-distro login ubuntu
  # inside ubuntu (needs node 18+; use nodesource/nvm if apt's node is too old):
  apt update && apt install -y nodejs npm
  npm install -g @anthropic-ai/claude-code
  claude
  ```
  Bind in your Termux storage for shared files: `proot-distro login ubuntu --bind /sdcard:/sdcard`.
- **Tradeoff:** pinned-in-Termux is one command and stays native, but freezes the version; the chroot stays current but adds the proot layer (heavier, separate filesystem).

## Installing & updating apps

On-device installers (F-Droid, Aurora, the package-installer UI) hit "Unknown apps can't be installed by this user" — the `no_install_unknown_sources` restriction on user 0. F-Droid can *download* updates but can't install them; everything goes through the jumpbox via the Echos-installer-spoof. Use the helper:
```sh
./psg1_install.sh <app.apk>                      # local file
./psg1_install.sh https://f-droid.org/F-Droid.apk   # or a URL (e.g. F-Droid self-update)
```
It pushes, runs `pm install -r -i com.playsolana.echos`, and cleans up. For split-APK / `.xapk` bundles, merge to a universal APK first (see `PSG1_NOTES.md` → "For multi-APK apps"). If Echos was uninstalled for user 0 the spoof fails — restore with `adb shell pm install-existing --user 0 com.playsolana.echos`.

## Shizuku

- Manager APK: `moe.shizuku.privileged.api` (gets disabled by Echos boot — see "Reboot survival" below)
- Server: `shizuku_server` PID under shell uid, started via the wireless-debugging trick or the in-app ADB starter
- Apps that want Shizuku must be granted on first request
- **After reboot:** Shizuku needs to be re-started since the device can't auto-start it from system context. Two options:
  1. Open Shizuku app → tap "Start"
  2. Set up the ADB-over-WiFi pairing trick once and let Shizuku auto-start

## Network

- **Tailscale owns the VPN slot** (NetGuard intentionally not enabled — Android only allows one VPN slot)
- MagicDNS routes inside tailnet via 100.100.100.100
- WireGuard installed for ad-hoc tunnels but won't run simultaneously with Tailscale

## Hardware — USB-C hub use

- USB Type-C 1.2 + USB-PD 3.0, dual role data, dual role power
- Kernel exposes `card0-DP-1` — DisplayPort over USB-C alt-mode IS supported by the SoC
- **What works without setup:**
  - Plug a USB-C hub with DP-alt → external HDMI/DP monitor lights up automatically
  - Plug a USB keyboard or mouse → recognized via standard HID, key layouts in `/system/usr/keylayout/`
  - Plug a USB mass storage device → mounted under `/storage/` (browse via Material Files)
- **Power:** hub with PD passthrough will charge the device while host-mode is active

## Useful one-liners (from the jumpbox)

```sh
# Status snapshot
ssh <jumpbox-user>@<jumpbox-ip> 'adb shell "ip -4 addr show wlan0; settings get global private_dns_specifier"'

# Open dev settings on device
ssh <jumpbox-user>@<jumpbox-ip> 'adb shell am start -n com.android.settings/.Settings\$DevelopmentSettingsActivity'

# Reboot the PSG1
ssh <jumpbox-user>@<jumpbox-ip> 'adb reboot'

# Once Termux sshd is up: reach it directly
ssh -p 8022 -J <jumpbox-user>@<jumpbox-ip> <termux-user>@<PSG1_LAN_IP>
ssh -p 8022 <termux-user>@<PSG1_TS_IP>     # via Tailscale, from anywhere
```

## Solana on PSG1

- **No native CLI.** Anza publishes only aarch64-apple-darwin and x86_64-linux-gnu binaries — no aarch64-unknown-linux-gnu. So `agave-install-init` 404s on both Termux native and inside the Ubuntu chroot.
- **JS SDK path instead.** The `solana-tools/` project in this repo — `wallet.mjs`
  on `@solana/kit` (v2). Runs in the Debian proot (or Termux); `npm install` then:
  ```sh
  node wallet.mjs new                            # create keypair, save to ./id.json (0600)
  node wallet.mjs show                           # show pubkey + balance
  node wallet.mjs address                        # print this wallet's address only
  node wallet.mjs balance <pubkey>               # balance for any address
  ```
  `SOLANA_RPC=` overrides the RPC (default mainnet-beta); `SOLANA_KEY=` the keyfile.
  Add `@solana-program/system` + `@solana/spl-token` + `bs58` when you move past
  keypairs/balances into building transactions. `@solana/kit`'s own
  `generateKeyPairSigner` makes non-extractable keys, so `new` mints an extractable
  Ed25519 key via WebCrypto to produce a savable 64-byte `id.json`.
- RPC defaults to `https://api.mainnet-beta.solana.com`; override with `SOLANA_RPC=...`
- Keyfile defaults to `./id.json`; override with `SOLANA_KEY=...`

If you ever want the CLI: cargo-build from source inside the Ubuntu chroot is the only path, and it's a long heavy build that may OOM on a phone.

## Ubuntu chroot (proot-distro)

- Ubuntu 26.04 LTS installed: `proot-distro login ubuntu`
- Runs as root inside; full apt available
- Use for: anything that needs glibc, cargo-builds of x86-only crates, Anza source builds, etc.

## Running your own Linux (VM, own kernel)

The PSG1 can't boot a custom OS on bare metal — the OTP-fused secure boot rejects
any non-PlaySolana-signed loader from *any* source, SD card included (see
`PSG1_NOTES.md` → "secure boot"). What works instead: run a real Linux **guest
with its own kernel** in QEMU on top of Android, no root and no unlock. The
guest disk image lives on an SD card, so the card genuinely holds the OS — it's
just booted by the hypervisor inside Android rather than at power-on.

Helper: **`psg1_linux_vm.sh`** (runs in Termux on the PSG1). **Invoke it with
`bash`, not `./`** — the SD card is mounted `noexec` and Termux has no
`/usr/bin/env` (the script's shebang), so `./psg1_linux_vm.sh` fails with a
misleading `no such file or directory`. Also pass `SD=` explicitly: scoped storage
hides `/storage` from the app, so the script's auto-detect can't enumerate it.

```sh
SD=/storage/XXXX-XXXX bash /storage/XXXX-XXXX/psg1_linux_vm.sh run        # boot pre-installed Alpine -> root shell
SD=/storage/XXXX-XXXX bash /storage/XXXX-XXXX/psg1_linux_vm.sh ssh        # ssh in (your Termux key, or root/root)
SD=/storage/XXXX-XXXX bash /storage/XXXX-XXXX/psg1_linux_vm.sh probe      # report SD + KVM status
SD=/storage/XXXX-XXXX bash /storage/XXXX-XXXX/psg1_linux_vm.sh run --install  # attach ISO to (re)install
```

That's a mouthful, so drop a one-line wrapper in Termux home (which *is* exec-friendly):
```sh
printf '#!%s/bin/bash\nexport SD="${SD:-/storage/XXXX-XXXX}"\nexec bash /storage/XXXX-XXXX/psg1_linux_vm.sh "$@"\n' "$PREFIX" > ~/vm
chmod +x ~/vm
# then just:  ~/vm run  |  ~/vm ssh  |  ~/vm probe
```

- Defaults to **Alpine** (tiny, boots fast even emulated). `DISTRO=debian` for a
  cloud-image Debian instead. Override `SD=`, `VM_MEM=`, `VM_CPUS=`, `DISK_GB=`.
- **Speed hinges on `/dev/kvm`.** The script auto-selects `-accel kvm:tcg`:
  - `/dev/kvm` usable → hardware-accelerated, near-native (desktop-capable).
  - no KVM → TCG emulation: fine for a CLI/server Linux, sluggish for a GUI.
- **Confirmed on this unit (2026-07):** `/dev/kvm` is **absent** and `CONFIG_KVM`
  is **not built** into the `6.1.115-abplaysolana` kernel (only `CONFIG_HAVE_KVM`,
  the arch capability). So QEMU here is **TCG-only** — no acceleration, even for
  same-arch aarch64-on-aarch64 (TCG has no same-arch fast path; that speed comes
  from KVM). Boots a CLI Alpine fine, far too slow for a desktop. Root is
  unreachable (OTP secure boot), so the kernel can't be rebuilt to add KVM.
  → For anything interactive use the **GUI desktop over VNC** (below); keep QEMU
  for when you specifically need a *separate* kernel.
- **Measured TCG cost (Alpine `virt`, `-cpu max`, 4 vCPU / 2 GB, 2026-07):**
  boot-to-login **196 s** (~3m16s) vs single-digit seconds on KVM/native — and the
  first ~50 s of that is UEFI + GRUB alone (firmware emulation is the worst case).
  Pure CPU is ~**15×**: SHA-256 of 100 MB took **121 ms native vs 1885 ms under
  TCG** (qemu-user, same A76). Fine for a CLI / kernel sandbox; miserable as a
  daily driver — which is why proot is the everyday path.
- **The shipped disk is pre-installed + autologin.** `alpine.qcow2` on the card is
  a finished Alpine `sys` install, **built on an aarch64 KVM host** (seconds; a TCG
  install on-device would be brutal — that's why we don't do it on the PSG1). It
  **autologins to a root shell** on the serial console — `inittab` runs
  `ttyAMA0::respawn:/bin/login -f root` (busybox `getty` has no `-a`, so `login -f`
  is the way; `root/root` is set too). A removable-path UEFI loader
  (`/EFI/BOOT/BOOTAA64.EFI`) is added so it boots under the PSG1's `-bios` without
  an NVRAM entry. On-device it boots straight to a shell in **~175 s** (TCG):
  `~/vm run` (via the wrapper above — the card is `noexec`, so it must be run with
  `bash`, not `./`). `run --install` re-attaches the ISO for a fresh build.
- **SSH into it:** the image has `openssh` enabled at boot with `eth0` on DHCP, so
  once it's up, `~/vm ssh` (i.e. `ssh -p 2222
  root@localhost` from Termux — the guest's :22 is host-forwarded to the device's
  localhost:2222) lands a root shell. Key auth for the jumpbox + Termux keys,
  `root/root` as a password fallback. Reachable ~100–175 s after `run`.
- **The SD card is shared into the VM at `/mnt/card`.** The launcher adds a
  virtio-9p passthrough (`-virtfs local,path=$SD,mount_tag=card,security_model=none`),
  and the image auto-mounts it at boot via `/etc/local.d/card.start` (which does
  `modprobe 9pnet_virtio 9p; mount -t 9p -o trans=virtio,version=9p2000.L card
  /mnt/card`). So the 231 GB card is one shared workspace across Android, the proot
  desktop (`/mnt/card` there too), and the VM — a file written in one shows up in
  the others. (It also exposes the VM's own `alpine.qcow2` under `/mnt/card`; don't
  write to that file from inside the guest.)
- **`-accel` fix:** the script shipped with `-accel kvm:tcg`, which QEMU rejects
  (`invalid accelerator`) — the `kvm:tcg` colon-fallback is only valid with
  `-machine accel=`. It now selects `-accel kvm` (if `/dev/kvm` is usable) or
  `-accel tcg`. Before this, `run` never actually started on the PSG1.
- **`SD=` must be set explicitly.** The script's `detect_sd` globs `/storage/*`,
  but Android scoped storage won't let the app *list* `/storage` even with
  all-files access (direct paths like `/storage/F230-402C` work fine). So run e.g.
  `SD=/storage/XXXX-XXXX bash /storage/XXXX-XXXX/psg1_linux_vm.sh run` (or use the
  `~/vm` wrapper above, which presets it).
- **The card must be FAT32 — this kernel has no exFAT.** `CONFIG_EXFAT_FS` is
  **not set** in the `6.1.115-abplaysolana` kernel (only `CONFIG_VFAT_FS`), so an
  exFAT card enumerates but Android reports it `unmountable` (`sm list-volumes`).
  FAT32's **4 GB per-file cap** then constrains the VM disk: create the qcow2 at
  **≤3 GB** (`DISK_GB=3` — a CLI Alpine needs ~1–2 GB) so it can't grow past the
  cap, or keep the disk on internal storage instead. Reformat on the jumpbox:
  `sudo mkfs.vfat -F 32 -n PSG1SD /dev/sdX1`, then stage the Alpine ISO +
  `alpine.qcow2` + `psg1_linux_vm.sh` and move the card to the PSG1. (Android
  can only mount vfat/exfat for *portable* storage; with exfat out, vfat it is.)
- The `~119 GB eMMC` is tight; keep VM disks on the SD (the script does this).

## GUI desktop over VNC

A full Linux **desktop on the deck**, viewed from the jumpbox. It runs in a
proot-distro guest (Debian 13 here), so it **shares Android's kernel** — no VM,
no emulation, native A76 speed. Given there's no KVM (above), this is the only
way to get a *usable* GUI; QEMU's emulated framebuffer is unusably slow.

Stack: XFCE + TigerVNC inside the guest, bound to loopback, tunnelled to the
jumpbox over adb, viewed with any VNC client.

One-time setup, inside the guest (`proot-distro login debian`):
```sh
apt update && apt install -y --no-install-recommends \
  xfce4 xfce4-terminal xfce4-settings dbus-x11 dbus \
  tigervnc-standalone-server tigervnc-common fonts-dejavu-core x11-xserver-utils
```

Then, from the jumpbox, one command brings it up and opens a viewer:
```sh
./psg1_desktop.sh                 # ensure server up, tunnel :5901, launch viewer
GEOM=1920x1080 ./psg1_desktop.sh  # pick a resolution
```
The helper idempotently writes the guest's `~/.config/tigervnc/xstartup`, starts
`tigervncserver :1` inside a **tmux** session, `adb forward`s 5901 to the jumpbox,
and launches `xtigervncviewer`. To connect by hand once it's up:
`xtigervncviewer -SecurityTypes None localhost:5901`.

Gotchas learned the hard way:
- **TigerVNC ≥1.13 (Debian 13) moved config to `~/.config/tigervnc/`.** If a
  legacy `~/.vnc/` exists but `~/.config/tigervnc/` doesn't, *every*
  `tigervncserver` call — even `--version` — aborts with "Could not migrate …".
  Fix: create `~/.config/tigervnc/`, put `xstartup` there, delete `~/.vnc/`.
- **No password is fine** because the server binds `-localhost yes` (loopback
  only) and is reachable solely through the adb/ssh tunnel — never exposed on
  wlan0 or the tailnet.
- **tmux keeps it alive.** `tigervncserver` daemonises Xvnc as a child of the
  proot login; when that login returns, proot reaps it. The start script ends
  with `exec sleep infinity` inside a tmux session so the proot — and Xvnc —
  survive the login returning and any SSH drop.
- **Not reboot-persistent.** The desktop lives in a Termux tmux session; after a
  reboot or Termux being killed, just re-run `psg1_desktop.sh`.

### Sharing the SD card into Debian

`psg1_desktop.sh` auto-detects a mounted SD card (`/storage/XXXX-XXXX`) and binds
it into the guest at **`/mnt/card`**, so the desktop, the CLI, and the QEMU VM
all share the 231 GB card. For a plain login: `proot-distro login debian --bind
/storage/XXXX-XXXX:/mnt/card`.

Prerequisite — Android scoped storage blocks apps from `/storage` by default, so
the proot (running as the Termux uid) can't see the card until Termux is granted
broad storage access **and restarted**:
- Grant all-files access: `adb shell appops set com.termux MANAGE_EXTERNAL_STORAGE
  allow` (or Settings → Apps → Termux → Permissions → Files → all files). The SD
  *root* needs all-files access; `READ_EXTERNAL_STORAGE` alone only reaches
  `/storage/emulated/0`.
- **Then fully restart Termux** — swipe it from recents, reopen, `sshd`. The
  per-app storage mount is set at process-fork time, so a running Termux won't
  see the card until the whole app process restarts; `pkill sshd; sshd` is not
  enough (that child inherits the old mount namespace). Persists across reboots
  once granted.

## Backing up the deck

The scripts and docs here are in git, but the **hand-built device state is not**:
the proot Debian desktop, the Kali container, Termux's keys/config, and the VM
image all live on the PSG1's eMMC/SD and would be lost on a wipe or eMMC failure.
**`psg1_backup.sh`** (jumpbox) snapshots all of it:

```sh
./psg1_backup.sh                 # -> ~/psg1-backups/psg1-backup-<ts>/
DEST=/mnt/somewhere ./psg1_backup.sh
```

It pulls every proot-distro container (via `proot-distro backup`), the Termux
home (SSH keys, `.termux/`, `~/vm`), the SD-card VM image, and the package list,
and drops a `README-restore.md`. Compression happens on-device, so large
containers are slow — a multi-GB Kali can take 20-30 min.

**Keep the output local — it contains SSH private keys.** Do not commit it or push
it to the `pi-config-backups` repo (that one is redacted configs only).

Restore (push a file to the device, then run in Termux):
- container: `proot-distro restore proot-<name>.tar.gz` (destroys the existing one)
- home:      `tar xzf termux-home.tar.gz -C ~`
- VM image:  copy `alpine-vm.qcow2` onto the card as `alpine.qcow2`
- packages:  `xargs pkg install -y < termux-packages.txt` (or re-run `psg1_termux_setup.sh`)

## Reboot survival

> **Measured 2026-07-15**, the first time the cycle was ever actually exercised. Everything
> below that says "measured" was observed; everything that says "assumed" is inherited from
> earlier sessions and did **not** reproduce. Several long-standing claims in this section
> turned out to be wrong — they're called out rather than quietly deleted, because the wrong
> model shaped the whole design.

### The unlock gate (measured — this dominates everything)

The deck has a **lock credential** and file-based encryption (`ro.crypto.type=file`). Termux
is **not** direct-boot aware, so its home — including the `~/.bashrc` sshd guard — lives in
credential-encrypted storage that does not exist until the first manual unlock. `BOOT_COMPLETED`
is likewise withheld until then. Check with `getprop sys.user.0.ce_available` and
`dumpsys user | grep RUNNING_UNLOCKED` (**not** `ls /data/user/0/com.termux` — the shell gets
"Permission denied" whether locked or not, so that probe reads "locked" always and proves nothing).

**Consequence: after a reboot, nothing brings sshd back until a human unlocks the deck.** No
jumpbox, no network adb, and no amount of `am start` can cross that line. Since unlocking means
physically holding the deck — at which point sshd returns on its own in seconds — **autonomous
untethered post-reboot recovery is not achievable on this device while a lock credential is set.**
That is a property of the platform, not a bug to fix.

### What actually happened (measured)

```
17:59:24  reboot issued
17:59:49  adbd back (6s). persist.adb.tcp.port survived; adbd listening on 5555.
          WiFi rejoined unaided, same IP, no DHCP drift.
18:00:01  keepalive tick: "cold-starting Termux" — no effect, device locked
          ... deck sits at keyguard. sshd down. ALL PACKAGES STILL ENABLED ...
18:03:18  manual unlock          <-- the hard gate
18:03:20  BOOT_COMPLETED -> Termux:Boot starts -> runs start-sshd.sh
18:03:31  sshd listening (13s after unlock). The keepalive contributed nothing.
```

### Claims that did not survive the test

- ~~"SvalGuard re-disables the packages on *every* boot"~~ — **it disabled nothing, and it was
  never the culprit.** See "SvalGuard was misidentified" below. All five packages stayed
  `enabled=1`, `always_on_vpn_app` survived, and logcat shows no `setEnabledSetting` calls and no
  SvalGuard log lines at all.
- ~~"Termux:Boot can't fire — it's disabled during the boot window"~~ — **it fired and did the
  entire recovery**, executing `start-sshd.sh` 2s after unlock. It only can't fire on boots where
  SvalGuard actually disables it.
- ~~"After a reboot, sshd self-recovers within ≤5 min"~~ — it recovers **13s after a manual
  unlock**, via Termux:Boot, not the keepalive. Without the unlock it never recovers at all.
- ~~"Heals the deck after a reboot even undocked"~~ — see the unlock gate: impossible in principle,
  and it was also broken in practice (see the adb bugs below).

**Tailscale did not come back** after the reboot: `tun0` had no address 15 min later despite the
package being enabled and `always_on_vpn_app` set to it. So the tailnet endpoint is a black hole
after every reboot — it likely needs the app opened by hand. Do not rely on it for recovery.

### SvalGuard was misidentified (investigated 2026-07-16)

**`vendor.playsolana.svalguard-service` is the Solana Seed Vault's key-custody HAL. It has nothing
to do with disabling packages.** The evidence:

- `/vendor/etc/init/svalguard-default.rc` declares it `class hal`, exposing the AIDL interface
  `vendor.playsolana.svalguard.IPlaySolanaSvalGuard/default`. A HAL waits on binder calls; it
  doesn't roam around calling `pm`.
- Its own strings are `IPlaySolanaSvalGuard::hash`, `Invalid signature size`, **`Invalid mnemonic
  size`**, `Invalid public key size`. A *mnemonic* is a BIP-39 seed phrase — this thing holds the
  wallet seed. "SvalGuard" is almost certainly *Seed VAuLt Guard*.
- The `/system/priv-app/SvalguardApp/SvalguardApp.apk` beside it is `com.solanamobile.seedvaultimpl`.
- It contains **zero** references to any package in the alleged kill list.

**How the misidentification happened:** by elimination plus a suggestive name — no app held
`CHANGE_COMPONENT_ENABLED_STATE`, therefore the disabler must be native, therefore it must be the
native PlaySolana daemon with "Guard" in its name. That accused the wallet's key custody service.

**`lastDisabledCaller` is a dead end.** Every kill-list package reads `shell:1000`, which looks
like a system-uid culprit — but a `pm disable-user` typed at an adb prompt (uid 2000) produces the
*same* string, because `cmd package` executes inside system_server (uid 1000). It records "someone
used `pm`", not who. Verified with a deliberate control.

**There may be no boot-time disabler at all.** Searching `/vendor`, `/system/bin`, `/system/etc`
and `/system/priv-app` for `com.termux`, `com.tailscale.ipn` and `moe.shizuku.privileged.api`
returns **zero files**. `playsolana_setup` (a root oneshot, the one component that plausibly could)
has 41 strings total, none package-related.

**The parsimonious explanation that fits every observation:** the packages were disabled *once*, by
a human or agent via `pm disable-user`, and stayed disabled — persistent state, exactly as designed.
"Still disabled after each reboot" was then read as "re-disabled at each boot", and the hunt for a
boot-time culprit followed from there. Once they were genuinely enabled, they stayed enabled across
the measured reboot.

**Caveats — this is not proof.** One boot; a negative can't be proven; the search didn't cover
`/system/app`, `/system/framework`, `/product` or `/system_ext`; `/data/vendor/svalguard` is
unreadable (0700 system); and a stripped binary could build strings at runtime. **Keep the keepalive**
— it's cheap insurance and harmless when idle. But treat "a vendor daemon fights us every boot" as
**unsupported**, and don't build anything else on it. A second reboot would firm this up.

### What the keepalive is actually for

Not post-reboot self-heal — the unlock gate owns that. It's a **safety net for boots where
SvalGuard does disable things** (which is how this project started, so it evidently happens),
and for re-asserting `always_on_vpn_app` / `private_dns_mode` if they get cleared. On a boot like
the one measured, it is a no-op and Termux:Boot does the work.

**Keepalive (`psg1_keepalive.sh`, jumpbox, every 5 min via cron):** re-enables the packages,
re-asserts `always_on_vpn_app` + `private_dns_mode`, and — once `com.termux` is back — cold-starts
Termux with `am start` whenever sshd isn't listening. Silent on no-op.

**Cron runs a copy under `~/bin`, never the git tree.** Install/refresh it with `./psg1_keepalive_install.sh`:

```crontab
PATH=/usr/local/bin:/usr/bin:/bin
*/5 * * * * PSG1_ADB_TARGETS="192.168.2.32:5555 100.64.30.85:5555" timeout 240 /home/pi/bin/psg1_keepalive.sh >>/home/pi/psg1_keepalive.log 2>&1
```

The explicit `PATH=` matters — cron's default environment is too bare to find `adb`. An empty `psg1_keepalive.log` is the healthy state; it only writes when it actually repairs something.

Pointing cron into the working tree would mean the live keepalive silently follows whatever branch is checked out — check out an older branch to look at something and the deck quietly loses its fixes for as long as you're there. (A symlink doesn't help: it resolves back into the tree.) The cost of a copy is that it can go stale, so the installed file is stamped with the commit it came from and drift is detectable:

```sh
./psg1_keepalive_install.sh           # install or refresh after editing the repo
./psg1_keepalive_install.sh --check   # in sync with the repo? prints the source commit
head -3 ~/bin/psg1_keepalive.sh       # what's actually running, and from where
```

**After changing `psg1_keepalive.sh`, re-run the installer — otherwise cron keeps running the old copy.**

**Off the cable (network adb).** The keepalive reaches the deck over USB *or the network*. Enable persistent network adb on the deck once — `adb shell setprop persist.adb.tcp.port 5555` — which survives reboots (measured: adbd was listening on 5555 six seconds after boot, key-authorized).

**What this is not.** It does *not* buy untethered post-reboot recovery — the unlock gate above forecloses that, and network adb cannot unlock a device. It's useful for reaching the deck undocked *while it's already unlocked and running*, and for re-enabling packages remotely. It is not a recovery channel for a rebooted deck.

- **The tailnet endpoint is a black hole after a reboot** (measured) — Tailscale doesn't come back on its own, so `100.64.x.y:5555` doesn't route. Keeping it in `PSG1_ADB_TARGETS` is harmless now only because connects are bounded; before that it hung every tick for >2 min.
- **Security:** this opens a reboot-persistent, network-reachable adb port. It's gated by adb key auth (only authorized hosts connect; anyone else just gets an ignored prompt), but with no root we can't firewall it to only Tailscale — it listens on all interfaces. Fine on a trusted LAN/tailnet; a small surface on hostile WiFi. Revert with `setprop persist.adb.tcp.port -1` + reboot.

**Two jumpbox-side adb bugs the reboot test found** (both fixed in `psg1_keepalive.sh`; neither was findable by reading the script):

1. **Stale transports are permanent.** After the deck reboots, its TCP transport goes `offline` and stays there. `adb connect` answers *"already connected"*; `adb disconnect` + `adb connect` answers the same; `adb reconnect offline` says *"reconnecting"* and changes nothing. **Only `adb kill-server` clears it.** The keepalive's own connects during the boot window create these, so every real reboot poisoned the server and the network path silently did nothing, forever. The script now restarts the adb server when nothing live is found but offline entries exist.
2. **`adb connect` hangs >2 min** on an address that black-holes rather than refusing — exactly the tailnet endpoint's post-reboot state. Every tick burned minutes and cron stacked them. All connects are now bounded (`PSG1_CONNECT_TIMEOUT`, default 5s), and cron wraps the script in `timeout 240` as a backstop.

**Field recovery is the real answer.** You have to unlock the deck by hand anyway, so: unlock → if sshd isn't back in ~15s, Settings → Apps → enable **Termux** → open it (`~/.bashrc` restarts sshd) → open **Tailscale**, Connect. Keeping the deck charged avoids the involuntary reboot that starts all this.

**Finding the deck (three steps).** The keepalive locates the deck in this order, so a moved lease isn't fatal:
1. **USB** — auto-detected whenever docked, and preferred when present.
2. **`PSG1_ADB_TARGETS`** — the explicit endpoints above, tried first on the network.
3. **Discovery** — if neither answers, it ping-sweeps the local /24s to populate the neighbour table, matches the deck's **WiFi MAC**, and connects to whatever IP that MAC now holds. This survives DHCP drift, a router reset, or the deck joining a new network. Disable with `PSG1_DISCOVER=0`.

A DHCP reservation for the deck is therefore a *nice-to-have* rather than load-bearing — discovery covers the drift. Reserve it anyway if you want step 2 to keep hitting on the first try (deck MAC `78:be:81:2a:28:1a`, hostname `PSG1`); DHCP here is served by the router, not by pi2-zero's Pi-hole.

- **Identity, not address.** An `ip:port` is an address, not an identity — a lease can move and leave *someone else's* device answering on `:5555`. Every network transport is checked against the deck's serial (`ro.serialno`) before the keepalive touches it, and disconnected with a log line if it doesn't match. Without that gate, a stale `PSG1_ADB_TARGETS` entry could have it running `pm enable` against a stranger's phone. USB transports are self-identifying (the transport name *is* the serial). Override the expected serial with `PSG1_SERIAL` if the deck is ever replaced.
- **MAC randomisation.** Android randomises its MAC per-SSID by default, so the baked-in `PSG1_MAC` is only valid on the network it was read on. On a new SSID, read the deck's MAC there (`adb shell cat /sys/class/net/wlan0/address`) and pass it via `PSG1_MAC`.
- Discovery only sweeps `/24`s, so the tailnet (a `/32`) is never swept.

The explicit `PATH=` matters — cron's default environment is too bare to find `adb`. The `timeout 240` is a backstop: an adb call that hangs must never let cron stack ticks (it did, before connects were bounded).

## What is NOT done

- Root — not possible (OTP-fused secure boot; see `PSG1_NOTES.md`)
- NetGuard firewalling — gave up the VPN slot to Tailscale instead
- External monitor: only verified the kernel claims DP-alt support; no hub plugged in yet to confirm hand-off
- Native solana-cli — see Solana section above; JS SDK is the supported path
- **Identifying the boot-time disabler — reopened, and it may not exist.** SvalGuard was misidentified (it's the Seed Vault key HAL; see "Reboot survival"). No vendor file references the kill-list packages, and the measured boot disabled nothing. The premise the keepalive was built on is unsupported. Not closed, because a negative can't be proven and the search wasn't exhaustive.
- **Autonomous untethered post-reboot recovery — not achievable, closed.** The lock credential + FBE means Termux's storage and `BOOT_COMPLETED` are gated on a manual unlock, which no jumpbox can perform. Removing the lock credential would allow it, at an obvious opsec cost on a deck you carry. Not a bug; a platform property.
- **The undocked (Phase 2) reboot test has not been run** — the docked one was (2026-07-15). So the stale-transport fix is written and reasoned but not yet exercised against a real reboot, and MAC discovery has never run in its actual scenario.
- **Why Tailscale doesn't come back after a reboot** — `tun0` had no address 15 min post-boot despite the package being enabled and `always_on_vpn_app` set. Unexplained; probably needs the app opened once by hand.
- DHCP reservation for the deck — not set (router at `192.168.2.1` serves DHCP; needs the operator's admin login). Discovery makes this non-critical, and the deck kept its lease across the measured reboot anyway.
