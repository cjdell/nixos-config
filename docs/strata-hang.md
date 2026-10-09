# Strata hang → SIGABRT → core dump → GPU reset (2026-10-05 … 10-08)

Companion to [`strata.md`](strata.md) (serving) and [`strata-degeneration.md`](strata-degeneration.md)
(non-finite logits). **Different failure class**: nothing here is NaN — the GPU stops making
progress, Strata's watchdog kills the engine, and the kernel resets the card.

## TL;DR

- The "core dumps" are **not crashes**. Strata has a hang watchdog (upstream issue
  **[#29](https://github.com/Niko1221/Strata/issues/29)**) that `SIGABRT`s the engine after 60 s
  without progress, so the serve layer can restart it. 7 of them, 2026-10-05 → 10-08, across
  **four builds** (0.1.39, 0.1.40.1, 0.1.40.2, 0.1.40.3) — not a 0.1.40.3 regression.
- **Every abort is a wedged R9700.** Each one is followed within seconds by the amdgpu MES
  teardown failing and a MODE1 GPU reset (`VRAM is lost due to GPU reset!`). The reset is the
  *recovery*, not the cause.
- **The cores are worthless and huge.** One was on disk: **32 GB** on `/` (81 G free). `bin/strata`
  is stripped with **no build-id**, so there is nothing to symbolize; all 41 threads sit in libc
  syscall stubs waiting on the GPU; the 32 GB is the ~46 GiB of routed experts + KV in RAM.
  Deleted 2026-10-08; `LimitCORE = 0` now set in `hosts/zen3-nixos/ai/strata.nix`.
- **The useful signal is the journal line**, which names the stall: always **prefill**, always
  "waiting for the GPU (attention, router)", at 49K–186K tokens.
- **Most likely fix to try:** `HSA_USERPTR_FOR_PAGED_MEM=0` — upstream report **#750 is two
  Radeon AI PRO R9700 on ROCm 7.2**, which is exactly this box (clr/hipblaslt **7.2.3**).
  **Applied 2026-10-08** in `hosts/zen3-nixos/ai/strata.nix`; takes effect on the next switch.

## 1. The inventory

`sudo coredumpctl list strata` (run it with **sudo** — the files are `root:root 0640` and show up
as `inaccessible` to a normal user):

| when (BST) | pid | sig | core | build |
| --- | --- | --- | --- | --- |
| 10-05 15:02:39 | 243406 | SIGABRT | none | 0.1.39 `skc1qpvfdi606…` |
| 10-06 13:35:15 | 276673 | SIGABRT | none | 0.1.39 |
| 10-07 15:25:59 | 782070 | SIGABRT | none | 0.1.40.1 `vl353xnf6ccd…` |
| 10-07 21:38:38 | 962264 | SIGABRT | missing | 0.1.40.2 `v63bhabzfxwg…` |
| 10-08 02:14:47 | 1074362 | SIGABRT | missing | 0.1.40.3 `mcvch76h0ab3…` |
| 10-08 03:39:19 | 1736 | SIGABRT | missing | 0.1.40.3 |
| 10-08 21:30:30 | 1757 | SIGABRT | **32 GB on disk → deleted** | 0.1.40.3 |

The dump lived in `/var/lib/systemd/coredump` on **`/` (`nvme0n1p3`, 81 G free)** — not `/home`.
One more would have been a third of the free root filesystem.

## 2. What the engine says (this is the useful part)

Engine log (`/var/lib/strata/strata.log`, no timestamps, binary-ish — read it with `strings`):

```
strata serve: no progress for 60 s during a request (reading the prompt (batched):
waiting for the GPU (attention, router) at layer 11 of the prompt chunk from token 185686)
- stopping the engine so the server starts it again (issue #29)
```

Every site captured in the current log:

| layer | token offset |
| --- | --- |
| 3 | 105599 |
| 11 | 49345 |
| 11 | 76950 |
| 11 | 185686 |
| 19 | 129984 |
| 31 | 61606 |

**Always `reading the prompt (batched)` — never decode.** The layer varies, so it is not one
kernel; the common factor is long-prompt prefill on the attention/router step, in the same
130K–186K regime as the degeneration incidents.

The unit then logs (journald, `-u strata`):

```
[strata] the engine stopped unexpectedly (exit code -6). The engine stopped itself because it had
stopped making progress - a hang it caught. … - stopping the engine so the server starts it again
(issue #29) … The next request starts the engine again.
```

**Gotcha: `NRestarts=0` does not mean healthy.** `bin/strata-server` (the wrapper, e.g. pid 1289)
supervises the engine child (the one that dumps core, e.g. pid 1757) and restarts it *in-process*,
so systemd never sees a failure and `Restart = "on-failure"` never fires.

## 3. What the kernel says

Identical signature every time, on the R9700 only (BDF is `09:00.0` this boot, `03:00.0` in
earlier boots — the NVMe/GPU kernel names and BDFs shuffle between boots, match by device):

```
MES(0) failed to respond to msg=REMOVE_QUEUE
MES(0) failed to respond to msg=SUSPEND
failed to suspend all gangs
failed to suspend gangs from MES
MES might be in unrecoverable state, issue a GPU reset
failed to remove hardware queue from MES, doorbell=0x1004
Failed to evict queue 3
Failed to evict process queues
GPU reset begin!. Source:  3
remove_all_kfd_queues_mes: Failed to remove queue 2 for dev 2741
MODE1 reset → GPU mode1 reset → GPU smu mode1 reset
GPU reset succeeded, trying to resume
VRAM is lost due to GPU reset!
GPU reset(1) succeeded!
[drm] device wedged, but no recovery needed        (boot 0)
[drm] device wedged, but recovered through reset   (boot -3)
```

Abort ↔ reset correlation (`journalctl -b N -k | grep -c 'GPU reset begin'` vs `-u strata | grep -c 'no progress for'`):

| boot | strata hang aborts | amdgpu GPU resets |
| --- | --- | --- |
| 0 | 1 (21:30:30) | 1 (21:30:34 → `reset(1) succeeded` 21:30:36) |
| -1 | 0 | 0 |
| -2 | 1 (03:39:19) | 1 (03:39:21) |
| -3 | 2 | 8 |

**Read the causality carefully.** The MES `REMOVE_QUEUE`/`SUSPEND` failure is *downstream*: the GPU
had already stopped making progress (that is why the watchdog fired), and when the process dies the
kernel tries to evict its KFD queues, MES will not answer, so it escalates to a MODE1 reset. The
`coredumpctl` timestamp can trail the reset by ~40 s because zstd-compressing 32 GB takes that long.

**How this differs from [`r9700-smu-hangs.md`](r9700-smu-hangs.md)** (the 2026-10-01 llama-server
era): there is **no `ring gfx_… timeout` drm_sched line and no SMU "I'm not done" preamble** in any
of the strata-era events. Same card, same reset path, different entry point — MES queue teardown
rather than an SMU lockup. SMU fw is still **104.80.0** (`0x00685000`, verified in dmesg on every
boot); the firmware A/B proposed in that doc (§7) was **never applied**.

## 4. What the core dump actually contains (why it is not worth keeping)

Parsed the 32 GB one without gdb — `sudo zstd -dc <core>.zst | head -c 256MiB > /tmp/core.head`,
then walk the ELF64 program headers and the `PT_NOTE` notes in python3:

- **806 notes, 41 threads** (`NT_PRSTATUS`, note type 1), **`si_signo = 6` / `cursig = 6` on every
  thread** → a deliberate `SIGABRT`, not a fault.
- **`NT_FILE` (type `0x46494c45`): 501 file mappings.** Kernel 7.2.9 note: the desc carries **one
  extra `u64` after the count** — entries start at desc offset **16**, not 8 (start, end, pgoff per
  entry, then the NUL-terminated names). Getting this wrong yields garbage mappings.
- **All 41 threads parked in libc syscall stubs** (`poll`/`ioctl`/`futex` regions) — the process was
  *waiting*, not spinning, consistent with a GPU fence that never returns.
- **`bin/strata` is stripped and has no `PT_NOTE` build-id** → no symbols, and no way to tie a core
  to a build. gdb would add nothing.
- The 32 GB is the private RW mappings: the ~46 GiB of routed experts + the int8 KV cache in RAM.

So: a core dump here tells you *that* it aborted, which the journal line already says better.

## 5. Upstream context — and the fix most worth trying

- The watchdog itself is **#29**; the message asks for reports. Same class, other hardware:
  **#964** (verify windows), **#1407** (gfx1200 layer split, prompt-read stalls), **#1500**
  (strix halo), **#251**.
- **Strata's own `docs/AMD_HIP.md` § "Linux: verify timeouts while the kernel reclaims host
  memory (experimental workarounds)"** describes a mechanism that fits this box exactly: the GPU's
  queues are suspended while the kernel reclaims host pages the GPU pinned through a **KFD
  userptr**, and a restore that keeps returning **`-EAGAIN`** leaves them suspended for tens of
  seconds.
  - **#750 — two Radeon AI PRO R9700, ROCm 7.2**: `HSA_USERPTR_FOR_PAGED_MEM=0` in the server JSON
    `env`. Five paired runs gave the same outputs and the same median (16.65 s vs 16.63 s) and the
    29.8 s / 42.2 s outliers disappeared; solo requests a little slower (3.55 s → 3.69 s).
    **This box: R9700 + clr/hipblaslt 7.2.3** (`ldd` on `bin/strata`) — the closest match available.
  - **#920 — RX 6800 with `--mmap-experts`**: `GPU_PINNED_MIN_XFER_SIZE=1048576` fixed every run.
    (Less applicable here — we use the packed/native expert path, not `--mmap-experts`.)
  - **On a systemd unit use `MemoryMax`, never `MemoryHigh`** — `MemoryHigh` counts the page cache
    `--mmap-experts` reads from, and a 16K prompt stalled in `pread` for 8 minutes under it.
- `docs/TROUBLESHOOTING.md` (Windows TDR section) notes the same shape on **gfx1201 with
  `--kv-resident 32768` while reading a long prompt** — our exact configuration
  (`--kv int8 --kv-resident 32768`, `--max-context 262144`). Its ladder, in order:
  `STRATA_PF_STEP_SYNC=1` (waits for the GPU after each prompt step and logs any step over 250 ms —
  names the step, slower, diagnostic only), `STRATA_KV_HOST_DMA=1` (the KV RAM copy is written by
  DMA instead of by a GPU kernel; same answers), drop `--kv-resident`, or shrink the chunk with
  `--prefill 512`.
- Our log already carries the engine's own hint: `STRATA_HIP_WMMA=1` "reads prompts about 30%
  faster on this card with `--kv int8` (prompt attention on the matrix cores); off by default
  because the output bits change (last-place rounding)". Since the stall is in **prompt
  attention**, this swaps in a different kernel — worth a try, with the bit-change caveat (and it
  interacts with the finiteness guard work in `strata-degeneration.md`).
- **0.1.41 (pinned 2026-10-09, not yet live) adds two watchdog layers, neither a fix
  for our shape.** The #29 engine watchdog now tolerates up to `STRATA_WATCHDOG_IO_S`
  (default 10× the 60 s limit) of silence *while the file tier is still being read*
  (#1407) — ours say `waiting for the GPU (attention, router)`, not `reading experts`,
  so this only removes a slow-storage false-positive class. And `serve/server.py` now
  ends + restarts an engine silent for `STRATA_ENGINE_STALL_S` (90 s) that also uses no
  CPU time, no disk bytes and an idle GPU (#1317); it needs `psutil`, which
  `serverPython` in `strata-package.nix` already bundles, so it is live the moment we
  switch. `stall_report` also prints more (`batch_groups` counters, `#1341`
  `CUDA_LAUNCH_BLOCKING` warning). No change to the abort itself, and `LimitCORE = 0`
  still keeps the dumps off.

## 6. State of the config

Applied (needs `nixos-rebuild switch` to take effect — zen3-nixos has autoRollback commented out,
so **no `nixos-confirm`**):

- `LimitCORE = "0"` in `hosts/zen3-nixos/ai/strata.nix` `serviceConfig` — no more 32 GB dumps.
- `env.HSA_USERPTR_FOR_PAGED_MEM = "0"` in `configFile` — the #750 match, applied 2026-10-08.
  Verified the knob is real in our runtime: the string `HSA_USERPTR_FOR_PAGED_MEM` is present in
  `libhsa-runtime64.so.1` from `rocm-runtime-7.2.3` (and `GPU_PINNED_MIN_XFER_SIZE` in
  `libamdhip64.so.7` from clr 7.2.3).
- The 32 GB core deleted; `/var/lib/systemd/coredump` is empty, `/` back to 81 G free.

**Verification after the switch** — the engine must actually have it:

```sh
pid=$(pgrep -f '[b]in/strata --serve'); sudo tr '\0' '\n' < /proc/$pid/environ | grep -i userptr
```

Then watch for regressions: `no progress for 60 s` should stop appearing, and prefill speed should
stay within a few percent (upstream saw solo requests go 3.55 s → 3.69 s).

Still **not** applied (change one at a time and re-measure):

1. `env.GPU_PINNED_MIN_XFER_SIZE = "1048576"` — the #920 knob (confirmed present in clr 7.2.3);
   next candidate if the userptr change does not move it.
2. `env.STRATA_KV_HOST_DMA = "1"`, or `--prefill 512`.
3. `env.STRATA_PF_STEP_SYNC = "1"` to *diagnose* which step stalls (slower — remove afterwards).
4. `STRATA_NO_HANG_ABORT=1` keeps the engine alive instead of aborting. **Not recommended**: the
   abort is what releases the wedged queues, so this can leave the GPU stuck with no reset and the
   VRAM never reclaimed.
5. The SMU fw 104.79.0 pin from `r9700-smu-hangs.md` §7 — still unapplied, still a live hypothesis.
6. If the unit ever needs a memory cap, use `MemoryMax`, **never `MemoryHigh`** (upstream: a 16K
   prompt stalled in `pread` for 8 minutes under `MemoryHigh`).

## 7. Commands

```sh
sudo coredumpctl list strata                       # sudo, or everything reads "inaccessible"
journalctl -u strata -o short-iso | grep -B2 -A6 "no progress for"
sudo strings /var/lib/strata/strata.log | grep -iE "no progress|WMMA|issue #29"
journalctl -b 0 -k | grep -E "MES\(0\)|unrecoverable|GPU reset|MODE1|VRAM is lost|wedged"
for b in 0 -1 -2 -3; do printf 'boot %s: aborts=%s resets=%s\n' "$b" \
  "$(journalctl -b $b -u strata | grep -c 'no progress for')" \
  "$(journalctl -b $b -k | grep -c 'GPU reset begin')"; done
dmesg | grep 'smu fw version'                      # 0x00685000 = 104.80.0
ldd /nix/store/<hash>-strata-<ver>/bin/strata | grep -iE "hsa|hip"   # ROCm runtime version
df -h / ; du -sh /var/lib/systemd/coredump          # watch for new dumps
```
