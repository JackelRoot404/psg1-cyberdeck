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
- **JS SDK path instead.** A `solana-tools/` project with `@solana/kit@2.1` + `@solana-program/system` + `@solana/spl-token` + `bs58`. Wallet helper:
  ```sh
  node wallet.mjs new                            # create keypair, save to ./id.json
  node wallet.mjs show                           # show pubkey + balance
  node wallet.mjs balance <pubkey>               # balance for any address
  ```
- RPC defaults to `https://api.mainnet-beta.solana.com`; override with `SOLANA_RPC=...`
- Keyfile defaults to `./id.json`; override with `SOLANA_KEY=...`

If you ever want the CLI: cargo-build from source inside the Ubuntu chroot is the only path, and it's a long heavy build that may OOM on a phone.

## Ubuntu chroot (proot-distro)

- Ubuntu 26.04 LTS installed: `proot-distro login ubuntu`
- Runs as root inside; full apt available
- Use for: anything that needs glibc, cargo-builds of x86-only crates, Anza source builds, etc.

## Reboot survival

**WARNING:** PlaySolana firmware disables `com.termux`, `com.termux.boot`, `com.tailscale.ipn`, `moe.shizuku.privileged.api`, `app.lawnchair`, and more at every reboot. Disabled apps don't receive `BOOT_COMPLETED` → sshd won't start → device boots into "remotely unusable" state without intervention.

**Mitigation:** Keepalive script (`psg1_keepalive.sh`, in the repo) on the jumpbox runs every 5 min via cron, re-enables disabled packages and re-asserts `always_on_vpn_app` + `private_dns_mode`. Silent when no action needed.

**Worst case (jumpbox unreachable + PSG1 rebooted):** open Termux on device manually, run `sshd`. Then open Tailscale, tap Connect. After that, the jumpbox is reachable again.

## What is NOT done

- Root — not possible (OTP-fused secure boot; see `PSG1_NOTES.md`)
- NetGuard firewalling — gave up the VPN slot to Tailscale instead
- External monitor: only verified the kernel claims DP-alt support; no hub plugged in yet to confirm hand-off
- Native solana-cli — see Solana section above; JS SDK is the supported path
- Pinpointing the boot-time package disabler — works around it with the keepalive
