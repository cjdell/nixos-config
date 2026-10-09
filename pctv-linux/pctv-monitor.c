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
 * Video input selection: keys 1/2 pick Composite or S-Video; Tab cycles.  The
 * choice can also be given at startup with `-i <input>` / PCTV_INPUT (e.g.
 * `pctv-monitor -i svideo`).  A small overlay names the active input.
 *
 * Audio: the card's own analog audio path over USB is still undecoded
 * (TRUTH.md §9.6 - only bulk-IN 0x82 ever delivers, and it carries BT.656), so
 * the pigtail's L/R RCAs go into the host's line-in and are captured from
 * ALSA.  `a` cycles the audio input (none / Internal Mic / Mic / Line /
 * digital), `-`/`+` set the capture gain, `b` the input boost, `m` mutes.  A
 * live stereo meter with peak-hold, clip count and a verdict shows whether
 * the level is present and in range.
 *
 * Capture: `c` writes an MPEG-2 program stream - 720x576 interlaced mpeg2video
 * plus MP2 audio, i.e. a plain PAL-DVD-style .mpg - by piping deframed UYVY
 * video to ffmpeg's stdin and the ALSA PCM to fd 3.  `r` still dumps raw
 * BT.656.
 *
 * Keys:
 *   1/2 / Tab  video input (Composite, S-Video)      g  toggle colour/grey
 *   s  snapshot a PPM                                 c  toggle MPEG-2 capture
 *   r  toggle raw BT.656 recording                    a  cycle audio input
 *   -/+ capture gain      b input boost      m mute    space pause display
 *   q / ESC quit
 *
 * Build: see build-monitor.sh  (cc + SDL2 + alsa-lib; the probe needs libusb).
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
#include <math.h>
#include <strings.h>
#include <pthread.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <sys/types.h>
#include <sys/poll.h>
#include <alsa/asoundlib.h>
#include <SDL.h>

#include "font5x7.h"

#define W 720
#define H 576
#define FIELD_MAX 296
#define RBUF (8u << 20)          /* 8 MiB read/parse buffer */
#define UV_SIZE ((size_t)H * W * 2)  /* one 720x576 UYVY frame */

/* This card has exactly one composite input (the yellow RCA) and one S-Video
 * connector; the other two RCAs are L/R audio.  The CX25843 exposes eight
 * composite VINs but only VIN1 is wired here, so the UI offers just the two
 * physical inputs.  (`pctv_probe analog2 composite2|3 ...` is still available
 * for board bring-up experiments.) */
static const char *INPUTS[] = { "composite1", "svideo" };
static const char *INPUT_LABEL[] = { "Composite", "S-Video" };
#define NINPUTS ((int)(sizeof(INPUTS) / sizeof(INPUTS[0])))

static int input_from_name(const char *s)
{
    if (!s) return -1;
    for (int i = 0; i < NINPUTS; i++)
        if (!strcasecmp(s, INPUTS[i]) || !strcasecmp(s, INPUT_LABEL[i])) return i;
    if (!strcmp(s, "composite") || !strcmp(s, "cvbs") || !strcmp(s, "rca")) return 0;
    if (!strcmp(s, "s") || !strcmp(s, "sv") || !strcmp(s, "s-vhs")) return 1;
    return -1;
}

static pid_t child = -1;
static int   child_fd = -1;
static char  probe_path[4096];
static int   cur_input = 0;
static int   grey = 0;
static int   paused = 0;
static int   recording = 0;
static FILE *rec_file = NULL;
static char  out_dir[512];
static int   mpeg2_kbps = 6000;

/* Overlay: draw the big input banner until this SDL tick; the controls hint
 * is shown alongside it. */
static unsigned long long overlay_until = 0;
static void show_overlay(unsigned ms) { overlay_until = SDL_GetTicks() + ms; }

/* current field being assembled */
static unsigned char fY[FIELD_MAX][W];
static unsigned char fCb[FIELD_MAX][W / 2];
static unsigned char fCr[FIELD_MAX][W / 2];
static unsigned char fb[H][W * 3];   /* RGB24, for the display */
static unsigned char fuv[UV_SIZE];   /* UYVY, for the encoder */
static int  field_F = -1, field_lines = 0;
static int  parity_mask = 0;         /* which field parities are in fuv */
static int  field_repeat = 0;        /* same parity twice: feed anyway */
static int  frame_ready = 0;
static unsigned long long frames = 0;
static unsigned long long bytes_in = 0;   /* bytes read from the probe */

static void die(const char *m)
{
    fprintf(stderr, "pctv-monitor: %s: %s\n", m, strerror(errno));
    exit(1);
}

/* Ctrl-C / kill must still finalise the MPEG-2 stream (a PS with no pack-end
 * is unplayable), so the loop exits through the normal shutdown path. */
static volatile sig_atomic_t g_quit = 0;
static void on_sigint(int sig)
{
    (void)sig;
    g_quit = 1;
}

/* The audio thread feeds the encoder, so the capture sink is declared up front
 * (the capture section itself lives after the audio section). */
static void cap_feed_audio(const void *p, size_t n);

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

/* A dark panel of several lines. */
static void draw_panel_lines(SDL_Renderer *ren, int x, int y, const char *const *lines,
                             int nlines, int scale)
{
    int w = 0;
    for (int i = 0; i < nlines; i++) {
        int lw = text_w(lines[i], scale);
        if (lw > w) w = lw;
    }
    int lh = 7 * scale + 3, h = nlines * lh + 8;
    SDL_SetRenderDrawBlendMode(ren, SDL_BLENDMODE_BLEND);
    SDL_SetRenderDrawColor(ren, 0, 0, 0, 180);
    SDL_Rect bg = { x - 6, y - 4, w + 12, h };
    SDL_RenderFillRect(ren, &bg);
    for (int i = 0; i < nlines; i++) {
        SDL_SetRenderDrawColor(ren, 235, 235, 235, 255);
        draw_text(ren, x, y + i * lh, scale, lines[i]);
    }
}

/* ------------------------------------------------------------------ config */

static const char *cfg_dir(void)
{
    static char p[4096];
    const char *xdg = getenv("XDG_CONFIG_HOME");
    const char *home = getenv("HOME");
    if (xdg && *xdg) snprintf(p, sizeof p, "%s/pctv-monitor", xdg);
    else if (home && *home) snprintf(p, sizeof p, "%s/.config/pctv-monitor", home);
    else p[0] = 0;
    return p;
}

static void cfg_write(const char *leaf, const char *val)
{
    const char *d = cfg_dir();
    if (!*d) return;
    mkdir(d, 0700);
    char p[4096];
    snprintf(p, sizeof p, "%s/%s", d, leaf);
    FILE *f = fopen(p, "w");
    if (f) { fprintf(f, "%s\n", val); fclose(f); }
}

static int cfg_read(const char *leaf, char *buf, size_t n)
{
    const char *d = cfg_dir();
    if (!*d) return 0;
    char p[4096];
    snprintf(p, sizeof p, "%s/%s", d, leaf);
    FILE *f = fopen(p, "r");
    if (!f) return 0;
    int ok = fgets(buf, (int)n, f) != NULL;
    fclose(f);
    if (!ok) return 0;
    char *nl = strchr(buf, '\n'); if (nl) *nl = 0;
    return 1;
}

/* The "audio" config file: line 1 = input label, line 2 = "<gain%> <boost step>".
 * The staging is remembered because the right capture gain for a given wiring is
 * a property of the wiring, not of the session - on this box the line-in needs
 * the codec's whole +30 dB to land a normal program in the metered range, and
 * without this every launch starts 46 dB too quiet. */
static void cfg_write_audio(const char *label, int gain_pct, int boost_step, int agc)
{
    const char *d = cfg_dir();
    if (!*d) return;
    mkdir(d, 0700);
    char p[4096];
    snprintf(p, sizeof p, "%s/%s", d, "audio");
    FILE *f = fopen(p, "w");
    if (f) { fprintf(f, "%s\n%d %d %d\n", label, gain_pct, boost_step, agc); fclose(f); }
}

static int cfg_read_audio(char *buf, size_t n, int *gain_pct, int *boost_step,
                          int *agc)
{
    const char *d = cfg_dir();
    *gain_pct = *boost_step = *agc = -1;
    if (!*d) return 0;
    char p[4096];
    snprintf(p, sizeof p, "%s/%s", d, "audio");
    FILE *f = fopen(p, "r");
    if (!f) return 0;
    int ok = fgets(buf, (int)n, f) != NULL;
    char second[64] = "";
    if (ok) fgets(second, sizeof second, f);
    fclose(f);
    if (!ok) return 0;
    char *nl = strchr(buf, '\n'); if (nl) *nl = 0;
    if (second[0]) sscanf(second, "%d %d %d", gain_pct, boost_step, agc);
    return 1;
}

static void pick_out_dir(void)
{
    const char *e = getenv("PCTV_OUT_DIR");
    if (e && *e) { snprintf(out_dir, sizeof out_dir, "%s", e); return; }
    const char *home = getenv("HOME");
    if (home && *home) {
        snprintf(out_dir, sizeof out_dir, "%s/Videos", home);
        mkdir(out_dir, 0755);              /* may exist already; that is fine */
        if (access(out_dir, W_OK) == 0) return;
    }
    snprintf(out_dir, sizeof out_dir, "/tmp");
}

static void usage(const char *p)
{
    fprintf(stderr,
        "usage: %s [options]\n"
        "  -i|--input <in>     video input: composite (default) or svideo\n"
        "  -l|--list           list video inputs and exit\n"
        "  -L|--list-audio     list audio inputs and exit\n"
        "  --audio <name>      audio input (see -L; 'none' disables)\n"
        "  --no-audio          same as --audio none\n"
        "  --alsa-dev <dev>    force an ALSA capture device, e.g. hw:0,0\n"
        "  --gain <0-100>      capture gain as %% of the hardware range\n"
        "  --boost <0-3>       input boost step (Line/Mic/Internal Mic Boost)\n"
        "  --agc/--no-agc      automatic gain control (default on): keeps the\n"
        "                      peaks near -18 dBFS by driving the codec\n"
        "  --monitor           start with input monitoring on: play the captured\n"
        "                      samples out of the host's speakers (key: o)\n"
        "  --out-dir <dir>     where captures go (default ~/Videos, else /tmp)\n"
        "  --bitrate <kbps>    MPEG-2 video bitrate (default 6000)\n"
        "  --ffmpeg <path>     ffmpeg binary (default PCTV_FFMPEG or 'ffmpeg')\n"
        "  --capture           start an MPEG-2 capture immediately\n"
        "  --capture-seconds N stop after N seconds and exit (headless test)\n"
        "\n"
        "  keys: 1/2 or Tab video input | a audio input | A automatic gain |\n"
        "        -/+ gain | b boost | m mute | o monitor input | c MPEG-2 capture |\n"
        "        s snapshot | g grey | space pause display | q/ESC quit\n", p);
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
        if (geteuid() == 0 || getenv("PCTV_NO_SUDO"))
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

/* Commit the assembled field into the interlaced frame, for both the display
 * (RGB24) and the encoder (UYVY). */
static void field_commit(void)
{
    if (field_lines <= 0) return;
    int rows = field_lines < 288 ? field_lines : 288;
    int parity = field_F ? 1 : 0;
    if (parity_mask & (1 << parity)) field_repeat = 1;
    for (int r = 0; r < rows; r++) {
        int out = 2 * r + parity;
        if (out >= H) continue;
        unsigned char *o = fb[out];
        unsigned char *u = fuv + (size_t)out * W * 2;
        for (int x = 0; x < W; x++) {
            int y = fY[r][x], cb = fCb[r][x >> 1], cr = fCr[r][x >> 1];
            yuv2rgb(y, cb, cr, o + x * 3);
            u[x * 2 + 0] = (x & 1) ? (unsigned char)cr : (unsigned char)cb;
            u[x * 2 + 1] = (unsigned char)y;
        }
    }
    parity_mask |= 1 << parity;
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
    return i;
}

/* ------------------------------------------------------------------ output */

static void stamp_name(char *path, size_t n, const char *prefix, const char *ext)
{
    time_t t = time(NULL);
    struct tm tm; localtime_r(&t, &tm);
    char ts[64];
    strftime(ts, sizeof ts, "%Y%m%d-%H%M%S", &tm);
    snprintf(path, n, "%.400s/%.16s-%s.%.16s", out_dir, prefix, ts, ext);
}

static void snapshot_ppm(void)
{
    char path[512];
    stamp_name(path, sizeof path, "pctv-snap", "ppm");
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
        fprintf(stderr, "pctv-monitor: raw BT.656 recording stopped\n");
    } else {
        char path[512];
        stamp_name(path, sizeof path, "pctv-rec", "bt656");
        rec_file = fopen(path, "wb");
        if (!rec_file) { fprintf(stderr, "record: %s\n", strerror(errno)); return; }
        recording = 1;
        fprintf(stderr, "pctv-monitor: recording raw BT.656 -> %s\n", path);
    }
}

