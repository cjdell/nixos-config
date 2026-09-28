# zen3-nixos random hard resets — investigation & evidence (2026-09-28)

**Status: OPEN.** The CPU compute path is exonerated. Prime suspect is the
**memory subsystem** — a 4-DIMM, two-kit, 2133 MT/s configuration on a CPU the
kernel already reports as **out of spec (BIOS PBO)**. Nothing is proven yet
because **there is no crash dump** (§7): this box hangs, the hardware watchdog
resets it, and the next boot only says "journal corrupted or uncleanly shut
down". Until pstore/netconsole is wired up (§7), every experiment is blind.

This is the sequel to **`docs/kernel-rcu-wedge.md`** (2026-08-26). That incident
was a *different* failure mode — an oops wedging RCU while the machine stayed
up. Read it too; §10 here explains what changed.

---

## TL;DR

- **Symptom:** roughly one unclean shutdown per day. Since wtmp begins
  2026-09-01 there are **25 `crash` records vs 3 clean shutdowns** (`last -x`).
- These are **hangs, not panics.** The machine wedges, the **SP5100 TCO
  watchdog** (`sp5100_tco`, 10-minute timeout — systemd adopts `/dev/watchdog0`)
  resets the box, so there is **no oops for the hang itself**. The only evidence
  left is the boot-time `systemd-journald: File … corrupted or uncleanly shut
  down, renaming and replacing`.
- Every crash signature is **memory / VM bookkeeping, never compute**:
  - a 309 s soft lockup inside the **per-CPU page allocator**
    (`vmstat_update → refresh_cpu_vm_stats → decay_pcp_high`);
  - a kernel `#PF: supervisor write access` to a bogus low address `0x8020`;
  - `BUG: Bad rss-counter state … MM_FILEPAGES val:-1 / MM_ANONPAGES val:1`.
- **CPU compute is not the problem.** 16 workers × 12 min of
  `stress-ng --cpu-method all --verify`: `passed: 16, failed: 0`, zero MCE,
  peak **70 °C**, flat 4.3 GHz (§5).
- The kernel itself decodes the taint: **`[S]=CPU_OUT_OF_SPEC`** — BIOS
  PBO/overclock is active. `kernel-rcu-wedge.md` §4 predicted exactly this and
  asked for a stability check; §5 answers half of it.
- **Memtest86 passing does not clear the IMC.** Runtime/IMC faults routinely
  sail through it. The memory topology here is the worst case for Cezanne:
  **96 GB across 4 DIMMs, 2 per channel, two mismatched kits, all at 2133 MT/s
  although rated 3600** (§4).
- **Red herring:** the recurring `qemu-system-riscv` GPFs in
  `libglib-2.0.so.0.8400.3` all hit the *same* offset — a deterministic bug in
  the esp32p4 qemu fork, not hardware (§6).

---

## 1. The machine

| | |
| --- | --- |
| Host | **`zen3-nixos`** = `192.168.49.50` |
| CPU | AMD Ryzen 7 5700G (Cezanne), 8 cores / 16 threads, 24 MB L3 |
| Motherboard | Gigabyte **B550 AORUS ELITE V2**, BIOS **FDb, 2023-06-01** |
| Memory | **96 GB**, 4 DIMMs, 2 per channel (§4) |
| iGPU | Cezanne Vega 8 (`0000:0a:00.0`) |
| dGPU 1 | **Radeon R9700 32 GB** (`0000:03:00.0`) — llama-swap's GPU |
| dGPU 2 | `0000:06:00.0` (145 W cap) — the old RX 580; **still installed**, no longer used by llama-swap |
| Kernel | `7.2.8` (`pkgs.linuxPackages_latest`); previous crashes on 7.2.7 / 7.2.2 |
| Kernel taint | `G S U` → **[S]=CPU_OUT_OF_SPEC, [U]=USER** |
| Watchdog | `sp5100_tco` (SP5100/SB800 TCO), 10 min hardware timeout, adopted by systemd |
| Test harness | `scripts/stress-monitor.sh` (added with this doc) |

---

## 2. What "random crash" actually looks like here

`last -x` is the clearest evidence and is worth running first on any "it just
rebooted" report:

