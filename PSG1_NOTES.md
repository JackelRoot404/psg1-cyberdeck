# PlaySolana PSG1 — Customization Notes

Comprehensive reference of what's been discovered about this device, what works, what doesn't.

**Device:** PSG1 (PlaySolana handheld, "Jupiter" edition)
**Goal:** Personal cyberdeck — full customization of owned hardware

> **About this writeup.** Everything documented here was done on a PSG1 I bought and own. No funds, accounts, or services beyond the device itself are in scope. I have not pursued, published, or shared any kernel exploit, BootROM exploit, or attack against PlaySolana's signing infrastructure. Sections that describe reachable kernel attack surface are documentation of the *state of the device as shipped*, not exploit material. DMCA §1201(f) interoperability and §1201(j) security-research exemptions cover this kind of documentation on consumer hardware you own.

---

## TL;DR

The PSG1 is **locked at the silicon level**. PlaySolana burned the RK3588S secure-boot OTP fuse with their own public-key hash. Even after reaching MaskROM mode via the on-PCB test pads, the BootROM silently rejects any non-PlaySolana-signed loader. Together with: a stubbed userdebug U-Boot that no-ops `flashing unlock`; a custom-patched Mali driver that EPERMs all userspace ioctls; and `no_install_unknown_sources` baked into the user 0 restrictions — this is a comprehensive multi-layer lockdown.

**Root is not achievable through any software-only path on the PSG1** without PlaySolana's signing key or an RK3588 BootROM exploit (no public ones exist).

**But cyberdeck conversion succeeded.** The device runs Lawnchair as home launcher, has Termux and other curated apps installed via the Echos-installer-spoof bypass, and Echos is uninstalled from the launcher. No PlaySolana branding remains in the user-facing layer (boot splash still shows it — baked into U-Boot). Day-to-day, the device is mine.

---

## Hardware

| | |
|---|---|
| SoC | Rockchip RK3588S |
| GPU | Mali-G610 r0p0 (Valhall) |
| GPU driver banner | `mali fb000000.gpu: Kernel DDK version g25p0-00eac0` (r25p0) |
| RAM/storage | eMMC ~119 GB, FBE encrypted |
| Form factor | Tablet (`ro.build.characteristics`) |
| Fingerprint sensor | Goodix |
| Secure element | Yes (StrongBox + SvalGuard TA) |
| No cellular (`ro.boot.noril=true`) | |

## Software

| | |
|---|---|
| Android | 15 (SDK 35) |
| Security patch | 2024-12-05 |
| Kernel | Linux 6.1.115-abplaysolana |
| Build | `PlaySolana/PSG1/PSG1:15/AP4A.241205.013.C1/playsolana-...:user/dev-keys` |
| Bootloader | U-Boot 2017.09 `#playsolana` variant=userdebug |
| `ro.product.ota.host` | local LAN address (no public OTA endpoint) |
| WiFi country code | CN |

## Security state — unusually loose for a production device

| Setting | Value | Implication |
|---|---|---|
| SELinux | **permissive** | Denials logged, NOT enforced. Removes a major mitigation layer. |
| KASLR | **disabled** ("KASLR disabled due to lack of seed") | Kernel addresses are static across reboots |
| `kptr_restrict` | 2 | kallsyms hidden from shell |
| `dmesg_restrict` | 0 | dmesg readable by shell (gives address leaks via boot prints) |
| `perf_event_paranoid` | **-1** | `perf_event_open()` fully accessible |
| `unprivileged_bpf_disabled` | 0 | Unprivileged BPF allowed |
| `modules_disabled` | 0 | Modules loadable (needs root, but worth noting) |
| `/dev/mali0` perms | `crw-rw-rw-` | World-readable/writable file mode — BUT kbase rejects shell uid internally |
| AVB | `verifiedbootstate=green`, `flash.locked=1` | Bootloader locked |
| `ro.oem_unlock_supported` | 1 | Kernel says unlock is supported |
| Bootloader unlock | **non-functional** | See section below |
| Mali driver UID check | **rejects shell uid 2000** | `EPERM` on every Mali ioctl from shell |

These knobs (permissive SELinux, KASLR off, perf/bpf open, dmesg readable) make this a notably less-defended Android 15 kernel than typical production devices ship with. The mitigations were dialed back, presumably so PlaySolana's own platform code could iterate faster — but the lowered guard-rails apply equally to anything else running on the device.