/* ================================================================= audio */

/* An audio input = an ALSA capture device plus, where the codec has one, the
 * position of its input selector ("Input Source") - on this box the ALC889A
 * offers Internal Mic / Mic / Line, the host-side equivalent of the vendor
 * driver's "Audio Tuner In" / "Audio Line In" crossbar pins. */
#define MAX_SRC 24
struct asrc {
    char dev[32];         /* "hw:0,0" - the PCM (capture) device */
    char mixdev[32];      /* "hw:0"  - the mixer lives on the card, not the device */
    char devlabel[64];    /* "ALC889A Analog" */
    char item[48];        /* selector item, e.g. "Line"; empty = no selector */
    int  sel_idx;         /* "Input Source"/"Capture" element index (-1 = none) */
    char label[160];      /* what the UI and -L show */
};
static struct asrc srcs[MAX_SRC];
static int nsrc = 0;
static int cur_src = 0;           /* 0 == "none" */

/* The mixer handle and its elements belong to the audio thread; the main
 * thread only posts requests and reads the meter state, all under amtx. */
static pthread_mutex_t amtx = PTHREAD_MUTEX_INITIALIZER;
static snd_mixer_t *mixer;
static snd_mixer_elem_t *el_cap, *el_boost;
static long cap_lo = 0, cap_hi = 0, cap_val = 0, boost_val = 0;
static long cap_db_lo = 0, cap_db_hi = 0;      /* Capture range in 0.01 dB units */
/* What the codec is actually at, as a percentage of each control's range
 * (boost as a 0..3 step).  Read back from the hardware by
 * audio_apply_controls() and remembered in the config file, so a relaunch
 * comes up at the staging that works on this wiring. */
static int cur_gain_pct = -1, cur_boost_step = -1;
static int cap_muted = 0;
static int pend_gain_pct = -1, pend_gain_step = 0, pend_boost_cycle = 0,
           pend_boost_step = -1, pend_mute_toggle = 0, pend_agc_toggle = 0,
           pend_manual = 0, pend_mon_toggle = 0;
/* Input monitoring: play back, on the host's output, exactly the samples the
 * capture would write, so the gain can be judged by ear before committing to a
 * recording.  Opened lazily (only while it is on) so the desktop's audio is not
 * held hostage the rest of the time. */
static int mon_on = 0;
static char mon_dev[64] = "";
/* Automatic gain control: on by default, toggled with `A' (shift+a) or
 * --agc/--no-agc, and remembered in the config file.  Any manual gain key
 * turns it off - the user's hand wins. */
static int agc_on = 1;

static pthread_t athr;
static int athr_started = 0;
static volatile int athr_stop = 0;
static volatile int athr_reopen = 0;

static int   audio_ok = 0;        /* PCM open and streaming */
static int   audio_rate = 48000;
static char  audio_err[160];
static double pk_db[2], rms_db[2], hold_db[2];
static unsigned clips = 0, xruns = 0;
static double gain_db = 0, boost_db = 0;

static double dbfs(double v) { return v <= 0.0 ? -99.0 : 20.0 * log10(v / 32768.0); }

static snd_mixer_elem_t *find_selem(snd_mixer_t *m, const char *name, unsigned idx)
{
    snd_mixer_selem_id_t *sid;
    snd_mixer_selem_id_alloca(&sid);
    snd_mixer_selem_id_set_index(sid, idx);
    snd_mixer_selem_id_set_name(sid, name);
    return snd_mixer_find_selem(m, sid);
}

/* Enumerate capture devices from /proc/asound/pcm and pair each analogue one
 * with the codec's input-selector elements in order.  Digital (IEC958/HDMI)
 * devices have no selector, and HDA drivers number "Input Source"/"Capture"
 * per ADC rather than per PCM device, so the analogue devices in
 * /proc/asound/pcm order map onto the selector indices in the same order. */
static int discover_audio(void)
{
    int devs[MAX_SRC][2];
    char names[MAX_SRC][64];
    int ndev = 0;

    srcs[0].dev[0] = 0; srcs[0].item[0] = 0; srcs[0].sel_idx = -1;
    snprintf(srcs[0].label, sizeof srcs[0].label, "none");
    nsrc = 1;

    FILE *f = fopen("/proc/asound/pcm", "r");
    if (!f) return nsrc;
    char line[256];
    while (fgets(line, sizeof line, f) && ndev < MAX_SRC) {
        int card = -1, dev = -1;
        char nm[64] = { 0 };
        if (sscanf(line, "%d-%d : %63[^:]", &card, &dev, nm) != 3) continue;
        if (!strstr(line, "capture")) continue;
        size_t nl = strlen(nm);
        while (nl && (nm[nl - 1] == ' ' || nm[nl - 1] == '\t')) nm[--nl] = 0;
        devs[ndev][0] = card; devs[ndev][1] = dev;
        snprintf(names[ndev], sizeof names[ndev], "%s", nm);
        ndev++;
    }
    fclose(f);

    for (int i = 0; i < ndev && nsrc < MAX_SRC; i++) {
        char hw[32], card[32];
        snprintf(hw, sizeof hw, "hw:%d,%d", devs[i][0], devs[i][1]);
        snprintf(card, sizeof card, "hw:%d", devs[i][0]);
        int digital = strstr(names[i], "Digital") || strstr(names[i], "IEC958") ||
                      strstr(names[i], "HDMI");

        /* how many input selectors does this card expose, and at which index? */
        int selidx[16], nsel = 0;
        snd_mixer_t *m = NULL;
        if (!digital && snd_mixer_open(&m, 0) == 0 && snd_mixer_attach(m, card) == 0) {
            snd_mixer_selem_register(m, NULL, NULL);
            if (snd_mixer_load(m) == 0)
                for (snd_mixer_elem_t *e = snd_mixer_first_elem(m); e;
                     e = snd_mixer_elem_next(e))
                    if (snd_mixer_selem_is_enum_capture(e) &&
                        !strcmp(snd_mixer_selem_get_name(e), "Input Source") &&
                        nsel < 16)
                        selidx[nsel++] = (int)snd_mixer_selem_get_index(e);
        }
        if (m) snd_mixer_close(m);

        int analog_rank = 0;
        for (int k = 0; k < i; k++)
            if (!(strstr(names[k], "Digital") || strstr(names[k], "IEC958") ||
                  strstr(names[k], "HDMI"))) analog_rank++;
        int mine = (!digital && analog_rank < nsel) ? selidx[analog_rank] : -1;

        if (mine < 0) {                    /* no selector: one entry per device */
            snprintf(srcs[nsrc].dev, sizeof srcs[nsrc].dev, "%.31s", hw);
            snprintf(srcs[nsrc].mixdev, sizeof srcs[nsrc].mixdev, "%.31s", card);
            snprintf(srcs[nsrc].devlabel, sizeof srcs[nsrc].devlabel, "%.63s", names[i]);
            srcs[nsrc].sel_idx = -1;
            snprintf(srcs[nsrc].label, sizeof srcs[nsrc].label, "%.63s (%.31s)", names[i], hw);
            nsrc++;
            continue;
        }

        if (snd_mixer_open(&m, 0) != 0 || snd_mixer_attach(m, card) != 0) continue;
        snd_mixer_selem_register(m, NULL, NULL);
        if (snd_mixer_load(m) != 0) { snd_mixer_close(m); continue; }
        snd_mixer_elem_t *e = find_selem(m, "Input Source", (unsigned)mine);
        if (e) {
            long nitem = snd_mixer_selem_get_enum_items(e);
            for (long k = 0; k < nitem && nsrc < MAX_SRC; k++) {
                char item[48];
                snd_mixer_selem_get_enum_item_name(e, (unsigned)k, sizeof item, item);
                snprintf(srcs[nsrc].dev, sizeof srcs[nsrc].dev, "%.31s", hw);
                snprintf(srcs[nsrc].mixdev, sizeof srcs[nsrc].mixdev, "%.31s", card);
                snprintf(srcs[nsrc].devlabel, sizeof srcs[nsrc].devlabel, "%.63s", names[i]);
                snprintf(srcs[nsrc].item, sizeof srcs[nsrc].item, "%.47s", item);
                srcs[nsrc].sel_idx = mine;
                snprintf(srcs[nsrc].label, sizeof srcs[nsrc].label, "%.47s (%.31s)", item, hw);
                nsrc++;
            }
        }
        snd_mixer_close(m);
    }
    return nsrc;
}

static int src_from_name(const char *s)
{
    if (!s) return -1;
    if (!strcasecmp(s, "none") || !strcasecmp(s, "off")) return 0;
    for (int i = 1; i < nsrc; i++)
        if (!strcasecmp(s, srcs[i].label) || !strcasecmp(s, srcs[i].item) ||
            !strcasecmp(s, srcs[i].dev)) return i;
    for (int i = 1; i < nsrc; i++)              /* substring match */
        if (strcasestr(srcs[i].label, s)) return i;
    return -1;
}

