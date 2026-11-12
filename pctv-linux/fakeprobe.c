/* fakeprobe - a stand-in for `pctv_probe stream`, for capture-selftest.sh.
 *
 * Emits real-time BT.656 in this card's line layout (SAV(4) 0xFF 00 00 XY +
 * 1440 active + 284 tail = 1728 B; 288 active lines + 24 blanking per field;
 * 50 fields/s) and injects the failure modes worth testing.  Not built or
 * installed by package.nix - it is test equipment, not part of the capture
 * path.
 *
 *   FAKE_GAP=<s>       remove 32768 bytes from the byte stream at that time,
 *                      mid-line: what losing one 32 KiB URB looks like, and the
 *                      case the parser can locate exactly (seam + shortfall)
 *   FAKE_GAPLINES=<s>  remove exactly 19 whole lines instead: the guard codes
 *                      stay 1728 B apart, so no parser can tell where they went
 *                      - it only shows up as a short field
 *   FAKE_MULTIGAP=<s>  eight dropouts through one field's vertical interval,
 *                      spaced so each proves exactly one row to the pitch:
 *                      a damaged tape's rotation, and the shape that pushed
 *                      the row counter into the VBI and off the end of the
 *                      good-frame buffer (the 2026-11-12 SIGSEGV class)
 *   FAKE_BLUE=<s>[:d]  emit the deck's dark blue (U ~204, Y ~47) from time s
 *                      for d seconds (default: to the end) - the end-of-tape
 *                      colour the no-content detector catches, so the blue
 *                      timeout (PCTV_BLUE_SECS) can be tested with a tape
 *                      that plays, ends, and is replaced
 *   FAKE_STALL=<s>     write nothing for FAKE_STALL_LEN s (data delayed, not
 *                      lost)
 *   FAKE_FIELD_MS=<ms> field period, default 20 (= exactly 25 fps)
 */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <signal.h>
static volatile int stop;
static void onsig(int s) { (void)s; stop = 1; }
static double now(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t);
                          return t.tv_sec + 1e-9 * t.tv_nsec; }
static unsigned char line[1728];
static long long written;            /* generator frame: skipped bytes COUNT */
/* Holes are absolute ranges in the generator frame, so a pair of them can be
 * placed inside ONE field (fields are 312*1728 B each from stream start, and
 * `written` is exactly field*312*1728 at the top of a field loop).  That is
 * how the 2026-11-12 bottom-of-field crash is reproduced: a second mid-line
 * hole near the end of a field drives the parser's row counter past the last
 * frame row, and only a bug in the repair path turns that into a crash. */
