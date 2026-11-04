/* avclock-selftest.c - prove the coupled writer leaves the two tracks on the
 * same tape position, without a deck, a card, or two hours.
 *
 * This is a unit test of the capture clock, and it runs the real machinery:
 * pctv-monitor.c is #included, so cap_feed_audio()/cap_feed_silence() (the ALSA
 * thread's producers), the ring, a_make_chunk() (the commit's audio half) and
 * rs_update() (the controller) are the ones that ship.  Time is driven by hand:
 * one simulated second = the ADC's raw frames pushed into the ring, N pictures
 * committed (each building and "writing" its chunk), one forced rs_update().
 * A 2 h tape costs milliseconds instead of a tape.
 *
 * The rewrite on 2026-11-04 mirrors the design change.  The old test drove the
 * producer-side resampler and checked track LENGTHS, because that was all the
 * old design could break.  With the coupling the tracks can never differ -
 * audio leaves the ring only inside a commit - so length equality is an
 * invariant asserted on every case (it must be EXACT, not within a tolerance),
 * and the real assertions moved to what can still be wrong:
 *
 *   - WHERE IN TIME the sound each commit carries came from: the phase
 *     E = queue depth - ring depth must stay milliseconds-small under crystal
 *     drift, a sink stall, a paused deck, and - the regression that started
 *     the whole redesign - a chronically deep picture queue.  The old design
 *     shipped that last tape a full second early with every counter at zero.
 *
 *   - WHAT THE CONTROLLER MAKES OF DAMAGE.  A hole the gap detector catches
 *     on time is aligned by construction (its zeros are committed as exactly
 *     the hole, backlog and all), so E must NOT move - a controller that
 *     flinched there would be squeezing audio for a debt it already paid.
 *     One it catches LATE (zeros pushed in behind a second of sound that
 *     arrived after the dead device) lags by the hole, and E must see it,
 *     name it, and pay it back at a visible, bounded, inaudible rate.
 *     A hole nobody catches starves the drain instead: rs_pad_into fills it,
 *     counted, soft, and equal-length.  And the catch-up after a 12 s sink
 *     stall must be rejected as a crystal (the old +42362 ppm lie) while E
 *     sits unmoved, because a stall deepens both backlogs at 1000 ms/s.
 *
 *   - WHETHER EVERY SEAM IS SOFT.  The simulated sound is a 200 Hz tone, and
 *     every case that can move it around has its file audio captured and
 *     scanned for the largest consecutive-sample step: legitimate slope is
 *     ~209 units, a hard edge at this amplitude is thousands.  Nothing
 *     reaches a tape un-ramped (the operator's standing order since SaLou).
 *
 * Build and run it with ./avclock-selftest.sh.  -v keeps the controller's own
 * log lines, which is the fastest way to see what it decided.
 */
/* _GNU_SOURCE must precede the FIRST system header in this translation unit:
 * pctv-monitor.c defines it itself, but by then glibc's features.h has already
 * been included by the line below and __USE_GNU - F_SETPIPE_SZ, pipe sizing -
 * would be locked off for the whole file. */
#define _GNU_SOURCE
#include <math.h>

#define main pctv_monitor_main_not_used
#include "pctv-monitor.c"
#undef main

#define RATE 48000
#define COMMIT 1920                       /* audio frames per picture (40 ms) */
#define TONE_AMPL 8000.0
#define TONE_HZ   200.0
/* The click ceiling: the tone's own worst consecutive-sample step is
 * 8000 x 2pi x 200/48000 ~ 209, and resampling ripple adds a fraction of one
 * sample on top.  A HARD seam at this amplitude would be 4000-16000, so the
 * threshold sits far above any legitimate slope and far below any click. */
#define CLICK_MAX 800

struct tape {
    const char *what;
    int secs;
    double ppm;               /* what the ADC actually runs at, vs the card */
    int hole_at, hole_ms;     /* a PCM hole at second hole_at; 0 = none */
    int fill;                 /* the gap detector stands in for it... */
    int fill_late;            /* ...one second late: zeros land behind the
                               * sound that arrived after the gap (the way a
                               * 500 ms dead device is actually discovered),
                               * so the tape really does lag by the hole */
    int stall_from, stall_to; /* sink stall: no commits, both arrivals run */
    int pause_from, pause_to; /* deck pause: no ARRIVALS, commits (dupes) run */
    int ramp_secs;            /* sink down for this many opening seconds, so
                               * the writer starts a picture queue behind -
                               * the chronic-depth regression (the take that
                               * arrived one second early) */
    int record;               /* capture the file's audio and click-test it */
    long e_tol_ms;            /* ceiling on |E| at any second */
    long e_final_ms;          /* |E| where the take ends (payback done) */
    long e_min_ms;            /* require a PEAK of at least this (cases whose
                               * damage is real and must be seen) */
    long pad_lo_ms, pad_hi_ms;/* what the drain may invent (only the hole) */
    int  want_bad;            /* >=1 clock window expected to be discarded */
    double min_step_ppm;      /* require the step to work THIS hard (drain) */
};

