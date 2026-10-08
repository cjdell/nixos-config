/* SPDX-License-Identifier: GPL-2.0
 *
 * pctv-monitor - live monitor / capture GUI for the Pinnacle PCTV 320cx,
 * pure userspace: it spawns `pctv_probe stream <input>` (libusb bring-up +
 * raw BT.656 on stdout) and never touches /dev/video* or a kernel module.
 *
 * The child may need root for raw USB; we launch it through `sudo -n` unless
 * we are already root (set PCTV_PROBE to override the binary path, or run the
 * whole GUI under sudo).
 *
 * Keys:
 *   1..4 / C  composite1/2/3, S-Video    g  toggle colour/grey
 *   s snapshots a PPM                     r  toggle raw BT.656 recording
 *   space    pause/resume display         q / ESC  quit
 *
 * Build: see build-monitor.sh  (cc + SDL2 + libusb headers not needed here).
 */
#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <unistd.h>
#include <fcntl.h>
#include <signal.h>
#include <time.h>
#include <sys/wait.h>
#include <sys/types.h>
#include <SDL.h>

#define W 720
#define H 576
#define FIELD_MAX 296
#define RBUF (8u << 20)     /* 8 MiB read/parse buffer */

static const char *INPUTS[] = { "composite1", "composite2", "composite3", "svideo" };
static const char *INPUT_LABEL[] = { "Composite 1", "Composite 2", "Composite 3", "S-Video" };

static pid_t child = -1;
static int   child_fd = -1;
static char  probe_path[4096];
static int   cur_input = 0;
static int   grey = 0;
static int   paused = 0;
static int   recording = 0;
static FILE *rec_file = NULL;

/* current field being assembled */
static unsigned char fY[FIELD_MAX][W];
static unsigned char fCb[FIELD_MAX][W / 2];
static unsigned char fCr[FIELD_MAX][W / 2];
static int  field_F = -1, field_lines = 0;
static unsigned char fb[H][W * 3];   /* RGB24 */
static int  frame_ready = 0;         /* set when a field was committed */
static unsigned long long frames = 0;

static void die(const char *m) { fprintf(stderr, "pctv-monitor: %s: %s\n", m, strerror(errno)); exit(1); }

/* ------------------------------------------------------------------ child */

static void child_stop(void)
{
    if (child > 0) { kill(child, SIGTERM); waitpid(child, NULL, 0); child = -1; }
    if (child_fd >= 0) { close(child_fd); child_fd = -1; }
}

static void child_start(int input)
{
    int p[2];
    if (pipe(p) < 0) die("pipe");
    fcntl(p[0], F_SETPIPE_SZ, 1 << 20);
    signal(SIGPIPE, SIG_IGN);

    child = fork();
    if (child < 0) die("fork");
    if (child == 0) {
        dup2(p[1], STDOUT_FILENO);
        close(p[0]); close(p[1]);
        /* keep stderr for the driver's diagnostics */
        if (geteuid() == 0)
            execlp(probe_path, probe_path, "stream", INPUTS[input], NULL);
        else if (getenv("PCTV_NO_SUDO"))
            execlp(probe_path, probe_path, "stream", INPUTS[input], NULL);
        else
            execlp("sudo", "sudo", "-n", probe_path, "stream", INPUTS[input], NULL);
        fprintf(stderr, "pctv-monitor: exec failed: %s\n", strerror(errno));
        _exit(127);
    }
    close(p[1]);
    child_fd = p[0];
    int fl = fcntl(child_fd, F_GETFL, 0);
    fcntl(child_fd, F_SETFL, fl | O_NONBLOCK);
    fprintf(stderr, "pctv-monitor: started %s on input %s (pid %d)\n",
            probe_path, INPUT_LABEL[input], child);
}

/* --------------------------------------------------------------- decoding */

static inline void yuv2rgb(int y, int cb, int cr, unsigned char *o)
{
    int c = y - 16; if (c < 0) c = 0;
    int d = cb - 128, e = cr - 128;
    int r = (298 * c + 409 * e + 128) >> 8;
    int g = (298 * c - 100 * d - 208 * e + 128) >> 8;
    int b = (298 * c + 516 * d + 128) >> 8;
    if (grey) { r = g = b = (298 * c + 128) >> 8; }
    o[0] = r < 0 ? 0 : r > 255 ? 255 : r;
    o[1] = g < 0 ? 0 : g > 255 ? 255 : g;
    o[2] = b < 0 ? 0 : b > 255 ? 255 : b;
}

