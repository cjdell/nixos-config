# zen3 R9700: SMU firmware hang → gfx reset → VRAM loss → llama-server death (2026-10-01)

**Status: OPEN — two R9700 GPU hangs captured in full (boot -2); one unexplained hard death
(boot -1). Root cause ranked below; proposed fixes NOT yet applied (they need a reboot,
and this machine serves the LLM that runs the agent investigating it).**

## TL;DR

- The "GPU stopped working" symptom was the **R9700 (0000:03:00.0, card1, the llama-swap
  GPU) hanging twice inside a single 3.5-day boot** (Sep 28 16:29 → Oct 1 08:19).
  Each time the **SMU (the GPU's power-management firmware) stopped responding first**
  (`SMU: I'm not done with your previous command: SMN_C2PMSG_66:0x00000012
  SMN_C2PMSG_82:0x00000005`), ~14 s later the gfx ring timed out, the in-GPU ring reset
  (via MES) failed, the driver did a full **mode1 reset** — which recovered the GPU but
  **lost all VRAM** and killed `llama-server`. LLM serving was down until llama-swap
  respawned it and reloaded the model.
- Both hangs happened **during sustained heavy inference** (large `pi` streaming
  completions, up to ~1.17 MB / 2 m 04 s per request). No MCE/EDAC/RAS/ECC errors in
  either window; the GPU is healthy since the reboot.
- The box's **SMU firmware changed 104.79.0 → 104.80.0 on ~Sep 20** (linux-firmware
  20260810 → 20260916) via a nixpkgs bump. The old version ran ~5 days without an issue;
  the new one ran ~8 days clean, then hung twice during the most LLM-intensive stretch.
  Firmware regression vs load-triggered lockup **cannot be cleanly separated** — but the
  signature matches a known upstream issue class where a firmware regression caused
  exactly this SMU hang and the fix was to pin the older firmware.
- Separately, the actual "last boot" (boot -1, Oct 1 08:19:51–08:20:05) **died hard 14 s
  after boot with no kernel evidence at all** (no panic, no OOM, no clean shutdown);
  boot 0 reports the reset as **external** (`system reset pin BP_SYS_RST_L was tripped`,
  39 s gap) — the box froze and was power-cycled, or got a deliberate power cycle.
  GPUs had initialized fine in that boot and llama-swap had not loaded a model yet, so
  the GPU is not an obvious suspect for that one. It is **distinct** from the 10-minute
  `sp5100_tco` watchdog resets in `zen3-random-crashes.md` — worth one line in that doc.
- Current state (Oct 1 ~08:50, boot 0): R9700 healthy, `amd-smi` shows 32624 MB VRAM,
  ~30 GB resident (`DeepSeek-V4-Pro-Qwen3.5-9B-MTP-Q4_K_M`), GTT 850/90112 MB; SMU
  answers metrics queries; llama-swap serving normally.

## 1. Machine

| | |
| --- | --- |
| Host | zen3-nixos (192.168.49.50) |
| CPU/board | AMD Ryzen 7 5700G (Cezanne, Vega 8 iGPU) on Gigabyte B550 AORUS ELITE V2 |
| Kernel | 6.18.54 LTS (moved off bleeding-edge 7.2.8 — "unstable, went to LTS") |
| System | `26.11.20260926.e158d9e` (boots -2..0); boot -4 ran 7.2.8 off a separate ESP entry |
| R9700 32 GB | `0000:03:00.0` = card1 / renderD128 — llama-swap's GPU, **no displays attached** |
| RX 580 | `0000:06:00.0` = card2 — display, used with the iGPU (kwin rejects it: "misses required Vulkan extensions", every boot, unrelated) |
| Vega 8 iGPU | `0000:0a:00.0` = card0 — console |
| autoRollback | **off** on this host (verified: no rollback units) → `nixos-confirm` not needed |
| Firmware pkg | live: `/nix/store/4myvwvpn8ql0zqwhil59bhcji24sj8xj-firmware` (contains `smu_14_0_3.bin` = 104.80.0) |