/* ---- the simulated tape --------------------------------------------------
 * The producer side is the REAL path: tone frames through cap_feed_audio()
 * (which counts aq_raw_frames and runs the raw fade-up) and holes through
 * cap_feed_silence() (which ramps the seam down in the sample domain).  The
 * writer side is the REAL commit: a_make_chunk() resamples from the ring at
 * the controller's step and pads when the ring cannot cover it; rs_vframes
 * advances exactly as the writer's chunk stage does (once the pair is in).
 * The picture queue is modelled as a depth: a live writer commits one second
 * of pictures per second (duplicating when the card stopped, catching up at
 * up to +100/s after a stall) - the queue only grows when the SINK is what
 * was slow, which is exactly the case the coupling survives. */

static double tone_phase;
static short  fbuf[1024 * 2];
static void feed_adc(size_t frames)
{
    while (frames) {
        size_t k = frames > 1024 ? 1024 : frames;
        for (size_t i = 0; i < k; i++) {
            tone_phase += 2.0 * M_PI * TONE_HZ / (double)RATE;
            if (tone_phase > 2.0 * M_PI) tone_phase -= 2.0 * M_PI;
            short s = (short)lrint(TONE_AMPL * sin(tone_phase));
            fbuf[i * 2] = s; fbuf[i * 2 + 1] = s;
        }
        cap_feed_audio((const unsigned char *)fbuf, k * 4);
        frames -= k;
    }
}

/* The file's audio track, captured for the click test (record cases only). */
static int g_rec;
static int verbose = 0;    /* set from argv in main; gates SEAM dumps + logs */
#define FMAX ((size_t)RATE * 70)
static short *faudio;
static size_t faudio_n, faudio_clip;
static void commit_audio(void)
{
    if (!g_rec || !faudio) return;
    if (faudio_n + a_chunk_frames <= FMAX) {
        memcpy(faudio + faudio_n * 2, a_chunk,
               a_chunk_frames * 2 * sizeof *faudio);
        faudio_n += a_chunk_frames;
    } else faudio_clip++;
}

/* One commit: exactly what the writer's two stages do to the clock state. */
static void one_commit(void)
{
    a_make_chunk();
    if (a_chunk_frames != COMMIT) {
        fprintf(stderr, "FATAL: a chunk was not one 40 ms picture's worth "
                        "(%zu frames)\n", a_chunk_frames);
        exit(2);
    }
    commit_audio();
    rs_vframes++;                     /* the pair reached the file */
}

struct run_stats {
    long a_frames, v_frames;
    long e_peak, e_final;
    double step_ppm_peak, step_ppm_final;
    long pad_ms, silence_ms;
    unsigned long long bad_windows;
    long click_max;
    long long len_err;                /* audio frames minus 40 ms x video */
};