| Boot started (kernel) | Lasted | Ended |
| --- | --- | --- |
| 2026-09-02 02:01 (7.2.2) | 18 d 18 h | **crash** (~09-20 20:55) |
| 2026-09-26 23:27 (7.2.7) | 21 h | clean shutdown 09-27 20:52 |
| 2026-09-27 20:53 (7.2.7) | 4 h 56 m | **crash** (09-28 01:41) |
| 2026-09-28 01:49 (7.2.7) | 9 h 21 m | **crash** (09-28 11:07) |
| 2026-09-28 11:11 (7.2.7) | 14 m | **crash** (09-28 ~11:25) |
| 2026-09-28 11:25 (7.2.7) | 5 m | clean shutdown 11:31 |
| 2026-09-28 11:32 (7.2.8) | current | (running) |

Note the 2026-09-28 morning: the box churned through **three** boots in 20
minutes. `last -x | grep -c crash` = **25** versus **3** clean shutdowns.

**How to tell a hang from a panic.** A panic/oops writes a fresh journal entry,
so the next boot has a clean journal plus a visible trace. Here every unclean
event is followed by:

```
systemd-journald: File /var/log/journal/…/system.journal corrupted or
                  uncleanly shut down, renaming and replacing.
```

i.e. the kernel never got to flush anything — it was reset underneath. With
`sp5100_tco` armed and systemd's 10-minute watchdog, a full-system hang is
reaped by hardware, and the hang itself leaves **no** trace. That single fact is
why this has been hard to pin down, and it is the thing to fix first (§7).

---

## 3. The crash signatures

All four recent unclean boots, key excerpt each (from `journalctl -k -b <-N>`;
`-1` is the boot *before* the crash, since the crash leaves nothing in its own):

**a) Per-CPU page allocator soft lockup** (boot `-2`, 2026-09-28 11:17):
```
watchdog: BUG: soft lockup - CPU#13 stuck for 309s! [kworker/13:1:145]
Call Trace:
  decay_pcp_high+0x65/0xa0
  refresh_cpu_vm_stats+0x13c/0x2d0
  vmstat_update+0x13/0x50
  process_one_work+0x199/0x370
  worker_thread+0x177/0x2e0
```
A worker spinning for **309 seconds** inside `decay_pcp_high` is not a busy CPU —
it is a corrupted/livelocked per-CPU pageset. That is a *data* problem.

**b) Wild kernel write** (boot `-4`, 2026-09-28 01:41):
```
BUG: unable to handle page fault for address: 0000000000008020
#PF: supervisor write access in kernel mode
#PF: error_code(0x0002) - not-present page
```
The kernel dereferenced a bogus near-null pointer and tried to *write* to it.

**c) Corrupted mm accounting** (boot `-3`, 2026-09-28 11:06):
```
BUG: Bad rss-counter state mm:00000000a092ac18 type:MM_FILEPAGES val:-1 Comm:nix
BUG: Bad rss-counter state mm:00000000a092ac18 type:MM_ANONPAGES val:1 Comm:nix
```
Negative rss counters mean the mm's per-page-type accounting went backwards.

**d) Transmit queue timeout** (boot `-5`, 2026-09-27 20:51):
```
r8169 0000:08:00.0 lan: NETDEV WATCHDOG: CPU: 5: transmit queue 0 timed out 5001 ms
```

Different subsystems, one theme: the kernel's *bookkeeping data structures* are
being corrupted or the CPU is stalling on memory access — never "a core produced
a wrong answer". Compare `kernel-rcu-wedge.md`, whose trigger was likewise a
memory-management oops (`__pgalloc_tag_sub` during `exit_mmap`).

The 2026-08-23-era RCA also matters here: `kernel-rcu-wedge.md` logged
`Tainted: G S U O` and called out **[S] = CPU_OUT_OF_SPEC** as a possible
cause. `S` is **still set today**:
```
Tainted: G S   U              7.2.8 #1-NixOS PREEMPT(lazy)
Tainted: [S]=CPU_OUT_OF_SPEC, [U]=USER
```

---

## 4. Configuration facts relevant to stability

### Memory — the sore spot

`sudo dmidecode -t 17` (or `scripts/ram.sh`):

| Slot | Channel | Size | Part number | Rated | **Configured** |
| --- | --- | --- | --- | --- | --- |
| DIMM 0 | P0 CHANNEL A | 16 GiB | `CMK32GX4M2Z3600C18` | 3600 MT/s | **2133 MT/s** |
| DIMM 1 | P0 CHANNEL A | 32 GiB | `CMK64GX4M2D3600C18` | 3600 MT/s | **2133 MT/s** |
| DIMM 0 | P0 CHANNEL B | 16 GiB | `CMK32GX4M2Z3600C18` | 3600 MT/s | **2133 MT/s** |
| DIMM 1 | P0 CHANNEL B | 32 GiB | `CMK64GX4M2D3600C18` | 3600 MT/s | **2133 MT/s** |

