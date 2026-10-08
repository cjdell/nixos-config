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
 * Input selection: keys 1/2 pick Composite or S-Video; Tab cycles.
 * The choice can also be given at startup with `-i <input>` / PCTV_INPUT
 * (e.g. `pctv-monitor -i svideo`).  A small overlay names the active input.
 *
 * Keys:
 *   1/2 / Tab  input (Composite, S-Video)          g  toggle colour/grey
 *   s snapshots a PPM                              r  toggle raw BT.656 recording
 *   space       pause/resume display               q / ESC  quit
 *
 * Build: see build-monitor.sh  (cc + SDL2; the probe needs libusb, not us).
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
#include <strings.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <sys/types.h>
#include <SDL.h>

#include "font5x7.h"

#define W 720
#define H 576
#define FIELD_MAX 296
#define RBUF (8u << 20)     /* 8 MiB read/parse buffer */

/* This card has exactly one composite input (the yellow RCA) and one S-Video
 * connector; the other two RCAs are L/R audio.  The CX25843 exposes eight
 * composite VINs but only VIN1 is wired here, so the UI offers just the two
 * physical inputs.  (`pctv_probe analog2 composite2|3 ...` is still available
 * for board bring-up experiments.) */
static const char *INPUTS[] = { "composite1", "svideo" };
static const char *INPUT_LABEL[] = { "Composite", "S-Video" };
#define NINPUTS ((int)(sizeof(INPUTS) / sizeof(INPUTS[0])))

static pid_t child = -1;
static int   child_fd = -1;
static char  probe_path[4096];
static int   cur_input = 0;
static int   grey = 0;
static int   paused = 0;
static int   recording = 0;
static FILE *rec_file = NULL;

/* Overlay: draw the big input banner until this SDL tick; the controls hint
 * is shown alongside it. */
static unsigned long long overlay_until = 0;
static void show_overlay(unsigned ms)
{
    overlay_until = SDL_GetTicks() + ms;
}

/* current field being assembled */
static unsigned char fY[FIELD_MAX][W];
static unsigned char fCb[FIELD_MAX][W / 2];
static unsigned char fCr[FIELD_MAX][W / 2];
static int  field_F = -1, field_lines = 0;
static unsigned char fb[H][W * 3];   /* RGB24 */
static int  frame_ready = 0;         /* set when a field was committed */
static unsigned long long frames = 0;

static void die(const char *m) { fprintf(stderr, "pctv-monitor: %s: %s\n", m, strerror(errno)); exit(1); }

/* ------------------------------------------------------------------- text */

/* Draw one ASCII glyph from the 5x7 font at (x,y), pixel scale s. */
static void draw_char(SDL_Renderer *ren, int x, int y, int s, unsigned char c)
{
    if (c >= 128) c = '?';
    const unsigned char *g = FONT5X7[c];
    for (int col = 0; col < 5; col++)
        for (int row = 0; row < 7; row++)
            if (g[col] & (1u << row)) {
                SDL_Rect r = { x + col * s, y + row * s, s, s };
                SDL_RenderFillRect(ren, &r);
            }
}

static void draw_text(SDL_Renderer *ren, int x, int y, int s, const char *t)
{
    for (; *t; t++, x += 6 * s) draw_char(ren, x, y, s, (unsigned char)*t);
}

static int text_w(const char *t, int s) { return (int)strlen(t) * 6 * s; }

/* A dark panel + text, used for the input banner and the controls hint. */
static void draw_panel(SDL_Renderer *ren, int x, int y, const char *text, int scale)
{
    int w = text_w(text, scale) + 12, h = 7 * scale + 8;
    SDL_SetRenderDrawBlendMode(ren, SDL_BLENDMODE_BLEND);
    SDL_SetRenderDrawColor(ren, 0, 0, 0, 180);
    SDL_Rect bg = { x - 6, y - 4, w, h };
    SDL_RenderFillRect(ren, &bg);
    SDL_SetRenderDrawColor(ren, 235, 235, 235, 255);
    draw_text(ren, x, y, scale, text);
}

/* --------------------------------------------------------------- input */

static int input_from_name(const char *s)
{
    if (!s) return -1;
    for (int i = 0; i < NINPUTS; i++)
        if (!strcasecmp(s, INPUTS[i]) || !strcasecmp(s, INPUT_LABEL[i])) return i;
    if (!strcasecmp(s, "svideo1")) return 1;
    if (!strcasecmp(s, "composite")) return 0;
    if (!strcasecmp(s, "1") || !strcasecmp(s, "2")) return atoi(s) - 1;
    return -1;
}

/* Remember the last chosen input under $XDG_CONFIG_HOME/pctv-monitor/input so
 * the monitor comes back on the connector the user actually uses. */
static const char *state_path(void)
{
    static char p[4096];
    const char *xdg = getenv("XDG_CONFIG_HOME");
    const char *home = getenv("HOME");
    if (xdg && *xdg) snprintf(p, sizeof p, "%s/pctv-monitor/input", xdg);
    else if (home && *home) snprintf(p, sizeof p, "%s/.config/pctv-monitor/input", home);
    else p[0] = 0;
    return p;
}

