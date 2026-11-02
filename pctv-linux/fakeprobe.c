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
static long long written;
static long long hole_at = -1, hole_len;
static void emit(const unsigned char *p, size_t n)
{
    if (hole_at >= 0 && written + (long long)n > hole_at &&
        written < hole_at + hole_len) {
        long long s = hole_at > written ? hole_at - written : 0;
        long long e = hole_at + hole_len < written + (long long)n
                    ? hole_at + hole_len - written : (long long)n;
        if (s > 0 && write(STDOUT_FILENO, p, (size_t)s) != s) exit(0);
        if (e < (long long)n && write(STDOUT_FILENO, p + e, n - (size_t)e) != n - e) exit(0);
        written += n;
        return;
    }
    if (write(STDOUT_FILENO, p, n) != (ssize_t)n) exit(0);
    written += n;
}
int main(int argc, char **argv)
{
    int a = (argc > 1 && !strcmp(argv[1], "stream")) ? 3 : 1;
    double secs = argc > a ? atof(argv[a]) : 20.0;
    double gap_at = getenv("FAKE_GAP") ? atof(getenv("FAKE_GAP")) : -1;
    double gapl_at = getenv("FAKE_GAPLINES") ? atof(getenv("FAKE_GAPLINES")) : -1;
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
        if (gap_at > 0 && hole_at < 0 && t >= gap_at) {
            hole_at = written + 900;      /* mid-line, as a FIFO overrun is */
            hole_len = 32768;
            fprintf(stderr, "fakeprobe: 32768 B hole at byte %lld\n", hole_at);
        }
        if (gapl_at > 0 && hole_at < 0 && t >= gapl_at) {
            hole_at = written + 900;
            hole_len = 19 * 1728;         /* aligned: undetectable by pitch */
            fprintf(stderr, "fakeprobe: 19 aligned lines dropped at byte %lld\n", hole_at);
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
                p[4 + x * 2 + 1] = (unsigned char)(((l + field * 3) & 0x3F) * 4);
                p[4 + x * 2] = 0x80;
            }
            emit(line, 1728);
            if (hole_at >= 0 && written > hole_at + hole_len) { /* once */ }
        }
        if (hole_at >= 0 && written > hole_at + hole_len && field < 0) {}
        field++;
    }
    fprintf(stderr, "fakeprobe: %lld fields, %lld bytes\n", field, written);
    return 0;
}
