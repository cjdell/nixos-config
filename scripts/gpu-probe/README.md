# gpu-probe — selective GPU stress ladder

Hunt a "flaky GPU" by **varying one axis at a time** until a step kills it,
instead of running one big benchmark that passes and confusing you.

The reason this exists: a card that is rock solid in FurMark can die inside
Folding@home in six seconds, and no amount of GL benchmarking will show why.
GL exercises the 3D pipeline; a compute workload exercises the SMs through CUDA
or OpenCL, the copy engines, different `di/dt` current profiles, and a different
PCIe traffic pattern. If you don't vary those independently you can't tell a
dying card from a marginal PCIe link from a driver path.

No CUDA toolkit, no compiler, no root install needed. Compute kernels are
hand-written **PTX JIT'ed by the driver** (`libcuda` via `ctypes`); the OpenCL
programs are compiled at runtime by the vendor ICD.

## Build

```sh
nix build .#gpu-probe            # → result/bin/{gpu-probe,gpu-probe-ladder,gpu-probe-arm}
```

## One axis at a time, by hand

```sh
./result/bin/gpu-probe ctx        --seconds 60      # CUDA context up, zero work
./result/bin/gpu-probe churn      --seconds 60      # ~100k tiny launches + host sync / s
./result/bin/gpu-probe continuous --seconds 60      # long SM kernels, no launch churn
./result/bin/gpu-probe dma        --seconds 60      # pinned H2D/D2H, link saturated, SM idle
./result/bin/gpu-probe vram       --seconds 60      # GDDR5 hammer (>>L2), no PCIe
./result/bin/gpu-probe alloc      --seconds 60      # VRAM alloc + first-touch + free churn
./result/bin/gpu-probe ocl_fma    --seconds 60      # same ALU work via the OpenCL ICD
./result/bin/gpu-probe ocl_churn  --seconds 60      # same churn via the OpenCL ICD
./result/bin/gpu-probe mixed      --seconds 60      # compute + concurrent pinned DMA
```

`--gpu N` selects the CUDA/OpenCL device index; on a multi-GPU box also export
`CUDA_DEVICE_ORDER=PCI_BUS_ID` so the index means the slot. The probe logs the
device name and PCI bus id on the first line — check it stresses what you think.
Modes whose runtime is absent exit 18 (`SKIP: ...`) instead of failing, so the
same table runs on AMD hosts (OpenCL via Rusticl / the amdgpu ICD).

## The ladder (survives the reboots a kill requires)

A card that falls off the bus cannot be reclaimed without a reboot, so the
runner is a per-boot state machine: verdict → `results.log` → reboot → next step.

```sh
./result/bin/gpu-probe-arm arm --steps default --link gen3 --power-limit 120
./result/bin/gpu-probe-arm status
./result/bin/gpu-probe-arm disarm          # also: touch ~/.local/state/gpu-probe/ABORT
./result/bin/gpu-probe-arm reset           # clear step + reboot counters
```

It installs a **user** unit with linger (`/etc` is read-only on NixOS, so system
units must come from the flake) and uses `sudo -n` only for the privileged bits:
power limit, PCIe retrain, `systemctl stop/mask`, and the recovery reboot.

| option | meaning |
| --- | --- |
| `--steps NAME` | `default` (12 axes), `xid79` (+ the real FAH control), `quick` (¼ time), `traditional` (standard tools, no FAH) |
| `--only a,b` | run just those steps |
| `--link gen3\|gen1\|keep` | force the root-port target speed (retrain ×3) and log what it holds |
| `--power-limit W` | set it, **then verify it held** — stale units love to revert caps |
| `--gpu N` | device index for every step |
| `--no-reboot` | never reboot: halt on the first kill (use when you want to inspect) |
| `--state-dir DIR` | default `~/.local/state/gpu-probe` (never in git). `gpu-probe-arm` passes its own `GPU_PROBE_STATE_DIR` through, so two campaigns can run side by side without overwriting each other's evidence |
| `--max-reboots N` | give up after N reboots (default 14) |

## `traditional.tsv` — separating "the card is sick" from "this box is sick"

When the custom axes all pass and only one real application dies, you need tools
whose behaviour other people also know. `steps/traditional.tsv` is that table:
`glmark2-wayland` (the FurMark class of test), `memtest_vulkan` (VRAM with data
verification), `clpeak` (OpenCL bandwidth + FP32/FP64), `hashcat -b` (the full
kernel sweep), `stress-ng --cpu --cpu-method all` / `--vm`, `stressapptest`,
`memtester`, `sysbench`, then a combined CPU+VRAM step and a re-run of the most
sensitive GPU probe last (healthy-before *and* healthy-after is the proof).
Deliberately **no Folding@home anywhere in it** — that is the thing under test.

```sh
nix build .#gpu-probe-traditional          # same ladder + the standard tools on ITS PATH
GPU_PROBE_STATE_DIR=~/.local/state/gpu-probe-trad ./result/bin/gpu-probe-arm \
    arm --steps traditional --power-limit 120
```