static void run_tape(const struct tape *t, struct run_stats *st)
{
    memset(st, 0, sizeof *st);
    rs_reset();
    aq_reset();
    tone_phase = 0.0;
    faudio_n = faudio_clip = 0;
    g_rec = t->record;
    unsigned long long sil0 = cap_a_silence_bytes;

    long vq = 0;                      /* simulated picture queue depth */
    vq_count = 0;

    for (int s = 0; s < t->secs; s++) {
        int hole = (t->hole_ms && s == t->hole_at) ? t->hole_ms : 0;
        int late = (t->hole_ms && t->fill && t->fill_late &&
                    s == t->hole_at + 1) ? t->hole_ms : 0;
        int paused = (t->pause_to && s >= t->pause_from && s < t->pause_to);
        int stalled = (t->stall_to && s >= t->stall_from && s < t->stall_to);
        int ramping = (t->ramp_secs && s < t->ramp_secs);

                /* --- the ADC: raw frames into the ring, exactly as the ALSA thread
         * delivers them (a 48000 x (1+ppm) frame clock, holes missing).  An
         * on-time gap filler puts its zeros where the gap was - before the
         * sound that came after it; a late one finds them queued up behind
         * that sound instead, and THAT is what lags the tape by the hole.
         * The ADC NEVER stops: a paused deck feeds silence-or-noise at full
         * rate, it does not switch off the crystal.  What a pause stops is
         * the CARD - and that is why the writer duplicates and still commits
         * at real time: the sound each dupe carries must be the room's, now. --- */
        {
            long long frames = (long long)(RATE * (1.0 + t->ppm));
            if (hole) frames -= (long long)hole * 48;
            if (hole && t->fill && !t->fill_late)
                cap_feed_silence((size_t)hole * 48);
            if (frames > 0) feed_adc((size_t)frames);
            if (late) cap_feed_silence((size_t)late * 48);
        }

        /* --- the card: 25 pictures/s arrive (none during a deck pause) --- */
        if (!paused) vq += 25;
        vq_count = (int)vq;

        /* --- the sink: live commits (with dupes when the queue is empty,
         * as the writer's take-next stage does), none while stalled, and
         * catch-up at up to +100/s once it recovers. --- */
        long commits = 0;
        if (!stalled && !ramping) {
            commits = 25;
            /* A writer that fell behind a STALLED sink digests the queue at up
             * to 100 pictures/s over and above real time.  (Capped queues -
             * the real code refuses past vq_n - end the capture instead; the
             * clock logic here is depth-agnostic.) */
            if (t->stall_to && s >= t->stall_to && vq > 25)
                commits += vq - 25 > 100 ? 100 : vq - 25;
        }
        for (long c = 0; c < commits; c++) one_commit();
        vq -= commits > vq ? vq : commits;
        vq_count = (int)vq;

        /* --- the controller's once-a-second look (gate forced open) --- */
        rs_last_update = 0;
        rs_update();

        /* --- metrics, in the units the operator reads them in --- */
        unsigned long bpm = (unsigned long)aq_bytes_per_ms();
        long e = vq * FRAME_MS - (bpm ? (long)(aq_count / bpm) : 0);
        if (labs(e) > labs(st->e_peak)) st->e_peak = e;
        st->e_final = e;
        double ppm = (rs_step - 1.0) * 1e6;
        if (fabs(ppm) > fabs(st->step_ppm_peak)) st->step_ppm_peak = fabs(ppm);
        st->step_ppm_final = ppm;
    }

    st->a_frames = (long)rs_out_frames;
    st->v_frames = (long)rs_vframes;
    st->len_err = (long long)rs_out_frames - 1920LL * (long long)rs_vframes;
    st->pad_ms = (long)(rs_pad_frames / 48);
    st->silence_ms = (long)((cap_a_silence_bytes - sil0) / 192);
    st->bad_windows = rs_bad_windows;
    g_rec = 0;
    if (faudio_n && !faudio_clip) {
        long top[5] = { -1, -1, -1, -1, -1 };       /* positions of the 5 largest */
        for (size_t i = 2; i < faudio_n * 2; i++) {
            long d = (long)faudio[i] - (long)faudio[i - 2];
            if (d < 0) d = -d;
            if (d > st->click_max) st->click_max = d;
            if (verbose && d > CLICK_MAX) {
                static int shown;
                if (shown < 5) {
                    fprintf(stderr, "SEAM i=%zu (%.3fs) d=%ld around: ", i,
                            (double)i / 2 / RATE, d);
                    for (size_t k = (i > 3 ? i - 4 : 0); k < i + 5 && k < faudio_n * 2; k++)
                        fprintf(stderr, "%d ", faudio[k]);
                    fprintf(stderr, "\n");
                    shown++;
                }
                (void)top;
            }
        }
    }
}

static int fails = 0;

