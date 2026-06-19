# PSG1 Cyberdeck

Documentation of the work I did to turn a PlaySolana PSG1 handheld into a personal cyberdeck — what I tried, what worked, what didn't, and the silicon-level lockdown I ran into.

## What's in here

- **[PSG1_NOTES.md](PSG1_NOTES.md)** — full reverse-engineering writeup. Hardware, software, bootloader, security state, what bypasses worked, what's blocked, and why root-via-software isn't reachable on this device.
- **[PSG1_MOTHERBOARD.md](PSG1_MOTHERBOARD.md)** — physical mainboard spec sheet read off the bare PCB: board ID/revision, SoC (RK3588S2), RAM/storage SKU, Wi-Fi module, and the connector layout. Complements the software-probed hardware section in the notes.
- **[PSG1_CYBERDECK_OPS.md](PSG1_CYBERDECK_OPS.md)** — how the device is configured day-to-day after conversion. Termux, sshd, Tailscale, Solana SDK, USB-C hub support.
- **[psg1_termux_setup.sh](psg1_termux_setup.sh)** — idempotent bootstrap script that installs and configures everything on the Termux side. Edit `AUTHORIZED_PUBKEY` before running.
- **[psg1_keepalive.sh](psg1_keepalive.sh)** — cron-friendly keepalive that re-enables packages PlaySolana firmware disables at every boot. Runs on a separate Linux machine acting as an ADB jumpbox.
- **[psg1_install.sh](psg1_install.sh)** — sideload an APK (file or URL) from the jumpbox via the Echos-installer-spoof, bypassing the `no_install_unknown_sources` restriction. Push + install + cleanup in one command.

## Scope and disclaimers

- All work was done on a PSG1 **I bought and own.** No services, accounts, or other people's devices are involved.
- I have not published, attempted, or distributed any exploit. Sections that note "this kernel surface is reachable" or "this Mali CVE was blocked by a driver patch" describe the device's shipped state — the kind of observation anyone with `adb shell` can reproduce — not exploit material.
- The Echos-installer-spoof bypass (`pm install -i com.playsolana.echos ...`) installs apps onto a device I own. DMCA §1201(f) and §1201(j) cover documenting that kind of interoperability/research work on consumer hardware.
- **Network IPs, SSH keys, device serials, and similar identifiers in the writeup are placeholders** — replace with your own when adapting.

## Reproducing

If you're playing with your own PSG1 and want to follow along: start with `PSG1_NOTES.md` for the lay of the land, then `PSG1_CYBERDECK_OPS.md` for the actual setup. The `psg1_termux_setup.sh` is the practical entry point — run it inside Termux once you've sideloaded Termux via the bypass.

## License

This documentation and the scripts in this repo are released under the [MIT License](LICENSE) — do whatever you want with them. Third-party tools mentioned (Termux, Tailscale, Shizuku, Lawnchair, etc.) have their own licenses and are not included in this repo.