Three things stand out:

1. **Two different Corsair kits are mixed** (2×16 GB + 2×32 GB) — different
   rank/size geometry on the same channel.
2. **Four DIMMs, two per channel.** Cezanne's IMC is happiest with two; four
   (especially mixed) is the hardest topology, and it is the first thing AMD
   and board vendors point at for "random" instability.
3. **Everything is at JEDEC 2133** although the DIMMs are rated 3600 — i.e.
   EXPO/XMP is **off**. Either it was switched off after trouble, or the board
   fell back after failed training. Both readings say memory has been the weak
   point of this build.

There is **no ECC and no EDAC telemetry** on this board
(`/sys/devices/system/edac/mc/` has no `mc0`), so correctable errors are
invisible and there is no counter to watch.

### Kernel command line (`/proc/cmdline`)

```
amd_iommu=on  pcie_aspm=off
amdgpu.gttsize=90112  ttm.pages_limit=23068672 amdttm.pages_limit=23068672
amdgpu.vm_update_mode=3  amdgpu.gpu_recovery=1  amdgpu.lockup_timeout=10000
amdgpu.runpm=0  amdgpu.ppfeaturemask=0xffffffff  mitigations=off
```

- `amdgpu.gttsize=90112` = **88 GB of GTT** on a 96 GB box, with a matching
  `ttm.pages_limit` (~88 GB). See `docs/gtt-vram.md` for why this exists.
- `amdgpu.ppfeaturemask=0xffffffff` enables **all** overdrive features, and the
  kernel warns about it at boot:
  `amdgpu: Overdrive is enabled, please disable it before reporting any bugs
  unrelated to overdrive.` It also logs, repeatedly:
  `amdgpu 0000:03:00.0: Invalid overdrive table content: OD_UNSUPPORTED_FEATURE`
  → `Failed to upload overdrive table, ret:-5`.
- `amdgpu.gpu_recovery=1 lockup_timeout=10000 vm_update_mode=3 runpm=0` — a pile
  of GPU-stability knobs already in place, i.e. someone has been fighting GPU
  hangs here for a while.
- `mitigations=off` — CPU vulnerability mitigations disabled (affects exposure,
  not stability, but it is a conscious taint-adjacent choice).
- **IOMMU timeouts**, logged on essentially every boot:
  `AMD-Vi: IOMMU 0000:00:00.2: Completion-Wait loop timed out` and
  `iommu ivhd0: AMD-Vi: Event logged [IOTLB_INV_TIMEOUT device=0000:06:00.0 …]`.
  `0000:06:00.0` is the **idle** RX 580 — so this is not load-dependent.
  `kernel-rcu-wedge.md` already dismissed it as a pre-existing quirk, but it is
  not nothing: it means IOMMU↔device translation is misbehaving at boot.

### Other

- **BIOS FDb (2023-06-01)** is old for a B550 + Cezanne + 4-DIMM box; AGESA
  memory-compatibility fixes have landed repeatedly since.
- The out-of-tree `ddcci` module still exists in the config
  (`common/cosmic.nix`) and appeared in earlier boots' module lists; it is the
  only OOT module on the box.

---

## 5. What the stress test proved (2026-09-28)

Run via the harness added with this doc (`scripts/stress-monitor.sh`), which
samples die temp, all-core clock, RAPL package power, GPU junction/power and the
hottest board sensor every 10 s, and writes `/dev/kmsg` start/end markers so any
new kernel fault is attributable to the run.

**Phase 1 — CPU compute (the ask):**
```
stress-monitor.sh cpu 720 --cpu 16 --cpu-method all
```
| Metric | Result |
| --- | --- |
| Workers / duration | 16 (all 16 threads) / 720 s |
| Methods | `--cpu-method all` (every stressor: int, float, fft, matrix, prime, …) |
| Verification | `--verify` on (results recomputed & compared) |
| Result | **`passed: 16  failed: 0  skipped: 0`**, exit 0 |
| Throughput | 17,035,356 bogo-ops @ 23,660 ops/s |
| CPU busy | 95.64 % user, 3.04 s system |
| Peak die temp | **70 °C** (`Tctl`) |
| All-core clock | 4.30–4.32 GHz, flat |
| Throttling | none; zero MCE; zero kernel faults in the window |

**Phase 2 — memory subsystem (partial, deliberately stopped):**
`--cpu 4 --cache 4 --cache-enable-all --cache-permute --vm 4 --vm-bytes 2G
--vm-method all --memthrash 2 --memthrash-method all`. Ran ≈ 3.5 min before being
stopped; **no faults observed**, die 57–61 °C. This is *not* a pass — it needs a
multi-hour soak (§8).