The tools are baked into the *ladder wrapper's* PATH rather than the caller's
because the ladder outlives the shell that armed it: it is a user unit that
resumes after the reboots it triggers itself. `gpu-probe-arm` likewise copies
`PATH`/`DISPLAY`/`WAYLAND_DISPLAY`/`XDG_RUNTIME_DIR` into the unit, since a GL
step that cannot reach the compositor tests nothing.

Each step's `requires` column is checked with `command -v` before it runs, and a
missing tool is `SKIP-TOOL`, never a result. Verify the knobs on the target box
before trusting a table — these were wrong on first try and are wrong elsewhere:
`vkcubeoffscreen` does not exist in `vulkan-tools`; `y-cruncher` rejects `c 1g`
and wants a TTY; `glmark2` needs the `-wayland` (or `-gbm`/`-drm`) backend on a
Wayland session; `memtest_vulkan` is time-bounded with `--device=N --test=SECONDS`
and ignores flags it does not know instead of erroring.

## Reading the output

`results.log` is one line per event, greppable by design:

```
RESULT step=2 name=churn verdict=PASS rc=0 dur=171s alive=yes link=... x4
        link-transitions=0 unresponsive-samples=0 last-marker="[170932ms] launches+sync=19300000 ..." journal=""
```

Verdicts: `PASS` · `DIED` (kernel logged it) · `DIED-CARD-GONE` (NVML stopped
answering — the card vanished even if nothing was logged) · `TIMEOUT-STALL` (the
workload hung *and* the card stopped answering, which for a compute engine *is*
the fault) · `TIMEOUT-SLOW` (the step simply needed a bigger budget — not a fault,
no reboot) · `TOOLING-SKIP` (that runtime isn't installed) · `DRIVER-ERR` (API
error without a link event).

`runs/NN-step.csv` samples every 2 s: `gpu_W, gpu_limit_W, gpu_sm_MHz,
gpu_mem_MHz, gpu_C, throttle, util, memused, link, cpu_uj, cpu_mC` plus
`NN-step.csv.transitions`, the count of **link renegotiations during the step**.
For a Physical-Layer fault that counter is often the real signal, long before
anything crashes.

## Which axis rules out what

| step dies | suspect |
| --- | --- |
| `ctx` | driver/context bring-up, clock ramp out of idle — not load at all |
| `churn` | launch/ioctl path, queue teardown, DVFS transitions |
| `continuous` | sustained SM power/clock regulation |
| `dma` | PCIe link, copy engines, root-complex contention |
| `vram` | GDDR5 / memory controller (no ECC on GeForce — nothing logs these) |
| `alloc` | page tables, first-touch, VRAM size pressure |
| `ocl_*` but not `cuda` (or vice versa) | user-mode runtime, not silicon |
| `cpu` | the fault is not the GPU at all |
| `mixed_cpu` only | the sum: PSU/12 V transients, thermal, or root-complex load |
| `fah` only | whatever the ladder has not modelled — bisect the real core next |
| only `fah`, while `traditional` is clean | not silicon: the folding *path* — the core's bundled userspace, its `LD_PRELOAD`/`OCL_ICD_VENDORS`/`HOME` env, or the P0 transition of its first kernel. Bisect the environment before condemning the card |
| `gl_*`/`vram_*`/`ocl_*` all clean at ~150 GB/s with verification | the memory controller, the copy path and the vendor ICD are exonerated; a death at a few watts is then a *transition*, not load |