## 2. Boot timeline (`journalctl --list-boots`)

| boot | span | SMU fw | GPU events |
| --- | --- | --- | --- |
| -16 … -11 | Aug 26 … Sep 2 | **104.79.0** (`0x00684f00`) | none |
| -10 … -3 | Sep 20 … Sep 28 | **104.80.0** (`0x00685000`) | none |
| **-2** | **Sep 28 16:29 → Oct 1 08:19 (3.5 d)** | 104.80.0 | **TWO full SMU→gfx hangs** (below) |
| -1 | Oct 1 08:19:51 → 08:20:05 (14 s) | 104.80.0 | all GPUs init OK 08:19:54; **hard death 08:20:05, no kernel trace** |
| 0 | Oct 1 08:20:44 → now | 104.80.0 | healthy; reset reason = external `BP_SYS_RST_L` tripped |

Boot -2 ended by the user's own `sudo reboot` at 08:18:10 (after `sudo amdgpu_top` at
08:15:29 / 08:17:28, PWD=/home/cjdell/Projects/WHY2025). Boot 0's 39 s gap from the end
of boot -1's journal to its first kernel line + the external reset-pin report = a power
cycle by a human, not the TCO watchdog (which resets at ~10 min into a hang and records
a different reason).

## 3. The hangs, in full (boot -2)

Both episodes follow the identical sequence. **The SMU is first to fail in both.**

### Hang 1 — Sep 30 15:30:47 → 15:34:22 (workload: `pi` streaming completions ~0.6–1.1 MB)

```
Sep 30 15:30:47 amdgpu 0000:03:00.0: amdgpu: SMU: I'm not done with your previous command: SMN_C2PMSG_66:0x00000012 SMN_C2PMSG_82:0x00000005
Sep 30 15:30:47 amdgpu 0000:03:00.0: amdgpu: Failed to disable gfxoff!
Sep 30 15:30:47 amdgpu 0000:03:00.0: amdgpu: Failed to export SMU metrics table!
Sep 30 15:30:47 amdgpu 0000:03:00.0: amdgpu: Failed to get current clock freq!   (repeats every ~5 s)
Sep 30 15:31:44 amdgpu 0000:03:00.0: amdgpu: ring gfx_0.0.0 timeout, signaled seq=1358449, emitted seq=1358451
Sep 30 15:31:44 amdgpu 0000:03:00.0: amdgpu: Process llama-server pid 394216
Sep 30 15:31:44 amdgpu 0000:03:00.0: amdgpu: MES(1) failed to respond to msg=RESET
Sep 30 15:31:44 amdgpu 0000:03:00.0: amdgpu: reset via MES failed and try pipe reset -110
Sep 30 15:31:44 amdgpu 0000:03:00.0: amdgpu: The CPFW hasn't support pipe reset yet
Sep 30 15:31:44 amdgpu 0000:03:00.0: amdgpu: Ring gfx_0.0.0 reset failed
Sep 30 15:31:44 amdgpu 0000:03:00.0: amdgpu: GPU reset begin!. Source: 1
Sep 30 15:31:44 amdgpu 0000:03:00.0: amdgpu: [SetDfCstate] failed!
Sep 30 15:31:44 amdgpu 0000:03:00.0: amdgpu: Failed to disallow df cstate
Sep 30 15:31:44 [drm] *ERROR* dc_dmub_srv_log_diagnostic_data: DMCUB error - collecting diagnostic data
Sep 30 15:31:44 amdgpu 0000:03:00.0: amdgpu: MES(1) failed to respond to msg=REMOVE_QUEUE   (×6)
Sep 30 15:31:44 amdgpu 0000:03:00.0: amdgpu: MODE1 reset
Sep 30 15:32:16 amdgpu 0000:03:00.0: amdgpu: GPU reset succeeded, trying to resume
Sep 30 15:32:16 amdgpu 0000:03:00.0: amdgpu: PCIE GART of 512M enabled
Sep 30 15:32:16 amdgpu 0000:03:00.0: amdgpu: VRAM is lost due to GPU reset!
Sep 30 15:32:16 amdgpu 0000:03:00.0: amdgpu: PSP is resuming...
Sep 30 15:32:16 amdgpu 0000:03:00.0: amdgpu: GECC is disabled, set amdgpu_ras_enable=1 to enable GECC
Sep 30 15:34:22 systemd-coredump: Process 394216 (llama-server) of user 0 terminated abnormally without generating a coredump.
Sep 30 15:34:23 llama-swap: error processing streaming response: no valid JSON data found in stream, path=/v1/chat/completions
```