/* Commit the assembled field into the interlaced frame buffer. */
static void field_commit(void)
{
    if (field_lines <= 0) return;
    int rows = field_lines < 288 ? field_lines : 288;
    int parity = field_F ? 1 : 0;
    for (int r = 0; r < rows; r++) {
        int out = 2 * r + parity;
        if (out >= H) continue;
        unsigned char *o = fb[out];
        for (int x = 0; x < W; x++) {
            int y = fY[r][x];
            int cb = fCb[r][x >> 1];
            int cr = fCr[r][x >> 1];
            yuv2rgb(y, cb, cr, o + x * 3);
        }
    }
    frame_ready = 1;
    frames++;
    field_lines = 0;
}

/* One BT.656 active line, starting right after SAV. */
static void field_line(const unsigned char *act, int xy)
{
    int F = (xy >> 6) & 1;
    int V = (xy >> 5) & 1;
    if (V) return;                        /* vertical blanking, not picture */
    if (field_lines > 0 && F != field_F) field_commit();
    if (field_lines == 0) field_F = F;
    if (field_lines >= FIELD_MAX) return;
    unsigned char *Y = fY[field_lines];
    unsigned char *Cb = fCb[field_lines];
    unsigned char *Cr = fCr[field_lines];
    for (int x = 0; x < W; x++) Y[x] = act[x * 2 + 1];
    for (int x = 0; x < W / 2; x++) {
        Cb[x] = act[x * 4 + 0];
        Cr[x] = act[x * 4 + 2];
    }
    field_lines++;
}

/* Parse as much of [d,d+n) as possible; return bytes consumed. */
static size_t parse(const unsigned char *d, size_t n)
{
    size_t i = 0;
    while (i + 4 + W * 2 <= n) {
        if (d[i] == 0xFF && d[i + 1] == 0x00 && d[i + 2] == 0x00) {
            int xy = d[i + 3];
            if ((xy & 0x10) == 0) {           /* SAV begins the active part */
                field_line(d + i + 4, xy);
                i += 4 + W * 2;
                continue;
            }
        }
        i++;
    }
    /* never let a stalled field linger without data */
    return i;
}

/* ------------------------------------------------------------------ output */

static void snapshot_ppm(void)
{
    char path[256];
    time_t t = time(NULL);
    struct tm tm; localtime_r(&t, &tm);
    strftime(path, sizeof path, "/tmp/pctv-snap-%Y%m%d-%H%M%S.ppm", &tm);
    FILE *f = fopen(path, "wb");
    if (!f) { fprintf(stderr, "snapshot: %s\n", strerror(errno)); return; }
    fprintf(f, "P6\n%d %d\n255\n", W, H);
    fwrite(fb, 1, sizeof fb, f);
    fclose(f);
    fprintf(stderr, "snapshot: %s\n", path);
}

static void rec_toggle(void)
{
    if (recording) {
        recording = 0;
        if (rec_file) fclose(rec_file);
        rec_file = NULL;
        fprintf(stderr, "recording stopped\n");
    } else {
        char path[256];
        time_t t = time(NULL); struct tm tm; localtime_r(&t, &tm);
        strftime(path, sizeof path, "/tmp/pctv-rec-%Y%m%d-%H%M%S.bt656", &tm);
        rec_file = fopen(path, "wb");
        if (!rec_file) { fprintf(stderr, "record: %s\n", strerror(errno)); return; }
        recording = 1;
        fprintf(stderr, "recording -> %s\n", path);
    }
}

/* -------------------------------------------------------------------- main */

