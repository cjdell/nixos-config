/* avclock-selftest.c - prove the A/V clock leaves the two tracks on the same
 * tape position, without a deck, a card, or two hours.
 *
 * This is a unit test of the resampler controller, and it runs the real one:
 * pctv-monitor.c is #included, so rs_reset()/rs_run()/rs_update() and every
 * counter they touch are the ones that ship.  Time is driven by hand - one
 * rs_update() per simulated second, with rs_last_update forced to 0 to get past
 * the once-a-second gate - so a 2 h tape costs milliseconds instead of a tape.
 *
 * Four things it has to catch, all of which happened on real masters:
 *
 *   1. Two hours of a 450 ppm crystal with nothing else wrong.  The audio track
 *      must end the same length as the video track, to milliseconds.
 *
 *   2. A 500 ms hole in the PCM at 20 minutes - an overrun, a device reopen, a
 *      PipeWire graph restart, the audio thread not being run.  Nothing reports
 *      these; the card keeps delivering pictures all the way through.  The hole
 *      is filled with silence, the tracks still end together, and the resampler
 *      never leaves its inaudible band.  Before 2026-11-04 this was the "the
 *      sound is over a second out of sync" report:
 *      pctv-cap-20261104-015210.mkv ended 1.183 s long against 7294.96 s of
 *      picture, and the design had no way to pay it back because nothing
 *      measured what the two tracks disagreed by.
 *
 *   3. A hole the silence filler did not catch.  The phase term still walks it
 *      back before the tape ends, inside RS_PPM_MAX, so an unmeasured loss costs
 *      a slow inaudible stretch rather than a permanent offset.
 *
 *   4. A 12 s sink stall (ffmpeg SIGSTOP'd - the 2026-11-02 measurement).  The
 *      estimate must not run away: the cumulative ratio read +42362 ppm through
 *      exactly this and called it a 4 % crystal error.  A window with no pictures
 *      in it is skipped, not measured.
 *
 * Build and run it with ./avclock-selftest.sh.  -v keeps the controller's own
 * log lines, which is the fastest way to see what it decided.
 */
#define main pctv_monitor_main_not_used
#include "pctv-monitor.c"
#undef main

struct tape {
    const char *what;
    int secs;
    double ppm;          /* what the ADC actually runs at, against the card */
    int hole_at, hole_ms;/* a hole in the PCM; hole_at < 0 = one every -hole_at s */
    int fill;            /* 1 = the silence filler stands in for it */
    int stall_from, stall_to;  /* seconds of sink stall, 0 = none */
    int mode;            /* 0 = the tracks must end aligned; 1 = bound the step only */
    long long tol_ms;    /* how far apart the two tracks may end up */
};

/* One simulated second of tape: the ADC delivers 48000 x (1+ppm) frames (minus
 * any hole), the writer writes 25 pictures (minus any stall), and the controller
 * gets its once-a-second look. */
static void sim_second(double ppm, int hole_ms, int fill, int stalled)
{
    long long frames = (long long)(48000.0 * (1.0 + ppm));
    if (hole_ms) frames -= (long long)hole_ms * 48;
    static short buf[1024 * 2];
    memset(buf, 0, sizeof buf);
    while (frames > 0) {
        long long k = frames < 1024 ? frames : 1024;
        size_t out = rs_run(buf, (size_t)k);
        if (out) aq_push((const unsigned char *)rs_buf, out * 4);
        frames -= k;
    }
    if (hole_ms && fill) rs_silence((size_t)hole_ms * 48);
    /* the writer drains everything it is given; this test is not about the ring */
    aq_head = aq_count = aq_sent = 0;
    if (!stalled) rs_vframes += 25;
    rs_last_update = 0;                 /* bypass the once-a-second gate */
    rs_update();
}

/* The length of the audio track the file would end up with: what the resampler
 * produced, plus the silence that stood in for lost PCM, minus what was produced
 * and thrown away, minus what was cut to match a repeated picture. */
static long long file_audio_samples(void)
{
    return (long long)rs_out_frames + (long long)rs_credit_frames
         - (long long)rs_waste_frames - (long long)rs_cut_frames;
}

static int fails = 0;