Corroborating llama-swap lines: `<r9700> recovered from upstream disconnection during
streaming` at 15:27:24 and 15:31:03; the in-flight `pi` request died mid-stream
(200, 62 bytes, 3 m 40.5 s). gpu-panel logged `fan curve write failed: …/gpu_od/fan_ctrl/fan_curve:
Device or resource busy (os error 16)` during the reset window — a symptom (the driver
re-owns the device mid-reset), not a cause.

### Hang 2 — Oct 1 06:41:50 → 06:42:56 (same shape)

`SMU: I'm not done…` from 06:41:50 → `ring gfx_0.0.0 timeout, signaled seq=1822800,
emitted seq=1822802` (llama-server pid 454779) at 06:42:19 → MES `RESET`/`REMOVE_QUEUE`
failures → `MODE1 reset` / `GPU smu mode1 reset` → 06:42:56 `VRAM is lost due to GPU
reset!`; in-flight `pi` request lost (146 bytes, 1 m 44.8 s, same "no valid JSON" error).

### What the sequence means

- `SMN_C2PMSG_66/82` 0x12/0x05 = the driver's command mailbox to the SMU never gets an
  ack: the **SMU firmware is locked up**, not the 3D engine. The gfx ring timeout ~14 s
  later is a downstream effect (the SMU also drives gfx-off/gfx-on power gating — note
  the immediate `Failed to disable gfxoff!`).
- The driver's first-choice recovery (reset the gfx ring via the MES microcontroller)
  also fails because the MES is wedged behind the SMU; only the full **mode1 (GPU + SMU)
  reset** works, at the cost of all VRAM contents.
- No MCE/EDAC/RAS/ECC errors precede either hang; `GECC is disabled` (RAS error capture
  is off — see §6). GART re-enables at 512 M after reset, exactly as at boot (not a diff).
- Nothing like this appears in boots -3 … -16.

## 4. SMU firmware version history (verified from the binaries, not just dmesg)

The R9700 (gfx12, `smu_v14_0_0`) loads `lib/firmware/amdgpu/smu_14_0_3.bin`.
Version = header bytes 0x10–0x13, checked with hexdump of the store copies:

| linux-firmware (store) | `smu_14_0_3.bin` ver | boots running it | GPU hangs |
| --- | --- | --- | --- |
| 20260810 (`slk0gkhn1diy8l84qyb8vdmvf9mc264i-linux-firmware-20260810-zstd`) | `0x00684f00` = **104.79.0** | -11 … -15 (Aug 28 → Sep 2) | **0** |
| 20260916 (`ji9pn6fd74acidjgar9d183bpxpjv5ar-linux-firmware-20260916-zstd`) | `0x00685000` = **104.80.0** | -10 … 0 (Sep 20 → now) | **2, both in boot -2** |

(`smu_14_0_2.bin` = 102.71.0 in 20260916 — a different ASIC, so no file ambiguity; each
boot's dmesg `smu fw version` matches the table. Other gfx12 firmware changed between the
two releases too: `gc_12_0_0_{me,mec,pfp,uni_mes}.bin` differ; `imu/mes1/mes/rlc/toc` are
identical.)

