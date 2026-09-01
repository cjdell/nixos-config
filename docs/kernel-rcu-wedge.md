# Kernel oops wedges RCU — "filesystem slow", rebuilds hang (2026-08-26)

Post-mortem of an incident on `zen3-nixos` where the machine appeared to have
a dying filesystem (everything "slow", `nixos-rebuild` hung forever) but was
actually a **kernel bug** that permanently stalled RCU grace periods after an
oops. The disks were fine the whole time. Covers: what happened, what RCU is,
and how to avoid / recover from it next time.

## TL;DR

- At 13:41:55 a Nix build worker (`nixbld1`, PID 91104) exited and the kernel
  **oops'd** (`BUG: unable to handle page fault`) in `__pgalloc_tag_sub`, the
  page-allocation-tagging bookkeeping, while tearing down its memory during
  `exit_mmap`.
- The oops left that task's RCU state permanently stuck, so **no RCU grace
  period can ever complete**. Every kernel path that waits on RCU — dentry
  eviction, `open()`/`close()`, mount-namespace teardown, filesystem writeback
  bookkeeping — now blocks forever.
- Result: load average ~17 with 97% idle CPU, 16 tasks stuck in D-state
  (uninterruptible sleep), the filesystem *felt* dead, and `nixos-rebuild`
  hung because `nix-daemon` itself was stuck in an RCU wait.
- **Recovery is a reboot** — the stall cannot be cleared live.
- The NVMe drives were healthy the whole time (clean SMART, no I/O errors).

## Timeline

| Time (2026-08-26) | Event |
| --- | --- |
| 12:39 | Boot. (Also logged at boot: `iommu ivhd0: AMD-Vi: IOTLB_INV_TIMEOUT device=0000:06:00.0` — that's the RX 580; a pre-existing AMD-Vi quirk, unrelated.) |
| 13:41:55 | **Kernel oops** while PID 91104 (`ctrl-c`, UID 30001 = `nixbld1`) exits: page fault in `__pgalloc_tag_sub` during `exit_mmap → tlb_finish_mmu → free_pages_and_swap_cache`. Kernel continues (no panic) but RCU state is corrupt. |
| 13:41:55 | `Voluntary context switch within RCU read-side critical section!` — WARNING in `rcu_note_context_switch` on CPU#14, same task. |
| 13:42:16 | First `rcu: INFO: rcu_preempt detected stalls on CPUs/tasks:` — repeats every ~63 s from then on. |
| 13:49:47 | `rcu: ... expedited stalls ... { P91104 } 21187 jiffies` — the crashed task is named as the stall. |
| 13:41→ | `nix-daemon` and `nix` processes pile up in D-state; load climbs; rebuild hangs; filesystem appears frozen. |
| ~14:06 | Diagnosis (this doc). |

## What RCU is (Read-Copy-Update)

RCU is the kernel's synchronization primitive for **lock-free reading** of
shared data structures. It's used all over the kernel, but especially in the
VFS (filesystem) layer, networking, mount namespaces and memory management.

How it works, in three parts:

1. **Readers don't take locks.** A reader (e.g. a filesystem operation
   dereferencing a dentry or inode pointer) just loads the pointer and uses
   the data. No lock, no atomic increment, no contention — that's why it's
   fast on the hot path.

2. **Writers make a copy.** To change something, a writer allocates a *new*
   version of the object, updates the published pointer to it, and only then
   frees the old version.

3. **The grace period decides *when* the old version can be freed.** The old
   object can only be freed once the kernel is sure no reader is still using
   it — i.e. once every CPU has passed through a **quiescent state**
   (context switch, idle, or returning to user mode). The kernel tracks this
   with a counter/state per CPU or per task. When a writer needs to free the
   old object it calls `synchronize_rcu()` (or the faster
   `synchronize_rcu_expedited()`), which **blocks until a grace period
   completes**.

The catch: **a grace period completes only when every CPU (or task) reaches
a quiescent state.** One stuck participant and the grace period never
completes — and every `synchronize_rcu*()` caller blocks *indefinitely*.