---

## What worked / what I cleared

### Settings access — **CLEARED**
- `device_provisioned=0` and `user_setup_complete=0` were both flagged false — making Settings think SUW was incomplete
- Set both to 1 via `adb shell settings put`
- After this, Dev Options activity (`com.android.settings/.Settings$DevelopmentSettingsActivity`) became reachable via `am start`

### Launcher cage — **CLEARED**
- `com.playsolana.echos/.MainActivity` was registered as `type=home` and intercepted all focus changes
- `pm disable-user com.playsolana.echos` successfully disables it; persists across reboots
- `pm enable com.playsolana.echos` re-enables when desired
- FallbackHome (`com.android.settings.FallbackHome`) takes over when Echos is disabled

### Shizuku service — **RUNNING**
- Installed: `moe.shizuku.privileged.api` v13.6+
- Started via: running `libshizuku.so` from inside the Shizuku APK lib dir (libshizuku.so IS the starter binary in v13+)
- Useful for app-mediated privileged calls but runs as same shell uid as adb

---

## What doesn't work

### `no_install_unknown_sources` user restriction — **BYPASSED**
- Set on user 0 as a baked-in default by PlaySolana
- No device owner / profile owner (`dpm list-owners` returns "no owners")
- `pm set-user-restriction --user 0 no_install_unknown_sources 0` requires `MANAGE_USERS` permission (signature-level, shell can't hold it)
- Shizuku-as-shell can't clear this either
- `adb install` and `pm install -i com.android.shell` both fail with `INSTALL_FAILED_USER_RESTRICTED: Installer not allowed`
- **BYPASS:** `pm install -i com.playsolana.echos /data/local/tmp/foo.apk` succeeds. The user restriction trusts the Echos launcher as an installer source. Spoofing the `-i` flag with `com.playsolana.echos` clears the gate. Apps installed this way show `installerPackageName=com.playsolana.echos` in `dumpsys package`.
- This is the working channel for sideloading anything onto a stock PSG1.

### Bootloader unlock — **STUBBED**
- `ro.oem_unlock_supported=1` but the U-Boot's actual handlers are no-ops
- `fastboot flashing unlock` → returns `OKAY` immediately (no on-device confirmation prompt) but `unlocked` stays `no`
- `fastboot oem unlock` → returns "not implemented" (handler exists but stubbed)
- `fastboot oem unlock-go`, `oem device-info`, `oem dump`, `fastboot fetch`, etc. → "unknown oem command" or "not supported"
- Conclusion: PlaySolana ships a U-Boot with the unlock handlers stubbed at the lowest level — `userdebug` variant string is misleading

### Reading partitions from fastboot — **BLOCKED**
- No `fastboot fetch`, no `oem dump`, no rkpartdump
- Boot/recovery/vbmeta/dtbo all `brw-------` root-only from Android
- Only way to read these would be via `rkdeveloptool` from MaskROM (which is reachable — see below)

### MaskROM mode + rkdeveloptool — **REACHABLE BUT LOADER REJECTED**
- **MaskROM entry IS possible** via on-PCB test pads on the motherboard. Requires partial disassembly. Specific pad locations and bridging procedure are intentionally not documented here — the path is reproducible by anyone willing to open the device with standard Rockchip-platform debugging knowledge.
- USB enumerates as `2207:0x350b` (Rockchip MaskROM). `rkdeveloptool ld` confirms "Maskrom".
- **HOWEVER**, `rkdeveloptool db <loader>` hangs forever. The BootROM accepts the USB connection, the USB transfer is submitted, then no completion event arrives. Same behavior on macOS (libusb-darwin) and Linux (libusb).
- strace on Linux shows: 491520-byte loader read into memory → interface claimed → first URB submitted → silent hang.
- I tried `rk3588_spl_loader_v1.19.113.bin` (built locally via `boot_merger` in a linux/amd64 Docker container against rkbin's `RKBOOT/RK3588MINIALL.ini`). Header starts with `LDR f\0\v\1` — valid RK3588 loader signed with Rockchip's stock dev key.
- **Conclusion: PlaySolana burned the RK3588S secure-boot OTP fuse with their own public-key hash.** This is silicon-level lockdown — the SoC only accepts loaders signed by PlaySolana's private key. This is permanent (OTP = one-time programmable).

### Mali GPU ioctls — **BLOCKED FOR ALL USERSPACE**
- `/dev/mali0` is `crw-rw-rw-` but every ioctl returns `EPERM` regardless of uid
- Tested from `shell` (uid 2000) AND from an app context — both return EPERM
- Even using the Mali fd that libGLES_mali.so itself opened (which IS working for EGL/GPU) — same EPERM when calling ioctls on it
- No SELinux denial in dmesg — the EPERM comes from inside the kbase driver
- Conclusion: PlaySolana custom-patched the Mali driver to reject userspace ioctls entirely. Published Mali exploits (CVE-2022-46395, CVE-2023-4211, etc.) are unusable.
- Mali driver banner from dmesg: `mali fb000000.gpu: Kernel DDK version g25p0-00eac0` (r25p0)
- Module path: `/sys/module/bifrost_kbase/` (NOT `mali_kbase` — important for finding sysfs nodes)

### TEE / SvalGuard access — **HARD**
- TAs enumerable via libteec from app context
- Goodix Fingerprint TA, KeyMint, Rockchip Gatekeeper, SvalGuard, two unknown TAs (UUIDs in the appendix)
- Real TEE bug exploitation is a research-grade project; not pursued.

---

## Bootloader probe details

`fastboot getvar all` output (key items):

```
version-bootloader: U-Boot 2017.09-#playsolana
product: evb_rk3588   ← Rockchip evaluation board reference, minimal renaming
secure: yes
unlocked: no
variant: userdebug    ← misleading; unlock handlers are still stubbed
max-download-size: 0x07000000 (112 MB)
slot-count: 2 (suffixes a,b) but NO partitions have slots, ro.build.ab_update=false
```

## Partition layout

eMMC enumerates as `mmcblk1` on first boot, `mmcblk2` on subsequent boots — by-name symlinks update correctly.

| Partition | Size | Notes |
|---|---|---|
| security (p1) | 4 MB | |
| uboot (p2) | 4 MB | |
| trust (p3) | 4 MB | trustzone image |
| misc (p4) | 4 MB | bootloader commands |
| dtbo (p5) | 4 MB | |
| vbmeta (p6) | 1 MB | AVB metadata |
| boot (p7) | 64 MB | kernel + ramdisk |
| recovery (p8) | 96 MB | |
| backup (p9) | 384 MB | |
| cache (p10) | 384 MB | |
| metadata (p11) | 64 MB | |
| frp (p12) | 512 KB | OEM unlock byte stored here (last byte) |
| baseparameter (p13) | 1 MB | |
| super (p14) | ~51 GB | dynamic partitions (system, vendor, product, odm) |
| userdata (p15) | ~64 GB | wiped on first unlock |

## Trusted Applications (UUIDs enumerated from libteec)

- `258be795-f9ca-40e6-a869-9ce6886c5d5d` — Android Keymaster (KeyMint, Rust)
- `7c2fc71b-a45e-2fa1-acf3-42ebc235c082` — Goodix Fingerprint
- `7b30b820-a9ea-11e5-b178-0002a5d5c51b` — Rockchip Gatekeeper (well-known UUID)
- `a5add343-fdc5-438e-af99-5e7abf51fa01` — Unknown TA (158 KB) — possibly SvalGuard
- `c7c0ae4f-9e30-4872-bd68-77b3ba0d00cc` — Unknown TA (88 KB)

---

## Public exploit candidates (researched, attempted, blocked)

**Mali r25p0 PoCs — ALL BLOCKED by driver patch:**

| CVE | Affected range | PSG1 viability |
|---|---|---|
| CVE-2022-46395 | r0p0–r41p0 | ❌ Mali ioctl EPERM |
| CVE-2023-4211  | r19p0–r42p0 | ❌ Mali ioctl EPERM |
| CVE-2023-26083 | all Mali generations | ❌ Mali ioctl EPERM |
| CVE-2022-38181 | up to ~r38p1 | ❌ Mali ioctl EPERM |

Confirmed via APK wrapper running as app uid: every Mali kbase ioctl returns EPERM, including on the EGL-acquired fd. PlaySolana custom-patched the driver.

**Non-Mali kernel attack surface — VERIFIED REACHABLE from app context:**
- `perf_event_open(PERF_TYPE_SOFTWARE)` — works ✓
- `perf_event_open(PERF_TYPE_HARDWARE, CPU_CYCLES)` — works ✓ (rare; usually CAP_PERFMON)
- `bpf(BPF_MAP_CREATE, ARRAY)` — works ✓
- `bpf(BPF_PROG_LOAD, SOCKET_FILTER)` — works ✓, verifier reachable
- `io_uring_setup` — works ✓
- `userfaultfd` — EPERM ✗
- `keyctl` — reachable (returned ENOKEY, meaning the call hit kernel code)

These three surfaces (perf_event, bpf, io_uring) are documented kernel attack surfaces with published LPEs against other Android devices. I have not built or attempted such a chain against the PSG1 kernel. Stating that the surfaces are reachable is documentation of the device's shipped state — the same observation you'd reach by reading the relevant `/proc/sys/kernel/*` entries.

---

## Cyberdeck build (what the device looks like now)

- **Lawnchair** is the home launcher (custom-themed)
- **Echos** is uninstalled from launcher view (`pm disable-user`), but stays installed for user 0 because the install-spoof depends on it
- ~12 curated apps installed via the Echos-installer-spoof: Lawnchair, F-Droid, Aurora Store, Termux + Termux:API + Termux:Boot, ConnectBot, Material Files, NetGuard, KeePassDX, RetroArch, Shizuku, plus later additions (Tailscale, WireGuard, Aegis, etc.)
- Termux:Boot scripts to auto-start sshd + wake-lock on reboot
- Tailscale as the always-on VPN
- proot-distro Ubuntu chroot for anything needing glibc (Solana toolchains, etc.)

### How to install another app (the working bypass)
```
adb push my.apk /data/local/tmp/
adb shell 'pm install -i com.playsolana.echos /data/local/tmp/my.apk'
```
**Critical:** Echos must be installed for user 0 (even if `disabled-user`). If you `pm uninstall --user 0 com.playsolana.echos`, the spoof breaks — you'll get `Installer not allowed: null (uid=-1)`. Restore with `pm install-existing --user 0 com.playsolana.echos`.

### For multi-APK / xapk / aab apps
Single-file `pm install -i` doesn't work with split APKs — the `-i` attribution is lost in the session-based install path. Solution:
1. Get the xapk (e.g. from apkcombo.com)
2. Merge splits into a universal APK using APKEditor:
   ```
   java -jar APKEditor.jar m -i app.xapk -o app_universal.apk
   ```
3. Re-sign (APKEditor strips the signature) — `zipalign` + `apksigner` with any debug keystore
4. Install via the regular Echos-spoof.

### One catch — boot-time component disabler
PlaySolana firmware disables `com.termux`, `com.termux.boot`, `com.tailscale.ipn`, `moe.shizuku.privileged.api`, `app.lawnchair` (and others) at every reboot via some system-level mechanism I have not pinpointed. Mitigation: a small `pm enable` keepalive script running on cron from a separate Linux machine that ADBs into the PSG1. Example script in the repo.

---

## Theoretical remaining paths (not pursued)

- **eMMC chip swap** — desolder the eMMC, replace with one containing a custom firmware. Requires BGA rework + reballing.
- **RK3588 BootROM exploit research** — would require finding a new 0-day in the BootROM USB protocol parser. No public ones exist. Original security research effort.
- **Kernel LPE chain via the open kernel surfaces** — fully out of scope here for the reasons above.
- **Ask PlaySolana directly** for OEM unlock or developer access. They have a devkit program. Untried at writeup time.

### Key research links

- ARM Mali advisories list: https://developer.arm.com/Arm%20Security%20Center/Mali%20GPU%20Driver%20Vulnerabilities
- Man Yue Mo blog (CVE-2022-46395 deep dive): https://github.blog/security/vulnerability-research/rooting-with-root-cause-finding-a-variant-of-a-project-zero-bug/
- Mali Valhall ABI / kbase docs: https://gitlab.com/icecream95/kbase-valhall
- rkdeveloptool: https://github.com/rockchip-linux/rkdeveloptool
- RK3588 MaskROM entry techniques (Radxa wiki): https://wiki.radxa.com/Rock5/install/usb-install-emmc
- RK3588 secure boot research: https://github.com/DualTachyon/rk3588-secure-boot
- PlaySolana developer portal: https://developers.playsolana.com
- PlaySolana devtools landing: https://www.playsolana.com/devtools