Caveat: 104.80.0 ran **~8 days without a hang** before the intense period, so "new
firmware is broken" isn't proven — "104.80.0 locks up under sustained heavy compute load"
is the claim. The conservative move is the A/B: pin the known-good 104.79.0 and see if
the class of event disappears.

## 5. Configuration facts (kernel command line)

Observed `/proc/cmdline` amdgpu-relevant params:

```
amd_iommu=on pcie_aspm=off amdgpu.gttsize=90112
ttm.pages_limit=23068672 ttm.page_pool_size=23068672
amdttm.pages_limit=23068672 amdttm.page_pool_size=23068672
amdgpu.vm_update_mode=3 amdgpu.gpu_recovery=1 amdgpu.ppfeaturemask=0xffffffff
amdgpu.runpm=0 amdgpu.lockup_timeout=10000 amdgpu.ppfeaturemask=0xffffffff
```

(`ppfeaturemask` appears twice — two modules both add it; harmless.)

| param | set in |
| --- | --- |
| `pcie_aspm=off`, `amdgpu.gttsize=90112`, `ttm/amdttm.*`, `amdgpu.vm_update_mode=3`, `amdgpu.gpu_recovery=1`, `amdgpu.ppfeaturemask=0xffffffff`, `amdgpu.runpm=0` | `hosts/zen3-nixos/hardware-configuration.nix:45-60` |
| `amdgpu.ppfeaturemask=0xffffffff` (+ amdgpu in initrd modules) | `common/amdgpu.nix` (unlocks `gpu_od` overdrive sysfs for gpu-panel; no LACT) |
| `amdgpu.lockup_timeout=10000` | `hosts/zen3-nixos/ai/default.nix:68` |

Relevant history in that file: `pcie_aspm=off` was added after the **RTL8125B (r8169)
hung its TX queue under ASPM L1** and starved DHCP renewal (Sep 2026) — this board has a
documented PCIe power-management instability, which is why PCIe-PM is on the hypothesis
list below. `vm_update_mode=3` is a workaround from gitlab `work_items/226`.

## 6. Hypotheses, ranked

**H1 (top) — SMU firmware 104.80.0 locks up under sustained heavy compute load.**
SMU is first to fail in both hangs; the exact signature (SMU mailbox timeout 0x12/0x05 →
gfx ring timeout → MES reset failure) is a **known upstream issue class**:

