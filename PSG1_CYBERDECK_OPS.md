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

**What disables things:** a native system daemon, **`vendor.playsolana.svalguard-service`** (SvalGuard), re-disables `com.termux`, `com.termux.boot`, `com.tailscale.ipn`, `moe.shizuku.privileged.api`, `app.lawnchair` and friends on *every* boot — which is why `pm enable` doesn't stick. No app on the device holds `CHANGE_COMPONENT_ENABLED_STATE`, so it's enforced below the app layer. It **can't be neutralised without root** (OTP-fused bootloader → no root), and every candidate on-device auto-recovery helper (Termux:Boot, Shizuku) is *itself* in the kill list — so a fully autonomous **on-device** self-heal isn't possible here. The keepalive is the workaround.

**Keepalive (`psg1_keepalive.sh`, jumpbox, every 5 min via cron):** re-enables the disabled packages, re-asserts `always_on_vpn_app` + `private_dns_mode`, and — once `com.termux` is back — cold-starts Termux with `am start` whenever sshd isn't listening (the fresh login sources `~/.bashrc`, whose guard restarts `sshd`; Termux:Boot can't fire since the package is disabled during the boot window). Silent on no-op. **After a reboot, sshd self-recovers within ≤5 min.**

**Cron runs a copy under `~/bin`, never the git tree.** Install/refresh it with `./psg1_keepalive_install.sh`:

```crontab
PATH=/usr/local/bin:/usr/bin:/bin
*/5 * * * * PSG1_ADB_TARGETS="192.168.2.32:5555 100.64.30.85:5555" /home/pi/bin/psg1_keepalive.sh >>/home/pi/psg1_keepalive.log 2>&1
```

The explicit `PATH=` matters — cron's default environment is too bare to find `adb`. An empty `psg1_keepalive.log` is the healthy state; it only writes when it actually repairs something.

Pointing cron into the working tree would mean the live keepalive silently follows whatever branch is checked out — check out an older branch to look at something and the deck quietly loses its fixes for as long as you're there. (A symlink doesn't help: it resolves back into the tree.) The cost of a copy is that it can go stale, so the installed file is stamped with the commit it came from and drift is detectable:

```sh
./psg1_keepalive_install.sh           # install or refresh after editing the repo
./psg1_keepalive_install.sh --check   # in sync with the repo? prints the source commit
head -3 ~/bin/psg1_keepalive.sh       # what's actually running, and from where
```

**After changing `psg1_keepalive.sh`, re-run the installer — otherwise cron keeps running the old copy.**

**Off the cable (untethered keepalive).** The keepalive reaches the deck over USB *or the network*. Enable persistent network adb on the deck once — `adb shell setprop persist.adb.tcp.port 5555` — which survives reboots (a system-level adb setting SvalGuard doesn't touch; adbd then listens on TCP:5555 at every boot, key-authorized). Then point the keepalive at it: `PSG1_ADB_TARGETS="<deck-lan-ip>:5555 <deck-tailnet-ip>:5555"`. Now it heals the deck after a reboot even undocked, as long as the jumpbox can reach it.
- **Post-reboot recovery goes over the LAN endpoint** — Tailscale is disabled on boot, so the tailnet endpoint can't reach the deck until the LAN path re-enables it first.
- **Security:** this opens a reboot-persistent, network-reachable adb port. It's gated by adb key auth (only authorized hosts connect; anyone else just gets an ignored prompt), but with no root we can't firewall it to only Tailscale — it listens on all interfaces. Fine on a trusted LAN/tailnet; a small surface on hostile WiFi. Revert with `setprop persist.adb.tcp.port -1` + reboot.

**Finding the deck (three steps).** The keepalive locates the deck in this order, so a moved lease isn't fatal:
1. **USB** — auto-detected whenever docked, and preferred when present.
2. **`PSG1_ADB_TARGETS`** — the explicit endpoints above, tried first on the network.
3. **Discovery** — if neither answers, it ping-sweeps the local /24s to populate the neighbour table, matches the deck's **WiFi MAC**, and connects to whatever IP that MAC now holds. This survives DHCP drift, a router reset, or the deck joining a new network. Disable with `PSG1_DISCOVER=0`.

A DHCP reservation for the deck is therefore a *nice-to-have* rather than load-bearing — discovery covers the drift. Reserve it anyway if you want step 2 to keep hitting on the first try (deck MAC `78:be:81:2a:28:1a`, hostname `PSG1`); DHCP here is served by the router, not by pi2-zero's Pi-hole.

- **Identity, not address.** An `ip:port` is an address, not an identity — a lease can move and leave *someone else's* device answering on `:5555`. Every network transport is checked against the deck's serial (`ro.serialno`) before the keepalive touches it, and disconnected with a log line if it doesn't match. Without that gate, a stale `PSG1_ADB_TARGETS` entry could have it running `pm enable` against a stranger's phone. USB transports are self-identifying (the transport name *is* the serial). Override the expected serial with `PSG1_SERIAL` if the deck is ever replaced.
- **MAC randomisation.** Android randomises its MAC per-SSID by default, so the baked-in `PSG1_MAC` is only valid on the network it was read on. On a new SSID, read the deck's MAC there (`adb shell cat /sys/class/net/wlan0/address`) and pass it via `PSG1_MAC`.
- Discovery only sweeps `/24`s, so the tailnet (a `/32`) is never swept.

**Field recovery (no jumpbox reachable at all).** You're holding the deck, so: Settings → Apps → enable **Termux** and **Tailscale** → open Termux, run `termux-wake-lock; sshd` → open Tailscale, Connect. A minute of taps and it's back. Dead battery is the main *involuntary* reboot trigger, so keeping it charged avoids the whole thing.

## What is NOT done

- Root — not possible (OTP-fused secure boot; see `PSG1_NOTES.md`)
- NetGuard firewalling — gave up the VPN slot to Tailscale instead
- External monitor: only verified the kernel claims DP-alt support; no hub plugged in yet to confirm hand-off
- Native solana-cli — see Solana section above; JS SDK is the supported path
- Neutralising the boot-time disabler — **identified** as `vendor.playsolana.svalguard-service` (native, runs below the app layer), but stopping it needs root; worked around with the keepalive (reachable over network adb, and self-locating by MAC — not just USB)
- **A full post-reboot recovery cycle has never actually been exercised.** Every piece is verified in isolation (cron fires, keepalive repairs a real disable, network adb reachable, discovery finds the deck by MAC), but the end-to-end "reboot the deck undocked and watch it heal itself within 5 min" run has not been done — rebooting is discouraged, so this remains reasoned-through rather than observed
- DHCP reservation for the deck — not set (router at `192.168.2.1` serves DHCP; needs the operator's admin login). Discovery makes this non-critical