That's exactly what happened here. The oops left task `P91104` permanently
marked as "inside an RCU read-side critical section that never ends", so:

- normal grace periods never complete (`synchronize_rcu_normal` blocks),
- expedited grace periods never complete either
  (`rcu_exp_gp_kthread_worker` waits in `synchronize_rcu_expedited_wait_once`),
- and every process that calls into RCU-waiting code joins the pileup.

### Why it looked like a slow filesystem

The filesystem layer is one of the biggest RCU consumers:

- **Dentry/inode lifecycle**: `dput()`, `dentry_kill()`, `evict()` wait for
  RCU before freeing dentries/inodes. Every `rm -rf`, every nix-store
  write/GC churns millions of these.
- **`open()`**: even `alloc_fd`/`expand_files` (seen in the stuck rebuild's
  stack) syncs RCU to safely reallocate the fd table.
- **Mount namespaces**: `namespace_unlock()` calls
  `synchronize_rcu_expedited()` — the exact frame the stuck `nix-daemon` was
  sitting in (it was evicting a mount namespace while exiting).
- **Writeback**: `kworker ... inode_switch_wbs` (stuck too) syncs RCU to move
  inodes between writeback cgroups.

So a wedged RCU makes *every* file operation that allocates/frees anything
hang. The system looks like a dying disk (or a dead NFS server) when the
block devices are perfectly healthy.

### Telling the two apart (D-state diagnosis)

High load + idle CPU + many D-state tasks is the signature. Check *what* the
D-state tasks are blocked on:

```sh
ps -eo pid,stat,wchan:30,comm | awk '$2 ~ /D/'
sudo cat /proc/<pid>/stack   # if wchan is unhelpful (shows 0)
```

Blocked-on-RCU stacks contain `synchronize_rcu*`, `exp_funnel_lock`,
`dput`, `evict`, `namespace_unlock`. Blocked-on-disk stacks contain
`blk_mq_*`, `nvme_wait_*`, `wait_on_page_bit*`, etc.

## Evidence (this incident)

Kernel oops (the trigger):

```
BUG: unable to handle page fault for address: fffffff78fca9340
#PF: supervisor read access in kernel mode
#PF: error_code(0x0000) - not-present page
Oops: 0000 [#1] SMP NOPTI
CPU: 14 UID: 30001 PID: 91104 Comm: ctrl-c Tainted: G S   U     O
RIP: 0010:__pgalloc_tag_sub+0xc1/0x170
Call Trace:
  free_unref_folios+0x18f/0x7f0
  folios_put_refs+0x12c/0x260
  free_pages_and_swap_cache+0x102/0x170
  __tlb_batch_free_encoded_pages+0x45/0xa0
  tlb_finish_mmu+0x82/0xd0
  exit_mmap+0x1c8/0x3b0
  __mmput+0x41/0x150
  do_exit+0x29a/0xaa0
```

The stall (the consequence):

```
rcu: INFO: rcu_preempt detected stalls on CPUs/tasks:
rcu: INFO: rcu_preempt detected expedited stalls on CPUs/tasks: { P91104 } 21187 jiffies
```

Stuck process stacks (three examples):

```
nix-daemon:  exp_funnel_lock → synchronize_rcu_expedited → namespace_unlock
             → evict → dentry_kill → dput → __fput → do_exit
nix (rebuild): synchronize_rcu_normal → expand_files → alloc_fd → do_sys_openat2
rcu_exp_gp_kthread_worker: synchronize_rcu_expedited_wait_once
```

### What it was NOT

- **The NVMe drives.** `smartctl` on both (`nvme0n1` WD_BLACK SN770,
  `nvme1n1` Crucial P3): PASSED, 0 media/integrity errors, 0 error-log
  entries, 0–1% used, 100% spare. Kernel log had zero NVMe/EXT4 errors.
- **The NFS mounts.** `ls /ds-games`, `stat /ds-public` responded in ms.
- **Disk space / inodes.** `/` 47%, `/home` 77%, plenty of inodes.