static void check(struct tape t)
{
    struct run_stats st;
    run_tape(&t, &st);

    /* The real ADC frames per second are an integer, so the honest target
     * for the settled step is what that integer works out to, not the
     * nominal ppm. */
    double real_ppm = ((long long)(RATE * (1.0 + t.ppm)) - RATE)
                    * 1e6 / (double)RATE;

    int bad = 0;
    char msg[512] = "";
    #define FAIL(...) do { bad = 1; snprintf(msg, sizeof msg, __VA_ARGS__); \
                           if (verbose) fprintf(stderr, "%s\n", msg); } while (0)

    /* Structural, on every case: one commit, one pair.  The audio track must
     * be 40 ms x the video track EXACTLY - not to a tolerance.  If anyone
     * ever reopens a path that drains audio outside a commit, this is what
     * catches it at 3 a.m. instead of at a viewing. */
    if (st.len_err != 0)
        FAIL("tracks diverged by %+lld frames (%lld ms): the coupling is broken",
             st.len_err, st.len_err / 48);
    if (fabs(st.step_ppm_peak) > RS_PPM_MAX + 1.0)
        FAIL("resampling peaked at %.0f ppm - past the audible band",
             st.step_ppm_peak);
    if (labs(st.e_peak) > t.e_tol_ms)
        FAIL("A/V phase peaked at %+ld ms (ceiling %ld): the sound was not "
             "each picture's own moment", st.e_peak, t.e_tol_ms);
    if (t.e_min_ms && labs(st.e_peak) < t.e_min_ms)
        FAIL("the phase never saw the damage (peak %+ld ms, expected >= %ld): "
             "the controller is blind again", st.e_peak, t.e_min_ms);
    if (labs(st.e_final) > t.e_final_ms)
        FAIL("the phase never paid back: %+ld ms left at the end (ceiling %ld)",
             st.e_final, t.e_final_ms);
    if (st.pad_ms < t.pad_lo_ms || st.pad_ms > t.pad_hi_ms)
        FAIL("the drain invented %ld ms of sound (expected %ld..%ld)",
             st.pad_ms, t.pad_lo_ms, t.pad_hi_ms);
    if (t.want_bad && st.bad_windows < 1)
        FAIL("a catch-up window was believed as a crystal - the old +42362 ppm "
             "lie is back");
    if (t.min_step_ppm && st.step_ppm_peak < t.min_step_ppm)
        FAIL("the step never worked harder than %.0f ppm: the drain is not "
             "spending the phase error", st.step_ppm_peak);
    /* A crystal case that has settled must END on its crystal: the flow term
     * is measured over ARRIVALS, so this is the proof it is not reading back
     * the drain.  (Cases whose E has not returned yet are exempt: their step
     * legitimately carries the payback.) */
    if (labs(st.e_final) <= 40 &&
        fabs(st.step_ppm_final - real_ppm) > 60)
        FAIL("the step ended at %.0f ppm, not the injected %.0f - the flow term "
             "is not reading arrivals", st.step_ppm_final, real_ppm);
    if (t.record && st.click_max > CLICK_MAX)
        FAIL("CLICK: a seam stepped %ld units (tone slope ~209, ceiling %d)",
             st.click_max, CLICK_MAX);
    if (t.record && faudio_clip)
        FAIL("the click buffer overflowed - shorten the case");
    #undef FAIL

    printf("%-56s len %+4ld  E %+4ld/%+4ld ms (pk/end)  step %5.0f/%+5.0f ppm"
           "  pad %3ld sil %3ld ms  bad %llu%s%s\n",
           t.what, (long)(st.a_frames - COMMIT * st.v_frames),
           st.e_peak, st.e_final, st.step_ppm_peak, st.step_ppm_final,
           st.pad_ms, st.silence_ms, st.bad_windows,
           t.record ? "  click" : "", bad ? "  FAIL" : "");
    if (bad) { printf("      %s\n", msg); fails++; }
    else if (t.record) printf("      (largest sample step %ld, ceiling %d)\n",
                              st.click_max, CLICK_MAX);
}

