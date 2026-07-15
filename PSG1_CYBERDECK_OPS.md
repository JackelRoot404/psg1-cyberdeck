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

Helper: **`psg1_linux_vm.sh`** (run it in Termux on a working PSG1):

```sh
./psg1_linux_vm.sh probe            # report SD mount + KVM status
./psg1_linux_vm.sh setup            # install qemu, fetch image, make disk on SD
./psg1_linux_vm.sh run              # boot (Alpine installer on first run)
./psg1_linux_vm.sh run --no-cd      # boot from disk after install
./psg1_linux_vm.sh ssh              # ssh into the guest
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
- **`SD=` must be set explicitly.** The script's `detect_sd` globs `/storage/*`,
  but Android scoped storage won't let the app *list* `/storage` even with
  all-files access (direct paths like `/storage/F230-402C` work fine). So run e.g.
  `SD=/storage/XXXX-XXXX ./psg1_linux_vm.sh run`.
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

## Reboot survival

**WARNING:** PlaySolana firmware disables `com.termux`, `com.termux.boot`, `com.tailscale.ipn`, `moe.shizuku.privileged.api`, `app.lawnchair`, and more at every reboot. Disabled apps don't receive `BOOT_COMPLETED` → sshd won't start → device boots into "remotely unusable" state without intervention.

**Mitigation:** Keepalive script (`psg1_keepalive.sh`, in the repo) on the jumpbox runs every 5 min via cron: re-enables disabled packages, re-asserts `always_on_vpn_app` + `private_dns_mode`, and — once `com.termux` is back — cold-starts Termux with `am start` whenever sshd isn't listening. The cold start opens a fresh login session that sources `~/.bashrc`, whose guard line restarts `sshd`. Net effect: **after a reboot, sshd self-recovers within ≤5 min, no manual step.** (Termux:Boot's `10-sshd` still can't fire — the package is disabled during the boot window — so this `am start` path is what actually brings sshd back.) Silent when no action needed.

**Worst case (jumpbox itself down + PSG1 rebooted):** the auto-recovery can't run, so fall back to manual — open Termux on the device, run `sshd`, then open Tailscale and tap Connect. After that the jumpbox is reachable again.

## What is NOT done

- Root — not possible (OTP-fused secure boot; see `PSG1_NOTES.md`)
- NetGuard firewalling — gave up the VPN slot to Tailscale instead
- External monitor: only verified the kernel claims DP-alt support; no hub plugged in yet to confirm hand-off
- Native solana-cli — see Solana section above; JS SDK is the supported path
- Pinpointing the boot-time package disabler — works around it with the keepalive