**Conclusion:** the 5700G's compute path, its cache, and its ability to hold
4.3 GHz at 70 °C are all fine. If the CPU is implicated at all, it is the
**memory/Infinity-Fabric side of PBO** (which `stress-ng --cpu` barely touches),
not the execution units.

Reproduce with:
```sh
scripts/stress-monitor.sh cpu 720 --cpu 16 --cpu-method all      # ~75 s of my time, 12 min wall
scripts/stress-monitor.sh mem 3600 \
    --cpu 4 --cpu-method all --cache 4 --cache-enable-all --cache-permute \
    --vm 4 --vm-bytes 2G --vm-method all --memthrash 2 --memthrash-method all
```

---

## 6. Hypotheses, ranked

### H1 (top) — unstable memory subsystem / IMC
*For:* all four signatures are mm/VM bookkeeping (§3); the topology is the worst
case (§4); the kernel flags CPU_OUT_OF_SPEC; no ECC to catch it; memtest86 does
not exercise runtime access patterns or the IMC at PBO settings.
*Against:* no MCE/EDAC evidence (there can't be — no ECC). Memtest passing is
weakly reassuring for the DRAM *cells*.
*Falsify:* run 24–48 h with **two DIMMs only** (one kit). Stable ⇒ it's the
4-DIMM/mixed config. Then add the second kit back and watch it fail.

### H2 (strong) — amdgpu GTT/overdrive + IOMMU
*For:* 88 GB GTT config; overdrive enables everything and *fails to apply* the
table; IOMMU translation timeouts on every boot; pre-existing GPU-stability
knobs everywhere. "Bad rss-counter state" is a known companion of amdgpu
userptr/GTT accounting bugs — so H1 and H2 may even be one bug.
*Falsify:* drop the overdrive bits from `ppfeaturemask`, and/or try
`iommu=pt` (passthrough) or `amd_iommu=off`; reduce `amdgpu.gttsize` to
something sane (e.g. 12–16 GB). If the IOMMU timeouts and crashes both stop, the
chain is implicated.

### H3 (enabler) — bleeding-edge + tainted kernel
*For:* `7.2.8` (`linuxPackages_latest`), tainted, `mitigations=off`, OOT `ddcci`.
A new kernel makes mm/amdgpu regressions likelier; `kernel-rcu-wedge.md` §2–3
already recommended trying the LTS line if oopses recurred.
*Falsify:* boot `pkgs.linuxPackages` (LTS 6.12) for a week. Nothing here needs a
bleeding-edge kernel (`gfx1201` amdgpu support landed in 6.10).

### Not hypotheses
- **CPU compute / thermals / PSU:** 12 min all-core at 70 °C with zero
  verification failures (§5). PSU is only partially ruled out — the GPU was
  already pulling 300–400 W throughout, but we never deliberately maxed
  CPU+GPU together.
- **The qemu GPFs:** the repeated
  `traps: qemu-system-ris[NNNN] general protection fault ip:… in
  libglib-2.0.so.0.8400.3[…4fd10…]` hit the **same offset every time** across
  many processes. Hardware corruption is not that tidy — this is a deterministic
  bug in the esp32p4 qemu fork. Ignore it.

---

## 7. The real problem: no crash dump

```
$ ls /sys/fs/pstore/          # empty
```
Every hang is reset by the TCO watchdog, so the kernel never writes an oops and
pstore is never populated. **Fix this before running any more experiments**, or
you'll keep re-deriving the same conclusions.

Options, cheapest first:

1. **`ramoops`/pstore** — reserve a small physical RAM region and mount pstore;
   survives a hard reset and captures the panic/oops the watchdog resets over.
   Requires a reserved-memory DT/ACPI node (and, on this board, likely a kernel
   param), so it's a config change, not a one-liner.
2. **netconsole** — ship kernel messages over UDP to another host. One
   `boot.kernelParams` addition + `netconsole` module; captures the *last*
   messages before a hang even if nothing is written to disk.
3. **`kdump`/kexec crashkernel** — heavier, but gives a full vmcore.
4. **Cheap monitoring while you decide** (from `kernel-rcu-wedge.md` §5):
   ```sh
   sudo journalctl -k -b | grep -cE "Oops|BUG:|rcu.*stall"   # expect 0
   sudo journalctl -k -b | grep -m1 'Previous system reset reason'
   ```

Also relevant: the 10-minute TCO timeout bounds how long a *wedged* box stays
wedged, and a hang that the watchdog resets is **not** the same as a box that
power-cycles the PSU (which would leave no "reset reason" at all).

---

## 8. Next tests — one variable at a time

Ordered by (value ÷ effort), not by my confidence:

1. **Capture-first (§7).** Enable netconsole (fastest) and/or ramoops. Without
   it, tests 2–5 are guesses.
2. **Two-DIMM test (highest signal).** Power off, remove one kit, run for
   24–48 h under normal load. Then swap to the other kit. Then both. This is the
   single cheapest way to falsify H1.
3. **BIOS update** FDb (2023-06) → latest. Contains AGESA memory fixes;
   low effort, no downside, and takes effect on the same reboot as a DIMM change.
4. **Soak the memory path** rather than trusting a 12-minute CPU run:
   `scripts/stress-monitor.sh mem 7200 …` (see §5 for args), overnight, with
   pstore armed. Watch for a *repeat* of any §3 signature.
5. **Isolate the GPU/IOMMU (H2).** One change at a time, each for a week or
   until it crashes:
   - remove overdrive from `ppfeaturemask` (the kernel explicitly asks for this);
   - `amdgpu.gttsize` back to a sane value;
   - `iommu=pt` (passthrough is much cheaper than full translation and is the
     usual fix for `IOTLB_INV_TIMEOUT`);
   - if all quiet, re-enable one at a time.
6. **LTS kernel (H3).** `boot.kernelPackages = pkgs.linuxPackages;` — a week.
7. **Re-check PBO (the `S` taint).** If the BIOS has PBO/Curve-Optimiser/etc.
   enabled, set a stock profile and re-run the 2-DIMM test with it. The kernel
   flagging CPU_OUT_OF_SPEC means the CPU is being run outside spec *by design*;
   that is a legitimate thing to blame.

Do **not** in the meantime: `fsck` the NVMe (the block layer was never the
problem), or chase the qemu GPFs.

---

## 9. Reference — commands used

```sh
# Is it a hang or a panic? Did it reboot cleanly at all?
last -x -F | grep -i crash
last -x | grep -c crash ; last -x | grep -c 'shutdown system down'
journalctl --list-boots --no-pager | tail -15

# The crash evidence (the crashing boot leaves nothing; look at the one before)
for b in -2 -3 -4 -5; do
  journalctl -k -b "$b" --no-pager | grep -iE \
    'Oops|BUG:|soft lockup|page fault|rcu.*stall|rss-counter|NETDEV WATCHDOG' | tail
done

# Is the kernel reporting an out-of-spec CPU / which taints are live?
cat /proc/sys/kernel/tainted
journalctl -k -b 0 | grep -E 'Tainted:'

# Hardware inventory
scripts/ram.sh                       # DIMM sizes/channels
sudo dmidecode -t 17                 # + rated vs configured speed  ← key
sudo dmidecode -t bios -t baseboard  # BIOS version / date
cat /proc/cmdline                    # amdgpu.gttsize, ppfeaturemask, iommu…
ls /sys/fs/pstore/                   # empty here — see §7

# Telemetry around a stress run
scripts/stress-monitor.sh cpu 720 --cpu 16 --cpu-method all
journalctl -k --since "<run start>" | grep -iE 'mce|thermal|soft lockup|BUG:'
```

---

## 10. Relationship to `kernel-rcu-wedge.md`

| | `kernel-rcu-wedge.md` (2026-08-26) | this doc (2026-09-28) |
| --- | --- | --- |
| Failure mode | oops → **RCU grace periods never complete**; box stays up, filesystem looks frozen | whole box **hangs**, TCO watchdog resets it |
| Trigger signature | `__pgalloc_tag_sub` oops in `exit_mmap` | `decay_pcp_high` soft lockup, `0x8020` write PF, bad rss-counters |
| Evidence left | full oops + RCU stall traces + D-state stacks | **nothing at the crash** — only a corrupted journal |
| Recovery | reboot | reboot (automatic, via watchdog) |
| Taint then / now | `G S U O` | `G S U` |
| Shared thread | **[S] = CPU_OUT_OF_SPEC** — flagged as a suspect in Aug, still set in Sep | §5 finally stress-tests the CPU; compute is clean, so if `S` is to blame it is the memory/IF side |

The Aug doc's recommendation §4 — *"verify stability (memtest86+, stress-ng) and
consider a stock PBO profile"* — is now half-done: memtest and stress-ng both
pass, so that recommendation is unsatisfied rather than refuted, and points at
the IMC/profile rather than the cores.