int main(int argc, char **argv)
{
    if (argc > 1 && !strcmp(argv[1], "-v")) verbose = 1;
    else freopen("/dev/null", "w", stderr);   /* the controller's logs go away;
                                             * FAIL text is rebuilt in-line */

    aq = malloc(AQ_BYTES);                    /* what vq_start() would do */
    audio_rate = RATE;
    cap_has_audio = 1;
    faudio = malloc(FMAX * 2 * sizeof *faudio);
    if (!aq || !faudio) { printf("cannot allocate the rig\n"); return 2; }

    printf("invariants: file audio == 40 ms x file video EXACTLY; every seam\n"
           "            under %d units; step within +/-%d ppm of the crystal\n\n",
           CLICK_MAX, RS_PPM_MAX);

    struct tape tapes[] = {
        /* The crystals, both directions, nothing else in the way.  The pad
         * ceiling is the known, counted cold start: the ring holds only the
         * queue's own sound at frame 0, the first window (and with it the
         * step seed) needs 125 pictures, and a -300 ppm ADC starves the drain
         * by ~14 frames/s in the meantime - about 1.5 ms of SOFT silence in
         * the first five seconds of a two-hour tape.  Everything after the
         * seed is pad-free, which is what the 2 ms ceiling pins down. */
        { "crystal +450 ppm over 2 h",        7200,  450e-6,
          .e_tol_ms = 25, .e_final_ms = 5, .pad_lo_ms = 0, .pad_hi_ms = 2 },
        { "crystal -300 ppm over 2 h",        7200, -300e-6,
          .e_tol_ms = 25, .e_final_ms = 5, .pad_lo_ms = 0, .pad_hi_ms = 2 },
        /* A 12 s SIGSTOP of ffmpeg (the 2026-11-02 measurement): the stall
         * itself must not move E (both backlogs deepen together), the
         * catch-up must be refused as a crystal, and the settled step after
         * it must still be the crystal. */
        { "sink stall 12 s: window refused, E unmoved",
                                              7200,  450e-6,
          .stall_from = 3600, .stall_to = 3612,
          .e_tol_ms = 40, .e_final_ms = 10, .pad_lo_ms = 0, .pad_hi_ms = 0,
          .want_bad = 1 },
        /* A detected hole, caught on time: its zeros are the hole - aligned
         * by construction - so E must stay near 0 and the drain must not
         * starve (nothing is missing from the backlog), and the two seams
         * (fade down through the raw ramp, up through aq_fsin) must survive
         * the click test after resampling. */
        { "detected hole, on time: aligned, soft (click test)",
                                              60,    135e-6,
          .hole_at = 30, .hole_ms = 500, .fill = 1, .record = 1,
          .e_tol_ms = 80, .e_final_ms = 40, .pad_lo_ms = 0, .pad_hi_ms = 30 },
        /* The same hole caught LATE (zeros land behind a second of audio that
         * arrived after the dead device): THAT lags the tape by the hole, E
         * must see it, spend the resampler on it, and clear it. */
        { "detected hole, late: E sees it and pays it back",
                                              3600,  135e-6,
          .hole_at = 1200, .hole_ms = 500, .fill = 1, .fill_late = 1,
          .e_tol_ms = 650, .e_final_ms = 30, .e_min_ms = 200,
          .pad_lo_ms = 400, .pad_hi_ms = 620, .min_step_ppm = 400 },
        /* An UNdetected hole: nobody fills, the drain starves, and
         * rs_pad_into takes exactly the hole's worth - counted, soft, and
         * leaving the tracks equal the whole way. */
        { "undetected hole: drain pads it, softly (click test)",
                                              60,    135e-6,
          .hole_at = 20, .hole_ms = 500, .record = 1,
          .e_tol_ms = 80, .e_final_ms = 40, .pad_lo_ms = 400, .pad_hi_ms = 620 },
        { "undetected hole, 40 min: lengths never drifted",
                                              2400,  135e-6,
          .hole_at = 600, .hole_ms = 500,
          .e_tol_ms = 80, .e_final_ms = 30, .pad_lo_ms = 400, .pad_hi_ms = 620 },
        /* The deck pauses: duplicates commit at real time and take the LIVE
         * sound of each moment (a still picture with the room's hum).  The
         * drain must not starve and the clock must not twitch. */
        { "deck pause 30 s: dupes carry the live sound",
                                              600,   135e-6,
          .pause_from = 180, .pause_to = 210,
          .e_tol_ms = 60, .e_final_ms = 20, .pad_lo_ms = 0, .pad_hi_ms = 0 },
        /* THE regression: the sink is a second behind from the first second
         * and stays there (the NFS-to-ds-public steady state that made the
         * 2026-11-04 take arrive early).  The queue's second must be matched
         * by a second IN THE RING - E = queue - ring is the lip error, and
         * it must read zero while a full second of both is always in flight.
         * The pre-coupling design scored this tape 1000 ms and never saw it. */
        { "chronic 1 s picture queue (the early-audio bug)",
                                              1800,  135e-6,
          .ramp_secs = 1, .e_tol_ms = 60, .e_final_ms = 20,
          .pad_lo_ms = 0, .pad_hi_ms = 0 },
    };
    for (size_t i = 0; i < sizeof tapes / sizeof tapes[0]; i++)
        check(tapes[i]);

    printf("\n%s\n", fails ? "FAILED" : "all clock cases pass");
    return fails != 0;
}