/* Re-read the codec state for the current source.  amtx must be held. */
static void audio_apply_controls(void)
{
    const struct asrc *s = &srcs[cur_src];
    el_cap = el_boost = NULL;
    gain_db = boost_db = 0;
    cap_lo = cap_hi = cap_val = 0;
    boost_val = 0;
    if (!mixer || s->sel_idx < 0) return;

    snd_mixer_elem_t *sel = find_selem(mixer, "Input Source", (unsigned)s->sel_idx);
    if (sel) {
        long nitem = snd_mixer_selem_get_enum_items(sel);
        for (long k = 0; k < nitem; k++) {
            char item[48];
            snd_mixer_selem_get_enum_item_name(sel, (unsigned)k, sizeof item, item);
            if (!strcmp(item, s->item)) {
                snd_mixer_selem_set_enum_item(sel, SND_MIXER_SCHN_MONO, (unsigned)k);
                break;
            }
        }
    }
    el_cap = find_selem(mixer, "Capture", (unsigned)s->sel_idx);
    if (el_cap) {
        snd_mixer_selem_get_capture_volume_range(el_cap, &cap_lo, &cap_hi);
        snd_mixer_selem_get_capture_volume(el_cap, SND_MIXER_SCHN_FRONT_LEFT, &cap_val);
        int sw = 1;
        if (snd_mixer_selem_has_capture_switch(el_cap))
            snd_mixer_selem_get_capture_switch(el_cap, SND_MIXER_SCHN_FRONT_LEFT, &sw);
        cap_muted = !sw;
        long lo, hi, d;
        cap_db_lo = cap_db_hi = 0;
        int have_db = 0;
        if (snd_mixer_selem_get_capture_dB_range(el_cap, &lo, &hi) >= 0) {
            cap_db_lo = lo; cap_db_hi = hi;
            if (snd_mixer_selem_get_capture_dB(el_cap, SND_MIXER_SCHN_FRONT_LEFT, &d) >= 0) {
                gain_db = d / 100.0;
                have_db = 1;
            }
        }
        if (!have_db && cap_hi > cap_lo)
            gain_db = (cap_val - cap_lo) * 0.75;   /* ALC889: 0.75 dB per step */
        cur_gain_pct = cap_hi > cap_lo
                     ? (int)((cap_val - cap_lo) * 100 / (cap_hi - cap_lo)) : -1;
    }
    char bn[64];
    snprintf(bn, sizeof bn, "%s Boost", s->item);
    el_boost = find_selem(mixer, bn, 0);
    if (el_boost) {
        snd_mixer_selem_get_capture_volume(el_boost, SND_MIXER_SCHN_FRONT_LEFT, &boost_val);
        long lo, hi, d;
        if (snd_mixer_selem_get_capture_volume_range(el_boost, &lo, &hi) >= 0 && hi > lo)
            cur_boost_step = (int)(((boost_val - lo) * 3 + (hi - lo) / 2) / (hi - lo));
        if (snd_mixer_selem_get_capture_dB_range(el_boost, &lo, &hi) >= 0 &&
            snd_mixer_selem_get_capture_dB(el_boost, SND_MIXER_SCHN_FRONT_LEFT, &d) >= 0)
            boost_db = d / 100.0;
    }
}

/* Automatic gain control.  Drives the codec's Capture volume - and, when that
 * runs out of headroom or bottoms out, the coarser input boost - so the
 * program's peaks sit in the metered -12..-3 dBFS zone.  The gain is applied
 * in the hardware, never as a software multiply, so the meter and the recorded
 * file always agree.  Called from the audio thread with amtx held; it consumes
 * the peak of the window it is handed.  The source level on this wiring moved
 * by ~20 dB between two captures an hour apart, which is the whole argument
 * for having this. */
static double agc_win_pk = -99.0;

/* Where the AGC tries to keep the peaks.  -18 dBFS, not the top of the meter's
 * -12..-3 zone: this source has been measured swinging ~20 dB by itself inside
 * a second, and a feedback loop (no lookahead) can only follow, not predict -
 * the headroom is what keeps those steps out of the ADC.  A capture at -18 dBFS
 * peaks still has 6 dB of clean room for ffmpeg/volume normalisation later. */
#define AGC_TARGET_DBFS (-18.0)

static void agc_tick(double win_pk, unsigned long long clips_now)
{
    static unsigned long long last_clips;
    static unsigned long last_move, last_eval;
    unsigned long t = SDL_GetTicks();
    double pk = agc_win_pk > win_pk ? agc_win_pk : win_pk;
    agc_win_pk = -99.0;

    if (!el_cap || cap_hi <= cap_lo) { last_clips = clips_now; return; }
    double spdb = (cap_db_hi > cap_db_lo)
        ? (double)(cap_hi - cap_lo) / ((double)(cap_db_hi - cap_db_lo) / 100.0)
        : 1.0;

    long clip_delta = (long)(clips_now - last_clips);
    last_clips = clips_now;

    /* Two loops: a violent attack (8 dB, up to ~16 times a second) for anything
     * near or over full scale, and a gentle proportional steady state.  The
     * source has been measured moving 30 dB by itself inside a minute, so the
     * target sits well under the meter's -12..-3 manual zone - headroom is what
     * keeps its steps out of the ADC. */
    double want;
    if (clip_delta > 0 || pk > -3.0) {
        /* Attack: either the ADC is already over, or this block came in within
         * 3 dB of it.  Waiting for actual clipping is 3 dB too late - the
         * source has been measured stepping up ~20 dB in a second, and at
         * 8 dB per 60 ms the loop needs ~150 ms to catch a step, which is
         * exactly the window in which it clips. */
        if (t - last_move < 60) return;
        want = -8.0;
    } else {
        if (t - last_eval < 250) return;
        static double prev_pk = -99.0;
        double rise = pk - prev_pk;
        prev_pk = pk;
        if (pk <= -75.0) want = 0.0;             /* at/below the codec's own noise:
                                                 * do not hunt a dead input */
        else if (rise > 10.0 && pk > -25.0) {
            want = -6.0;                         /* the source just stepped up by
                                                  * more than the loop could have
                                                  * caused: get under it before it
                                                  * reaches the ADC ceiling */
        } else {
            /* Proportional to the distance from the target, so a source that
             * arrives 35 dB down converges in a couple of seconds instead of a
             * minute.  The big steps are only taken while there is real room to
             * spare: within 30 dB of the target the approach is gentle, because
             * raising gain fast is how you clip the next transient. */
            double deficit = AGC_TARGET_DBFS - pk;  /* +ve = need more gain */
            if (deficit > 5.0)      want = (pk < -30.0) ? +6.0 : +2.0;
            else if (deficit > 1.0) want = +2.0;
            else if (deficit > -3.0) want = 0.0;  /* dead band: no pumping */
            else if (deficit > -8.0) want = -2.0;
            else                    want = -6.0;
        }
    }
    last_eval = t;

    /* Staging: the Capture volume is a much quieter gain stage than the input
     * boost, so once the fine control has drifted to the bottom of its range,
     * trade a boost step for headroom in it.  The two limits are far apart
     * (this fires below 20 % of the range, boost-up only when the fine control
     * wants to exceed its top), so it cannot oscillate. */
    if (want >= 0.0 && el_boost && cap_val < cap_lo + (cap_hi - cap_lo) / 5) {
        long blo, bhi;
        snd_mixer_selem_get_capture_volume_range(el_boost, &blo, &bhi);
        if (boost_val > blo) {
            snd_mixer_selem_set_capture_volume_all(el_boost, boost_val - 1);
            snd_mixer_selem_set_capture_volume_all(el_cap,
                                                   cap_lo + (cap_hi - cap_lo) * 60 / 100);
            audio_apply_controls();
            last_move = t;
            fprintf(stderr, "pctv-monitor: AGC: staging, boost down -> capture %+.1f dB\n",
                    gain_db);
            return;
        }
    }
    if (want == 0.0) return;
    last_move = t;

    long v = cap_val + lround(want * spdb);

    if (v > cap_hi && el_boost) {                 /* out of headroom: boost up */
        long blo, bhi;
        snd_mixer_selem_get_capture_volume_range(el_boost, &blo, &bhi);
        if (boost_val < bhi) {
            snd_mixer_selem_set_capture_volume_all(el_boost, boost_val + 1);
            v = cap_lo + (cap_hi - cap_lo) * 40 / 100;
            fprintf(stderr, "pctv-monitor: AGC: peak %.1f dBFS, boost step up\n", pk);
        } else v = cap_hi;
    } else if (v < cap_lo && el_boost) {          /* bottomed out: boost down */
        long blo, bhi;
        snd_mixer_selem_get_capture_volume_range(el_boost, &blo, &bhi);
        if (boost_val > blo) {
            snd_mixer_selem_set_capture_volume_all(el_boost, boost_val - 1);
            v = cap_lo + (cap_hi - cap_lo) * 60 / 100;
            fprintf(stderr, "pctv-monitor: AGC: peak %.1f dBFS, boost step down\n", pk);
        } else v = cap_lo;
    }
    if (v == cap_val) return;
    snd_mixer_selem_set_capture_volume_all(el_cap, v);
    snd_mixer_selem_set_capture_switch_all(el_cap, 1);
    audio_apply_controls();
    fprintf(stderr, "pctv-monitor: AGC: peak %.1f dBFS -> capture %+.1f dB\n",
            pk, gain_db);
}

/* Open the host's playback stream for input monitoring.  Tries the desktop's
 * default route first (so it co-exists with PipeWire) and then the capture
 * card's own playback stream.  Returns NULL with a reason in err. */
static snd_pcm_t *mon_open(char *err, size_t n)
{
    char hwdev[64];
    snprintf(hwdev, sizeof hwdev, "%s", srcs[cur_src].dev);
    /* Sound server first: it follows whatever the desktop is routed to
     * (speakers, headphones, Bluetooth) and coexists with everything else.  The
     * card profile that makes "default" a real sink is pinned declaratively by
     * live-module.nix; with it off, "default" is a Dummy Output, which is why
     * this order used to be hw-first.  Raw hardware stays as the fallback for a
     * machine with no sound server at all. */
    const char *cands[3] = { "default", hwdev, NULL };
    snd_pcm_t *m = NULL;
    err[0] = 0;
    for (int q = 0; q < 2 && !m; q++) {
        int e = snd_pcm_open(&m, cands[q], SND_PCM_STREAM_PLAYBACK, 0);
        if (e < 0) { snprintf(err, n, "%s: %s", cands[q], snd_strerror(e)); m = NULL; continue; }
        int rates[] = { audio_rate, 48000, 44100 };
        int ok = 0;
        for (unsigned w = 0; w < sizeof rates / sizeof rates[0]; w++) {
            e = snd_pcm_set_params(m, SND_PCM_FORMAT_S16_LE,
                                   SND_PCM_ACCESS_RW_INTERLEAVED, 2, rates[w],
                                   1 /* allow resample */, 60000 /* latency us */);
            if (e >= 0) { ok = 1; snprintf(mon_dev, sizeof mon_dev, "%s", cands[q]); break; }
        }
        if (!ok) {
            snprintf(err, n, "%s: params: %s", cands[q], snd_strerror(e));
            snd_pcm_close(m); m = NULL;
        }
    }
    return m;
}

/* Open the PCM for the current source; returns 0 on success. */
/* Which PCM route the capture stream actually got ("default" = the desktop
 * sound server's ALSA plugin, "hw:x,y" = raw).  Shown in the panel and logged,
 * because "which audio path am I on" must never be a guess. */
static char audio_route[64] = "";

/* Streams go through the desktop sound server when there is one: on this system
 * ALSA's "default" is PipeWire's plugin, so capture and monitoring coexist with
 * everything else instead of taking the hardware exclusively - which is what
 * made the raw-hw path unreliable in both directions (EBUSY when the daemon had
 * a duplex profile, a Dummy sink when it had none).  The codec *controls* stay
 * on the card's control device (controlC0): it is multi-client, and it is the
 * only way to reach `Input Source` and the `* Boost` elements, which the AGC
 * needs and the sound server does not expose. */
