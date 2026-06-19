# PSG1 — Motherboard / Hardware Spec Sheet

Physical teardown notes for the PSG1 mainboard, read off the bare board.
Pairs with [PSG1_NOTES.md](PSG1_NOTES.md) (software / bootloader / security state)
and [PSG1_CYBERDECK_OPS.md](PSG1_CYBERDECK_OPS.md) (day-to-day config).

> **Source of these facts.** Everything in the "read off the board" tables below
> comes from inspecting the physical PCB (silkscreen, chip markings, the
> production sticker). Where a value is cross-checked against what the running
> software reports, it's called out. Anything I couldn't read cleanly under glare
> is listed as **unconfirmed** rather than guessed.

---

## TL;DR

PSG1 **V2.0** mainboard, board ID `PS01-2547-002-A2`. Built around a
**Rockchip RK3588S2** (8-core, Mali-G610, ~6 TOPS NPU) with **8 GB LPDDR** and
**128 GB eMMC** — the "8+128G" SKU per the back-of-board sticker. Onboard
Wi-Fi/BT module, dual microSD, and a row of FPC ribbon connectors driving the
display, touch, and controls. It's a high-end handheld SoC, well above the
RK3326/RK3566 class used in budget retro devices.

---

## Board identity (silkscreen + sticker)

| | | Where |
|---|---|---|
| Board ID | `PS01-2547-002-A2` | Front silkscreen, top-right |
| Module marking | `PSG1 RK3588S2 V2.0N 2025.10.27` | Front silkscreen, center-right |
| Sticker | `PSG1 RK3588S2 V2.0 8+128G  2026-11-25  FS01219` | Back of board |
| Hardware rev | **V2.0** | — |
| Build / date code | `2026-11-25` | Back sticker |
| Unit serial / batch | `FS01219` | Back sticker |

### A note on "RK3588S" vs "RK3588S2"

`PSG1_NOTES.md` records the SoC as **RK3588S** because that's what the running
software reports (`fastboot product: evb_rk3588`, the Mali/kernel banners). The
physical board is marked **RK3588S2**. These are not a contradiction: the
RK3588S2 is a cost-reduced respin of the RK3588S with a trimmed I/O complement
(fewer high-speed lanes, one less display head) but **identical CPU/GPU/NPU
compute**, and it presents to software the same way an RK3588S does. Treat
"RK3588S" (software view) and "RK3588S2" (board marking) as the same device for
all practical purposes.

---

## Core silicon (read off the board)

| Part | Marking / ID | Notes |
|---|---|---|
| SoC | `Rockchip` (large BGA, board says RK3588S2) | 8-core: 4× Cortex-A76 + 4× Cortex-A55; Mali-G610 MP4; ~6 TOPS NPU |
| RAM | Micron LPDDR (`4CB77 / D8CIX`), next to SoC | **8 GB** per sticker SKU |
| Storage | FORESEE flash (`F1G0BU…`) | **128 GB** eMMC (≈119 GiB usable — matches the `~119 GB eMMC` in PSG1_NOTES) |
| PMIC | smaller `Rockchip`-marked chip, lower-center | Almost certainly an RK806 companion PMIC for the RK3588. **Exact P/N unconfirmed** (glare). `1R5` / `2R2` nearby are buck-converter power-inductor values |
| Wi-Fi / BT | green module w/ onboard antenna + QR, top-right | Combo radio. **Exact model + Wi-Fi 5/6 generation unconfirmed** (silkscreen obscured) |

### RK3588S2 capability summary

- **CPU:** 4× Cortex-A76 (~2.2–2.4 GHz) + 4× Cortex-A55. Flagship-phone-class from a few years back; far beyond typical retro-handheld SoCs.
- **GPU:** Mali-G610 MP4 — handles serious 3D emulation and native Android 3D.
- **NPU:** ~6 TOPS (3 cores) — relevant only if firmware uses on-device AI.
- **Video:** HW decode 8K H.265/VP9 + 4K AV1; encode up to 8K H.265.

---

## Connectors & I/O (read off the board)

| Location | Connector | Drives |
|---|---|---|
| Bottom edge | Row of FPC/ribbon connectors (varying widths) | Display, touch digitizer, control board (D-pad / buttons / sticks). On a handheld this edge is the whole front-panel interface. |
| Bottom-left | White JST-style connector | Battery (most likely) or a speaker/peripheral pigtail |
| Right edge (front) | microSD slot + a board-to-board / FPC | microSD; the B2B/FPC routes the USB-C port (charge/OTG + DP-alt video — confirmed in software, see below) via a port daughterboard |
| Left edge (back) | Second microSD slot | Dual-SD: OS on one card, library on the other |
| Top-right | Wi-Fi/BT module | Onboard antenna; a U.FL to a shell antenna may also be present |

**USB-C (confirmed from software — `PSG1_CYBERDECK_OPS.md`):** the Type-C port is
**USB 1.2 + USB-PD 3.0, dual-role data and dual-role power**, and the kernel
exposes **`card0-DP-1`** — so **DisplayPort alt-mode is supported**: a USB-C hub
with DP-alt drives an external monitor, and a PD-passthrough hub charges the
device while in host mode. This is the single external display head the S2
provides.

**S2 I/O caveat:** because this is the **S2** variant, don't expect SATA,
multiple full PCIe lanes, or dual independent display heads — those are trimmed
vs. the full RK3588. The one DP-alt output above is the display head you get.
Fine for a handheld; it's not an SBC/NAS-class chip.

---

## OS & what it runs

Runs **Android 15 (SDK 35)** — see `PSG1_NOTES.md` for the full software state
(kernel `6.1.115-abplaysolana`, locked bootloader, silicon-level secure-boot
fuse, etc.). With Android + the Mali-G610 + 8 GB RAM, the realistic emulation
envelope is:

| Tier | Systems | Notes |
|---|---|---|
| Flawless | up to PS1, N64, Dreamcast, PSP, GBA/DS, Saturn | Full speed |
| Very good | GameCube, Wii, PS2 | Most titles full speed; a few heavy ones need per-game tweaks |
| Playable→good | 3DS, Wii U, lighter Switch titles | Via Android emulators; per-game settings matter |
| Native | Android apps, native 3D games | Smooth; doubles as a general handheld |

> **The real limiter is thermals, not the chip.** The RK3588 throttles under
> sustained load without a heatsink/fan, so how this board is mounted (and
> cooled) in the shell governs sustained performance more than the SoC spec does.

---

## Open items (need clearer macro shots to confirm)

1. **PMIC exact part number** — the smaller Rockchip-marked chip lower-center (suspected RK806).
2. **Wi-Fi/BT module model** — to pin down Wi-Fi 5 vs Wi-Fi 6 and TX power.

The rest of the project docs were checked for these and don't record them: the
only Wi-Fi-related fact anywhere is the **`CN` country code** (`PSG1_NOTES.md`),
which doesn't identify the chip, and the PMIC isn't mentioned at all. So a
straight-on, well-lit close-up of each chip is still the way to resolve both —
the firmware/software side doesn't expose them.

---

*Cross-references: SoC/GPU/storage figures here are consistent with the
software-probed values in [PSG1_NOTES.md](PSG1_NOTES.md) → "Hardware". This doc
adds the RAM size (8 GB), storage SKU (128 GB), board revision (V2.0), board ID,
and the physical connector layout, none of which are visible from software.*
