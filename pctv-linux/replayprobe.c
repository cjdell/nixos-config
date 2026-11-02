/* replayprobe - fakeprobe with REAL tape pixels.
 *
 * fakeprobe emits a synthetic staircase, which any MPEG-2 encoder finds easy;
 * that is why capture-selftest.sh never caught the 2026-11-02 loss of 59688
 * pictures: the encoder only falls behind on high-entropy tape, and the harness
 * had none.  This replays a captured UYVY file as real-time BT.656 in this
 * card's exact line layout, so a benchmark run is reproducible, needs no deck,
 * and faces the same bits that failed.
 *
 *   REPLAY_UYVY=/path/clip.uyvy   720x576 UYVY, looped (default ~/bench/clip30.uyvy)
 *   PCTV_RT_PRIO=10               SCHED_FIFO like the real probe (default 10)
 *   argv: [stream] [input] [seconds]
 *
 * Unlike the real probe it never drops: stdout is blocking, so a stalled
 * consumer stalls the source.  That is deliberate - a benchmark harness must
 * not create the very loss it is measuring.
 */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <signal.h>
#include <sched.h>

#define W 720
#define H 576
#define LINE_BYTES 1728          /* SAV(4) + 1440 active + 284 tail */
#define ACTIVE 1440
#define LINES_PER_FIELD 312
#define ACTIVE_LINES 288
#define FRAME_BYTES ((size_t)W * H * 2)

static volatile sig_atomic_t stop_;
static void onsig(int s) { (void)s; stop_ = 1; }
static double now(void)
{
    struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t);
    return t.tv_sec + 1e-9 * t.tv_nsec;
}

int main(int argc, char **argv)
{
    int a = (argc > 1 && !strcmp(argv[1], "stream")) ? 3 : 1;
    /* The monitor calls us as `stream <input>` with no duration, so the
     * default has to be "until told otherwise" - a finite default here ends
     * the capture by walking away from it (60 s on 2026-11-02, which looked
     * exactly like the monitor hanging).  REPLAY_SECS or argv[3] bound it. */
    double secs = argc > a ? atof(argv[a])
                           : (getenv("REPLAY_SECS") ? atof(getenv("REPLAY_SECS"))
                                                    : 1e9);
    const char *src = getenv("REPLAY_UYVY");
    if (!src) src = getenv("HOME") ? strcat(strcpy(malloc(4096), getenv("HOME")),
                                                   "/bench/clip30.uyvy")
                                   : "/tmp/clip30.uyvy";
    FILE *f = fopen(src, "rb");
    if (!f) { fprintf(stderr, "replayprobe: %s: cannot open\n", src); return 1; }
    fseek(f, 0, SEEK_END);
    long long frames = (long long)(ftell(f) / FRAME_BYTES);
    fseek(f, 0, SEEK_SET);
    if (frames < 2) { fprintf(stderr, "replayprobe: %s: too short\n", src); return 1; }

    unsigned char *frame = malloc(FRAME_BYTES);
    unsigned char *out = malloc((size_t)LINES_PER_FIELD * LINE_BYTES);
    if (!frame || !out) { fprintf(stderr, "replayprobe: out of memory\n"); return 1; }
    memset(out, 0x80, (size_t)LINES_PER_FIELD * LINE_BYTES);
    for (int l = 0; l < LINES_PER_FIELD; l++) {
        unsigned char *p = out + (size_t)l * LINE_BYTES;
        p[0] = 0xFF; p[1] = 0; p[2] = 0;
        memset(p + 4 + ACTIVE, 0x10, LINE_BYTES - 4 - ACTIVE);
    }
    long long prio = getenv("PCTV_RT_PRIO") ? atoll(getenv("PCTV_RT_PRIO")) : 10;
    if (prio > 0) {
        struct sched_param sp = { .sched_priority = (int)prio };
        if (sched_setscheduler(0, SCHED_FIFO, &sp) == 0)
            fprintf(stderr, "replayprobe: SCHED_FIFO prio %d (like the probe)\n", (int)prio);
        else
            fprintf(stderr, "replayprobe: SCHED_FIFO refused (continuing without)\n");
    }
    signal(SIGPIPE, SIG_IGN); signal(SIGTERM, onsig); signal(SIGINT, onsig);

    double t0 = now();
    long long field = 0, bytes = 0;
    for (;;) {
        double t = now() - t0;
        if (t >= secs || stop_) break;
        /* Hold each source frame for FOUR fields (two whole frame periods), not
         * two.  The monitor groups two consecutive fields into a frame, and
         * which F value opens a frame is the card's convention (derived in
         * docs/pctv-analog-capture.md 10.3).  Guessing it shows up as a frame
         * holding the even rows of source frame n and the odd rows of n+1 - both
         * bit-perfect, and looking exactly like a broken capture for a while
         * here.  Holding across two pairs makes the byte-identity check
         * independent of the convention, which is all this harness is for. */
        long long fi = (field / 4) % frames;
        if (fseek(f, (long)(fi * (long long)FRAME_BYTES), SEEK_SET) != 0 ||
            fread(frame, 1, FRAME_BYTES, f) != FRAME_BYTES) {
            clearerr(f); continue;                    /* short file: restart */
        }
        int F = 1 - (int)(field & 1);          /* F=1 leads the pair (10.3) */
        /* the deframer puts field F on rows 2r+F, so emit exactly that */
        for (int r = 0; r < ACTIVE_LINES; r++) {
            unsigned char *p = out + (size_t)r * LINE_BYTES;
            memcpy(p + 4, frame + (size_t)(2 * r + F) * W * 2, ACTIVE);
            p[3] = (unsigned char)(0x80 | (F << 6));         /* V=0, this field */
        }
        for (int r = ACTIVE_LINES; r < LINES_PER_FIELD; r++)  /* blanking */
            out[(size_t)r * LINE_BYTES + 3] = (unsigned char)(0xA0 | (F << 6));
        double due = t0 + (double)field * 0.020;
        double left = due - now();
        if (left > 0) { struct timespec ts = { (time_t)left,
                            (long)((left - (time_t)left) * 1e9) };
                        nanosleep(&ts, NULL); }
        if (write(STDOUT_FILENO, out,
                  (size_t)LINES_PER_FIELD * LINE_BYTES) < 0) break;
        bytes += (size_t)LINES_PER_FIELD * LINE_BYTES;
        field++;
    }
    fprintf(stderr, "replayprobe: %lld fields, %lld B from %s\n", field, bytes, src);
    return 0;
}