static int audio_open_pcm(snd_pcm_t **pcm, char *err, size_t n)
{
    const struct asrc *s = &srcs[cur_src];
    *pcm = NULL;
    audio_route[0] = 0;
    if (cur_src == 0) { snprintf(err, n, "no input selected"); return -1; }

    const char *forced = getenv("PCTV_ALSA_DEV");
    const char *cands[3]; int nc = 0;
    if (forced && *forced) cands[nc++] = forced;
    else { cands[nc++] = "default"; cands[nc++] = s->dev; }   /* server, then raw */

    /* Every candidate is tried completely - open AND hw params.  The sound
     * server's ALSA plugin opens happily even when the card profile has no
     * input and only fails at set_params ("Unable to install hw params"), so
     * stopping at the first open failure is what made audio disappear with no
     * way back.  Raw hw is the fallback for exactly that case: when the daemon
     * has no source it is also not holding the stream. */
    int rates[] = { 48000, 44100, 32000 };
    int e = -1, ep = -1;
    char last[128] = "";
    for (int q = 0; q < nc; q++) {
        e = snd_pcm_open(pcm, cands[q], SND_PCM_STREAM_CAPTURE, 0);
        if (e < 0) {
            snprintf(last, sizeof last, "%s: %s", cands[q], snd_strerror(e));
            continue;
        }
        for (unsigned r = 0; r < sizeof rates / sizeof rates[0]; r++) {
            ep = snd_pcm_set_params(*pcm, SND_PCM_FORMAT_S16_LE,
                                    SND_PCM_ACCESS_RW_INTERLEAVED, 2, rates[r],
                                    1 /* allow format/rate change */, 20000);
            if (ep >= 0) { audio_rate = rates[r]; break; }
        }
        if (ep >= 0) {
            snprintf(audio_route, sizeof audio_route, "%s", cands[q]);
            e = 0;
            break;
        }
        snprintf(last, sizeof last, "%s: params: %s", cands[q], snd_strerror(ep));
        snd_pcm_close(*pcm);
        *pcm = NULL;
    }
    if (e < 0) {
        if (e == -EBUSY)
            snprintf(err, n, "%s busy - the audio daemon holds it; use an "
                             "output-only profile (wpctl set-profile)", s->dev);
        else
            snprintf(err, n, "%s", last);
        audio_route[0] = 0;
        return e;
    }
    return 0;
}

static void *audio_thread(void *arg)
{
    (void)arg;
static snd_pcm_t *pcm = NULL;
    snd_pcm_t *mon = NULL;
    short buf[1024 * 2];

    for (;;) {
        if (athr_stop) break;

        if (athr_reopen || !pcm) {
            athr_reopen = 0;
            if (pcm) { snd_pcm_close(pcm); pcm = NULL; }
            pthread_mutex_lock(&amtx);
            if (mixer) { snd_mixer_close(mixer); mixer = NULL; }
            audio_ok = 0;
            el_cap = el_boost = NULL;
            pk_db[0] = pk_db[1] = rms_db[0] = rms_db[1] = -99.0;
            hold_db[0] = hold_db[1] = -99.0;
            clips = 0; xruns = 0;
            pthread_mutex_unlock(&amtx);
            if (cur_src == 0) { usleep(200000); continue; }

            snd_mixer_t *m = NULL;
            if (snd_mixer_open(&m, 0) == 0 &&
                snd_mixer_attach(m, srcs[cur_src].mixdev) == 0 &&
                snd_mixer_selem_register(m, NULL, NULL) == 0 &&
                snd_mixer_load(m) == 0) {
                pthread_mutex_lock(&amtx);
                mixer = m;
                audio_apply_controls();
                pthread_mutex_unlock(&amtx);
            } else if (m) snd_mixer_close(m);

            char err[160] = "";
            int ok = audio_open_pcm(&pcm, err, sizeof err) == 0;
            /* The monitor follows the input: if it was on, re-open it against the
             * new rate/device so the pitch stays right. */
            if (mon_on && !mon) {
                char merr[160] = "";
                mon = mon_open(merr, sizeof merr);
                if (!mon) { mon_on = 0; fprintf(stderr, "pctv-monitor: input monitor lost: %s\n", merr); }
            }
            pthread_mutex_lock(&amtx);
            snprintf(audio_err, sizeof audio_err, "%s", err);
            if (ok) {
                audio_ok = 1;
                fprintf(stderr, "pctv-monitor: audio %s via %s (%d Hz)\n",
                        srcs[cur_src].label, audio_route[0] ? audio_route : "?", audio_rate);
            } else fprintf(stderr, "pctv-monitor: audio: %s\n", err);   /* once per retry */
            pthread_mutex_unlock(&amtx);
            if (!ok) { usleep(500000); continue; }
        }

        /* apply gain / boost / mute requests posted by the UI thread */
        pthread_mutex_lock(&amtx);
        if (pend_agc_toggle) {
            agc_on = !agc_on;
            agc_win_pk = -99.0;
            fprintf(stderr, "pctv-monitor: automatic gain control %s\n",
                    agc_on ? "on" : "off");
            pend_agc_toggle = 0;
        }
        if (pend_manual && agc_on) {
            agc_on = 0;
            fprintf(stderr, "pctv-monitor: AGC off (manual gain)\n");
        }
        pend_manual = 0;
        if (pend_gain_pct >= 0 && el_cap) {
            long v = cap_lo + (cap_hi - cap_lo) * pend_gain_pct / 100;
            snd_mixer_selem_set_capture_volume_all(el_cap, v);
            snd_mixer_selem_set_capture_switch_all(el_cap, 1);
            fprintf(stderr, "pctv-monitor: capture gain set to %d%% of range\n",
                    pend_gain_pct);
            pend_gain_pct = -1;
            audio_apply_controls();
        }
        if (pend_gain_step && el_cap) {
            long span = cap_hi - cap_lo, step = span / 20;
            if (step < 1) step = 1;
            long v = cap_val + pend_gain_step * step;
            if (v < cap_lo) v = cap_lo;
            if (v > cap_hi) v = cap_hi;
            snd_mixer_selem_set_capture_volume_all(el_cap, v);
            snd_mixer_selem_set_capture_switch_all(el_cap, 1);
            fprintf(stderr, "pctv-monitor: capture gain %.1f dB\n", gain_db);
            pend_gain_step = 0;
            audio_apply_controls();
        }
        if (pend_boost_step >= 0 && el_boost) {
            long lo, hi;
            snd_mixer_selem_get_capture_volume_range(el_boost, &lo, &hi);
            long v = lo + (hi - lo) * pend_boost_step / 3;
            snd_mixer_selem_set_capture_volume_all(el_boost, v);
            fprintf(stderr, "pctv-monitor: input boost step %d\n", pend_boost_step);
            pend_boost_step = -1;
            audio_apply_controls();
        }
        if (pend_boost_cycle && el_boost) {
            long lo, hi;
            snd_mixer_selem_get_capture_volume_range(el_boost, &lo, &hi);
            long v = boost_val + 1;
            if (v > hi) v = lo;
            snd_mixer_selem_set_capture_volume_all(el_boost, v);
            fprintf(stderr, "pctv-monitor: input boost cycled\n");
            pend_boost_cycle = 0;
            audio_apply_controls();
        }
        if (pend_mute_toggle && el_cap && snd_mixer_selem_has_capture_switch(el_cap)) {
            cap_muted = !cap_muted;
            snd_mixer_selem_set_capture_switch_all(el_cap, cap_muted ? 0 : 1);
            fprintf(stderr, "pctv-monitor: capture %s\n", cap_muted ? "muted" : "unmuted");
            pend_mute_toggle = 0;
            audio_apply_controls();
        }
        /* Input monitoring: open (or release) the host's playback stream.  It is
         * opened on demand and never held otherwise, so PipeWire/the desktop can
         * use the output when we are not listening. */
        if (pend_mon_toggle) {
            pend_mon_toggle = 0;
            if (mon) {
                snd_pcm_drain(mon); snd_pcm_close(mon); mon = NULL; mon_dev[0] = 0;
                mon_on = 0;
                fprintf(stderr, "pctv-monitor: input monitor off\n");
            } else {
                char merr[160] = "";
                mon = mon_open(merr, sizeof merr);
                if (!mon) {
                    mon_on = 0;
                    /* amtx is already held here (this whole control block runs
                     * under it) - locking it again would deadlock. */
                    snprintf(audio_err, sizeof audio_err, "monitor %s", merr);
                    fprintf(stderr, "pctv-monitor: input monitor failed: %s\n", merr);
                } else {
                    mon_on = 1;
                    /* Make sure the output is actually audible: PipeWire leaves
                     * the codec's Master wherever the desktop put it, and a
                     * muted or near-silent Master makes the test look like a
                     * dead input.  Only ever raise it, never turn it up past a
                     * moderate level. */
                    if (mixer) {
                        snd_mixer_elem_t *ms = find_selem(mixer, "Master", 0);
                        if (ms) {
                            long lo, hi, v;
                            int sw = 1;
                            if (snd_mixer_selem_has_playback_switch(ms) &&
                                snd_mixer_selem_get_playback_switch(ms, SND_MIXER_SCHN_MONO, &sw) >= 0 &&
                                !sw)
                                snd_mixer_selem_set_playback_switch_all(ms, 1);
                            if (snd_mixer_selem_get_playback_dB_range(ms, &lo, &hi) >= 0 &&
                                snd_mixer_selem_get_playback_dB(ms, SND_MIXER_SCHN_MONO, &v) >= 0) {
                                long want = lo + (hi - lo) * 70 / 100;   /* mid-high, not full */
                                if (v < lo + (hi - lo) * 30 / 100) {
                                    snd_mixer_selem_set_playback_dB_all(ms, want, 0);
                                    fprintf(stderr, "pctv-monitor: monitor raised Master to "
                                                    "%.1f dB (was %.1f)\n", want / 100.0, v / 100.0);
                                } else
                                    fprintf(stderr, "pctv-monitor: monitor: Master %.1f dB\n", v / 100.0);
                            }
                        }
                    }
                    fprintf(stderr, "pctv-monitor: input monitor on -> %s (the exact "
                                    "samples the capture writes)\n", mon_dev);
                }
            }
        }
        pthread_mutex_unlock(&amtx);

        int r = snd_pcm_readi(pcm, buf, 1024);
        if (r == -EPIPE) {                          /* overrun */
            snd_pcm_recover(pcm, r, 1);
            pthread_mutex_lock(&amtx); xruns++; audio_ok = 1;
            pthread_mutex_unlock(&amtx);
            continue;
        }
        if (r == -EINTR || r == -ERESTART) continue;
        if (r < 0) {                                /* device went away / busy */
            pthread_mutex_lock(&amtx);
            audio_ok = 0;
            snprintf(audio_err, sizeof audio_err, "read: %s", snd_strerror(r));
            pthread_mutex_unlock(&amtx);
            snd_pcm_close(pcm); pcm = NULL;
            usleep(500000);
            continue;
        }

        double p0 = 0, p1 = 0, s0 = 0, s1 = 0;
        unsigned cl = 0;
        for (int i = 0; i < r; i++) {
            double a = buf[2 * i], b = buf[2 * i + 1];
            if (fabs(a) > p0) p0 = fabs(a);
            if (fabs(b) > p1) p1 = fabs(b);
            s0 += a * a; s1 += b * b;
            if (buf[2 * i] >= 32760 || buf[2 * i] <= -32760 ||
                buf[2 * i + 1] >= 32760 || buf[2 * i + 1] <= -32760) cl++;
        }
        pthread_mutex_lock(&amtx);
        pk_db[0] = dbfs(p0); pk_db[1] = dbfs(p1);
        rms_db[0] = dbfs(sqrt(s0 / r)); rms_db[1] = dbfs(sqrt(s1 / r));
        if (cl) clips += cl;
        /* AGC: accumulate the peak of the current window and let the controller
         * act twice a second; it consumes the window when it does. */
        double wpk = pk_db[0] > pk_db[1] ? pk_db[0] : pk_db[1];
        if (wpk > agc_win_pk) agc_win_pk = wpk;
        if (agc_on && !cap_muted) agc_tick(agc_win_pk, clips);
        else agc_win_pk = -99.0;
        pthread_mutex_unlock(&amtx);

        /* Input monitoring: the same buffer, unaltered, that cap_feed_audio()
         * hands to the muxer - so what you hear is what the file gets. */
        if (mon) {
            int w = snd_pcm_writei(mon, buf, r);
            if (w == -EPIPE) snd_pcm_recover(mon, w, 1);
            else if (w == -EINTR || w == -ERESTART) { /* retry next round */ }
            else if (w < 0) {
                snd_pcm_close(mon); mon = NULL; mon_dev[0] = 0; mon_on = 0;
                fprintf(stderr, "pctv-monitor: input monitor closed (%s)\n", snd_strerror(-w));
            }
        }

        cap_feed_audio(buf, (size_t)r * 2 * sizeof(short));
    }
    if (pcm) snd_pcm_close(pcm);
    if (mon) { snd_pcm_drain(mon); snd_pcm_close(mon); mon = NULL; }
    pthread_mutex_lock(&amtx);
    if (mixer) { snd_mixer_close(mixer); mixer = NULL; }
    audio_ok = 0;
    pthread_mutex_unlock(&amtx);
    return NULL;
}

