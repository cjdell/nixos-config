/* pctv-rt.h - put the capture path into the real-time scheduling class.
 *
 * Why this exists: the only way this box loses a frame is by not being
 * scheduled.  The card delivers 27 MB/s of BT.656 in 32 KiB URBs (19 lines,
 * ~1.2 ms apart).  Since 2026-11-01 nothing on the path throws tape away when it
 * is late: probe.c copies each URB into a 64 MiB ring (2.4 s) that a writer
 * thread drains, pctv-monitor queues every assembled frame (10 deep) and every
 * audio sample (5.5 s), and both encoder pipes are non-blocking and resume a
 * partial write.  Losing data now costs seconds of stall rather than a field; what
 * scheduling still buys is that the queues stay empty.  (Before that change
 * probe.c wrote each URB into a pipe *non-blocking* and threw away the rest of it
 * on EAGAIN, and the parser spliced a field across the hole - the "one interlaced
 * field is misaligned" glitch in the live view and in the recorded .mpg; see
 * TRUTH.md and docs/pctv-analog-capture.md §11.)  Every cushion on the path is
 * measured in time, not priority: 24 URBs in flight (~29 ms), the 64 MiB stream
 * queue (2.4 s), the 32 MiB stream pipe (1.2 s) and the 8 MiB encoder pipe
 * (400 ms).  This is a 2-core box that simultaneously runs
 * kwin, PipeWire, Dolphin and whatever else the user started; measured during a
 * capture with a Plasma session up: load average 6.5 against ~1.15 cores of
 * real demand, i.e. the capture chain is regularly runnable-but-not-running.
 * SCHED_FIFO takes that out of the lottery - nothing at a normal priority can
 * preempt it again.
 *
 * The three stages are deliberately not equal:
 *
 *   pctv_probe    FIFO 10  the one stage that DESTROYS data when it is late,
 *                          and the one with the least buffer in front of it
 *                          (the URB pool); it also runs as root via `sudo -n`,
 *                          so it always gets what it asks for
 *   pctv-monitor  FIFO  8  has seconds of cushion behind it and 400 ms in front:
 *                          it needs to beat the desktop, not the probe
 *   ffmpeg        none     throughput-only, and forked from the monitor, so it
 *                          inherits our class unless pctv-monitor.c drops it
 *                          back to SCHED_OTHER (see cap_start()).  An RT
 *                          encoder on 2 cores starves the very thread that
 *                          feeds it - and PipeWire, which is nice -11 here, not
 *                          RT, so nothing on this box needs to outrank us.
 *
 * Prio 1-99; both numbers sit far below the 99 the kernel reserves, and
 * PCTV_RT_PRIO=0 turns the whole thing off for A/B testing (note that the probe
 * is launched through `sudo -n`, whose env_reset drops PCTV_RT_PRIO - the
 * wrapper from package.nix re-establishes it).
 *
 * Getting there takes a privilege: sched_setscheduler(2) to SCHED_FIFO wants
 * CAP_SYS_NICE or RLIMIT_RTPRIO > 0.  The probe has the former; pctv-monitor
 * runs as the user and so needs the `rtprio` login limit live-module.nix sets
 * for @wheel, plus a fresh login for PAM to apply it.  If the call is refused
 * we say so loudly on stderr and carry on normally - losing RT is a quality
 * regression, killing a live capture would be a bug.  (The alternative was
 * rtkit, already enabled here for PipeWire: it costs a D-Bus round trip and
 * adds its own policy ceiling.  A login limit is the boring answer.)
 *
 * One safety note for whoever reads the journal: on kernel 7.2 with
 * CONFIG_RT_GROUP_SCHED=n, RT throttling is off by default
 * (/proc/sys/kernel/sched_rt_runtime_us == sched_rt_period_us), i.e. a runaway
 * RT thread used to be a hard lock.  live-module.nix re-enables the upstream
 * 95 % cap, which cannot bite us (the capture path wants ~0.7 of 2 cores).
 */
#ifndef PCTV_RT_H
#define PCTV_RT_H

#include <errno.h>
#include <sched.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* Join the real-time class at `prio` (falling back to `dflt` when
 * PCTV_RT_PRIO is unset).  Never fatal: see the comment above. */
static void pctv_become_rt(const char *who, int dflt)
{
    const char *e = getenv("PCTV_RT_PRIO");
    int prio = e ? atoi(e) : dflt;
    struct sched_param sp;

    if (prio <= 0) {
        fprintf(stderr, "%s: RT disabled (PCTV_RT_PRIO=%d)\n", who, prio);
        return;
    }
    sp.sched_priority = prio;
    if (sched_setscheduler(0, SCHED_FIFO, &sp) == 0) {
        fprintf(stderr, "%s: SCHED_FIFO prio %d (pid %d)\n",
                who, prio, (int)getpid());
        return;
    }
    fprintf(stderr, "%s: SCHED_FIFO prio %d refused: %s\n",
            who, prio, strerror(errno));
    fprintf(stderr, "%s: continuing at normal priority - frames WILL be "
                    "dropped when the box is busy.  Give this user an `rtprio` "
                    "login limit (hardware.pctv320cxLive does that for @wheel) "
                    "and log back in, or run it as root.\n", who);
}

/* Leave the real-time class again - for a child that must not outrank its
 * parent.  Lowering one's own priority is always permitted. */
static void pctv_drop_rt(const char *who)
{
    struct sched_param sp;

    sp.sched_priority = 0;
    if (sched_setscheduler(0, SCHED_OTHER, &sp) < 0)
        fprintf(stderr, "%s: dropping to SCHED_OTHER failed: %s\n",
                who, strerror(errno));
}

#endif /* PCTV_RT_H */