static struct { long long at, len; } holes[16];
static int nholes;
static int in_hole(long long g)
{
    for (int k = 0; k < nholes; k++)
        if (g >= holes[k].at && g < holes[k].at + holes[k].len) return k;
    return -1;
}
static void emit(const unsigned char *p, size_t n)
{
    size_t i = 0;
    while (i < n) {
        int k = in_hole(written + (long long)i);
        if (k < 0) {                        /* live run: until the next hole */
            size_t s = i;
            while (i < n && in_hole(written + (long long)i) < 0) i++;
            if (write(STDOUT_FILENO, p + s, i - s) != (ssize_t)(i - s)) exit(0);
        } else {                            /* skip to the hole's end */
            long long adv = holes[k].at + holes[k].len - written;
            i = adv < (long long)n ? (size_t)adv : n;
        }
    }
    written += (long long)n;
}
int main(int argc, char **argv)
{
    int a = (argc > 1 && !strcmp(argv[1], "stream")) ? 3 : 1;
    double secs = argc > a ? atof(argv[a]) : 20.0;
    double gap_at = getenv("FAKE_GAP") ? atof(getenv("FAKE_GAP")) : -1;
    double gapl_at = getenv("FAKE_GAPLINES") ? atof(getenv("FAKE_GAPLINES")) : -1;
    double holes2_at = getenv("FAKE_MULTIGAP") ? atof(getenv("FAKE_MULTIGAP")) : -1;
    int holes2_armed = 0;
    /* The deck's blue: the colour the monitor's no-content detector looks
     * for (U ~204, dark ~47 - codes a real deck's screen reads, see the
     * BLUE_U_MIN/BLUE_Y_MAX note), from <start> s for <dur> s (default:
     * forever).  The tail of a tape, in a test tube. */
    const char *benv = getenv("FAKE_BLUE");
    double blue_at = benv ? atof(benv) : -1;
    double blue_len = benv && strchr(benv, ':') ? atof(strchr(benv, ':') + 1) : 1e9;
    int blue_on = -1;
    double stall_at = getenv("FAKE_STALL") ? atof(getenv("FAKE_STALL")) : -1;
    double stall_len = getenv("FAKE_STALL_LEN") ? atof(getenv("FAKE_STALL_LEN")) : 0.8;
    double field_ms = getenv("FAKE_FIELD_MS") ? atof(getenv("FAKE_FIELD_MS")) : 20.0;
    signal(SIGPIPE, SIG_IGN);
    signal(SIGTERM, onsig);
    signal(SIGINT, onsig);
    memset(line, 0x80, sizeof line);
    memset(line + 1444, 0x10, 284);
    double t0 = now();
    long long field = 0;
    for (;;) {
        double t = now() - t0;
        if (t >= secs || stop) break;
        if (stall_at > 0 && t >= stall_at && t < stall_at + stall_len) {
            usleep(20000);
            continue;
        }
        if (gap_at > 0 && !nholes && t >= gap_at) {
            holes[nholes++] = (typeof(holes[0])){ written + 900, 32768 };
            fprintf(stderr, "fakeprobe: 32768 B hole at byte %lld\n",
                    written + 900);       /* mid-line, as a FIFO overrun is */
        }
        if (gapl_at > 0 && !nholes && t >= gapl_at) {
            holes[nholes++] = (typeof(holes[0])){ written + 900, 19 * 1728 };
            fprintf(stderr, "fakeprobe: 19 aligned lines dropped at byte %lld\n",
                    written + 900);       /* aligned: undetectable by pitch */
        }
        /* The damaged-rotation signature that segfaulted the monitor five
         * times on 2026-11-05..12 (kernel `segfault at ... in
         * .pctv-monitor-wrapped`, HB stopping mid-capture, no stop line).
         * `written` is exactly at a field boundary here, so every offset
         * below is field-relative by construction.
         *
         * A dropout can prove at most ONE missing row to the pitch (between
         * its surviving guard codes sit (900) + (1728 - 20) bytes no matter
         * how much vanished - the pitch cannot see more), so it takes many
         * of them for gap_resync's advance-the-row-counter (the gap_seams>1
         * branch) to push field_lines past the 288 active rows into the VBI
         * range.  Rows 288+ are where field_fill_rows() indexed the 576-row
         * FRAME buffer as if it were a FIELD: 2r+parity crosses 575 and the
         * good_fuv read runs off the end of its mmap.
         *
         * So: eight dropouts through the vertical interval, three lines
         * apart (two lines apart and one dropout's surviving tail fakes a
         * full line and resets the count), each [line*1728+900, +2576) so
         * the resume lands 20 B into a line - past that line's swallowed
         * guard code, making the next real guard read exactly one line of
         * advance.  Seam #1 only records the row; seams 2..8 each advance:
         * fills land on r = 288..294, frame rows 576..589 - a read 13 KB
         * past the buffer.  Before the clamp the monitor dies on the third
         * of these fields, mid-HB, exactly as it did on real tape. */
        if (holes2_at > 0 && !holes2_armed && t >= holes2_at) {
            holes2_armed = 1;             /* arm at the NEXT field boundary */
        }
        if (holes2_armed && nholes == 0) {
            long long base = written;
            for (int k = 0; k < 8; k++)
                holes[nholes++] = (typeof(holes[0])){
                    base + (288 + 3 * k) * 1728 + 900, 2576 };
            fprintf(stderr, "fakeprobe: 8 VBI dropouts armed in field %lld "
                            "(first at byte %lld)\n", field,
                    base + 288 * 1728 + 900);
        }
        int blueing = blue_at > 0 && t >= blue_at && t < blue_at + blue_len;
        if (blueing != blue_on) {
            blue_on = blueing;
            fprintf(stderr, "fakeprobe: %s (t=%.1f s)\n",
                    blueing ? "deck blue screen" : "blue over, picture back", t);
        }
        int F = (int)(field & 1);
        double due = (double)field * (field_ms / 1000.0);
        if (due > t) { struct timespec ts; ts.tv_sec = 0;
                       ts.tv_nsec = (long)((due - t) * 1e9); nanosleep(&ts, NULL); }
        for (int l = 0; l < 312; l++) {
            int V = l >= 288;
            unsigned char *p = line;
            p[0] = 0xFF; p[1] = 0; p[2] = 0;
            p[3] = (unsigned char)(0x80 | (F << 6) | (V << 5));
            for (int x = 0; x < 720; x++) {
                p[4 + x * 2 + 1] = (unsigned char)(blueing ? 0x2F
                                       : (((l + field * 3) & 0x3F) * 4));
                p[4 + x * 2] = (unsigned char)(blueing ? ((x & 1) ? 0x30 : 0xCC)
                                                        : 0x80);
            }
            emit(line, 1728);
        }
        field++;
    }
    fprintf(stderr, "fakeprobe: %lld fields, %lld bytes\n", field, written);
    return 0;
}