(Observation only: both drives run a NAND sensor at ~80 °C vs an 84–85 °C
warning threshold — warm but never logged a temperature warning.)

## How to avoid / prevent

### 1. Recovery is always a reboot

A wedged RCU grace period cannot be cleared from userspace — the stuck tasks
are in uninterruptible sleep and even SIGKILL can't touch them. Reboot (the
kernel state is corrupt, but filesystems were mounted cleanly and no I/O
errors occurred, so it's safe). All systemd services (llama-swap, sd-gate,
nginx, …) come back automatically.

### 2. Update the kernel (the actual bug)

The oops is in `__pgalloc_tag_sub`, the page-allocation-tagging bookkeeping
— a kernel bug, not user error. `zen3-nixos` runs `pkgs.linuxPackages_latest`
(7.2.0, built 2026-08-16, from `hosts/zen3-nixos/hardware-configuration.nix`).
A newer nixpkgs may well contain the fix. When you next update the flake,
this is an argument to rebuild soon after.

### 3. LTS fallback if it recurs

This was the first oops in ~5 boots, so it may be a rare race. **If it
recurs**, switch the kernel line rather than living with it:

```nix
# hosts/zen3-nixos/hardware-configuration.nix
-  boot.kernelPackages = pkgs.linuxPackages_latest;
+  boot.kernelPackages = pkgs.linuxPackages;   # LTS (6.12)
```

Requirements check for this host: RDNA4 (`gfx1201`) amdgpu support landed in
kernel 6.10, so the LTS 6.12 line still drives the R9700; overlayfs, nfsd,
vhost (podman), NFS client are all standard. Nothing else on this box needs
a bleeding-edge kernel.

### 4. Reduce the taint surface

The oops logged `Tainted: G S U O`:

- **`O` = OOT_MODULE**: the `ddcci-driver` out-of-tree module
  (`common/cosmic.nix`). The only OOT module on the box. If oopses recur,
  test with `boot.extraModulePackages = [ ]` / the `ddcci_backlight` module
  removed — driver bugs corrupting memory would show up exactly like this.
- **`S` = CPU_OUT_OF_SPEC**: the kernel detected the CPU running out of
  spec (BIOS PBO / overclocking). An unstable CPU/IF can corrupt memory and
  produce random oopses in innocent-looking kernel paths. If oopses recur,
  verify stability (memtest86+, stress-ng) and consider a stock PBO profile.

### 5. Monitor for it

Cheap to add, catches the next one early (and confirms a clean boot):

```sh
# after every rebuild, or as a habit:
sudo journalctl -k -b | grep -cE "Oops|BUG:|rcu.*stall"   # expect 0
```

Or a one-shot systemd timer that greps the current boot and logs a warning.
Also worth grepping for `Voluntary context switch within RCU read-side
critical section` — that WARNING appeared in the same second as the oops and
is an early smell.

### 6. What NOT to do

- Don't blame or "fix" the disks (fsck, replace NVMe) — the block layer was
  never involved.
- Don't `pkill` the stuck processes — they're in D-state and can't be killed;
  you'll only chase your own tail (and the AGENTS.md warning about
  self-matching `pgrep -f` patterns applies).
- Don't keep retrying `nixos-rebuild` while the stall is active — every
  attempt just adds more stuck daemons to the pileup.

## Reference — key commands

```sh
# current state (load vs idle CPU, D-state tasks)
uptime; top -b -n 1 -o %CPU | head -5
ps -eo pid,stat,wchan:30,comm | awk '$2 ~ /D/'

# kernel stacks of stuck tasks
sudo cat /proc/<pid>/stack

# the oops / RCU stall evidence
sudo journalctl -k -b | grep -iE "Oops|BUG:|rcu.*stall|pgalloc_tag"

# disk health sanity check (rules out the disk)
sudo smartctl -a /dev/nvme0n1 | grep -E "Result|Error|Temperature"
sudo smartctl -a /dev/nvme1n1 | grep -E "Result|Error|Temperature"
```