static void audio_start_thread(void)
{
    if (!athr_started) { pthread_create(&athr, NULL, audio_thread, NULL); athr_started = 1; }
    else athr_reopen = 1;
}

/* =========================================================== MPEG-2 capture
 *
 * A PAL-DVD-style MPEG-2 program stream: deframed UYVY goes to ffmpeg's stdin
 * as rawvideo, the ALSA PCM to fd 3 as s16le, and ffmpeg muxes mpeg2video +
 * MP2 into a .mpg.  Both pipes are poll()ed before writing so a stalled
 * encoder can never wedge the GUI; a frame that cannot be handed over is
 * dropped and counted rather than half-written (which would desync rawvideo).
 */

static char ffmpeg_path[4096] = "ffmpeg";
static pid_t cap_pid = -1;
static int   cap_vfd = -1, cap_afd = -1;
static int   cap_on = 0, cap_has_audio = 0;
static char  cap_path[512];
static unsigned long long cap_vframes = 0, cap_vdrops = 0, cap_adrops = 0;
static unsigned long long cap_abytes = 0;
static time_t cap_t0 = 0;
static unsigned long cap_t0_tick = 0;   /* SDL ticks, for a smooth REC counter */
static int cap_pending = 0;      /* `c' pressed, waiting for the first frame */
static pthread_mutex_t cap_mtx = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t cap_cv = PTHREAD_COND_INITIALIZER;
static int cap_refs = 0, cap_closing = 0;

/* Take the capture fds for one write.  The lock is NOT held during the write
 * itself: a stalled encoder must never be able to block whoever holds it -
 * that would stall the main loop, which is what drains the probe's stdout. */
static int cap_get(int *vfd, int *afd)
{
    pthread_mutex_lock(&cap_mtx);
    while (cap_closing) pthread_cond_wait(&cap_cv, &cap_mtx);
    if (!cap_on) { pthread_mutex_unlock(&cap_mtx); return -1; }
    *vfd = cap_vfd; *afd = cap_afd;
    cap_refs++;
    pthread_mutex_unlock(&cap_mtx);
    return 0;
}

static void cap_put(void)
{
    pthread_mutex_lock(&cap_mtx);
    if (--cap_refs == 0) pthread_cond_broadcast(&cap_cv);
    pthread_mutex_unlock(&cap_mtx);
}

static void cap_died(void)
{
    pthread_mutex_lock(&cap_mtx);
    int was = cap_on;
    cap_on = 0;                    /* feeds stop; cap_stop() reaps the child */
    pthread_mutex_unlock(&cap_mtx);
    if (was) fprintf(stderr, "pctv-monitor: encoder went away, capture stopped\n");
}

/* Write a whole buffer, having first waited for the pipe to drain.  Returns 0
 * on success, -1 if it was dropped or the encoder died. */
static int pipe_write(int fd, const void *p, size_t n, int msecs)
{
    if (fd < 0) return -1;
    struct pollfd pf = { .fd = fd, .events = POLLOUT };
    if (poll(&pf, 1, msecs) <= 0) return -1;
    const unsigned char *b = p;
    while (n) {
        ssize_t w = write(fd, b, n);
        if (w > 0) { b += w; n -= (size_t)w; continue; }
        if (w < 0 && errno == EINTR) continue;
        return -1;
    }
    return 0;
}

/* Audio: never block.  s16le is self-synchronising on 2-byte boundaries, so a
 * partial write only loses samples - and losing samples is far better than
 * holding up the video path. */
static void cap_feed_audio(const void *p, size_t n)
{
    int vfd, afd;
    if (cap_get(&vfd, &afd) < 0) return;
    if (afd >= 0) {
        const unsigned char *b = p;
        size_t left = n & ~(size_t)1;
        while (left) {
            ssize_t w = write(afd, b, left);
            if (w > 0) { b += w; left -= (size_t)w; continue; }
            if (w < 0 && errno == EINTR) continue;
            pthread_mutex_lock(&cap_mtx);
            cap_adrops++;
            pthread_mutex_unlock(&cap_mtx);
            if (w < 0 && errno != EAGAIN && errno != EWOULDBLOCK) cap_died();
            break;
        }
        pthread_mutex_lock(&cap_mtx);
        cap_abytes += n - left;
        pthread_mutex_unlock(&cap_mtx);
    }
    cap_put();
}

/* ---- video feed: queue + writer thread ---------------------------------
 * A 720x576 UYVY frame is 829 KB and ffmpeg's stdin is a pipe.  Feeding it
 * inline meant the main loop blocked in write() whenever the encoder (or the
 * disk under it) stalled - and while the main loop is blocked it is not
 * draining the probe either, so the whole pipeline hiccups: that is the
 * "picture freezes for up to a second every 10-20 s while recording" bug.
 * Frames now go into a small ring and a dedicated thread does the blocking
 * writes.  The display never waits for the encoder.  If the ring is full the
 * newest frame is dropped whole and counted, which keeps rawvideo framing
 * intact (a partial frame would desynchronise the decoder). */
#define VQ_SLOTS 4
static unsigned char *vq[VQ_SLOTS];
static int vq_head, vq_count, vq_stop, vq_started;
static pthread_t vq_thr;
static pthread_mutex_t vq_mtx = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t  vq_cv = PTHREAD_COND_INITIALIZER;

static void cap_feed_video(void)
{
    /* The ring only exists while a capture owns it: vq[] is allocated by
     * vq_start(), which cap_start() calls.  The main loop feeds every frame it
     * assembles, capture or no capture, so without this guard the first locked
     * frame after launch memcpy()s 829 KB into a NULL slot - SIGSEGV seconds
     * after opening the monitor with no `c' pressed.  vq_started is only
     * mutated by the main thread (vq_start/cap_stop), which is also the only
     * caller here, so reading it unlocked is safe. */
    if (!vq_started) return;
    pthread_mutex_lock(&vq_mtx);
    int tail = (vq_head + vq_count) % VQ_SLOTS;
    if (vq_count >= VQ_SLOTS || !vq[tail]) {
        pthread_mutex_unlock(&vq_mtx);
        pthread_mutex_lock(&cap_mtx);
        cap_vdrops++;
        pthread_mutex_unlock(&cap_mtx);
        return;
    }
    memcpy(vq[tail], fuv, UV_SIZE);
    vq_count++;
    pthread_cond_signal(&vq_cv);
    pthread_mutex_unlock(&vq_mtx);
}

static void *vq_thread(void *unused)
{
    for (;;) {
        pthread_mutex_lock(&vq_mtx);
        while (!vq_count && !vq_stop) pthread_cond_wait(&vq_cv, &vq_mtx);
        if (vq_stop && !vq_count) { pthread_mutex_unlock(&vq_mtx); break; }
        int slot = vq_head;
        vq_head = (vq_head + 1) % VQ_SLOTS;
        vq_count--;
        pthread_mutex_unlock(&vq_mtx);

        int vfd, afd;
        if (cap_get(&vfd, &afd) < 0 || vfd < 0) continue;    /* capture ended */
        if (pipe_write(vfd, vq[slot], UV_SIZE, 3000) == 0) {
            pthread_mutex_lock(&cap_mtx); cap_vframes++;
            pthread_mutex_unlock(&cap_mtx);
        } else {
            pthread_mutex_lock(&cap_mtx); cap_vdrops++;
            pthread_mutex_unlock(&cap_mtx);
            cap_died();
        }
        cap_put();
    }
    return NULL;
}

/* Returns 0 when the ring is live (slots allocated, writer thread running),
 * -1 if it could not be - capture must then not start, because every feed
 * would have nowhere to put a frame. */
static int vq_start(void)
{
    for (int i = 0; i < VQ_SLOTS; i++)
        if (!vq[i]) vq[i] = malloc(UV_SIZE);
    for (int i = 0; i < VQ_SLOTS; i++)
        if (!vq[i]) return -1;
    vq_head = vq_count = vq_stop = 0;
    if (!vq_started) {
        if (pthread_create(&vq_thr, NULL, vq_thread, NULL) != 0) return -1;
        vq_started = 1;
    }
    return 0;
}

static void vq_stop_and_drain(void)
{
    if (!vq_started) return;
    pthread_mutex_lock(&vq_mtx);
    vq_stop = 1;
    pthread_cond_broadcast(&vq_cv);
    pthread_mutex_unlock(&vq_mtx);
    pthread_join(vq_thr, NULL);
    vq_started = 0;
}


static int cap_start(void)
{
    if (vq_start() < 0) {          /* the writer thread that owns the video pipe */
        fprintf(stderr, "pctv-monitor: cannot start the frame ring "
                        "(out of memory?) - not capturing\n");
        return -1;
    }
    int vp[2], ap[2];
    if (pipe(vp) < 0) return -1;
    if (pipe(ap) < 0) { close(vp[0]); close(vp[1]); return -1; }
    fcntl(vp[1], F_SETPIPE_SZ, 4 << 20);
    fcntl(ap[1], F_SETPIPE_SZ, 1 << 20);
    {   /* the audio write end is non-blocking: drop rather than stall video */
        int fl = fcntl(ap[1], F_GETFL, 0);
        fcntl(ap[1], F_SETFL, fl | O_NONBLOCK);
    }
    /* Only mux audio if the capture stream is actually up.  The audio thread
     * opens the PCM asynchronously, so give it a moment rather than silently
     * producing a video-only file. */
    if (cur_src != 0) {
        for (int wait = 0; wait < 40; wait++) {
            pthread_mutex_lock(&amtx);
            int up = audio_ok;
            pthread_mutex_unlock(&amtx);
            if (up) break;
            usleep(50000);
        }
    }
    pthread_mutex_lock(&amtx);
    cap_has_audio = audio_ok;
    pthread_mutex_unlock(&amtx);

    stamp_name(cap_path, sizeof cap_path, "pctv-cap", "mpg");

    char vsize[32], br[32], ar[32];
    snprintf(vsize, sizeof vsize, "%dx%d", W, H);
    snprintf(br, sizeof br, "%dk", mpeg2_kbps);
    snprintf(ar, sizeof ar, "%d", audio_rate);

    char *av[48]; int n = 0;
    av[n++] = ffmpeg_path;
    av[n++] = "-y";
    av[n++] = "-loglevel"; av[n++] = "error";
    av[n++] = "-f"; av[n++] = "rawvideo";
    av[n++] = "-pix_fmt"; av[n++] = "uyvy422";
    av[n++] = "-s"; av[n++] = vsize;
    av[n++] = "-r"; av[n++] = "25";
    av[n++] = "-i"; av[n++] = "pipe:0";
    if (cap_has_audio) {
        av[n++] = "-f"; av[n++] = "s16le"; av[n++] = "-ar"; av[n++] = ar;
        av[n++] = "-ac"; av[n++] = "2"; av[n++] = "-i"; av[n++] = "pipe:3";
    }
    av[n++] = "-c:v"; av[n++] = "mpeg2video";
    av[n++] = "-b:v"; av[n++] = br;
    av[n++] = "-maxrate"; av[n++] = br;
    av[n++] = "-bufsize"; av[n++] = "1835008";
    av[n++] = "-g"; av[n++] = "15";
    av[n++] = "-flags"; av[n++] = "+ilme+ildct";
    av[n++] = "-field_order"; av[n++] = "tt";
    av[n++] = "-aspect"; av[n++] = "4:3";
    if (cap_has_audio) { av[n++] = "-c:a"; av[n++] = "mp2"; av[n++] = "-b:a"; av[n++] = "192k"; }
    else av[n++] = "-an";
    av[n++] = "-sn";
    av[n++] = "-f"; av[n++] = "mpeg";
    av[n++] = cap_path;
    av[n] = NULL;

    pid_t pid = fork();
    if (pid < 0) { close(vp[0]); close(vp[1]); close(ap[0]); close(ap[1]); return -1; }
    if (pid == 0) {
        dup2(vp[0], STDIN_FILENO);          /* ffmpeg reads the video pipe */
        if (cap_has_audio) dup2(ap[0], 3);  /* ...and the audio pipe on fd 3 */
        close(vp[0]); close(vp[1]); close(ap[0]); close(ap[1]);
        execvp(ffmpeg_path, av);
        fprintf(stderr, "pctv-monitor: exec %s failed: %s\n", ffmpeg_path, strerror(errno));
        _exit(127);
    }
    /* the parent keeps the write ends and drops the read ends, so ffmpeg sees
     * EOF the moment we close them */
    close(vp[0]); close(ap[0]);
    pthread_mutex_lock(&cap_mtx);
    cap_pid = pid; cap_vfd = vp[1]; cap_afd = ap[1]; cap_on = 1;
    cap_vframes = cap_vdrops = cap_adrops = cap_abytes = 0;
    cap_t0 = time(NULL);
    cap_t0_tick = SDL_GetTicks();
    pthread_mutex_unlock(&cap_mtx);
    fprintf(stderr, "pctv-monitor: MPEG-2 capture -> %s (audio %s, %d kbps, pid %d)\n",
            cap_path, cap_has_audio ? srcs[cur_src].label : "OFF", mpeg2_kbps, pid);
    return 0;
}