- GitLab [drm/amd#4737](https://gitlab.freedesktop.org/drm/amd/-/issues/4737) —
  "linux-firmware-amdgpu 20251125: frequent gpu crashes and system freezes"
  (Raphael/Granite Ridge, bisected, hang/freeze; closed 2025-12-01): **bisected to a
  linux-firmware-amdgpu regression, fixed by pinning the older firmware** (20251111).
- Arch thread [id=310517](https://bbs.archlinux.org/viewtopic.php?id=310517) — 6.17.9
  freezes, same SMU signature (their stuck process was kwin_wayland).
- openSUSE Factory thread (same 0x12/0x05 message IDs; page Cloudflare-blocked, not fetched).

Against: 8 clean days on the same firmware before the hangs; load correlation is
consistent with a *threshold* bug rather than a straight regression.

**H2 (strong) — board power delivery / PCIe power management.** The SMU runs on the
GPU's own power domain; a droop or PM-state glitch under full load (350 W card, Cezanne
APU board with its own GPU) could take down the SMU first, with the gfx ring dying
after. Same board already needed `pcie_aspm=off` for the r8169. The `Failed to disable
gfxoff!` line points at exactly the gfx power-gating path.

**H3 (weak) — GPU hardware degradation (VRAM/PSU/VRM).** No RAS/ECC evidence — but
`GECC is disabled` means the kernel wasn't capturing it, so this can't be fully ruled
out until `amdgpu_ras_enable=1` has run for a while.

## 7. Proposed changes — **NOT applied** (need a reboot; don't reboot mid-LLM-session)

1. **Firmware A/B (the main test): pin SMU fw 104.79.0.** Prepend the older firmware
   package to `hardware.firmware` in `hosts/zen3-nixos/` — first-list-package-wins for
   same-named files, so its `smu_14_0_3.bin` shadows the current one:

   ```nix
   # hosts/zen3-nixos/gpu-firmware.nix (new)
   { pkgs, ... }:
   {
     # R9700 SMU firmware A/B: 104.80.0 (linux-firmware 20260916) hung the gfx engine
     # twice under sustained load (docs/r9700-smu-hangs.md). Pin the known-good
     # 104.79.0 (linux-firmware 20260810): first package in the list wins for
     # same-named firmware files.
     hardware.firmware = [ pkgs.linuxFirmware_20260810 ];  # attr name TBD at apply time
   }
   ```

   Verification after reboot: `dmesg | grep 'smu fw version'` must print
   `0x00684f00`. (Note for whoever applies this: this repo currently sets
   `hardware.firmware` nowhere for zen3 — the live firmware dir is a single store path,
   `/nix/store/4myvwvpn8ql0zqwhil59bhcji24sj8xj-firmware` — so check what the default
   wiring is before assuming the prepend works as documented; `nix eval .#config.hardware.firmware`.)
2. **`amdgpu_ras_enable=1`** — turns on GECC so the kernel logs (and can auto-correct)
   GPU memory errors; the reset path itself prints "set amdgpu_ras_enable=1 to enable
   GECC". Needed to rule H3 in or out.
3. **If hangs persist on 104.79.0: `amdgpu.gfxoff_enable=0`** — disables the gfx
   power-gating whose SMU transition is what fails first; costs a few watts/°C at idle.
4. **DVFS isolation test (optional, no reboot):** pin clocks via gpu-panel
   (`gpu_od/pp_od_clk_voltage`) during a heavy run — if hangs only happen with DVFS
   free-running, that narrows H1/H2 to the power-management path.
5. **On any recurrence, before reboot:** `cat /sys/class/drm/card1/device/devcoredump/data`
   (the driver writes GPU state there on reset; it's gone after a reboot) and
   `journalctl -k -b -1 | grep -Ei 'smu|amdgpu|mes|ras'`.
6. **Add boot -1 to `zen3-random-crashes.md`** — Oct 1 08:19:51→08:20:05 hard death,
   14 s in, no kernel trace, reset reason `0x00010800` (external `BP_SYS_RST_L`), 39 s
   power-cycle gap. Distinct from the 10-min `sp5100_tco` watchdog resets.

## 8. Reference — commands used

```sh
journalctl --list-boots                       # boot spans & which boots to dig into
sudo journalctl -b -2 -k | grep -iE 'amdgpu|smu|mes|ras'   # the full hang sequences
sudo journalctl -b 0 -k | grep -i 'reset reason'           # 0x00010800 BP_SYS_RST_L
dmesg | grep 'smu fw version'                     # per-boot SMU fw (0x00685000 etc.)
# firmware version from a store copy:
nix store path /nix/store/ji9pn6fd74acidjgar9d183bpxpjv5ar-linux-firmware-20260916-zstd
#   → extract lib/firmware/amdgpu/smu_14_0_3.bin, hexdump header bytes 0x10–0x13
amd-smi metric -m --json                        # current VRAM/clocks/fans (SMU alive?)
sudo nix eval .#config.hardware.firmware        # which firmware package is wired in
```

## 9. Related

- `zen3-random-crashes.md` — whole-machine hard resets (25 crashes vs 3 clean shutdowns
  since Sep 1; `sp5100_tco` 10-min watchdog; memory/IMC as H1 there). The R9700 hangs
  are a *different* failure class (GPU-only, driver recovers), but boot -1's hard death
  belongs in that doc's tally.
- `kernel-rcu-wedge.md` — predecessor machine-wide wedge investigation.
- `gtt-vram.md` — R9700 VRAM/GTT behaviour under llama.cpp.