static void check(struct tape t)
{
    double max_ppm = 0.0;
    rs_reset();
    rs_in_win = rs_in_frames;
    rs_v_win  = rs_vframes;
    for (int s = 0; s < t.secs; s++) {
        int hole = 0;                       /* ms of PCM missing this second */
        if (t.hole_ms) {
            if (t.hole_at > 0) hole = (s == t.hole_at) ? t.hole_ms : 0;
            else hole = (s > -t.hole_at && s % -t.hole_at == 0) ? t.hole_ms : 0;
        }
        int stalled = (t.stall_to && s >= t.stall_from && s < t.stall_to);
        sim_second(t.ppm, hole, t.fill, stalled);
        double p = (rs_step - 1.0) * 1e6;
        if (fabs(p) > max_ppm) max_ppm = fabs(p);
    }
    long long v = 1920LL * (long long)rs_vframes;
    long long a = file_audio_samples();
    long long d_ms = (a - v) / 48;
    /* The sound must never be mangled, in any case: that is the one promise the
     * resampler makes to the tape.  Whether the two tracks have to end up the
     * same length is the case-specific part. */
    int bad = max_ppm > (double)RS_PPM_MAX + 1.0 ||
              (t.mode == 0 && llabs(a - v) / 48 > t.tol_ms);
    printf("%-52s audio %+6lld ms vs video, resample %+7.0f ppm (peak %6.0f), "
           "%4lld ms silence, %3llu bad windows%s\n",
           t.what, d_ms, (rs_step - 1.0) * 1e6, max_ppm,
           (long long)(rs_credit_frames / 48), rs_bad_windows,
           bad ? "  FAIL" : (t.mode ? "  ok (bounded)" : "  ok"));
    if (bad) {
        printf("    allowed: %s|ppm| <= %d\n",
               t.mode ? "" : "|delta| <= 20 ms and ", RS_PPM_MAX);
        fails++;
    }
}

int main(int argc, char **argv)
{
    if (argc < 2 || strcmp(argv[1], "-v") != 0)
        freopen("/dev/null", "w", stderr);   /* the controller logs a lot */

    pthread_mutex_init(&vq_mtx, NULL);
    pthread_mutex_init(&cap_mtx, NULL);
    pthread_mutex_init(&amtx, NULL);
    if (!aq) aq = malloc(AQ_BYTES);
    memset(aq, 0, AQ_BYTES);
    aq_head = aq_count = aq_sent = 0;
    audio_rate = 48000;
    cap_has_audio = 1;
    cap_clock_audio = 0;

    printf("== avclock-selftest: 48 kHz stereo, 25 fps, RS_DRAIN_S %.0f s, "
           "RS_PPM_MAX %d, A_GAP_MIN_MS %d\n",
           RS_DRAIN_S, RS_PPM_MAX, A_GAP_MIN_MS);

    /* The four cases, in the order they were found. */
    struct tape cases[] = {
        { "2 h, ADC +450 ppm, nothing else wrong",
          7200,  450e-6, 0, 0, 0, 0, 0, 0,  20 },
        { "2 h, ADC -500 ppm (the other direction)",
          7200, -500e-6, 0, 0, 0, 0, 0, 0,  20 },
        /* The pattern the run log actually shows: not one dramatic dropout but a
         * few hundred milliseconds going missing every few minutes, all of it
         * silent.  Twenty of them in two hours is 4 s of sound, which is the whole
         * difference between a tape you can watch and one you cannot. */
        { "2 h, 200 ms PCM hole every 6 min, filled",
          7200,  450e-6, -360, 200, 1, 0, 0, 0, 20 },
        { "2 h, 200 ms PCM hole every 6 min, missed",
          7200,  450e-6, -360, 200, 0, 0, 0, 0, 200 },
        { "2 h, 500 ms PCM hole at 20 min, filled",
          7200,  450e-6, 1200, 500, 1, 0, 0, 0, 20 },
        { "2 h, 500 ms PCM hole at 20 min, missed",
          7200,  450e-6, 1200, 500, 0, 0, 0, 0, 200 },
        { "2 h, 12 s sink stall at 10 min",
          7200,  450e-6, 0, 0, 0, 600, 612, 0, 20 },
        /* A 40 s stall is not reachable as a *clock* problem: a sink that quiet
         * for 40 s has filled the 150-slot picture queue (6 s) and the 5.46 s
         * audio ring, and queue-selftest.sh already proves the capture ends loudly
         * long before then.  What this case checks is the promise the clock still
         * makes from here: the sound is never squeezed harder than RS_PPM_MAX, no
         * matter how wrong the pipeline gets.  The 26 s of divergence it prints is
         * the honest remainder of a state the capture path would have aborted. */
        { "2 h, 40 s stall at 30 min (queue ends it first)",
          7200,  450e-6, 0, 0, 0, 1800, 1840, 1, 20 },
        { "10 min, hole at 1 min (short tape, fast drain)",
          600,   450e-6, 60, 500, 1, 0, 0, 0, 20 },
        { "6 min, flow reads +18000 ppm (not a crystal)",
          360,  18000e-6, 0, 0, 0, 0, 0, 1, 20 },
    };
    for (unsigned i = 0; i < sizeof cases / sizeof cases[0]; i++) check(cases[i]);

    printf("%s\n", fails ? "SOME CHECKS FAILED" : "ALL CHECKS PASSED");
    return fails ? 1 : 0;
}