static void cap_stop(void)
{
    vq_stop_and_drain();          /* flush the frame ring to ffmpeg, then reap it */
    pthread_mutex_lock(&cap_mtx);
    if (!cap_on && cap_pid < 0) { pthread_mutex_unlock(&cap_mtx); return; }
    cap_closing = 1;
    while (cap_refs) pthread_cond_wait(&cap_cv, &cap_mtx);   /* let feeds finish */
    int vfd = cap_vfd, afd = cap_afd;
    pid_t pid = cap_pid;
    cap_on = 0; cap_vfd = cap_afd = -1; cap_pid = -1;
    unsigned long long vf = cap_vframes, vd = cap_vdrops, ad = cap_adrops;
    unsigned long long ab = cap_abytes;
    cap_closing = 0;
    pthread_cond_broadcast(&cap_cv);
    pthread_mutex_unlock(&cap_mtx);

    if (vfd >= 0) close(vfd);                  /* EOF -> ffmpeg finalises the PS */
    if (afd >= 0) close(afd);
    if (pid > 0) {
        int st = 0, waited = 0;
        while (waited < 10000) {               /* give it time to flush */
            pid_t r = waitpid(pid, &st, WNOHANG);
            if (r == pid) break;
            if (r < 0) break;
            usleep(10000); waited += 10;
        }
        if (waited >= 10000) { kill(pid, SIGTERM); waitpid(pid, NULL, 0); }
    }
    off_t sz = -1;
    struct stat sb;
    if (stat(cap_path, &sb) == 0) sz = sb.st_size;
    fprintf(stderr, "pctv-monitor: capture stopped: %s (%lld B, %llu frames, "
                    "%llu B audio, %llu video drops, %llu audio drops)\n",
            cap_path, (long long)sz, vf, ab, vd, ad);
}

/* ------------------------------------------------------------- audio meter */

/* Map a dBFS value to a 0..1 position on a -60..0 dB scale. */
static double db_pos(double db)
{
    if (db < -60.0) db = -60.0;
    if (db > 0.0) db = 0.0;
    return (db + 60.0) / 60.0;
}

static void draw_meter(SDL_Renderer *ren, int x, int y, int w, int h,
                       double cur, double rms, double hold)
{
    SDL_Rect bg = { x, y, w, h };
    SDL_SetRenderDrawColor(ren, 24, 24, 24, 255);
    SDL_RenderFillRect(ren, &bg);

    /* the target zone: peaks between -12 and -3 dBFS are "in range" */
    SDL_Rect tz = { x + (int)(db_pos(-12.0) * w), y,
                    (int)((db_pos(-3.0) - db_pos(-12.0)) * w), h };
    SDL_SetRenderDrawColor(ren, 40, 80, 40, 255);
    SDL_RenderFillRect(ren, &tz);

    int cx = x + (int)(db_pos(cur) * w);
    for (int px = x; px <= cx && px < x + w; px++) {
        double db = (px - x) / (double)w * 60.0 - 60.0;
        if (db > -2.0) SDL_SetRenderDrawColor(ren, 230, 60, 60, 255);
        else if (db > -6.0) SDL_SetRenderDrawColor(ren, 230, 200, 60, 255);
        else SDL_SetRenderDrawColor(ren, 60, 200, 90, 255);
        SDL_Rect c = { px, y, 1, h };
        SDL_RenderFillRect(ren, &c);
    }
    SDL_SetRenderDrawColor(ren, 255, 255, 255, 255);
    SDL_Rect rm = { x + (int)(db_pos(rms) * w), y, 1, h };   /* RMS marker */
    SDL_RenderFillRect(ren, &rm);
    int hx = x + (int)(db_pos(hold) * w);                    /* peak hold */
    for (int dy = -1; dy <= h; dy++) { SDL_Rect c = { hx, y + dy, 1, 1 }; SDL_RenderFillRect(ren, &c); }
    SDL_SetRenderDrawColor(ren, 150, 150, 150, 255);
    const int ticks[] = { -40, -30, -20, -12, -6, 0 };
    for (unsigned t = 0; t < sizeof ticks / sizeof ticks[0]; t++) {
        SDL_Rect c = { x + (int)(db_pos(ticks[t]) * w), y + h, 1, 3 };
        SDL_RenderFillRect(ren, &c);
    }
    SDL_SetRenderDrawColor(ren, 120, 120, 120, 255);
    SDL_Rect fr = { x, y, w, h };
    SDL_RenderDrawRect(ren, &fr);
}

/* The audio panel: source, gain staging, live meters, verdict. */
static void draw_audio_panel(SDL_Renderer *ren)
{
    const int x = 10, w = 300, bh = 10;
    int y = H - 96;

    pthread_mutex_lock(&amtx);
    int ok = audio_ok, rate = audio_rate, muted = cap_muted, agc = agc_on, mon = mon_on;
    double p0 = pk_db[0], p1 = pk_db[1], r0 = rms_db[0], r1 = rms_db[1];
    double h0 = hold_db[0], h1 = hold_db[1], g = gain_db, bo = boost_db;
    unsigned cl = clips, xr = xruns;
    char err[160]; snprintf(err, sizeof err, "%s", audio_err);
    pthread_mutex_unlock(&amtx);

    SDL_SetRenderDrawBlendMode(ren, SDL_BLENDMODE_BLEND);
    SDL_SetRenderDrawColor(ren, 0, 0, 0, 180);
    SDL_Rect bg = { x - 6, y - 16, w + 110, 104 };
    SDL_RenderFillRect(ren, &bg);

    char t[240];
    /* Name the route too: "default" means the stream is going through the
     * desktop sound server, "hw:x,y" means raw - the difference explains most
     * "there is no audio" reports. */
    snprintf(t, sizeof t, "AUDIO: %s%s%s", srcs[cur_src].label,
             audio_route[0] ? " via " : "",
             audio_route[0] ? audio_route : (cur_src == 0 ? "   (press a to select)" : ""));
    SDL_SetRenderDrawColor(ren, 235, 235, 235, 255);
    draw_text(ren, x, y - 12, 1, t);

    if (cur_src == 0) {
        SDL_SetRenderDrawColor(ren, 150, 150, 150, 255);
        draw_text(ren, x, y + 12, 1, "no input - wire the L/R RCAs to a host input");
        return;
    }
    if (!ok) {
        SDL_SetRenderDrawColor(ren, 230, 120, 60, 255);
        draw_text(ren, x, y + 12, 1, err[0] ? err : "opening...");
        return;
    }

    draw_meter(ren, x, y, w, bh, p0, r0, h0);
    draw_meter(ren, x, y + bh + 3, w, bh, p1, r1, h1);
    SDL_SetRenderDrawColor(ren, 235, 235, 235, 255);
    draw_text(ren, x + w + 6, y + 1, 1, "L");
    draw_text(ren, x + w + 6, y + bh + 4, 1, "R");

    snprintf(t, sizeof t, "L %6.1f  R %6.1f  pk %6.1f  gain %+.1f dB  boost %+.1f dB%s",
             p0, p1, h0 > h1 ? h0 : h1, g, bo, agc ? "  [AGC]" : "");
    draw_text(ren, x, y + 2 * bh + 9, 1, t);

    const char *verdict;
    unsigned char col[3] = { 235, 235, 235 };
    double pk = h0 > h1 ? h0 : h1;
    if (muted) { verdict = "MUTED (m)"; col[0] = 200; col[1] = 200; col[2] = 60; }
    else if (cl) { verdict = agc ? "TOO HOT - AGC reducing" : "TOO HOT - lower gain (-)"; col[0] = 230; col[1] = 60; col[2] = 60; }
    else if (pk < -50) { verdict = "NO SIGNAL - check cable / source"; col[0] = 230; col[1] = 160; col[2] = 60; }
    else if (agc) {
        /* With the AGC in charge the judgement is against its own target, not
         * the manual zone - otherwise the panel calls the level it is holding
         * "LOW". */
        if (pk < AGC_TARGET_DBFS - 8) { verdict = "LOW - AGC raising gain"; col[0] = 230; col[1] = 200; col[2] = 60; }
        else if (pk > AGC_TARGET_DBFS + 10) { verdict = "HOT - AGC lowering gain"; col[0] = 230; col[1] = 120; col[2] = 60; }
        else { verdict = "OK - AGC holding level"; col[0] = 90; col[1] = 220; col[2] = 110; }
    }
    else if (pk < -18) { verdict = agc ? "LOW - AGC raising gain" : "LOW - raise gain (+)"; col[0] = 230; col[1] = 200; col[2] = 60; }
    else if (pk > -3) { verdict = agc ? "HOT - AGC lowering gain" : "HOT - lower gain (-)"; col[0] = 230; col[1] = 120; col[2] = 60; }
    else { verdict = "OK - level in range"; col[0] = 90; col[1] = 220; col[2] = 110; }
    SDL_SetRenderDrawColor(ren, col[0], col[1], col[2], 255);
    draw_text(ren, x, y + 2 * bh + 20, 1, verdict);
    if (mon) {          /* what you hear is the buffer the muxer would be given */
        SDL_SetRenderDrawColor(ren, 90, 190, 255, 255);
        draw_text(ren, x, y + 2 * bh + 31, 1,
                  strcasecmp(srcs[cur_src].item, "Mic") &&
                  strcasecmp(srcs[cur_src].item, "Internal Mic")
                  ? "MONITOR ON - speakers (o)" : "MONITOR ON - speakers (o)  feedback risk: mic input");
    }
    if (cl || xr) {
        snprintf(t, sizeof t, "clips %u  xruns %u  %d Hz", cl, xr, rate);
        SDL_SetRenderDrawColor(ren, 180, 180, 180, 255);
        draw_text(ren, x + text_w(verdict, 1) + 18, y + 2 * bh + 20, 1, t);
    }
}