Also always check before blaming hardware: `journalctl -k | grep -E 'Xid|AER|CmpltTO'`,
and compare the *link speed line* across boots — a slot that cannot hold its
rated width/speed is a finding in itself, and it is a purely software-visible
one (`lspci -vvvs <rootport>` LnkSta, or the CSV's `link` column).

## Reproducing a *service's* workload, not just a workload

A card can survive everything you run from your own shell and die the moment the
deployed service runs the same thing, because the service hands the binary a
different userspace. Two tools exist for that, and both read the unit **live**
(`systemctl show`) so they cannot drift from what is deployed:

```sh
gpu-probe-envtest --unit fah-client --seconds 240 -- continuous --seconds 240
gpu-probe-envtest --unit fah-client --extra-ld auto --seconds 240 -- mixed --seconds 240
gpu-probe-fahcore-repro --from-scratch --cpu-load 8 --seconds 360   # a saved FAH WU
```

`envtest` re-runs any probe mode inside the unit's `Environment`/`User`/`Group`/
`SupplementaryGroups`/`PrivateTmp`/`ProtectHome`/`WorkingDirectory` via
`sudo systemd-run`; `--extra-ld auto` additionally prepends the newest OpenMM core
directory (its own CUDA 11.8-era `libCUFFT`/`libnvrtc`/`libOpenMMCUDA`).
`fahcore-repro` copies a real GPU work unit to `/run` (the original is never
written), stops + runtime-masks the client, and runs `FahCore_NN` against the copy
with the client's own argv, watching the bus every 2 s and logging watts/util/clocks
to a CSV. Verdicts: `REPRO-DIED-CARD-GONE` / `REPRO-DIED` / `REPRO-HUNG-AT-STEP-0` /
`MAKING-PROGRESS` / `FOLDING-NO-LOG-LINE-YET` (busy SMs but no "Completed" line yet —
the core only prints one per 25 000 steps, ~6 min) / `CORE-EXIT-200` / `CORE-ERROR-N`.

Three traps in that path cost a placebo run each, and they are worth knowing because
each one *looks like a result*:

- **`-lifeline 1` does not work.** The core polls that pid and hard-exits (no log)
  when it cannot signal it, and a service user cannot signal PID 1 (EPERM reads as
  "the client died"). The tool wraps the core in a script that owns a real lifeline.
- **The scratch dir must not be under `/tmp` or `/var/tmp`.** The launched unit
  inherits `PrivateTmp=yes`, so the directory does not exist in its namespace and
  systemd dies with `status=200/CHDIR` — indistinguishable from FAH's own exit code
  200 ("results ready"). The tool refuses such a path and says why.
- **Put the core's directory on `LD_LIBRARY_PATH`.** `FahCore_28`'s RPATH is the dead
  build path `/opt/conda/envs/build/lib` and it NEEDs `libOpenMMCPU.so` by plain
  soname; the real client supplies that for its child. Without it the core dies in
  the loader (127) and never reaches the GPU.

Because a reproduced kill always ends in a reboot, and `/run` is tmpfs, evidence
(CSV + the core's own `logfile_01.txt` / `science.log`) is copied to
`~/.local/state/gpu-probe/repro` before the run reports its verdict.

## `corebisect.tsv` — one env knob per step, once the fault reproduces

Run it as its own campaign so its `state`/`results.log` do not mix with another
ladder's:

```sh
GPU_PROBE_STATE_DIR=~/.local/state/gpu-probe-core ./result/bin/gpu-probe-arm \
    arm --steps corebisect --power-limit 120 --max-reboots 8
```

`ctrl_scratch` is a **positive control and must reproduce the kill**; every PASS
below it is meaningless if it does not, because then the fault simply went quiet.
The rest are single variables: `CUDA_MODULE_LOADING=EAGER`, `CUDA_LAUNCH_BLOCKING=1`,
core 27 (OpenMM 8.2.1) instead of 28, `--platform opencl` (hides the CUDA device so
OpenMM falls back to the ICD), no CPU load, and resume-from-checkpoint — the shape
that ran 4.4 h in production. Each step costs a reboot when it kills, which is what
the per-boot state machine is for.

## Traps learned while building this

- **`rc=124` is not a fault, it is a budget.** A `hashcat -b` step on 2026-11-20 was
  called `TIMEOUT-STALL`, rebooted the box, and was written up as a second kill —
  but the card was `alive=yes`, its CSV held no bad samples, and the log was full
  of completed benchmark speeds: it simply had not finished ~30 algorithms inside
  330 s. Now a timeout only counts as a stall if the card also stopped answering
  `nvidia-smi` in that window (`unresponsive-samples>0`); otherwise it is
  `TIMEOUT-SLOW` and the ladder carries on. Read the tool's own output before
  believing any verdict, including this one.
- `nvidia-smi -pl`/`-pm`, `setpci`, `systemctl` and `reboot` all need root; from a
  user service use `sudo -n`. A power limit that "was set" is not a power limit
  that *held* — verify with `--query-gpu=power.limit` under load, and trust
  `power.draw` + `clocks_throttle_reasons.active`, never `power.limit` alone.
- Runtime masks (`systemctl mask --runtime`) and hand-set caps **do not survive a
  reboot** — the ladder re-asserts both every boot, or it silently tests a
  different machine than the last boot.
- The legacy unversioned driver-API entry points (`cuMemAlloc`, `cuMemAllocHost`)
  reject a primary context with `CUDA_ERROR_INVALID_CONTEXT` (201); call the
  `_v2` symbols.
- In PTX the thread index is `%tid.x`, **not** `%threadIdx.x`; a bad special
  register surfaces as `218 CUDA_ERROR_NO_BINARY_FOR_GPU`, which looks like an
  architecture problem and is not.
- `rc=201` with `setpci`/sysfs means "you are not root past the first 64 bytes of
  config space", not "no capability".
- Never `pkill -f` a pattern that also appears in your own command line (this
  killed its own author's shell twice). Bracket it: `pkill -f 'gpu-[p]robe/run'`.
- Once a compute core is wedged inside a driver ioctl it is SIGKILL-proof, so a
  service stop job wedges too — that is a reboot, not a restart, and a `stop` in a
  test loop will burn your timeout.