int main(int argc, char **argv)
{
    /* locate pctv_probe next to us unless PCTV_PROBE says otherwise */
    const char *env = getenv("PCTV_PROBE");
    if (env) snprintf(probe_path, sizeof probe_path, "%s", env);
    else {
        char self[4096];
        ssize_t k = readlink("/proc/self/exe", self, sizeof self - 1);
        char dir[4096] = ".";
        if (k > 0) {
            self[k] = 0;
            char *sl = strrchr(self, '/');
            if (sl) { *sl = 0; snprintf(dir, sizeof dir, "%s", self); }
        }
        snprintf(probe_path, sizeof probe_path, "%s/pctv_probe", dir);
    }
    if (access(probe_path, X_OK) != 0)
        snprintf(probe_path, sizeof probe_path, "pctv_probe");

    if (SDL_Init(SDL_INIT_VIDEO) < 0) {
        fprintf(stderr, "SDL_Init: %s\n", SDL_GetError());
        return 1;
    }
    SDL_Window *win = SDL_CreateWindow("PCTV 320cx - live",
        SDL_WINDOWPOS_CENTERED, SDL_WINDOWPOS_CENTERED, W, H, SDL_WINDOW_RESIZABLE);
    if (!win) { fprintf(stderr, "SDL_CreateWindow: %s\n", SDL_GetError()); return 1; }
    SDL_Renderer *ren = SDL_CreateRenderer(win, -1,
        SDL_RENDERER_ACCELERATED | SDL_RENDERER_PRESENTVSYNC);
    if (!ren) ren = SDL_CreateRenderer(win, -1, SDL_RENDERER_SOFTWARE);
    if (!ren) { fprintf(stderr, "SDL_CreateRenderer: %s\n", SDL_GetError()); return 1; }
    SDL_RenderSetLogicalSize(ren, W, H);
    SDL_SetHint(SDL_HINT_RENDER_SCALE_QUALITY, "linear");
    SDL_Texture *tex = SDL_CreateTexture(ren, SDL_PIXELFORMAT_RGB24,
        SDL_TEXTUREACCESS_STREAMING, W, H);
    if (!tex) { fprintf(stderr, "SDL_CreateTexture: %s\n", SDL_GetError()); return 1; }

    memset(fb, 0, sizeof fb);
    child_start(cur_input);

    unsigned char *rbuf = malloc(RBUF);
    size_t rlen = 0;
    int running = 1;
    unsigned long long last_frames = 0;
    unsigned long long snap_after = 0;
    { const char *s = getenv("PCTV_SNAP_AFTER"); if (s) snap_after = strtoull(s, NULL, 0); }
    double last_t = (double)SDL_GetTicks() / 1000.0, fps = 0;

    while (running) {
        SDL_Event e;
        while (SDL_PollEvent(&e)) {
            if (e.type == SDL_QUIT) running = 0;
            else if (e.type == SDL_KEYDOWN) {
                switch (e.key.keysym.sym) {
                case SDLK_q: case SDLK_ESCAPE: running = 0; break;
                case SDLK_SPACE: paused = !paused; break;
                case SDLK_g: grey = !grey; break;
                case SDLK_s: snapshot_ppm(); break;
                case SDLK_r: rec_toggle(); break;
                case SDLK_1: case SDLK_2: case SDLK_3: case SDLK_4: {
                    int in = e.key.keysym.sym - SDLK_1;
                    if (in != cur_input) {
                        child_stop();
                        field_lines = 0; field_F = -1; rlen = 0;
                        cur_input = in;
                        child_start(cur_input);
                    }
                    break;
                }
                default: break;
                }
            }
        }

        /* drain the child's stdout */
        for (;;) {
            if (rlen == RBUF) { memmove(rbuf, rbuf + RBUF / 2, RBUF / 2); rlen = RBUF / 2; }
            ssize_t r = read(child_fd, rbuf + rlen, RBUF - rlen);
            if (r > 0) {
                if (recording && rec_file) fwrite(rbuf + rlen, 1, r, rec_file);
                rlen += r;
                continue;
            }
            if (r == 0) { child_stop(); running = 0; break; }   /* child died */
            break;                                              /* EAGAIN */
        }
        if (!paused && rlen > 0) {
            size_t used = parse(rbuf, rlen);
            if (used > 0) { memmove(rbuf, rbuf + used, rlen - used); rlen -= used; }
        }

        if (frame_ready) {
            SDL_UpdateTexture(tex, NULL, fb, W * 3);
            frame_ready = 0;
            if (snap_after && frames >= snap_after) { snapshot_ppm(); running = 0; }
        }
        SDL_SetRenderDrawColor(ren, 0, 0, 0, 255);
        SDL_RenderClear(ren);
        SDL_RenderCopy(ren, tex, NULL, NULL);
        SDL_RenderPresent(ren);

        double now = (double)SDL_GetTicks() / 1000.0;
        if (now - last_t >= 1.0) {
            fps = (double)(frames - last_frames) / (now - last_t);
            last_frames = frames; last_t = now;
            char title[256];
            snprintf(title, sizeof title, "PCTV 320cx - %s%s%s - %.0f fps",
                     INPUT_LABEL[cur_input], grey ? " [grey]" : "",
                     recording ? " [REC]" : "", fps);
            SDL_SetWindowTitle(win, title);
            if (getenv("PCTV_VERBOSE"))
                fprintf(stderr, "monitor: %s (frames=%llu)\n", title, frames);
        }
        if (rlen == 0) SDL_Delay(1);
    }

    child_stop();
    if (rec_file) fclose(rec_file);
    free(rbuf);
    SDL_DestroyTexture(tex);
    SDL_DestroyRenderer(ren);
    SDL_DestroyWindow(win);
    SDL_Quit();
    return 0;
}