static int load_saved_input(void)
{
    const char *p = state_path();
    if (!*p) return -1;
    FILE *f = fopen(p, "r");
    if (!f) return -1;
    char b[64] = { 0 };
    int ok = fgets(b, sizeof b, f) != NULL;
    fclose(f);
    if (!ok) return -1;
    char *nl = strchr(b, '\n'); if (nl) *nl = 0;
    return input_from_name(b);
}

static void save_input(int in)
{
    const char *p = state_path();
    if (!*p || in < 0 || in >= NINPUTS) return;
    char dir[4096];
    snprintf(dir, sizeof dir, "%s", p);
    char *sl = strrchr(dir, '/');
    if (sl) { *sl = 0; mkdir(dir, 0700); }
    FILE *f = fopen(p, "w");
    if (f) { fprintf(f, "%s\n", INPUTS[in]); fclose(f); }
}

static void usage(const char *p)
{
    fprintf(stderr,
        "usage: %s [-i|--input <input>] [-l|--list]\n"
        "  input: composite (default) or svideo\n"
        "  keys:  1/2 or Tab pick the input; g grey; s snapshot;\n"
        "         r record; space pause; q/ESC quit\n", p);
}

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
    /* input can be selected before the window exists: saved choice, then
     * PCTV_INPUT, then -i/--input on the command line (highest priority). */
    {
        int in = load_saved_input();
        if (in >= 0) cur_input = in;
    }
    {
        const char *env = getenv("PCTV_INPUT");
        if (env) {
            int in = input_from_name(env);
            if (in >= 0) cur_input = in;
            else fprintf(stderr, "pctv-monitor: ignoring PCTV_INPUT=%s\n", env);
        }
    }
    for (int i = 1; i < argc; i++) {
        if ((!strcmp(argv[i], "-i") || !strcmp(argv[i], "--input")) && i + 1 < argc) {
            int in = input_from_name(argv[++i]);
            if (in >= 0) cur_input = in;
            else { fprintf(stderr, "pctv-monitor: unknown input '%s'\n", argv[i]); return 2; }
        } else if (!strcmp(argv[i], "-l") || !strcmp(argv[i], "--list")) {
            for (int k = 0; k < NINPUTS; k++) printf("%s\n", INPUTS[k]);
            return 0;
        } else if (!strcmp(argv[i], "-h") || !strcmp(argv[i], "--help")) {
            usage(argv[0]);
            return 0;
        } else {
            fprintf(stderr, "pctv-monitor: unexpected argument '%s'\n", argv[i]);
            usage(argv[0]);
            return 2;
        }
    }

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

    save_input(cur_input);      /* persist the effective choice */

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
    show_overlay(8000);

    unsigned char *rbuf = malloc(RBUF);
    size_t rlen = 0;
    int running = 1;
    unsigned long long last_frames = 0;
    unsigned long long snap_after = 0;
    { const char *s = getenv("PCTV_SNAP_AFTER"); if (s) snap_after = strtoull(s, NULL, 0); }
    double last_t = (double)SDL_GetTicks() / 1000.0, fps = 0;

    while (running) {
        int want_input = cur_input;
        SDL_Event e;
        while (SDL_PollEvent(&e)) {
            if (e.type == SDL_QUIT) running = 0;
            else if (e.type == SDL_KEYDOWN) {
                switch (e.key.keysym.sym) {
                case SDLK_q: case SDLK_ESCAPE: running = 0; break;
                case SDLK_SPACE: paused = !paused; show_overlay(2000); break;
                case SDLK_g: grey = !grey; show_overlay(2000); break;
                case SDLK_s: snapshot_ppm(); break;
                case SDLK_r: rec_toggle(); break;
                case SDLK_TAB: case SDLK_i:
                    want_input = (cur_input + 1) % NINPUTS; break;
                case SDLK_1: case SDLK_2: case SDLK_3: case SDLK_4:
                    want_input = e.key.keysym.sym - SDLK_1; break;
                default: break;
                }
            }
        }

        if (want_input != cur_input) {
            child_stop();
            field_lines = 0; field_F = -1; rlen = 0;
            frame_ready = 0;
            cur_input = want_input;
            save_input(cur_input);
            child_start(cur_input);
            show_overlay(4000);
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

        /* input banner: always name the active input, plus transient hints */
        {
            char banner[64];
            snprintf(banner, sizeof banner, "INPUT: %s", INPUT_LABEL[cur_input]);
            draw_panel(ren, 10, 8, banner, 2);
            if (SDL_GetTicks() < overlay_until) {
                char hint[128];
                snprintf(hint, sizeof hint,
                         "1/2/Tab: input   G: grey   S: snap   R: rec   SPACE: pause   Q: quit");
                draw_panel(ren, 10, 8 + 7 * 2 + 12, hint, 1);
            }
        }
        SDL_RenderPresent(ren);

        double now = (double)SDL_GetTicks() / 1000.0;
        if (now - last_t >= 1.0) {
            fps = (double)(frames - last_frames) / (now - last_t);
            last_frames = frames; last_t = now;
            char title[256];
            snprintf(title, sizeof title, "PCTV 320cx - %s%s%s - %.0f fps  [1/2/Tab: input]",
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