/* -------------------------------------------------------------------- main */

int main(int argc, char **argv)
{
    char saved[200];
    int want_capture = 0;
    long capture_secs = 0;
    int gain_pct = -1, boost_step = -1, agc_cli = -1, mon_cli = 0;
    const char *audio_arg = NULL;

    /* input: saved choice, then PCTV_INPUT, then -i/--input (highest priority) */
    if (cfg_read("input", saved, sizeof saved)) {
        int in = input_from_name(saved);
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
    pick_out_dir();
    nsrc = discover_audio();                 /* srcs[0] == "none" */
    int saved_gain = -1, saved_boost = -1, saved_agc = -1;
    if (cfg_read_audio(saved, sizeof saved, &saved_gain, &saved_boost, &saved_agc)) {
        int s = src_from_name(saved);
        if (s >= 0) cur_src = s;
    } else {
        /* No saved choice: the pigtail's RCAs are line level, so default to the
         * first "Line" input the host has (Mic/Internal Mic are the wrong
         * gain stage for them); "none" if the box has no line input. */
        for (int i = 1; i < nsrc; i++)
            if (!strcasecmp(srcs[i].item, "Line")) { cur_src = i; break; }
    }
    {
        const char *env = getenv("PCTV_AUDIO");
        if (env) { int s = src_from_name(env); if (s >= 0) cur_src = s; }
        env = getenv("PCTV_MPEG2_BITRATE");
        if (env) mpeg2_kbps = atoi(env);
        env = getenv("PCTV_FFMPEG");
        if (env && *env) snprintf(ffmpeg_path, sizeof ffmpeg_path, "%s", env);
        env = getenv("PCTV_CAPTURE_SECS");
        if (env) capture_secs = strtol(env, NULL, 0);
    }

    for (int i = 1; i < argc; i++) {
        if ((!strcmp(argv[i], "-i") || !strcmp(argv[i], "--input")) && i + 1 < argc) {
            int in = input_from_name(argv[++i]);
            if (in >= 0) cur_input = in;
            else { fprintf(stderr, "pctv-monitor: unknown input '%s'\n", argv[i]); return 2; }
        } else if (!strcmp(argv[i], "-l") || !strcmp(argv[i], "--list")) {
            for (int k = 0; k < NINPUTS; k++) printf("%s\n", INPUTS[k]);
            return 0;
        } else if (!strcmp(argv[i], "-L") || !strcmp(argv[i], "--list-audio")) {
            for (int k = 0; k < nsrc; k++) printf("%s\n", srcs[k].label);
            return 0;
        } else if (!strcmp(argv[i], "--audio") && i + 1 < argc) {
            audio_arg = argv[++i];
        } else if (!strcmp(argv[i], "--no-audio")) {
            audio_arg = "none";
        } else if (!strcmp(argv[i], "--alsa-dev") && i + 1 < argc) {
            const char *d = argv[++i];
            int found = src_from_name(d);
            if (found > 0) cur_src = found;
            else if (nsrc < MAX_SRC) {          /* device with no known selector */
                snprintf(srcs[nsrc].dev, sizeof srcs[nsrc].dev, "%s", d);
                char cd[32]; snprintf(cd, sizeof cd, "%.*s",
                                       (int)(strchr(d, ',') ? strchr(d, ',') - d : strlen(d)), d);
                snprintf(srcs[nsrc].mixdev, sizeof srcs[nsrc].mixdev, "%s", cd);
                snprintf(srcs[nsrc].devlabel, sizeof srcs[nsrc].devlabel, "%s", d);
                srcs[nsrc].item[0] = 0;
                srcs[nsrc].sel_idx = -1;
                snprintf(srcs[nsrc].label, sizeof srcs[nsrc].label, "%s", d);
                cur_src = nsrc++;
            }
        } else if (!strcmp(argv[i], "--gain") && i + 1 < argc) {
            gain_pct = atoi(argv[++i]);
        } else if (!strcmp(argv[i], "--boost") && i + 1 < argc) {
            boost_step = atoi(argv[++i]);
        } else if (!strcmp(argv[i], "--out-dir") && i + 1 < argc) {
            snprintf(out_dir, sizeof out_dir, "%s", argv[++i]);
            mkdir(out_dir, 0755);
        } else if (!strcmp(argv[i], "--bitrate") && i + 1 < argc) {
            mpeg2_kbps = atoi(argv[++i]);
        } else if (!strcmp(argv[i], "--ffmpeg") && i + 1 < argc) {
            snprintf(ffmpeg_path, sizeof ffmpeg_path, "%s", argv[++i]);
        } else if (!strcmp(argv[i], "--capture")) {
            want_capture = 1;
        } else if (!strcmp(argv[i], "--capture-seconds") && i + 1 < argc) {
            capture_secs = strtol(argv[++i], NULL, 0); want_capture = 1;
        } else if (!strcmp(argv[i], "--agc")) {
            agc_cli = 1;
        } else if (!strcmp(argv[i], "--no-agc")) {
            agc_cli = 0;
        } else if (!strcmp(argv[i], "--monitor")) {
            mon_cli = 1;
        } else if (!strcmp(argv[i], "-h") || !strcmp(argv[i], "--help")) {
            usage(argv[0]);
            return 0;
        } else {
            fprintf(stderr, "pctv-monitor: unexpected argument '%s'\n", argv[i]);
            usage(argv[0]);
            return 2;
        }
    }
    if (audio_arg) {
        int s = src_from_name(audio_arg);
        if (s >= 0) cur_src = s;
        else { fprintf(stderr, "pctv-monitor: unknown audio input '%s' (try -L)\n", audio_arg); return 2; }
    }
    if (mpeg2_kbps < 800) mpeg2_kbps = 800;

    /* locate pctv_probe next to us unless PCTV_PROBE says otherwise */
    {
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
    }
    if (access(probe_path, X_OK) != 0)
        snprintf(probe_path, sizeof probe_path, "pctv_probe");

    cfg_write("input", INPUTS[cur_input]);
    /* AGC: command line, then the saved choice, else on */
    if (agc_cli >= 0) agc_on = agc_cli;
    else if (saved_agc >= 0) agc_on = saved_agc;
    cfg_write_audio(srcs[cur_src].label, gain_pct, boost_step, agc_on);

    if (SDL_Init(SDL_INIT_VIDEO) < 0) {
        signal(SIGINT, SIG_DFL);
        fprintf(stderr, "SDL_Init: %s\n", SDL_GetError());
        return 1;
    }
    signal(SIGINT, on_sigint);
    signal(SIGTERM, on_sigint);
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
    memset(fuv, 0, sizeof fuv);
    child_start(cur_input);
    audio_start_thread();
    if (gain_pct >= 0) { pthread_mutex_lock(&amtx); pend_gain_pct = gain_pct;
                         pthread_mutex_unlock(&amtx); }
    else if (saved_gain >= 0) { pthread_mutex_lock(&amtx); pend_gain_pct = saved_gain;
                                pthread_mutex_unlock(&amtx); }
    if (boost_step >= 0) { pthread_mutex_lock(&amtx); pend_boost_step = boost_step;
                           pthread_mutex_unlock(&amtx); }
    else if (saved_boost >= 0) { pthread_mutex_lock(&amtx); pend_boost_step = saved_boost;
                                 pthread_mutex_unlock(&amtx); }
    if (mon_cli) { pthread_mutex_lock(&amtx); pend_mon_toggle = 1;
                   pthread_mutex_unlock(&amtx); }
    show_overlay(8000);

    unsigned char *rbuf = malloc(RBUF);
    size_t rlen = 0;
    int running = 1;
    unsigned long long last_frames = 0, snap_after = 0;
    { const char *s = getenv("PCTV_SNAP_AFTER"); if (s) snap_after = strtoull(s, NULL, 0); }
    double last_t = (double)SDL_GetTicks() / 1000.0, fps = 0;

    if (want_capture) {
        if (frames > 0) cap_start();
        else cap_pending = 1;
        fprintf(stderr, "pctv-monitor: capture queued, starting with the first frame\n");
    }

    int help_on = getenv("PCTV_HELP") != 0;   /* `H' toggles it; env for headless checks */
    unsigned long gap_max = 0;
    /* Per-stage worst time in the last second.  A freeze is only fixable if we
     * know which stage ate the time: reading/decoding the stream, handing the
     * frame to the encoder, or drawing/presenting it. */
    unsigned long stage_max[3] = { 0, 0, 0 };
    const char *stage_name[3] = { "parse", "feed", "render" };

    while (running) {
        if (g_quit) { running = 0; break; }
        {   /* the honest measure of "did the picture stall": the longest gap
             * between two passes of this loop, reported and reset each second */
            static unsigned long iter_prev = 0;
            unsigned long it = SDL_GetTicks();
            if (iter_prev && it - iter_prev > gap_max) gap_max = it - iter_prev;
            iter_prev = it;
        }
        int want_input = cur_input, want_src = cur_src;
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
                case SDLK_c:
                    if (cap_on) cap_stop();
                    else if (cap_pending) {
                        cap_pending = 0;
                        fprintf(stderr, "pctv-monitor: capture cancelled\n");
                    }
                    else if (frames > 0) cap_start();
                    else cap_pending = 1;      /* no video yet: start on frame 1 */
                    show_overlay(4000);
                    break;
                case SDLK_o:
                    pthread_mutex_lock(&amtx); pend_mon_toggle = 1;
                    pthread_mutex_unlock(&amtx);
                    show_overlay(4000);
                    break;
                case SDLK_h: help_on = !help_on; show_overlay(4000); break;
                case SDLK_a:
                    if (e.key.keysym.mod & KMOD_SHIFT) {
                        pthread_mutex_lock(&amtx); pend_agc_toggle = 1;
                        pthread_mutex_unlock(&amtx);
                        show_overlay(4000);
                    } else {
                        want_src = nsrc > 1 ? (cur_src + 1) % nsrc : 0;
                    }
                    break;
                case SDLK_EQUALS: case SDLK_PLUS: case SDLK_KP_PLUS:
                    pthread_mutex_lock(&amtx); pend_gain_step = +1; pend_manual = 1;
                    pthread_mutex_unlock(&amtx); break;
                case SDLK_MINUS: case SDLK_UNDERSCORE: case SDLK_KP_MINUS:
                    pthread_mutex_lock(&amtx); pend_gain_step = -1; pend_manual = 1;
                    pthread_mutex_unlock(&amtx); break;
                case SDLK_b:
                    pthread_mutex_lock(&amtx); pend_boost_cycle = 1; pend_manual = 1;
                    pthread_mutex_unlock(&amtx); break;
                case SDLK_m:
                    pthread_mutex_lock(&amtx); pend_mute_toggle = 1;
                    pthread_mutex_unlock(&amtx); break;
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
            frame_ready = 0; parity_mask = 0; field_repeat = 0;
            cur_input = want_input;
            cfg_write("input", INPUTS[cur_input]);
            child_start(cur_input);
            show_overlay(4000);
        }
        if (want_src != cur_src) {
            cur_src = want_src;
            cfg_write_audio(srcs[cur_src].label, -1, -1, agc_on);
            athr_reopen = 1;
            show_overlay(4000);
            fprintf(stderr, "pctv-monitor: audio input -> %s\n", srcs[cur_src].label);
        }

        /* The codec state is authoritative for the staging: remember it (at most
         * once every 2 s) so the next run comes back at the same level. */
        {
            static unsigned long stage_t = 0;
            static int stage_gp = -999, stage_bs = -999;
            unsigned long t = SDL_GetTicks();
            if (t - stage_t > 2000) {
                stage_t = t;
                pthread_mutex_lock(&amtx);
                int gp = cur_gain_pct, bs = cur_boost_step, ag = agc_on;
                pthread_mutex_unlock(&amtx);
                if ((gp >= 0 || bs >= 0) && (gp != stage_gp || bs != stage_bs)) {
                    stage_gp = gp; stage_bs = bs;
                    cfg_write_audio(srcs[cur_src].label, gp, bs, ag);
                }
            }
        }

        /* drain the child's stdout; stop when the parse buffer is nearly full
         * so parse() can make room - discarding here would lose stream data */
        unsigned long t_stage = SDL_GetTicks();
        for (;;) {
            size_t space = RBUF - rlen;
            if (space < 4 + W * 2) break;
            ssize_t r = read(child_fd, rbuf + rlen, space);
            if (r > 0) {
                bytes_in += (unsigned long long)r;
                if (recording && rec_file) fwrite(rbuf + rlen, 1, r, rec_file);
                rlen += r;
                continue;
            }
            if (r == 0) { child_stop(); running = 0; break; }   /* child died */
            break;                                              /* EAGAIN */
        }
        /* Always parse: pausing freezes the display, not the capture. */
        if (rlen > 0) {
            size_t used = parse(rbuf, rlen);
            if (used > 0) { memmove(rbuf, rbuf + used, rlen - used); rlen -= used; }
        }
        /* Only if parse() could not move anything: keep the tail rather than
         * wedging on a full buffer, and say so (at most once a second). */
        if (RBUF - rlen < 4 + W * 2) {
            memmove(rbuf, rbuf + RBUF / 2, RBUF / 2);
            rlen = RBUF / 2;
            static unsigned long long sync_drops = 0, last_warn = 0;
            sync_drops++;
            unsigned long long t = SDL_GetTicks();
            if (t - last_warn > 1000) {
                last_warn = t;
                fprintf(stderr, "pctv-monitor: no BT.656 sync in %d B ("
                                "%llu drops total)\n", RBUF / 2, sync_drops);
            }
        }

        /* a complete interlaced frame is ready for the encoder */
        {   /* parse stage: stream read + BT.656 decode, top of loop to here */
            unsigned long d = SDL_GetTicks() - t_stage;
            if (d > stage_max[0]) stage_max[0] = d;
        }
        if (parity_mask == 3 || field_repeat) {
            parity_mask = 0; field_repeat = 0;
            /* Start the encoder on the first frame, not on the key press: both
             * streams then get PTS 0 at the same instant, and the audio cannot
             * run ahead by the decoder's lock time (8 s with no source). */
            if (cap_pending && !cap_on) { cap_pending = 0; cap_start(); }
            unsigned long t_feed = SDL_GetTicks();
            cap_feed_video();
            unsigned long d = SDL_GetTicks() - t_feed;
            if (d > stage_max[1]) stage_max[1] = d;
        }

        if (frame_ready) {
            if (!paused) SDL_UpdateTexture(tex, NULL, fb, W * 3);
            frame_ready = 0;
            if (snap_after && frames >= snap_after) { snapshot_ppm(); running = 0; }
        }
        t_stage = SDL_GetTicks();
        SDL_SetRenderDrawColor(ren, 0, 0, 0, 255);        SDL_RenderClear(ren);
        if (!paused) SDL_RenderCopy(ren, tex, NULL, NULL);

        /* input banner: always name the active input, plus transient hints */
        {
            char banner[96];
            snprintf(banner, sizeof banner, "INPUT: %s", INPUT_LABEL[cur_input]);
            draw_panel(ren, 10, 8, banner, 2);
            if (SDL_GetTicks() < overlay_until) {
                char hint[200];
                snprintf(hint, sizeof hint,
                         "1/2/Tab video   a audio   A agc   -/+ gain   b boost   m mute");
                draw_panel(ren, 10, 8 + 7 * 2 + 12, hint, 1);
                snprintf(hint, sizeof hint,
                         "c MPEG-2 capture   o monitor   r raw   s snap   g grey   space pause   q quit");
                draw_panel(ren, 10, 8 + 7 * 2 + 12 + 12, hint, 1);
            }
        }
        draw_audio_panel(ren);

        /* `H' - the key reference, left up until H is pressed again */
        if (help_on) {
            const char *hl[12];
            char h0[200], h1[200], h2[200], h3[200], h4[200], h5[200], h6[200],
                 h7[200], h8[200], h9[200], h10[200], h11[200];
            snprintf(h0, sizeof h0, "HELP (press H to close)");
            snprintf(h1, sizeof h1, " 1 / 2 / Tab   video input: Composite, S-Video");
            snprintf(h2, sizeof h2, " a             audio input (cycle)      A  automatic gain");
            snprintf(h3, sizeof h3, " - / +         capture gain             b  input boost");
            snprintf(h4, sizeof h4, " m             mute capture             g  colour / grey");
            snprintf(h5, sizeof h5, " c             MPEG-2 capture on/off    r  raw BT.656 dump");
            snprintf(h6, sizeof h6, " s             snapshot frame (PPM)     space  freeze display");
            snprintf(h7, sizeof h7, " o             monitor input on speakers (hear the gain first)");
            pthread_mutex_lock(&amtx);
            snprintf(h8, sizeof h8, " audio: %s  gain %+.1f dB  boost %+.1f dB  AGC %s",
                     srcs[cur_src].label, gain_db, boost_db, agc_on ? "on" : "off");
            pthread_mutex_unlock(&amtx);
            snprintf(h9, sizeof h9, " video: %s  720x576 interlaced 25 fps  %d kbps", INPUT_LABEL[cur_input], mpeg2_kbps);
            snprintf(h10, sizeof h10, " out: %.180s", out_dir);
            snprintf(h11, sizeof h11, " q/ESC quit - Ctrl-C also finalises a capture; H closes this");
            hl[0] = h0; hl[1] = h1; hl[2] = h2; hl[3] = h3; hl[4] = h4; hl[5] = h5;
            hl[6] = h6; hl[7] = h7; hl[8] = h8; hl[9] = h9; hl[10] = h10; hl[11] = h11;
            draw_panel_lines(ren, 10, 70, hl, 12, 1);
        }

        /* capture status, top right: recording has to be unmistakable - a red
         * frame border, a big blinking REC badge and a running counter */
        if (cap_pending && !cap_on) {
            const char *lines[1];
            char l0[200];
            snprintf(l0, sizeof l0, "REC queued - waiting for video lock");
            lines[0] = l0;
            draw_panel_lines(ren, W - text_w(l0, 2) - 30, 8, lines, 1, 2);
        }
        if (cap_on) {
            SDL_SetRenderDrawBlendMode(ren, SDL_BLENDMODE_BLEND);
            for (int t = 0; t < 4; t++) {          /* red border, 4 px in */
                SDL_Rect r[4] = { { t, t, W - 2 * t, 2 }, { t, H - t - 2, W - 2 * t, 2 },
                                  { t, t, 2, H - 2 * t }, { W - t - 2, t, 2, H - 2 * t } };
                SDL_SetRenderDrawColor(ren, 225, 45, 45, 255);
                SDL_RenderFillRect(ren, &r[t]);
            }

            unsigned long ms = SDL_GetTicks() - cap_t0_tick;
            char big[64];
            snprintf(big, sizeof big, "REC %02lu:%02d.%lu",
                     ms / 60000, (int)((ms / 1000) % 60), (ms / 100) % 10);
            const char *bl[1]; bl[0] = big;
            int bw = text_w(big, 2) + 26;
            draw_panel_lines(ren, W - bw - 24, 8, bl, 1, 2);
            /* the dot blinks once a second so it reads as "live" */
            int on = (ms / 1000) % 2 == 0;
            SDL_SetRenderDrawColor(ren, on ? 255 : 150, on ? 40 : 30, on ? 40 : 30, 255);
            SDL_Rect dot = { W - bw - 14, 14, 14, 14 };
            SDL_RenderFillRect(ren, &dot);

            const char *lines[2];
            char l1[200], l2[200];
            pthread_mutex_lock(&cap_mtx);
            snprintf(l1, sizeof l1, "%llu frames  %llu B  drops %llu/%llu",
                     cap_vframes, (unsigned long long)cap_abytes,
                     cap_vdrops, cap_adrops);
            pthread_mutex_unlock(&cap_mtx);
            snprintf(l2, sizeof l2, "audio %s  queue %d/%d",
                     cap_has_audio ? srcs[cur_src].label : "OFF", vq_count, VQ_SLOTS);
            lines[0] = l1; lines[1] = l2;
            int wpx = text_w(l1, 1) > text_w(l2, 1) ? text_w(l1, 1) : text_w(l2, 1);
            draw_panel_lines(ren, W - wpx - 24, 8 + 16 * 2 + 10, lines, 2, 1);
        }

        SDL_RenderPresent(ren);
        {   /* render stage: from the texture update to the present returning */
            unsigned long d = SDL_GetTicks() - t_stage;
            if (d > stage_max[2]) stage_max[2] = d;
        }

        double now = (double)SDL_GetTicks() / 1000.0;
        if (now - last_t >= 1.0) {
            fps = (double)(frames - last_frames) / (now - last_t);
            last_frames = frames; last_t = now;
            pthread_mutex_lock(&amtx);       /* peak hold decays ~6 dB/s */
            for (int c = 0; c < 2; c++) {
                if (pk_db[c] > hold_db[c]) hold_db[c] = pk_db[c];
                else hold_db[c] -= 6.0;
                if (hold_db[c] < -90) hold_db[c] = -99;
            }
            pthread_mutex_unlock(&amtx);

            char title[256];
            snprintf(title, sizeof title,
                     "PCTV 320cx - %s%s%s%s - %.0f fields/s",
                     INPUT_LABEL[cur_input], grey ? " [grey]" : "",
                     recording ? " [RAW]" : "", cap_on ? " [MPEG2 REC]" : "", fps);
            SDL_SetWindowTitle(win, title);
            if (getenv("PCTV_VERBOSE")) {
                pthread_mutex_lock(&amtx);
                fprintf(stderr, "monitor: %s | in %llu B rlen %zu | maxgap %lums "
                                "(%s %lums %s %lums %s %lums) vq %d/%d | "
                                "audio %s ok=%d L %.1f R %.1f pk %.1f clips %u gain %+.1f dB\n",
                        title, bytes_in, rlen, gap_max,
                        stage_name[0], stage_max[0], stage_name[1], stage_max[1],
                        stage_name[2], stage_max[2], vq_count, VQ_SLOTS,
                        srcs[cur_src].label, audio_ok, pk_db[0], pk_db[1],
                        hold_db[0] > hold_db[1] ? hold_db[0] : hold_db[1], clips, gain_db);
                pthread_mutex_unlock(&amtx);
                gap_max = 0;
                for (int q = 0; q < 3; q++) stage_max[q] = 0;
            }
            if (capture_secs && cap_on && time(NULL) - cap_t0 >= (time_t)capture_secs)
                running = 0;
        }
        if (rlen == 0) SDL_Delay(1);
    }

    cap_stop();
    athr_stop = 1;
    if (athr_started) pthread_join(athr, NULL);
    child_stop();
    if (rec_file) fclose(rec_file);
    free(rbuf);
    fprintf(stderr, "pctv-monitor: %llu fields, %llu encoded frames, "
                    "%llu B from the probe\n", frames, cap_vframes, bytes_in);
    SDL_DestroyTexture(tex);
    SDL_DestroyRenderer(ren);
    SDL_DestroyWindow(win);
    SDL_Quit();
    return 0;
}
