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
 *   s  snapshot a PPM                                 c  start/stop capture
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
#include <limits.h>
#include <errno.h>
#include <unistd.h>
#include <fcntl.h>
#include <signal.h>
#include <time.h>
#include <math.h>
#include <strings.h>
#include <stdarg.h>
#include <pthread.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <sys/types.h>
#include <sys/poll.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/statvfs.h>
#include <alsa/asoundlib.h>
#include <SDL.h>

#include "pctv-rt.h"

#include "font5x7.h"

#define W 720
#define H 576
#define FIELD_MAX 296
#define RBUF (8u << 20)          /* 8 MiB read/parse buffer */
/* One BT.656 line as this card actually ships it: SAV(4) + 1440 active +
 * EOF(4) + 280 B of H-blanking tail = 1728 B.  Measured from a raw dump: the
 * deltas between guard codes alternate 1444 / 284, and 15625 lines/s * 1728 =
 * 27.0 MB/s, exactly the rate the probe streams at.  The pitch is fixed, so a
 * guard code that is not 1728 B after the previous one proves bytes vanished -
 * see parse(). */
#define LINE_BYTES (4 + W * 2 + 284)
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

/* What a capture is *written as*.  Not to be confused with the `r` key, which
 * dumps the raw BT.656 byte stream before it is deframed at all.
 *
 *   dvd   the PAL-DVD-style MPEG-2 program stream this box has always produced:
 *         4:2:2, `-b:v 6000k`, plays on a DVD player and is small enough to keep
 *         years of tape.  It is also the only mode with a rate-controlled
 *         encoder: on detailed tape the 1.8 MB VBV cannot always hold 6 Mbps, so
 *         quality collapses exactly when the picture is hardest, and a dropped
 *         frame costs the rest of the `-g 15` GOP.  Fine for watching; not what
 *         you want as the archive of a camcorder tape.
 *   uyvy  the deframed picture, uncompressed, in Matroska: bit-exact by
 *         construction (verified with cmp through the muxer), stored in the very
 *         pixel format the deframer produces - no colourspace conversion at all
 *         - so the encoder drops out of the critical path entirely.  ~1.2 GB/min.
 *   ffv1  the same bits, lossless-coded, ~1/3 the size and ~1/4 the disk rate,
 *         for the price of a real encoder (which is SCHED_FIFO since 6fdd651).
 *
 * Both lossless modes are intra-only with no rate control, so a busy scene makes
 * the file bigger instead of making the encoder fall behind, which is the
 * property an archive of a one-shot tape capture wants.  Deinterlacing (50p) is
 * deliberately NOT done here: the only thing this box could do live is bob, and
 * that throws away half the vertical resolution permanently - see the comment in
 * cap_start() and docs/pctv-320cx.md. */
#define MASTER_DVD  0
#define MASTER_UYVY 1
#define MASTER_FFV1 2
#define MASTER_UTVIDEO 3
static int cap_master = MASTER_DVD;
static const char *const MASTER_NAME[] = { "dvd", "uyvy", "ffv1", "utvideo" };

static int master_from_name(const char *s)
{
    if (!s || !*s) return MASTER_DVD;
    if (!strcasecmp(s, "uyvy") || !strcasecmp(s, "raw"))
        return MASTER_UYVY;
    if (!strcasecmp(s, "ffv1")) return MASTER_FFV1;
    if (!strcasecmp(s, "utvideo") || !strcasecmp(s, "ut")) return MASTER_UTVIDEO;
    if (!strcasecmp(s, "dvd") || !strcasecmp(s, "mpeg2") || !strcasecmp(s, "mpg"))
        return MASTER_DVD;
    fprintf(stderr, "pctv-monitor: unknown master '%s' (dvd|uyvy|ffv1|utvideo) - using dvd\n", s);
    return MASTER_DVD;
}

/* ...and back again, for the log line that says what a capture was configured as. */
static const char *master_name(int m)
{
    switch (m) {
    case MASTER_UYVY:    return "uyvy";
    case MASTER_FFV1:    return "ffv1";
    case MASTER_UTVIDEO: return "utvideo";
    default:             return "dvd";
    }
}

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
/* ---- good-frame gate -----------------------------------------------------
 * A frame whose two fields do not belong together is far more visible than the
 * same picture shown twice: a field spliced across a stream hole sits ~19 rows
 * off, and a frame built from a repeated field has one half 40 ms older than
 * the other.  So keep the last clean frame and re-show / re-encode it when the
 * new one is not clean.  Holding costs a repeated frame - and 25 fps is kept,
 * so the encoder and the audio stay in step - while a glitch costs a frame that
 * is half someone else's picture.
 *
 * `f' toggles it (default on).  If it would hold EVERY frame for two seconds
 * the source itself never produces a clean one (not 288 active lines, odd
 * sync), and a frozen display is worse than a comb, so it switches itself off
 * and says so. */
static int   gate_on = 1;
static int   have_good = 0;                  /* good_fb/good_fuv are valid */
static int   gate_holds = 0;                 /* consecutive frames held */
static unsigned long long frames_held = 0;
static unsigned char *good_fb, *good_fuv;    /* the last frame that passed */
static unsigned long long frames = 0;
/* Fields committed with fewer than the 288 active lines a PAL field has, after
 * the seam repair in field_commit() has had its chance.  A field is short when
 * lines vanished from the byte stream and could not be placed: the hole was
 * aligned to whole line boundaries (so the guard codes are still exactly 1728 B
 * apart and the pitch proves nothing), or more than one hole opened in the same
 * field.  Those are the fields the frame gate holds. */
static unsigned long long fields_short = 0;
/* Frames fed with one field left over from the PREVIOUS frame (the same parity
 * arrived twice, so one parity's rows were never refreshed).  That is the
 * classic "one field is misaligned / combed" frame: half of it is a 40 ms-old
 * image.  Counted to tell a stale-field feed from a lost-lines feed. */
static unsigned long long fields_repeat = 0;
/* Guard codes found at a pitch other than LINE_BYTES: bytes were discarded
 * between them (the card's FIFO, the probe's URB pool, or the pipe).  Without
 * this the field is spliced across the hole - every line after it lands ~19
 * rows early, which is the "one interlaced field is misaligned" glitch.  Since
 * 2026-11-02 the hole is *repaired* instead of paid for (see gap_resync). */
static unsigned long long fields_gap = 0;
/* Bytes the BT.656 stream actually lost, and the lines that is worth.  The two
 * are printed together at the end of a capture: `gap 1152 B/19 lines` is one
 * 32 KiB URB that the host was not there to receive, i.e. the device dropped
 * data - and the size of that number is how you tell a USB problem from a
 * parser problem. */
static unsigned long long gap_bytes = 0;
static unsigned long long gap_lines = 0;
/* Where a hole opened in the field now being assembled, and how many opened in
 * it, so field_commit() can turn "this field is N lines short" into "N rows are
 * missing at row R" (see there). */
static int gap_seams;
static int gap_seam_row = -1;
/* Fields that ended short but were repaired by that arithmetic. */
static unsigned long long gap_repaired = 0;
/* Fields thrown away because they were spliced across such a gap (set by
 * parse(), reaped by field_line() at the field boundary).  Losing a field costs
 * one frame of picture; committing it costs a field whose lower half sits ~19
 * rows too high.  Since 2026-11-02 a gap is repaired row-accurately instead
 * (gap_resync) and this stays at 0. */
static unsigned long long fields_dropped = 0;
/* Worst time spent handing one assembled frame to the capture queue, measured
 * where the frame is born (field_commit) rather than in the main loop - the
 * verbose line's `feed` column.  If this ever rises, the queue is the problem. */
static unsigned long feed_max_ms = 0;
/* 0 = assembling normally, 1 = unusable (a stream hole before 2026-11-02 also
 * set this; a hole is now repaired instead - see gap_resync), 2 = this field
 * starts right after a discarded one or after a stream restart, so its head
 * lines may be missing too.  Fields in 1 or 2 are counted but not stored. */
static int field_state = 0;
/* Whether the frame just assembled was short, spliced or a repeated parity; read
 * by whoever feeds it, for the end-of-tape detector. */
static int frame_bad = 0;
/* Timestamped log of the two anomaly kinds, so they can be lined up against
 * each other (a lost chunk and a stale-field feed are the same event seen from
 * the two ends of the pipe) and against the capture window. */
#define ANOM_LOG 128
struct anom { unsigned long t; char kind; };
static struct anom anom[ANOM_LOG];
static int nanom = 0;
static void anom_note(unsigned long t, char kind)
{
    if (nanom < ANOM_LOG) { anom[nanom].t = t; anom[nanom].kind = kind; nanom++; }
}
static unsigned long long bytes_in = 0;   /* bytes read from the probe */
/* The read/parse buffer is at file scope so cap_start() and cap_stop() can keep
 * the probe pipe drained while they block (pump()).  Leaving it undrained for
 * the 2 s audio wait at capture start and the ffmpeg flush at capture stop is
 * what throws away the first and last frames of every recording. */
static unsigned char *rbuf;
static size_t rlen;
static void parse_reset(void);          /* defined with the parser */

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
static void cap_feed_silence(size_t nframes);
static void cap_feed_video(int stale);
static void field_fill_rows(int first, int count, int parity);

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
    if (e && *e) {
        /* Masters are the thing you cannot afford to lose, and this variable is
         * how the raw-to-NAS station points at the mount.  If the mount is not
         * there, writing into the empty mountpoint directory (or, worse,
         * silently falling back to /tmp after a typo) means a tape recorded
         * onto the wrong machine.  Refuse loudly instead. */
        if (access(e, W_OK) != 0) {
            fprintf(stderr, "pctv-monitor: PCTV_OUT_DIR=%s is not writable (%s)."
                            " If that is the NAS mount, it is not mounted - fix"
                            " that, do not capture somewhere else. Exiting.\n",
                    e, strerror(errno));
            exit(3);
        }
        snprintf(out_dir, sizeof out_dir, "%s", e);
        return;
    }
    const char *home = getenv("HOME");
    if (home && *home) {
        snprintf(out_dir, sizeof out_dir, "%s/Videos", home);
        mkdir(out_dir, 0755);              /* may exist already; that is fine */
        if (access(out_dir, W_OK) == 0) return;
    }
    snprintf(out_dir, sizeof out_dir, "/tmp");
}

/* `to' is not always stderr: main() dup2()s stderr onto the run log at startup
 * (so a menu-launched monitor leaves a trail), which quietly swallowed --help -
 * it appeared only in ~/.local/state/pctv-monitor.log. Help goes to the terminal. */
static void usage(const char *p, FILE *to)
{
    fprintf(to,
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
        "                      peaks near -18 dBFS.  Slow by design - it trims\n"
        "                      the codec toward the loudest peak of the last 30\n"
        "                      s at 0.5 dB/s, to calibrate the input, not to\n"
        "                      compress the programme (emergency pull-down only\n"
        "                      when the ADC is at full scale)\n"
        "  --monitor           start with input monitoring on: play the captured\n"
        "                      samples out of the host's speakers (key: o)\n"
        "  --out-dir <dir>     where captures go (default ~/Videos, else /tmp)\n"
        "  --bitrate <kbps>    MPEG-2 video bitrate (default 6000; the encoder is\n"
        "                      quantiser-limited near 15000 on grainy tape)\n"
        "  --master <mode>     capture format: dvd (MPEG-2, default), or a lossless\n"
        "                      Matroska master - ffv1 (lossless, 4.5x realtime,\n"
        "                      240 MB/min, and it WRITES the field order), utvideo\n"
        "                      (14x but no field flag: relabel it after), or uyvy\n"
        "                      (the probe's own bytes, 1.25 GB/min: zero encode,\n"
        "                      so nothing on this box can fall behind it)\n"
        "  --ffmpeg <path>     ffmpeg binary (default PCTV_FFMPEG or 'ffmpeg')\n"
        "  --capture           start a capture immediately (format: --master)\n"
        "  --capture-seconds N stop after N seconds and exit (headless test)\n"
        "\n"
        "  LOSSLESS RAW MASTERS, WITH SOUND\n"
        "  Every master carries the audio: PCM (pcm_s16le, 48 kHz stereo) inside the\n"
        "  .mkv for the lossless ones, MP2 inside the .mpg for dvd - from the input\n"
        "  --audio selects (default: whatever the last run saved, normally Line in).\n"
        "  --no-audio turns it off and REMEMBERS that choice, so check the first line\n"
        "  of the summary: 'audio Line (hw:0,0) ...' is the sound being recorded.\n"
        "    pctv-capture-nas                 the desktop entry's wrapper: --master\n"
        "                                     uyvy with PCTV_OUT_DIR on the NAS, and\n"
        "                                     it REFUSES to start if that mount is\n"
        "                                     not there (a 2 h tape is 151 GB, which\n"
        "                                     is not a laptop SSD story)\n"
        "    PCTV_MASTER=uyvy pctv-monitor    the same thing by hand\n"
        "    PCTV_OUT_DIR=/somewhere          where files land (default ~/Videos); it\n"
        "                                     exits 3 if the directory is not writable\n"
        "  A master is the tape as the card saw it: transcode it later\n"
        "  (pctv-linux/README.md), and check the run against 14.5 in\n"
        "  docs/pctv-analog-capture.md - or run pctv-linux/queue-selftest.sh, which\n"
        "  freezes the encoder mid-capture and proves a stall loses nothing.\n"
        "  end of tape: the monitor watches the picture, not the file.\n"
        "  A frozen frame is bit-identical and live tape never is, so after\n"
        "  PCTV_HOLD_SECS (default 600) of one the file is closed and the card\n"
        "  stays claimed: a blank stretch or a damaged patch costs a file\n"
        "  boundary and not the rest of the tape, and a picture again reopens\n"
        "  a file by itself.  PCTV_HOLD_MAX N also ends the run N s after the\n"
        "  picture stopped (0 = keep watching, the default);\n"
        "  PCTV_HOLD_SECS=0 turns that off.  A deck with nothing to play shows\n"
        "  a BLUE screen instead, which changes every frame and so is caught by\n"
        "  colour, not repetition: PCTV_BLUE_SECS (default 60) of it ends the\n"
        "  run and releases the card (0 = never).  A deck that answers end of\n"
        "  tape with static is neither - use --capture-seconds for that.\n"
        "\n"
        "  keys: 1/2 or Tab video input | a audio input | A automatic gain |\n"
        "        -/+ gain | b boost | m mute | o monitor input | c capture (master |\n"
        "        format, --master), h help on screen | s snapshot | g grey |\n"
        "        f frame gate | space pause display | r raw BT.656 dump | q/ESC quit\n", p);
}

/* ------------------------------------------------------------------ child */

/* Closing the read end comes FIRST, on pain of hanging the machine.  The probe
 * writes stdout into this pipe and only gives up when the write fails (EPIPE);
 * waitpid() before close() therefore waits for a process that is waiting for us
 * - which is exactly how this deadlocked for 90 min on 2026-11-02 (monitor in
 * wait4(1598), sudo waiting on the probe, the probe's writer thread in a 2 ms
 * EAGAIN retry loop on a full pipe).  It is not even a bug the probe could fix
 * by handling SIGTERM better: stream_stop is only ever checked between writes.
 * The reap is bounded after that, and SIGKILL is the backstop. */
static void child_stop(void)
{
    if (child > 0) {
        if (child_fd >= 0) { close(child_fd); child_fd = -1; }
        kill(child, SIGTERM);
        int waited = 0;
        while (waited < 3000) {
            if (waitpid(child, NULL, WNOHANG) == child) { child = -1; break; }
            usleep(10000); waited += 10;
        }
        if (child > 0) {                    /* still holding the card: end it */
            fprintf(stderr, "pctv-monitor: probe %d ignored SIGTERM for %d ms,"
                            " sending SIGKILL\n", (int)child, waited);
            kill(child, SIGKILL);
            waitpid(child, NULL, 0);
            child = -1;
        }
    }
    if (child_fd >= 0) { close(child_fd); child_fd = -1; }
}

/* Grow a pipe to `want` MiB, halving until the kernel allows it, and report
 * what was actually achieved.  F_SETPIPE_SZ is refused above
 * fs.pipe-max-size for an unprivileged process, and at the 1 MiB default the
 * 27 MB/s BT.656 stream has only 39 ms of cushion - one desktop hiccup and the
 * probe discards a whole 32 KiB URB.  live-module.nix raises the cap to 64 MiB
 * so the 32 MiB asked for here (1.2 s of slack) is granted; the ladder keeps
 * the monitor working on a host where that sysctl is not set. */
static int pipe_slack(int fd, int want_mib, const char *what)
{
    for (int mib = want_mib; mib >= 1; mib /= 2)
        if (fcntl(fd, F_SETPIPE_SZ, mib << 20) > 0) {
            if (mib < want_mib)
                fprintf(stderr, "pctv-monitor: %s pipe: %d MiB "
                                "(fs.pipe-max-size too low for %d MiB)\n",
                        what, mib, want_mib);
            return mib;
        }
    fprintf(stderr, "pctv-monitor: %s pipe: cannot grow (default 64 KiB)\n", what);
    return 0;
}

static void child_start(int input)
{
    int p[2];
    if (pipe(p) < 0) die("pipe");
    pipe_slack(p[0], 32, "stream");
    parse_reset();
    have_good = 0;            /* a new input is a new picture: nothing to hold */
    signal(SIGPIPE, SIG_IGN);

    child = fork();
    if (child < 0) die("fork");
    if (child == 0) {
        dup2(p[1], STDOUT_FILENO);
        close(p[0]); close(p[1]);
        /* keep stderr for the driver's diagnostics */
        if (geteuid() == 0 || getenv("PCTV_NO_SUDO"))
            execlp(probe_path, probe_path, "stream", INPUTS[input], NULL);
        else {
            /* `sudo -n` runs its env_reset, so PCTV_RT_PRIO (the RT escape
             * hatch, pctv-rt.h) would die at this boundary and the probe would
             * silently keep its default class.  Carry it over explicitly. */
            const char *rt = getenv("PCTV_RT_PRIO");
            char rtv[32];
            if (rt) {
                snprintf(rtv, sizeof rtv, "PCTV_RT_PRIO=%s", rt);
                execlp("sudo", "sudo", "-n", "env", rtv, probe_path, "stream",
                       INPUTS[input], NULL);
            } else {
                execlp("sudo", "sudo", "-n", probe_path, "stream",
                       INPUTS[input], NULL);
            }
        }
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
/* ------------------------------------------------------ end-of-tape detector
 *
 * A deck that reaches the end of its tape does not stop the digitiser: it hands
 * us the same field for ever.  That is detectable exactly rather than by
 * thresholds, because "for ever" means *bit-identical* - the nine hours of
 * end-of-tape hold on the 2026-11-02 overnight run fold to one hash (and to
 * Y=16 U=128 V=128, video black) while all 960279 frames of programme before
 * them differed, and a merely still-looking shot differs too because tape noise
 * is in it (docs/pctv-analog-capture.md §12 measured the same thing from the
 * decoder side: 3.8-9.5 mean inter-frame difference live, exactly 0.0000 held).
 *
 * So this lives here, next to the pixels, and not in a script watching how fast
 * the output file grows (scripts/pctv-autoend.sh).  Two reasons: the picture is
 * the evidence, and a second process can die - that one did, 11 minutes into a
 * shift, and the capture ran 9h past the tape.
 *
 * The response is deliberately NOT "stop".  It is "close this file, keep the
 * card, open a new one the moment there is a picture again", because nothing can
 * tell a blank stretch between two recordings apart from the end of a tape: any
 * rule confident enough to end the run is confident enough to throw the rest of
 * the tape away.  With auto-resume a wrong guess costs a file boundary and 2 min
 * of frozen tail (45 kB/s), instead of the programme after the gap.
 *
 * Counting is per complete frame, at the same point the frame is handed to the
 * encoder - so the predicate is "what would go in the file is repeating", which
 * is the thing worth knowing, and it covers a tape paused into tracking errors
 * (every fed frame is then the gate holding the last good one) as well as a deck
 * quietly outputting the same field.
 */
#define HOLD_SECS_DEFAULT 600      /* PCTV_HOLD_SECS: how long a still may run
                                    * inside a file; 0 turns the detector off.
                                    * 600 and not 120 because a damaged stretch
                                    * of tape reads exactly like a still (the
                                    * frame gate holds the last clean frame, so
                                    * every fed frame is bit-identical) and is
                                    * not the end of anything: at 2 min the file
                                    * was cut in the middle of one and
                                    * everything the gate held after that was
                                    * never recorded.  The real end of a tape is
                                    * the deck's blue screen, and the detector
                                    * below answers that in 60 s. */
#define HOLD_RESUME_DEFAULT 25     /* changed FRAMES (1 s) before the picture
                                    * counts as back - one tracking glitch must
                                    * not open a file */
static int hold_secs = HOLD_SECS_DEFAULT;
static int hold_max_secs;         /* PCTV_HOLD_MAX: end the run this long after
                                   * the picture stopped; 0 = watch for ever */
static int hold_resume = HOLD_RESUME_DEFAULT;
static int hold_have;             /* hold_hash refers to a real frame */
static unsigned long long hold_hash;
static int hold_same, hold_diff;  /* run lengths, in frames */
static int hold_state;            /* 1 = the picture has stopped moving */
static unsigned long hold_since;  /* SDL ticks on entry to state 1 */
static int hold_want_stop;        /* the actions belong in the main loop: */
static int hold_want_start;       /* cap_start() pumps the stream, so it must */
static int hold_quit;              /* never be called from inside the parser */
static int hold_stress;           /* PCTV_HOLD_STRESS: see hold_update() */
static int hold_stress_done;

/* Fold a frame into 64 bits.  Only two failure directions matter: a false
 * "different" is impossible, and a false "same" needs a 64-bit collision, so the
 * worst this can do is fail to notice a hold - it can never cut a live picture.
 *
 * Four accumulators because the fold is a dependency chain, not a bandwidth
 * problem: one lane costs 400 us per frame on this box (1% of a core at 25 fps),
 * four cost 82 us, and eight cost *more* than four again from register pressure
 * - all measured with the flags it ships with, because 0.2% of a core is worth
 * paying for a predicate that compares every pixel rather than a sample of them. */
static unsigned long long hold_fold(const unsigned char *p, size_t n)
{
    const unsigned long long K = 0x9E3779B97F4A7C15ULL;
    unsigned long long h0 = 1, h1 = 2, h2 = 3, h3 = 4, v;
    size_t i = 0;
    for (; i + 32 <= n; i += 32) {
        memcpy(&v, p + i, 8);      h0 = (h0 ^ v) * K;
        memcpy(&v, p + i + 8, 8);  h1 = (h1 ^ v) * K;
        memcpy(&v, p + i + 16, 8); h2 = (h2 ^ v) * K;
        memcpy(&v, p + i + 24, 8); h3 = (h3 ^ v) * K;
    }
    for (; i + 8 <= n; i += 8) { memcpy(&v, p + i, 8); h0 = (h0 ^ v) * K; }
    return ((h0 * K) ^ (h1 >> 17)) + ((h2 * K) ^ (h3 >> 17));
}

/* Called once per frame, from the place the frame is handed to the encoder, so
 * "stopped" means "what would go in the file is repeating" - gate substitutions
 * included, which is what makes a tape paused into tracking errors (every fed
 * frame is the gate holding the last good one) read as stopped too.  `bad` is
 * that frame's own cleanliness: a field that lost lines or arrived twice is the
 * tape sticking rather than the picture stopping, so when it also differs it
 * credits neither run. */
static void hold_update(int bad)
{
    unsigned long long h = hold_fold(fuv, UV_SIZE);

    /* PCTV_HOLD_STRESS=<s>: report a constant hash for the first <s> of the run,
     * then start telling the truth.  A self-test, not a behaviour: the two
     * transitions (close the file, reopen on motion) otherwise need a tape to run
     * out at the moment you are watching, and both have to be right for the
     * overnight case to work.  One run against a live signal proves the first file
     * is finalised and that a second one opens and records. */
    if (hold_stress && !hold_stress_done) {
        if ((int)(SDL_GetTicks() / 1000) < hold_stress) h = 1;
        else { hold_stress_done = 1; hold_have = 0; }
    }

    if (hold_have && h == hold_hash) {
        hold_same++; hold_diff = 0;
    } else if (!hold_have || !bad) {
        hold_hash = h; hold_have = 1;
        hold_diff++; hold_same = 0;
    }

    if (!hold_state) {
        if (hold_secs > 0 && hold_same >= hold_secs * 25) {
            hold_state = 1;
            hold_since = SDL_GetTicks();
            hold_want_stop = 1;
        }
        return;
    }
    if (hold_diff >= hold_resume) {
        hold_state = 0;
        hold_want_start = 1;
        return;
    }
    if (hold_max_secs > 0 &&
        SDL_GetTicks() - hold_since >= (unsigned long)(hold_max_secs * 1000))
        hold_quit = 1;
}

/* `c' means someone has decided what to record: the window starts over, and the
 * detector stops being allowed to second-guess that by reopening a file. */
static void hold_rearm(void)
{
    hold_same = hold_diff = 0;
    hold_state = 0;
    hold_want_stop = hold_want_start = 0;
}

/* ------------------------------------------------ no content: the blue screen
 *
 * The other way a camcorder says "nothing to play" is a blue screen, and it is
 * NOT a frozen frame: over the 69 min tail of the 2026-11-02 capture there were
 * 749 consecutive frames and zero identical pairs, because the no-signal colour
 * subcarrier beats against the digitiser's sampling clock
 * (docs/pctv-analog-capture.md §12).  The repetition detector above cannot see
 * it at all, and neither can a growth-rate watchdog on a raw master (a fixed-
 * frame-size master costs the same 20.9 MB/s for blue as for programme).
 *
 * What the blue does have is colour.  signalstats over that file, in 8-bit
 * codes with neutral chroma at 128:
 *
 *      deck blue   Y 47.4   U 205.9   V 116.3   (held to a tenth over 3000 s)
 *      programme   Y 94-113 U 123.2   V 129-136
 *      tape black  Y 16     U 128     V 128
 *
 * U alone separates blue from programme by 80 codes, so the predicate is
 * "strongly blue and dark" (mean U >= 170, mean Y <= 110) plus "the frame means
 * are not moving" (each within BLUE_TOL of the run's first frame).  V is *not*
 * used: 116 against 129 is a 13-code margin and that is how false triggers
 * happen.  Luma is what keeps a real blue thing on tape - a sky, a swimming
 * pool - out: those are bright (Y 150-200) and ordinary programme; the deck's
 * blue is dark, which is why it is separable at all.
 *
 * This one ENDS the run, unlike the stillness detector's "close the file and
 * keep watching": a blank stretch between two recordings is something tapes
 * genuinely do, but a blue screen is the deck answering "there is nothing to
 * play", so after BLUE_SECS of it the tape is over and the card belongs back
 * to the system.  It only counts while capturing, and only after a real picture
 * has been seen since the file opened - otherwise a monitor started in front of
 * a stopped deck would quit before the tape was rolled. */
#define BLUE_SECS_DEFAULT 60  /* PCTV_BLUE_SECS: how long blue ends the run; 0 off */
#define BLUE_U_MIN 170.0      /* mean Cb at or above this is the blue screen ... */
#define BLUE_Y_MAX 110.0      /* ... and at or below this it is the deck's dark
                               * one, not a bright blue that is real footage */
#define BLUE_TOL 3.0          /* codes a plane's mean may drift inside a run */
static int blue_secs = BLUE_SECS_DEFAULT;
static int blue_seen;         /* a real picture since the file opened: a blue
                               * screen before it is not the end of anything */
static int blue_run;          /* 1 = in a run of blue frames */
static unsigned long blue_since;          /* ticks of the run's first frame */
static double blue_y0, blue_u0, blue_v0;  /* means of the run's first frame */
static double frame_y, frame_u, frame_v;  /* the frame just measured: printed by
                                           * PCTV_VERBOSE so the predicate can be
                                           * checked against a real deck */
static int blue_hit;          /* the main loop acts: end the run */
static int blue_is;           /* this frame passes the colour test (verbose) */

/* Mean of each plane over the frame.  One extra pass over 829 kB per frame
 * (~1% of a core at 25 fps, next to hold_fold's 0.2%) and deliberately not
 * sampled: a stride would alias against the very subcarrier pattern this is
 * looking for.  fuv is UYVY, so every 4 bytes are U Y0 V Y1. */
static void frame_means(double *y, double *u, double *v)
{
    unsigned long long sy = 0, su = 0, sv = 0;
    size_t n = UV_SIZE / 4;
    for (size_t i = 0; i + 4 <= UV_SIZE; i += 4) {
        su += fuv[i];
        sy += fuv[i + 1] + fuv[i + 3];
        sv += fuv[i + 2];
    }
    *y = n ? (double)sy / (double)(2 * n) : 0.0;
    *u = n ? (double)su / (double)n : 0.0;
    *v = n ? (double)sv / (double)n : 0.0;
}

/* Called once per complete frame, next to hold_update(). */
static void blue_update(void)
{
    double y, u, v;
    frame_means(&y, &u, &v);
    frame_y = y; frame_u = u; frame_v = v;
    blue_is = (u >= BLUE_U_MIN && y <= BLUE_Y_MAX);
    if (!blue_is) {
        blue_run = 0;               /* a picture: the deck has something to play */
        blue_seen = 1;
        return;
    }
    if (!blue_seen) return;         /* blue before any picture: not an end */
    if (!blue_run) {
        blue_run = 1;
        blue_since = SDL_GetTicks();
        blue_y0 = y; blue_u0 = u; blue_v0 = v;
        return;
    }
    if (fabs(y - blue_y0) > BLUE_TOL || fabs(u - blue_u0) > BLUE_TOL ||
        fabs(v - blue_v0) > BLUE_TOL) {
        /* Still blue, but not the *same* blue: something is moving in it.  The
         * window starts over rather than ending, so a scene that merely sits in
         * the blue corner of the gamut can never accumulate 60 s. */
        blue_y0 = y; blue_u0 = u; blue_v0 = v;
        blue_since = SDL_GetTicks();
        return;
    }
    if (blue_secs > 0 &&
        SDL_GetTicks() - blue_since >= (unsigned long)blue_secs * 1000)
        blue_hit = 1;
}

/* A new file is a new question ("has anything played yet?"), so both the run
 * and the seen-a-picture flag start over. */
static void blue_rearm(void)
{
    blue_run = 0;
    blue_seen = 0;
    blue_hit = 0;
}

static void field_commit(void)
{
    if (field_lines <= 0) return;
    int rows = field_lines < 288 ? field_lines : 288;
    int bad = 0;
    int parity = field_F ? 1 : 0;
    if (field_lines < 288) {
        int shortrows = 288 - field_lines;
        if (gap_seams == 1 && gap_seam_row >= 0 && gap_seam_row <= field_lines) {
            /* One hole opened in this field, at row gap_seam_row, and the field
             * ends `shortrows' lines short - which is exactly how many whole
             * lines that hole swallowed.  The pitch cannot say that on its own
             * (removing N whole lines leaves the guard codes 1728 B apart, so
             * they look perfectly regular); the *field length* is the other half
             * of the measurement, and this is where the two are put together.
             *
             * Everything below the seam moves down by `shortrows' rows and the
             * band is filled from the last clean frame's same-parity rows, so
             * the field keeps its geometry and its place in the 50 Hz cadence.
             * Before 2026-11-02 this field was simply thrown away, which the
             * frame gate turns into a repeated picture - a visible hitch.
             *
             * Only a single seam can be located this way; with two the shortfall
             * cannot be divided between them, and the field is held instead. */
            int from = gap_seam_row, n = field_lines - from;
            if (from + shortrows + n <= (int)(sizeof fY / sizeof fY[0])) {
                memmove(fY[from + shortrows], fY[from], (size_t)n * W);
                memmove(fCb[from + shortrows], fCb[from], (size_t)n * (W / 2));
                memmove(fCr[from + shortrows], fCr[from], (size_t)n * (W / 2));
                field_fill_rows(from, shortrows, parity);
                rows = 288;
                gap_repaired++;
                anom_note(SDL_GetTicks(), 'g');
            } else {
                fields_short++; anom_note(SDL_GetTicks(), 'S'); bad = 1;
            }
        } else {
            fields_short++; anom_note(SDL_GetTicks(), 'S'); bad = 1;
        }
    }
    if (parity_mask & (1 << parity)) {
        field_repeat = 1; fields_repeat++; anom_note(SDL_GetTicks(), 'R'); bad = 1;
    }
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
    frame_bad = bad;              /* consumed by hold_update() with this frame */
    if (bad && gate_on && have_good) {
        /* Not clean: show and encode the last frame that was. */
        memcpy(fb, good_fb, sizeof fb);
        memcpy(fuv, good_fuv, UV_SIZE);
        frames_held++;
        anom_note(SDL_GetTicks(), 'H');
        if (++gate_holds >= 50) {
            gate_on = 0;
            fprintf(stderr, "pctv-monitor: frame gate held 50 frames in a row - "
                            "this source has no clean frames, gate off\n");
        }
    } else {
        gate_holds = 0;
        if (gate_on) {
            if (!good_fb) { good_fb = malloc(sizeof fb); good_fuv = malloc(UV_SIZE); }
            if (good_fb && good_fuv) {
                memcpy(good_fb, fb, sizeof fb);
                memcpy(good_fuv, fuv, UV_SIZE);
                have_good = 1;
            }
        }
    }
    frame_ready = 1;
    frames++;
    field_lines = 0;
    gap_seams = 0;
    gap_seam_row = -1;

    /* A frame is complete when both parities are in it (or when one parity
     * arrived twice).  Queue it HERE, where it is born - not from the main loop.
     * The loop's iteration period is 17-28 ms with nothing else going on, and a
     * modal paint, an SSH login or a page-in makes it far longer; one pump()
     * call then parses hundreds of milliseconds of stream and assembles a dozen
     * frames, of which a loop-side feed kept only the *last one*.  That is the
     * "a field goes missing whenever the box is busy" symptom, and it is why
     * none of the buffering in front of it helped: the frame was destroyed after
     * the buffer, not before it.  The main loop still owns cap_start() (it pumps,
     * so it must not run inside the parser) and everything that draws. */
    if (parity_mask == 3 || field_repeat) {
        int stale = (parity_mask != 3) || frame_bad;
        parity_mask = 0;
        field_repeat = 0;
        blue_update();            /* no-content blue screen: once per frame */
        hold_update(frame_bad);   /* end-of-tape detector: once per frame */
        unsigned long t_feed = SDL_GetTicks();
        cap_feed_video(stale);
        unsigned long d = SDL_GetTicks() - t_feed;
        if (d > feed_max_ms) feed_max_ms = d;
    }
}

/* One BT.656 active line, starting right after SAV. */
static void field_line(const unsigned char *act, int xy)
{
    int F = (xy >> 6) & 1;
    int V = (xy >> 5) & 1;
    if (V) return;                        /* vertical blanking, not picture */
    if (field_lines > 0 && F != field_F) {
        if (field_state) {
            /* Spliced across a hole, or missing its head lines after one: throw
             * this field away rather than show/encode a vertically shifted half.
             */
            fields_dropped++;
            anom_note(SDL_GetTicks(), 'D');
            field_lines = 0;
            field_state = (field_state == 1) ? 2 : 0;
        } else field_commit();
    }
    if (field_lines == 0) field_F = F;
    if (field_lines >= FIELD_MAX) return;
    if (field_state) { field_lines++; return; }  /* unusable: count only */
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
/* Bytes since the start of the previous guard code, carried across parse()
 * calls: -1 = no code seen yet (start of stream, or after a resync). */
static long line_pitch = -1;
static void parse_reset(void)
{
    line_pitch = -1;
    field_state = 2;        /* a stream restart begins mid-line: the field in
                             * progress after it is not trustworthy either */
}

/* Fill rows [first, first+count) of the field being assembled with something
 * that belongs there.  The last clean frame's same-parity rows are the right
 * answer (one frame old, same spatial position); with nothing clean to copy,
 * stretch the row above. */
static void field_fill_rows(int first, int count, int parity)
{
    if (count <= 0) return;
    if (first < 0) first = 0;
    if (first + count > FIELD_MAX) count = FIELD_MAX - first;
    for (int r = first; r < first + count; r++) {
        if (have_good && good_fuv) {
            const unsigned char *src = good_fuv + (size_t)(2 * r + parity) * W * 2;
            for (int x = 0; x < W; x++) fY[r][x] = src[x * 2 + 1];
            for (int x = 0; x < W / 2; x++) {
                fCb[r][x] = src[x * 4 + 0];
                fCr[r][x] = src[x * 4 + 2];
            }
        } else if (r > 0) {
            memcpy(fY[r], fY[r - 1], W);
            memcpy(fCb[r], fCb[r - 1], W / 2);
            memcpy(fCr[r], fCr[r - 1], W / 2);
        }
    }
}

/* A guard code arrived at the wrong pitch: `miss` bytes vanished between the two
 * guard codes, which is a whole number of missing lines (a hole that starts and
 * ends inside a line costs no rows - the line is still where it was).
 *
 * Before 2026-11-02 this threw the rest of the field AND the half-built frame
 * away, which is a *repeated picture* - a visible hitch, and 25 of them a second
 * when the USB path is marginal.  The lines that survived are not damaged though:
 * BT.656 numbers them by content, so the only thing a hole costs is *knowing
 * which row each line belongs to*.  The pitch knows exactly: `miss / LINE_BYTES`
 * rows are missing at this point in the field, so advance the row counter by that
 * many and carry on.  The missing rows are filled from the last clean frame, one
 * frame old, in the same spatial position - a 19-row band that is 40 ms stale,
 * against a whole 40 ms picture repeated plus a frame of cadence lost.
 *
 * Only a stream *restart* (parse_reset) still costs fields. */
static void gap_resync(long pitch)
{
    long miss = pitch - (long)LINE_BYTES;
    if (miss <= 0) return;
    gap_bytes += (unsigned long long)miss;
    fields_gap++;
    anom_note(SDL_GetTicks(), 'G');
    if (gap_seams++ == 0) gap_seam_row = field_lines;
    /* The *partial* line this seam proves is lost can be placed by the pitch:
     * miss in (0, 1728) costs no whole row, one whole line costs one.  Whole
     * lines beyond that leave no trace in the pitch at all - they are accounted
     * for at the end of the field, from its length (field_commit). */
    long lines = (miss + LINE_BYTES / 2) / LINE_BYTES;
    if (lines > FIELD_MAX) lines = FIELD_MAX;
    gap_lines += (unsigned long long)lines;
    if (gap_seams > 1) {
        /* Unlocatable: with two holes the shortfall cannot be divided between
         * them, so fall back to advancing by what the pitch says and let the
         * field be held if it still ends short. */
        if (lines <= 0 || field_lines <= 0 || field_F < 0) return;
        int first = field_lines;
        field_lines += (int)lines;
        if (field_lines > FIELD_MAX) field_lines = FIELD_MAX;
        field_fill_rows(first, field_lines - first, field_F ? 1 : 0);
    }
}

/* A candidate guard code closer than one line to the previous *real* one cannot
 * be a line boundary: the pitch is fixed.  It is 0xFF 0x00 0x00 occurring inside
 * active video, which bright, saturated pictures do produce - and treating it as
 * a line resets the pitch and shears every row after it.  Counting that as a
 * `gap' (the pre-2026-11-02 code threw two fields away when it saw one) is what
 * turned a rare false match into a visible repeat.  Ignore the candidate: fall
 * through, keep the pitch running from the last real SAV, and the next real one
 * lands where it should. */
static unsigned long long false_syncs;

static size_t parse(const unsigned char *d, size_t n)
{
    size_t i = 0;
    while (i + 4 + W * 2 <= n) {
        if (d[i] == 0xFF && d[i + 1] == 0x00 && d[i + 2] == 0x00) {
            int xy = d[i + 3];
            if ((xy & 0x10) == 0) {           /* SAV begins the active part */
                if (line_pitch >= 0 && line_pitch < LINE_BYTES) {
                    /* too soon to be a line: a false guard code in the picture */
                    false_syncs++;
                } else {
                    if (line_pitch > LINE_BYTES)
                        gap_resync(line_pitch);   /* keep the field, fix the rows */
                    line_pitch = 0;
                    field_line(d + i + 4, xy);
                    i += 4 + W * 2;
                    line_pitch += 4 + W * 2;
                    continue;
                }
            }
        }
        i++;
        if (line_pitch >= 0) line_pitch++;
    }
    return i;
}

/* Read everything the probe has queued and parse it.  The main loop calls this
 * once per iteration; cap_start() and cap_stop() must call it too while they
 * wait, or nobody drains the pipe, it fills in tens of milliseconds and the
 * probe starts discarding stream data.  Returns 1 if the child died. */
static int pump(void)
{
    int dead = 0;
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
        if (r == 0) { child_stop(); dead = 1; }      /* child died */
        break;                                       /* EAGAIN */
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
        parse_reset();              /* re-hunting for a guard code... */
        field_state = 1;            /* ...and the half-discarded is a hole */
        static unsigned long long sync_drops = 0, last_warn = 0;
        sync_drops++;
        unsigned long long t = SDL_GetTicks();
        if (t - last_warn > 1000) {
            last_warn = t;
            fprintf(stderr, "pctv-monitor: no BT.656 sync in %d B ("
                            "%llu drops total)\n", RBUF / 2, sync_drops);
        }
    }
    return dead;
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
/* `xruns` is per device open (it is zeroed on a reopen, along with the meters).
 * xruns_total is what the stop line reports: a capture that survived four
 * overruns has to say so, because each one is sound that is not in the file. */
static unsigned long long xruns_total = 0;
/* When the most recent clip happened (SDL ticks).  `clips` is a cumulative
 * counter - correct for the readout, wrong for a verdict: one clip at the start
 * of a session would shout TOO HOT for the rest of the run. */
static unsigned long clip_last_t;
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
 * programme's peaks sit at AGC_TARGET_DBFS.  The gain is applied in the
 * hardware, never as a software multiply, so the meter and the recorded file
 * always agree.  Called from the audio thread with amtx held.
 *
 * This is a CALIBRATION loop, not a dynamics processor.  The source level on
 * this wiring moved ~20 dB between two captures an hour apart and drifts slowly
 * within one; that drift is what the loop exists for.  A fast loop would be a
 * compressor: it pulls quiet passages up and ducks loud ones, which is exactly
 * the dynamic range the capture is meant to keep.  So
 *
 *   - the reference is the loudest peak of the last AGC_WINDOW_S seconds, kept
 *     in a ring of per-second maxima and stored in SOURCE units (peak minus the
 *     gain applied when it was measured), so moving the gain never moves the
 *     estimate;
 *   - the target is that peak at AGC_TARGET_DBFS;
 *   - the gain only ever slews at AGC_RATE_DBPS - 0.5 dB/s, so a 20 dB
 *     recalibration takes 40 s and nothing is ever stepped - and inside
 *     AGC_DEADBAND_DB of the target it does not move at all, so a settled
 *     source is left completely alone.
 *
 * One fast path exists and it only ever pulls DOWN: while the signal is at the
 * top of the scale, the gain slews at AGC_EMERG_DBPS toward where THIS peak
 * would sit at the target.  That is damage control for a source measured
 * stepping ~20 dB inside a second, not a way of squeezing the programme;
 * reaching back up is slow again.  A merely loud peak is NOT an emergency - the
 * old loop treated everything above -3 dBFS as one, and that is what made it
 * pump. */
#define AGC_TARGET_DBFS   (-18.0)
/* An error bigger than this is not a level to slew toward, it is a reference
 * that cannot be believed - see agc_tick(). */
#define AGC_MAX_ERR_DB        (24.0)
#define AGC_WINDOW_S           30     /* peak window: "average over ~30 s" */
#define AGC_RATE_DBPS         0.5    /* how fast the calibration may move */
#define AGC_EMERG_DBPS       12.0    /* only while the signal is at full scale */
#define AGC_DEADBAND_DB       0.4
/* A reference peak below this is not programme, it is the noise floor: tape
 * hiss on a paused deck, the ADC's own hiss with nothing connected.  The loop
 * holds still for one instead of treating it as a level to correct - see the
 * cold-start note in agc_tick(). */
#define AGC_SIGNAL_MIN_DBFS  (-50.0)
/* Full-scale latch: a post-gain peak this close to 0 dBFS is a clip even when
 * no sample lands exactly on the rail, and it stays an emergency for
 * AGC_HOT_MS after the last one. */
#define AGC_HOT_DBFS         (-1.0)
#define AGC_HOT_MS            500
/* No sane line-level source needs more than this, and past it the loop is only
 * amplifying its own noise floor. */
#define AGC_MAX_TOTAL_DB      36.0

static double agc_win_pk = -99.0;      /* peak since the last tick */
static double agc_slot_pk = -99.0;     /* peak of the current 1 s slot */
static double agc_ring[AGC_WINDOW_S];  /* per-second peaks, source dBFS */
static int    agc_slot, agc_ring_ready;
static unsigned long agc_slot_t, agc_last_t;
static double agc_slow_src = -99.0;    /* the ring's max: the reference peak */
static double agc_acc;                 /* dB not yet a whole mixer step */
static double agc_hot_pk = -99.0;      /* the peak that latched full scale */
static unsigned long agc_hot_t;        /* when it did */

/* Forget the calibration: a different input, or the loop switched back on. */
static void agc_reset(void)
{
    agc_win_pk = agc_slot_pk = agc_slow_src = -99.0;
    agc_slot = 0; agc_ring_ready = 0; agc_slot_t = agc_last_t = 0;
    agc_acc = 0.0;
    agc_hot_pk = -99.0; agc_hot_t = 0;
}

/* AGC lines are worth about one a second, and a flood of them is worth nothing:
 * a fresh session re-settles by tens of dB, and a measured clip puts the loop
 * into its emergency slew, which is ~10 log lines a second printing over the
 * frame counters that a capture is actually diagnosed with (that console flood
 * during a live tape, 2026-11-01, is the reason this exists).  The controller's
 * actions are untouched - only the printing is rate limited, with a count of
 * what it swallowed. */
#define AGC_LOG_MS 1000
static void agc_log(const char *fmt, ...)
{
    static unsigned long last_t;
    static int suppressed;
    unsigned long t = SDL_GetTicks();
    if (last_t && t - last_t < AGC_LOG_MS) { suppressed++; return; }
    if (suppressed) {
        fprintf(stderr, "pctv-monitor: AGC: (%d more gain move%s, %lus)\n",
                suppressed, suppressed == 1 ? "" : "s", (t - last_t) / 1000);
        suppressed = 0;
    }
    last_t = t;
    fputs("pctv-monitor: AGC: ", stderr);
    va_list ap;
    va_start(ap, fmt);
    vfprintf(stderr, fmt, ap);
    va_end(ap);
    fputc('\n', stderr);
}

/* Trade one step of the coarse input boost for room in the fine Capture
 * volume, and compensate with the fine stage in the same breath so the TOTAL
 * gain does not move.  The old code re-seated the fine stage at a fixed
 * 60 %/40 % of its range, which jumped the gain by tens of dB in one instant -
 * the one place a slow loop could still make an audible step. */
static void stage_boost(int dir, double keep_total, double spdb)
{
    long blo, bhi;
    snd_mixer_selem_get_capture_volume_range(el_boost, &blo, &bhi);
    if (dir > 0 && boost_val >= bhi) return;
    if (dir < 0 && boost_val <= blo) return;
    snd_mixer_selem_set_capture_volume_all(el_boost, boost_val + dir);
    audio_apply_controls();              /* refresh boost_db / gain_db / cap_val */
    long v = cap_lo + lround((keep_total - boost_db - cap_db_lo / 100.0) * spdb);
    if (v > cap_hi) v = cap_hi;
    if (v < cap_lo) v = cap_lo;
    snd_mixer_selem_set_capture_volume_all(el_cap, v);
    audio_apply_controls();
    agc_acc = 0.0;
    agc_log("staging, boost %s -> total %+.1f dB (capture %+.1f, boost %+.1f)",
            dir > 0 ? "up" : "down", gain_db + boost_db, gain_db, boost_db);
}

static void agc_tick(double win_pk, unsigned long long clips_now)
{
    static unsigned long long last_clips;
    unsigned long t = SDL_GetTicks();
    double pk = agc_win_pk;
    agc_win_pk = -99.0;

    if (!el_cap || cap_hi <= cap_lo) {
        if (getenv("PCTV_AGC_DEBUG"))
            fprintf(stderr, "agc: no capture element (el_cap=%p range %ld..%ld)\n",
                    (void *)el_cap, cap_lo, cap_hi);
        last_clips = clips_now; agc_last_t = t; return;
    }
    double dt = agc_last_t ? (double)(t - agc_last_t) / 1000.0 : 0.05;
    agc_last_t = t;
    if (dt <= 0.0 || dt > 5.0) dt = 0.05;
    double spdb = (cap_db_hi > cap_db_lo)
        ? (double)(cap_hi - cap_lo) / ((double)(cap_db_hi - cap_db_lo) / 100.0)
        : 1.0 / 0.75;   /* fallback if the dB query ever fails: this ALC889's
                         * Capture volume moves 0.75 dB per step.  Measured on
                         * this box it does report its range - 46 steps over
                         * 46 dB, so spdb = 1.00 and gain_db is exact. */

    if (!agc_ring_ready) {
        for (int i = 0; i < AGC_WINDOW_S; i++) agc_ring[i] = -99.0;
        agc_slot = 0; agc_slot_t = t; agc_ring_ready = 1;
    }

    /* Close a second of measurement, in source units, and re-read the window. */
    if (pk > agc_slot_pk) agc_slot_pk = pk;
    if (t - agc_slot_t >= 1000) {
        double total = gain_db + boost_db;
        agc_ring[agc_slot] = (agc_slot_pk > -90.0) ? agc_slot_pk - total : -99.0;
        agc_slot = (agc_slot + 1) % AGC_WINDOW_S;
        agc_slot_pk = -99.0;
        agc_slot_t = t;
        double m = -99.0;
        for (int i = 0; i < AGC_WINDOW_S; i++)
            if (agc_ring[i] > m) m = agc_ring[i];
        agc_slow_src = m;
    }

    long clip_delta = (long)(clips_now - last_clips);
    last_clips = clips_now;
    double total = gain_db + boost_db;

    /* Seed the window with the first real measurement instead of making the
     * loop sit out its first slot (and then slew from a reference that is only
     * one second of programme).  The window fills second by second after this,
     * so the slew is still driven by the loudest recent peak, not by one block.
     * The codec's dB query fails on this chip (see spdb above), so "total" is
     * then a step count, not dB - only trust the seed once the units agree. */
    if (agc_slow_src <= -90.0 && pk > -90.0 && fabs(total) < 45.0)
        agc_slow_src = pk - total;

    double want;
    /* A reference the loop is allowed to believe.  Below AGC_SIGNAL_MIN_DBFS it
     * is the noise floor and there is nothing to calibrate: slewing UP there is
     * how a session that started on a paused deck reached +49 dB, and the first
     * frame of real programme was then 30-40 dB hot, clipped for the 30 s the
     * loop needs to walk back down (measured on the 2026-11-02 13:15 capture:
     * 4575 clipped samples in second 0, then 37 dB of ramp over the minute).
     * Hold the gain where it is and wait for programme. */
    if (agc_slow_src <= AGC_SIGNAL_MIN_DBFS) want = total;
    else want = AGC_TARGET_DBFS - agc_slow_src;
    if (want > AGC_MAX_TOTAL_DB) want = AGC_MAX_TOTAL_DB;

    /* The fast path is for the signal being at the top of the scale and nothing
     * else.  It used to key off the ADC's clip counter, which misses the case
     * that actually hurts: the staging can be 40 dB hot with that counter at
     * zero for seconds at a time (the counter only sees samples that land on
     * the rail), and then the loop is back at 0.5 dB/s.  A post-gain peak
     * within a dB of full scale is a clip; latch it briefly so one loud
     * transient does not fall out of the window between two ALSA periods. */
    if (pk >= AGC_HOT_DBFS) { agc_hot_pk = pk; agc_hot_t = t; }
    int emerg = (agc_hot_t && t - agc_hot_t <= AGC_HOT_MS) || clip_delta > 0;
    if (emerg) {
        double want_now = AGC_TARGET_DBFS - (agc_hot_pk - total);
        if (want_now < want) want = want_now;  /* the fast path only pulls down */
    }

    double err = want - total;
    static unsigned long dbg_t;
    if (getenv("PCTV_AGC_DEBUG") && t - dbg_t > 5000) {
        dbg_t = t;
        fprintf(stderr, "agc: pk %.1f slow %.1f total %+.1f want %+.1f err %+.3f "
                        "acc %+.3f cap %ld/%ld..%ld spdb %.2f emerg %d muted %d "
                        "clips %ld\n",
                pk, agc_slow_src, total, want, err, agc_acc, cap_val, cap_lo, cap_hi,
                spdb, emerg, cap_muted, clip_delta);
    }
    if (!emerg && fabs(err) < AGC_DEADBAND_DB) err = 0.0;
    /* Tens of dB of error does not mean "slew hard", it means the reference is
     * not trustworthy.  A capture stream that is starved, or shared with a
     * second reader, measures digital silence; the loop then decides it is
     * 50 dB short and hunts at full tilt - logging a line per step the whole
     * way, which is what filled the console during a capture.  Freeze instead,
     * and say so once. */
    static int insane;
    if (!emerg && fabs(err) > AGC_MAX_ERR_DB) {   /* emerg is measured, not modelled:
                                                   * a clip is a fact whatever the
                                                   * reference says */
        if (!insane)
            fprintf(stderr, "pctv-monitor: AGC: %.0f dB off target with a %.0f dBFS "
                            "peak - ignoring that reference (no audio, or another "
                            "program is reading the capture device)\n", err, pk);
        insane = 1;
        agc_acc = 0.0;
        return;
    }
    insane = 0;
    double lim = (emerg ? AGC_EMERG_DBPS : AGC_RATE_DBPS) * dt;
    if (err >  lim) err =  lim;
    if (err < -lim) err = -lim;
    if (err == 0.0) return;

    /* Staging: the Capture volume is the fine stage and the input boost the
     * coarse one.  When the fine stage runs out of room in the direction the
     * loop wants to go, trade a boost step for room in it - compensated, so the
     * total never jumps. */
    if (el_boost) {
        if (err < 0.0 && cap_val <= cap_lo)
            stage_boost(-1, total, spdb);
        else if (err > 0.0 && cap_val >= cap_hi)
            stage_boost(+1, total, spdb);
        /* Make room in the stage the loop is about to run OUT of, not the one
         * it is comfortably inside: while attenuating and approaching its
         * floor, give up a boost step so the level sits mid-range again.  This
         * was tested against `err > 0` - firing while the loop wanted MORE
         * gain - so the next tick bought the step back and both logged. */
        else if (err < 0.0 && cap_val < cap_lo + (cap_hi - cap_lo) / 5)
            stage_boost(-1, total, spdb);
    }

    /* Slew, never step: accumulate the dB and apply whole mixer steps only when
     * they add up, so 0.5 dB/s on a 1 dB/step codec moves once every 2 s. */
    agc_acc += err;
    long dsteps = lround(agc_acc * spdb);
    if (dsteps == 0) return;
    agc_acc -= (double)dsteps / spdb;

    long v = cap_val + dsteps;
    if (v > cap_hi) v = cap_hi;
    if (v < cap_lo) v = cap_lo;
    if (v == cap_val) { agc_acc = 0.0; return; }
    snd_mixer_selem_set_capture_volume_all(el_cap, v);
    snd_mixer_selem_set_capture_switch_all(el_cap, 1);
    audio_apply_controls();
    agc_log("peak %.1f dBFS, %d s max %.1f dBFS source -> total %+.1f dB "
            "(capture %+.1f, boost %+.1f)",
            pk, AGC_WINDOW_S, agc_slow_src, gain_db + boost_db, gain_db, boost_db);
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
            /* 60 ms of target latency, not the 20 ms this used to ask for: the
             * ALSA read period is what an overrun costs, and an overrun is lost
             * *samples*.  The PCM thread now never blocks on the encoder (it only
             * copies into a 5.5 s ring), so the only thing that can still make it
             * miss is this buffer being too small to survive a scheduling hiccup
             * on a 2-core box.  It costs latency on the `o' monitor path, not
             * sync: the capture writes what it reads, and the video is paced off
             * the same byte count. */
            ep = snd_pcm_set_params(*pcm, SND_PCM_FORMAT_S16_LE,
                                    SND_PCM_ACCESS_RW_INTERLEAVED, 2, rates[r],
                                    1 /* allow format/rate change */, 60000);
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

/* ---- the hole detector: is the ADC delivering as much *time* as it delivers? */
/* Whether a capture is running: a hole in the sound only costs a tape anything
 * while one is.  Published here because the ALSA thread sits a thousand lines
 * above the capture section that owns cap_on. */
static volatile int cap_live = 0;
static unsigned long long a_anchor_us;    /* wall clock when this reckoning started */
static unsigned long long a_content_us;   /* audio time actually delivered since then  */

#define A_GAP_MIN_MS 60       /* one ALSA period: below this it is jitter, not a hole */
#define A_GAP_MAX_MS 2000     /* never invent more than 2 s of silence for one hole */

static unsigned long long mono_us(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (unsigned long long)ts.tv_sec * 1000000ull +
           (unsigned long long)ts.tv_nsec / 1000ull;
}

static void *audio_thread(void *arg)
{
    (void)arg;
    /* Above the parser/renderer: this thread's whole cushion is one ALSA period
     * (60 ms), and an overrun is lost *samples* - which no ring further down the
     * path can reconstruct.  Everything else on the path has seconds. */
    pctv_thread_prio("pctv-monitor/audio", 9);
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
            agc_reset();          /* a new device is a new calibration */
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
            agc_reset();
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
            pthread_mutex_lock(&amtx); xruns++; xruns_total++; audio_ok = 1;
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

        /* The device can lose sound without anyone reporting it: an overrun
         * (snd_pcm_recover() drops the samples and says nothing), a device
         * reopen, a PipeWire graph restart, or this thread simply not being run
         * for a while.  Not one of them is a "drop" any counter can see, and the
         * card does not care - it keeps delivering pictures, so the file's video
         * timeline runs on while the sound behind it is shorter.
         *
         * Two counters say when that has happened, in the only unit precise
         * enough: audio time actually delivered against wall time elapsed since
         * the same anchor.  They are equal while the device is healthy, and the
         * difference is exactly the sound that has gone missing.  Milliseconds
         * cannot be used: a block is 21.33 ms of sound and rounding it to 21 ms
         * invents 15 ms of hole every second, so this is microseconds and sample
         * arithmetic.  Nothing is invented while capture is off (the deck may be
         * stopped, the ALSA thread may be idle, and none of it is a hole).
         *
         * What happens on finding a hole matters more than finding it.  The hole
         * used to be paid for by the resampler, which cannot see holes - it only
         * sees the input arriving slower than the pictures owe, and squeezes the
         * *rest of the tape* to match.  That is how a momentary dropout became the
         * 2026-11-04 master being over a second out of step and staying there:
         * the debt was spread over the remaining 90 minutes instead of sitting
         * where the dropout was.  So the hole is now filled with silence at the
         * instant it happened, the sound that survives stays exactly where the
         * picture is, and the stop line says what it cost. */
        unsigned long long w = mono_us();
        if (!cap_live || !a_anchor_us || audio_rate <= 0) {
            a_anchor_us = w;              /* not recording: nothing here is late for anything */
            a_content_us = 0;
        } else {
            a_content_us += (unsigned long long)r * 1000000ull /
                            (unsigned long long)audio_rate;
            long long hole = (long long)(w - a_anchor_us) - (long long)a_content_us;
            if (hole >= (long long)A_GAP_MIN_MS * 1000) {
                if (hole > (long long)A_GAP_MAX_MS * 1000)
                    hole = (long long)A_GAP_MAX_MS * 1000;
                size_t hf = (size_t)((unsigned long long)hole *
                                     (unsigned long long)audio_rate / 1000000ull);
                cap_feed_silence(hf);
                a_content_us += (unsigned long long)hf * 1000000ull /
                                (unsigned long long)audio_rate;
                fprintf(stderr, "pctv-monitor: %d ms of PCM never arrived (overrun,"
                                " reopen or a scheduling hole) - %d ms of silence"
                                " written in its place so the sound stays on the"
                                " picture\n",
                        (int)(hole / 1000), (int)(hole / 1000));
            }
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
        if (cl) { clips += cl; clip_last_t = SDL_GetTicks(); }
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

/* =========================================================== capture path
 *
 * Two streams go to ffmpeg: deframed UYVY on stdin as rawvideo, the ALSA PCM on
 * fd 3 as s16le, muxed into the MPEG-PS or Matroska the chosen `--master` mode
 * asks for.  Whoever produces data only ever copies it into a ring; ONE writer
 * thread owns every blocking write to ffmpeg's two pipes, so neither the display
 * loop nor the ALSA thread can ever be held up by an encoder or a disk.
 *
 * Pacing is the subtle part, and the design before 2026-11-01 got it wrong in
 * both directions (measured in docs/pctv-320cx.md, "capture cadence"):
 *
 *   - The card supplies 25.00 frames/s on ITS clock (CX25843 at 13.5 MBaud,
 *     1728 B/line, 625/50).  The host clock is a different crystal, and this
 *     loop's iteration period is 17-28 ms - half a frame.
 *   - The encoder used to be fed by polling the single `fuv` buffer from the
 *     main loop whenever 40 ms of *host* time had passed.  A poll can only find
 *     the buffer unchanged (so it writes a duplicate: "the picture drags") or
 *     find two arrivals since the last poll (so one picture is overwritten
 *     before it was ever written: "the picture catches up") - and the second
 *     direction was counted nowhere at all.  A 120 s capture of a real tape
 *     measured 2991 frames written, 374 of them duplicates and ~375 never
 *     written; the 2 h tape that started the investigation is 2.376 s of video
 *     short of its own audio track, i.e. 59 lost frames and a lip-sync error
 *     grows toward a second across the tape.
 *   - Now a frame enters the queue the moment it is assembled (arrival driven:
 *     every frame exactly once, nothing can be overwritten) and the writer
 *     thread *pops* it on a clock.  The queue is a phase buffer, so a late pop
 *     costs nothing: a duplicate or an eviction now means the card and the host
 *     disagree by a whole frame, not that a loop iteration landed on the wrong
 *     side of a deadline.
 *   - That clock is the CARD (since 2026-11-02): a queued picture goes to
 *     ffmpeg the moment it exists, so the file's cadence is the field cadence
 *     and no difference between the two crystals can evict a picture.  The wall
 *     clock is only a watchdog for a source that stopped producing any (paused
 *     deck, input switch, dead card), and the audio is resampled onto the
 *     picture's timeline (rs_run/rs_update below) - the two tracks are the same
 *     length by construction and the pitch shift that buys it is 0.23 cents at
 *     the 135 ppm this box measures.
 *   - And since 2026-11-04 the audio is written ONLY as part of committing a
 *     picture (see a_make_chunk/a_flush): one picture is 829440 video bytes
 *     followed by 7680 audio bytes (40 ms), or nothing.  Nothing else appends
 *     to the audio pipe, so a whole class of desync became structurally
 *     impossible.  Until that day the audio drained on its own schedule, real
 *     time against a video track that lags real time by however deep the
 *     picture queue is - and a slow sink (NFS at 13:2x on 2026-11-04: a
 *     ~25-frame backlog) made the sound arrive a second early across an
 *     entire take while both track lengths, and therefore the phase figure,
 *     stayed perfect.  With one commit writing both halves, whatever the two
 *     streams are behind - queue, pipes, a stalled muxer - they are behind by
 *     the SAME frames, so they cannot drift apart; the crystals are handled by
 *     the resampler (flow term) and the only content errors left are holes in
 *     the PCM, which the phase term (ring backlog against queue backlog) pays
 *     back at <= RS_PPM_MAX.  The old PCTV_CLOCK=audio mode ("let the audio
 *     byte count pace the picture") is gone with this: that is now the only
 *     mode there is.
 *   - Consequence for policy: a duplicated frame (source stopped) is the file
 *     staying at 25 fps in WALL time, so the sound over it is the live sound
 *     of that moment - a paused deck is a still picture with the room's hum
 *     under it, exactly as on the tape.  The pre-2026-11-04 design cut 40 ms
 *     of audio per duplicate AND per gate-held frame on the theory that those
 *     frames "were not on the tape"; they were - the picture was lost, the
 *     sound was not, and cutting the sound made every tracking failure walk
 *     the audio ahead of the video by 40 ms a step.  Cut nothing; the queue
 *     does the aligning now.
 */

static char ffmpeg_path[4096] = "ffmpeg";
static pid_t cap_pid = -1;
static int   cap_vfd = -1, cap_afd = -1;
static int   cap_on = 0, cap_has_audio = 0;
static char  cap_path[512];
static unsigned long long cap_vframes = 0, cap_vdrops = 0, cap_adrops = 0;
static unsigned long long cap_abytes = 0, cap_adrop_bytes = 0;
/* Silence written in place of PCM that never arrived (an ALSA overrun, a device
 * reopen, a PipeWire graph restart, this thread not being scheduled).  That
 * sound is gone; the only question is who pays for it.  Letting the resampler
 * pay turns a 0.5 s hole at 20:00 into a 0.5 s lip-sync error over the whole of
 * the rest of the tape, so the hole is filled with silence where it actually
 * is, and this counter says how much of the tape that cost.  Reported at stop. */
static unsigned long long cap_a_silence_bytes = 0, cap_a_gaps = 0;
/* dup = re-sent because nothing new had arrived, skip = queued frame evicted
 * because the writer had not popped it.  Both are whole-frame events with a
 * cause now, and both are on screen: they are the two halves of what used to be
 * invisible. */
static unsigned long long cap_vrepeats = 0, cap_vskips = 0;
/* Pictures the queue refused.  With eviction gone this can only start counting
 * after the queue is already full and the capture is on its way out, so a
 * nonzero value means "the file ends here, on purpose, and this many pictures
 * of tape after that point were not recorded".  It is printed in the summary
 * line for exactly that reason. */
static unsigned long long cap_vrefused = 0;
static int vq_want_stop;        /* queue full: the main loop ends the capture */
static int vq_warned;           /* the 3/4-full warning has been printed */
static int cap_qmax = 0;                  /* video queue high-water, in frames */
static time_t cap_t0 = 0;
static unsigned long cap_t0_tick = 0;     /* SDL ticks, for a smooth REC counter */
static int cap_pending = 0;               /* `c' pressed, waiting for the first frame */
static pthread_mutex_t cap_mtx = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t cap_cv = PTHREAD_COND_INITIALIZER;
static int cap_refs = 0, cap_closing = 0;
/* One lock and one condition variable for BOTH capture rings (audio below, video
 * below): the writer thread waits on this one cv for either kind of work. */
static pthread_mutex_t vq_mtx = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t  vq_cv = PTHREAD_COND_INITIALIZER;
/* Two pieces of writer state defined before the audio ring because rs_update()
 * - the clock estimator - reads the DEPTH OF BOTH BACKLOGS as one atomic pair
 * (E = queue_ms - ring_ms); the queue itself lives in the video section. */
#define FRAME_MS 40                    /* 25 fps, and the file's fixed timebase */
static int vq_head, vq_count;          /* frames queued, excluding the one held */

/* Locking rule for the two capture locks: vq_mtx guards the two rings, cap_mtx
 * guards the fds and the statistics.  Never take cap_mtx while holding vq_mtx:
 * every statistics update in the writer takes them in that order (vq first,
 * released, then cap), and rs_update() - which reads the queue depth under
 * vq_mtx from the writer thread - is deliberately called with no cap_mtx held. */

/* Take the capture fds for one write.  The lock is NOT held during the write
 * itself: a stalled encoder must never be able to block whoever holds it -
 * that would stall the writer, which is the only thing draining both rings. */
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
    cap_on = 0; cap_live = 0;      /* feeds stop; cap_stop() reaps the child */
    pthread_mutex_unlock(&cap_mtx);
    if (was) fprintf(stderr, "pctv-monitor: encoder went away, capture stopped\n");
}

/* Write a buffer without ever sitting in the kernel.  Both pipe ends are
 * O_NONBLOCK, so this either gets the bytes into the pipe or reports what it
 * could not deliver - and that matters more than it looks: a blocking write()
 * here is unkillable (the encoder decides when it returns), which used to turn a
 * stuck ffmpeg into a monitor that could not finish stopping a capture, and a
 * writer thread that cannot finish means cap_stop() never closes the pipes and
 * nothing downstream ever sees EOF.
 *
 * *done reports how much reached the pipe, so a caller with fixed-size frames
 * can resume where it stopped: rawvideo has no framing of its own, so a half
 * written frame is not a lost frame, it is a corrupted stream (ffmpeg answers it
 * with "Error submitting packet to decoder: Invalid argument" and everything
 * after it is shifted).  Returns 0 = complete, -1 = the reader is gone, -2 = it
 * did not drain in time (retry). */
static int pipe_write(int fd, const void *p, size_t n, int msecs, size_t *done)
{
    if (done) *done = 0;
    if (fd < 0 || !n) return -1;
    const unsigned char *b = p;
    struct pollfd pf = { .fd = fd, .events = POLLOUT | POLLERR | POLLHUP };
    while (n) {
        ssize_t w = write(fd, b, n);
        if (w > 0) { b += w; n -= (size_t)w; if (done) *done += (size_t)w; continue; }
        if (w < 0 && errno == EINTR) continue;
        if (!(w < 0 && (errno == EAGAIN || errno == EWOULDBLOCK))) return -1;
        if (poll(&pf, 1, msecs) <= 0) return -2;                  /* still stalled */
        if (pf.revents & (POLLERR | POLLHUP)) return -1;          /* reader gone */
    }
    return 0;
}

/* ---- audio queue -------------------------------------------------------
 * The ALSA thread used to write to ffmpeg itself with a non-blocking fd and
 * count an `audio drop' on EAGAIN.  s16le is self-synchronising on 2-byte
 * boundaries, so that only lost the samples in flight - which is exactly how a
 * long tape ends up with audio and video tracks of different lengths, quietly.
 * Now the PCM callback only copies.  Bytes are released only once they are in
 * the pipe, and the eviction below can never eat what is in flight.
 *
 * What changed on 2026-11-04: the ring holds the RAW ADC frames, not the
 * resampled ones.  Resampling moved to the drain side (a_make_chunk), because
 * the writer thread now owns the timeline: a picture and the 40 ms of sound
 * over it leave the ring together or not at all, and the resampler runs at
 * that moment, at the ratio the phase measurement (E, in rs_update) calls for.
 * Raw in here also means the two soft seams a capture hole needs (fade down
 * into the invented zeros, fade up out of them) can live in the sample domain
 * the ALSA thread actually has - and linear resampling cannot damage them,
 * because a linear map of a fade is the same fade. */
/* Sizing: the old 1 MiB (5.5 s) was the ceiling ffmpeg's matroska muxer
 * imposed - its 10 s interleave limit, against which a backlog of EITHER
 * untimestamped stream IS a divergence (measured 2026-11-02: with an 8 MiB
 * ring, a 12 s encoder freeze left ffmpeg consuming nothing for 24 s after it
 * resumed, and the file ended with a hole - although the write path itself was
 * never the limit: 123 MB/s sustained to the NAS against 21 MB/s needed).  That
 * ceiling stopped applying the moment one commit began writing both halves: the
 * muxer now sees the two streams advance in lockstep, exactly 40 ms a step,
 * whatever the sink is doing behind the writer.  So the ring is sized by its
 * actual job - holding the sound belonging to the deepest the picture queue can
 * legitimately be (VQ_SLOTS_SINK: 150 frames = 6 s of sink stall) plus cushion
 * - and 4 MiB = 21 s is comfortably that.  Under the old design a 6 s queue
 * meant 6 s of audio parked inside a 5.5 s ring: the audio-ring eviction and
 * the full picture queue were the same event waiting to happen. */
#define AQ_BYTES (4u << 20)
#define AQ_SECONDS ((double)AQ_BYTES / 192000.0)
static unsigned char *aq;
static size_t aq_head, aq_count, aq_sent;  /* aq_sent = reserved, being written */
/* The spill backlog, in records and in their un-restored sound bytes.  They
 * live with the ring's counters because that is where they are spent
 * (rs_update) as well as earned (spill_append), and rs_update runs long
 * before the spill section itself. */
static unsigned long long sp_count, sp_sound;
/* Raw frames the ADC has actually delivered this take, silence fill excluded.
 * rs_update() windows THIS against the frames committed - arrivals against
 * arrivals - so the writer's own draining cannot bias the crystal estimate
 * the way the old consumed-samples figure did.  Guarded by vq_mtx. */
static unsigned long long aq_raw_frames;
/* Raw-domain seam state for the hole filler: aq_last_raw is the last real
 * sample pair to enter the ring (so a hole's fade-down starts from where the
 * sound actually was, not from nothing), and aq_fsin counts the raw frames
 * still owed a fade-up where sound comes back.  The ALSA thread is the only
 * writer of both, and aq_reset() (main thread, between takes) takes vq_mtx,
 * which every path that touches the ring holds - the pre-2026-11-04 aq_reset()
 * raced aq_push() by a hair; this one does not. */
static short aq_last_raw[2];
static unsigned int aq_fsin;
static volatile int aq_closed;            /* drain in progress: refuse more */
static volatile int vq_stopping;        /* stop requested, drain running */
/* The picture queue is more than a quarter deep: the sink is behind the tape.
 * Set by the producer (25 Hz, under the queue lock).  Since 2026-11-04 this is
 * diagnostics only - rs_update() measures over a window and skips a window with
 * no pictures in it, which is the precise version of what freezing on this flag
 * used to guess at (see the note there for the minutes-at-a-time it was
 * freezing the clock for on NFS). */
static volatile int vq_backlog;
/* When a stop was requested, how long the writer may keep trying to push what
 * is already queued before it is allowed to give up on it. Sized from the
 * backlog (a stalled sink needs about the time the pictures took to arrive);
 * 30 s of grace on top covers a normal quit, where the queue is empty and the
 * drain finishes immediately. */
static unsigned long vq_drain_deadline;
static unsigned long long vq_drain_dropped;
/* The drain gives up on a sink that has stopped taking BYTES, not on one that is
 * merely slow.  A wall-clock deadline alone was wrong: quitting while ffmpeg was
 * SIGSTOPped sat out the whole 30 s + 100 ms/frame grace on a window that had
 * stopped responding at all, which looks exactly like the 2026-11-02 quit lockup
 * from the outside.  Only a QUIT cuts it short though (see the writer): a stalled
 * sink that nobody walked away from keeps its grace and delivers its backlog, and
 * that is 148 pictures of tape worth waiting for. */
#define VQ_DRAIN_STALL_MS 3000u
static unsigned long vq_progress_ms;
/* The drain has given up: discard both rings instead of writing them.  Set once
 * the sink is judged wedged, cleared when the next capture starts. */
static volatile int vq_abandon;

static void aq_reset(void)
{
    pthread_mutex_lock(&vq_mtx);
    aq_head = aq_count = aq_sent = 0;
    aq_raw_frames = 0;
    aq_last_raw[0] = aq_last_raw[1] = 0;
    aq_fsin = 0;
    aq_closed = 0;
    pthread_mutex_unlock(&vq_mtx);
}

/* bytes of s16le stereo per millisecond at the negotiated rate (192 at 48 kHz);
 * also the divisor that turns "bytes written" into "the file's audio time" */
static unsigned long long aq_bytes_per_ms(void)
{
    return (unsigned long long)audio_rate * 2u * 2u / 1000ull;
}

/* ---- audio resampler: the audio track is made to fit the video track -----
 *
 * The two streams come from two crystals.  The card's 25 fps is derived from
 * the incoming video signal (15625 lines/s), the audio is the host codec's ADC
 * clocked by its own crystal, and the two differ by 100-300 ppm on this box
 * (measured: 59.328 s of audio against 59.320 s of video in a 60 s capture, i.e.
 * +135 ppm, which is 1.3 s over a two-hour tape).
 *
 * There are only two ways to reconcile them.  The one that was here until
 * 2026-11-02 paced the *video* on the audio byte count, so the file's audio was
 * exact and the picture paid: a frame was duplicated or evicted every time the
 * difference accumulated to 40 ms - a visible hitch every few minutes, and it
 * is the picture's smoothness that this whole program exists to protect.
 *
 * So the direction is reversed.  The picture is the clock (see the video writer
 * below: a queued frame goes out immediately, so the file's cadence is the
 * card's own).  The audio is resampled by the measured ratio instead, which
 * costs a 135 ppm pitch shift - 0.23 cents, roughly a sixty-fifth of the
 * smallest interval anyone can hear - and in exchange the two tracks are the
 * same length by construction and no clock difference can ever touch a frame.
 *
 * The measurement is windowed and smoothed, so it cannot chase jitter: each
 * window compares raw samples the ADC delivered against what the pictures
 * committed in the same window owe (see rs_update - since 2026-11-04 it must
 * be measured over arrivals, because the drain itself is the resampler and
 * reading the drain would be an instrument wired to its own output), and a
 * phase term E = queue depth - ring depth spends any measured disagreement
 * back over RS_DRAIN_S seconds instead of leaving it in the tape.  Linear
 * interpolation is ample at this ratio (the error of linear interpolation at
 * Nyquist is -40 dB at 1000 ppm and this is a 4th of that, on a tape's audio).
 */
/* Drain-side scratch: rs_run_into() wants contiguous samples and the ring is
 * circular, so a_make_chunk() linearises up to this many RAW frames into
 * rs_buf per pass; the ring hands over ALSA blocks of >= 1024 frames, and
 * 4096 covers a commit's whole demand (1920 frames at 48 kHz) in one pass. */
#define RS_MAX_OUT 4096
static short  rs_buf[RS_MAX_OUT * 2];
/* The restored-record stub of the drain's input stream: when a spilled pair
 * comes back from disk its sound lands here, and a_make_chunk() reads this
 * before the ring, so the two together stay ONE contiguous byte stream for
 * the resampler (the queue was never allowed to reorder the sound, and the
 * spill file therefore never has to either).  Sized for two records at the
 * widest supported rate because step < 1 means a commit can leave a residue
 * of the previous record here, and the next restore must not overwrite it -
 * that residue is the first samples of the next commit's chunk.  Writer
 * thread only, which is why it needs no lock and no reservation protocol.
 * The number is 40 ms of audio at 205 kHz plus a residue's worth, i.e. the
 * same ceiling A_CHUNK_MAX puts on a chunk's frame count (checked against
 * the negotiated rate at spill activation, not by a macro dependency). */
#define SPILL_AUDIO_MAX (8192u * 4u + 1024u)
#define RS_FRONT_MAX (2u * SPILL_AUDIO_MAX)
static unsigned char rs_front[RS_FRONT_MAX];
static size_t rs_front_len, rs_front_pos;    /* bytes live, bytes consumed */
static double rs_prev[2];               /* last input frame, held between calls */
static int    rs_have;
static double rs_frac;                  /* position between rs_prev and the next */
static volatile double rs_step = 1.0;   /* input frames per output frame */
static int rs_seeded;                   /* a measured window has set the step
                                         * (the first one jumps to the target,
                                         * see rs_update) */
static unsigned long long rs_out_frames;  /* audio frames actually reached the file */
/* Of those, the frames the ring could not cover and the commit therefore padded
 * with soft silence (rs_pad_into): an UNDETECTED hole in the PCM - sound that
 * vanished without the gap detector noticing, a dead device between cap_start
 * and the first PCM.  Distinct from cap_a_silence_bytes (detected holes, zeros
 * already ramped into the ring): both reach the tape ramped, only this one
 * means the drain ran dry. */
static unsigned long long rs_pad_frames;
static unsigned long long rs_vframes;     /* pictures actually committed */
static int    rs_ppm_logged;
static int    rs_phase_logged;          /* the same idea for the phase error */
static unsigned long rs_last_update;
/* Window baselines: see rs_update.  The arrivals side counts the RAW samples
 * the ADC delivered into the ring (aq_raw_frames): since 2026-11-04 the
 * resampler runs at the drain, so a flow term measured over what the resampler
 * consumed would just be reading back the step it set itself. */
static unsigned long long rs_raw_win, rs_v_win;
static short  rs_last_out[2];           /* last pair emitted: the edge of a fade */
/* The output-domain fade-up as a continuous envelope: gain starts where a pad's
 * fade-down left it (a pad SHORTER than RS_RAMP ends mid-ramp, and restarting
 * the ramp at 1/96 there would be an envelope step - a soft-sounding click) and
 * walks up to 1.0 over the frames still owed.  1.0 = no ramp running. */
static double rs_gain = 1.0, rs_gain_step;
static volatile int rs_phase_ms;        /* what the tracks disagree by, right now */
static unsigned long long rs_bad_windows;  /* windows too far off to be a crystal */
static int rs_bad_logged;               /* rate limiter for that one message */

#define RS_RAMP      96                 /* 2 ms at 48 kHz: the fade on a silence seam */
#define RS_DRAIN_S   120.0              /* seconds given to paying a phase error back */
#define RS_PPM_MAX   3000               /* the most resampling ever applied (0.3 %) */
/* A window whose flow reads more than this far from the card is not reporting a
 * crystal (those are 100-500 ppm on this box, and the doc's own measurement was
 * 135) - it is reporting the pipeline: a stall, a reopen, a device that stopped.
 * Ignore it and let the next credible window speak.  The 2026-11-02 measurement
 * that started this (+42362 ppm through a 12 s freeze of ffmpeg) and the 1.8 %
 * of the "Portugal Spain (continued)" take are both this case. */
#define RS_FLOW_MAX_PPM 5000

static void rs_reset(void)
{
    rs_prev[0] = rs_prev[1] = 0.0;
    rs_have = 0;
    rs_frac = 0.0;
    rs_step = 1.0;
    rs_front_len = rs_front_pos = 0;        /* nothing owed from a previous take */
    rs_out_frames = rs_vframes = 0;
    rs_pad_frames = 0;
    rs_raw_win = rs_v_win = 0;
    rs_last_out[0] = rs_last_out[1] = 0;
    rs_gain = 1.0; rs_gain_step = 0.0;
    rs_ppm_logged = 0;
    rs_phase_logged = 0;
    rs_phase_ms = 0;
    rs_bad_windows = 0;
    rs_bad_logged = 0;
    rs_seeded = 0;
    rs_last_update = 0;
}

/* Resample `nframes` interleaved stereo frames from `in` into `dst`, at most
 * `maxout` output frames; *consumed reports how many INPUT frames the run
 * actually used.  Returns the output frames produced.
 *
 * Since 2026-11-04 this runs at the drain (a_make_chunk), one call per
 * picture committed, not at the ALSA callback.  That is what lets a commit ask
 * for *exactly* the audio frames one 40 ms picture owes and pad softly when
 * the ring cannot say yes, and it is what lets the ring hold raw samples so a
 * capture hole's fades live in the domain the ALSA thread owns.  The maxout
 * stop makes the function resumable: rs_prev/rs_frac keep the interpolation
 * state, so the ring left over is picked up mid-sample on the next pass. */
static size_t rs_run_into(const short *in, size_t nframes,
                          short *dst, size_t maxout, size_t *consumed)
{
    size_t out = 0, i = 0;
    double step = rs_step;
    if (consumed) *consumed = 0;
    if (!nframes || !maxout) return 0;
    if (step < 0.9) step = 0.9;
    if (step > 1.1) step = 1.1;
    if (!rs_have) {                     /* first block: output the first frame
                                         * as-is rather than ramp up from zero */
        rs_prev[0] = in[0]; rs_prev[1] = in[1];
        rs_have = 1; rs_frac = 0.0; i = 1;
    }
    while (i < nframes && out < maxout) {
        double f = rs_frac;
        dst[out * 2 + 0] = (short)lrint(rs_prev[0] +
                                f * ((double)in[i * 2 + 0] - rs_prev[0]));
        dst[out * 2 + 1] = (short)lrint(rs_prev[1] +
                                f * ((double)in[i * 2 + 1] - rs_prev[1]));
        if (rs_gain < 1.0) {
            /* Sound coming back after a hole: run the stored gain envelope up to
             * full level, the partner of the fade down into the seam (the raw
             * ramp in cap_feed_silence() after a capture hole, rs_pad_into()'s
             * output ramp after a drain starve).  Every edge is needed or the
             * seam is a click, which is the artefact this file has already been
             * bitten by once (9356e5c, the ring wrap that shipped silence once
             * every 5.46 s).  Resampling cannot damage it: a linear map of a
             * fade is the same fade. */
            dst[out * 2 + 0] = (short)lrint(dst[out * 2 + 0] * rs_gain);
            dst[out * 2 + 1] = (short)lrint(dst[out * 2 + 1] * rs_gain);
            rs_gain += rs_gain_step;
            if (rs_gain > 1.0) rs_gain = 1.0;
        }
        out++;
        rs_frac += step;
        while (rs_frac >= 1.0) {
            rs_frac -= 1.0;
            if (i >= nframes) break;    /* ran out: rs_prev already holds the
                                         * last frame, which is what the next
                                         * block interpolates from */
            rs_prev[0] = in[i * 2 + 0];
            rs_prev[1] = in[i * 2 + 1];
            i++;
        }
    }
    if (out) {                            /* where the next fade-down starts from */
        rs_last_out[0] = dst[(out - 1) * 2 + 0];
        rs_last_out[1] = dst[(out - 1) * 2 + 1];
    }
    rs_out_frames += out;
    if (consumed) *consumed = i;
    return out;
}

/* The drain-side hole filler: `pad` output frames at dst[off..], because the
 * ring could not cover a commit - live sound was not arriving (device gone,
 * ALSA thread starved, the moment between cap_start and the first PCM).  Soft
 * in both directions: it starts with a RS_RAMP-frame fade from rs_last_out,
 * the exact sample that sits in front of it in the file, and it leaves
 * rs_ramp_in armed so the next RS_RAMP real samples fade up into place.  A
 * hard step to zero and back is precisely what a click is; the operator's
 * standing order since the SaLou take is that nothing reaches the tape but a
 * seam that has been ramped. */
static void rs_pad_into(short *dst, size_t off, size_t pad)
{
    /* Snapshot the fade source BEFORE the loop and keep rs_last_out pointing at
     * the pad's own tail throughout: reading rs_last_out as the loop's running
     * source zeroed it at the first sample and made every later ramp step read
     * silence - the pad shipped [last, 0, 0, ...], a hard edge, exactly the
     * click this function exists to prevent (the self-test caught 1079 units
     * at the drain-starve seam on 2026-11-04). */
    const short from0 = rs_last_out[0], from1 = rs_last_out[1];
    for (size_t i = 0; i < pad; i++) {
        int a = 0, b = 0;
        if (i < (size_t)RS_RAMP) {
            double g = (double)(RS_RAMP - (int)i) / RS_RAMP;
            a = (int)lrint((double)from0 * g);
            b = (int)lrint((double)from1 * g);
        }
        dst[(off + i) * 2 + 0] = (short)a;
        dst[(off + i) * 2 + 1] = (short)b;
    }
    rs_last_out[0] = rs_last_out[1] = 0;   /* a second pad fades from silence,
                                            * i.e. stays silent */
    rs_out_frames += pad;
    rs_pad_frames += pad;                       /* counted, never hidden */
    /* Continue the envelope where the fade-down left off.  The ramp-up rate is
     * FIXED at 1/RS_RAMP per frame: a SHORT pad (the drain went dry for a few
     * samples at a chunk boundary) then resumes from just under 1.0 and needs
     * exactly `pad` frames to finish - the fade-up mirrors the fade-down.  A
     * rate that sped up to "finish in RS_RAMP - pad" turned a 6-sample seam
     * into a 0.16 gain step per sample - ~1250 units at signal level, a click
     * the self-test caught on the first run (2026-11-04).  And the new level
     * LOWERS the envelope that is running rather than re-deriving it from the
     * pad length alone: a pad immediately after another pad starts from 0 and
     * must not arm the resume at 0.9. */
    double g1 = rs_gain - (double)pad / RS_RAMP;
    rs_gain = g1 > 0.0 ? g1 : 0.0;
    rs_gain_step = 1.0 / (double)RS_RAMP;
}

/* Re-estimate the resampling ratio.  Called from the writer thread just after
 * a picture committed, about once a second; the ~50 s time constant is what
 * keeps a one-second hiccup from reaching the samples.
 *
 * There are two numbers here.
 *
 *   flow   d_raw / d_want - raw samples the ADC delivered over the last window
 *          over samples the pictures committed in that window owe.  This is
 *          the crystals.  Since the 2026-11-04 coupling it MUST be measured
 *          over ARRIVALS (aq_raw_frames) and not over what the resampler
 *          consumed: the drain now IS the resampler, and a flow term read off
 *          the drain would be reading back the step it just set - an
 *          instrument wired to its own output.  Measuring it over a *window*
 *          is what stops one early event - the pre-roll, a device reopen, the
 *          first seconds before the queue settles - being charged against
 *          every second of tape that follows it.
 *
 *   phase  E             - what the two tracks disagree by *at this moment*:
 *
 *              E = queue_ms - ring_ms
 *
 *          The audio leaves the ring only in a commit, paired with a picture,
 *          so the two tracks IN THE FILE are always exactly the same length -
 *          no measurement at the commit point could report otherwise, which
 *          is precisely why the pre-2026-11-04 E (a produced/credited/wasted
 *          ledger against the frames owed) sat near 0 ms through the entire
 *          take that arrived with the sound a second early: audio drained on
 *          wall clock while the pictures committed behind a slow NFS sink,
 *          equal lengths, sound early the whole way.  What CAN disagree is
 *          what the two backlogs in front of the writer *contain*: the next
 *          sound to be written was captured ring_ms ago, the next picture was
 *          captured queue_ms ago, so the sound going into the file now belongs
 *          to the picture that will be committed ring_ms - queue_ms later.
 *          That difference is the live lip-sync error in one subtraction -
 *          and everything merely common to both streams cancels out of it by
 *          construction: a sink stall deepens both backlogs at the same
 *          1000 ms/s and moves E not at all, a paused deck drains both, and
 *          what is left standing is exactly the two things worth paying for:
 *          the ADC running at a different rate than the card, and holes in
 *          the PCM.
 *
 *          E deliberately COUNTS the silence that fills a capture hole - the
 *          zeros in the ring are backlog like any other.  That is correct,
 *          not slop: those zeros are the tape time they stand in for, and the
 *          alignment across the hole is intact the moment they commit.  The
 *          alternative - excluding fabricated samples through a credit FIFO -
 *          was modelled and rejected: it makes the controller stretch the
 *          sound to "refill" a hole already paid for, then squeeze when E
 *          unwinds: a pitch wobble at every dropout that buys nothing.
 *
 * So the step runs at the flow rate *and* spends E over RS_DRAIN_S seconds
 * paying it back.  With E = 0 that is exactly the crystal measurement; with a
 * hole in the sound it walks the two backlogs back onto each other instead of
 * leaving the debt in place for the rest of the tape.  The drain is bounded to
 * RS_PPM_MAX, which is 0.3 % (3.5 cents: under what anyone hears on speech and
 * on a tape's audio, and 6x the worst crystal this box has shown), because
 * paying an error back must never be more destructive than the error.  A 1.2 s
 * hole therefore takes about 7 minutes to unwind and not one second of it is
 * audible.
 *
 * Why the old `vq_backlog` freeze is gone: it existed because a sink stall
 * made the cumulative ratio explode (+42362 ppm measured across a 12 s freeze
 * of ffmpeg).  A windowed measurement cannot be fooled that way - a stalled
 * sink writes no pictures, so d_want is 0 and the window is skipped outright.
 * E is immune to stalls in a second, stronger way: a stall moves queue_ms and
 * ring_ms together and E does not even blink.  (A queue that is deep but
 * draining - normal on NFS to ds-public, qmax reached 109 of 150 slots on
 * 2026-11-03 - used to freeze the estimate for whole minutes at a time.) */
static void rs_update(void)
{
    unsigned long now = SDL_GetTicks();
    if (rs_last_update && now - rs_last_update < 1000) return;
    rs_last_update = now;
    if (!audio_rate || !cap_has_audio) return;

    /* One lock, both depths: a commit moves the pair together, so the
     * difference is only meaningful read atomically. */
    pthread_mutex_lock(&vq_mtx);
    unsigned long long raw = aq_raw_frames;
    double backlog_ms = (double)vq_count * (double)FRAME_MS;
    unsigned long long bpm = aq_bytes_per_ms();
    double ring_ms = bpm ? (double)aq_count / (double)bpm : 0.0;
    /* The spill backlog is backlog and sound at the same time: every record
     * is a pending picture (queue side, sp_count x FRAME_MS) plus that
     * picture's own ring bytes (ring side, sp_sound), and the rs_front
     * residue is sound already restored from the file and simply not
     * committed yet - ring class too.  Counted together they cancel out of
     * E exactly - a spilled minute is neither a lip error nor a reason to
     * touch step; forgotten on either side and the controller would chase
     * an invented phase error into the audio (or miss a real one).  This is
     * writer-thread-only code, which is why rs_front needs no lock. */
    backlog_ms += (double)sp_count * (double)FRAME_MS;
    if (bpm)
        ring_ms += (double)(sp_sound + (rs_front_len - rs_front_pos))
                 / (double)bpm;
    pthread_mutex_unlock(&vq_mtx);

    if (rs_vframes < 125) {                       /* 5 s of video first */
        rs_raw_win = raw;
        rs_v_win  = rs_vframes;
        return;
    }

    double d_raw  = (double)(raw - rs_raw_win);
    double d_want = (double)audio_rate * 0.040 * (double)(rs_vframes - rs_v_win);
    rs_raw_win = raw;
    rs_v_win  = rs_vframes;

    /* The phase, live, in samples - see the header note.  E > 0 means the ring
     * is shallower than the queue: the sound entering the file now belongs to a
     * picture that will not be written for another E samples, i.e. the audio
     * track is running AHEAD of the video. */
    int ms = (int)lrint(backlog_ms - ring_ms);
    double E = (double)ms * (double)audio_rate / 1000.0;   /* + = file wants sound */
    rs_phase_ms = ms;

    /* A window with no arrivals or no pictures in it teaches nothing about the
     * crystals, and pretending otherwise is what made this figure lie.  (A dead
     * ADC is the extreme case: d_raw is 0, the window is skipped, and E alone
     * keeps reporting the growing debt - honestly, in milliseconds.) */
    if (d_raw <= 0.0 || d_want <= 0.0) return;

    double flow = d_raw / d_want;
    double f_ppm = (flow - 1.0) * 1e6;
    if (fabs(f_ppm) > RS_FLOW_MAX_PPM) {
        rs_bad_windows++;
        if (rs_bad_logged > 200 || (rs_bad_windows % 60) == 1) {
            rs_bad_logged = 0;
            fprintf(stderr, "pctv-monitor: A/V clock window reads %+d ppm - that is"
                            " not a crystal, it is the pipeline (a stall, a reopen, a"
                            " device that stopped): ignored. %llu such windows, A/V"
                            " phase still %+d ms\n",
                    (int)f_ppm, rs_bad_windows, ms);
        }
        rs_bad_logged++;
        return;
    }

    double want = d_want + E / RS_DRAIN_S;        /* samples the file needs this window */
    if (want < d_want * 0.5) want = d_want * 0.5;   /* never demand a 2x squeeze */
    if (want > d_want * 2.0) want = d_want * 2.0;
    double desired = d_raw / want;      /* input frames per output frame */
    double lo = 1.0 - RS_PPM_MAX / 1e6, hi = 1.0 + RS_PPM_MAX / 1e6;
    if (desired < lo) desired = lo;
    if (desired > hi) desired = hi;
    double s = rs_step;
    /* The FIRST measured window sets the step outright; later ones blend 2 %
     * toward their target.  Blending from 1.0 is right for rejecting jitter
     * mid-take, but from a standing start it is a ~50 s ramp during which a
     * cold −300 ppm crystal outruns it and starves the drain - the self-test
     * saw 16 ms of invented silence in an otherwise clean take because of it.
     * One window at this depth (>= 125 pictures) cannot be jitter. */
    s = rs_seeded ? s + (desired - s) * 0.02 : desired;
    rs_seeded = 1;
    if (s < lo) s = lo;
    if (s > hi) s = hi;
    rs_step = s;
    int ppm = (int)lrint((s - 1.0) * 1e6);
    if (abs(ppm - rs_ppm_logged) >= 5) {
        rs_ppm_logged = ppm;
        fprintf(stderr, "pctv-monitor: A/V clock: the ADC runs %+d ppm against the "
                        "card (audio resampled by %.6f, no frame is touched)\n",
                ppm, s);
    }
    /* The number that was missing: what the sound and the picture disagree by
     * right now, in milliseconds.  Positive = the file's audio track is short, so
     * the sound is ahead of the lips; the drain term above is spending RS_PPM_MAX
     * of resampling walking it back.  Logged at 50 ms, so a run of tape that is
     * drifting is visible while there is still time to do something about it. */
    if (abs(ms - rs_phase_logged) >= 50) {
        rs_phase_logged = ms;
        fprintf(stderr, "pctv-monitor: A/V phase: the sound is %d ms %s the picture"
                        " (paying it back at %+d ppm)\n", abs(ms),
                ms > 0 ? "ahead of" : "behind", ppm);
    }
}

/* Is the audio ring still taking bytes?  During a drain the sound still has to
 * be accepted: the pictures still queued ahead of this belong to it, and
 * refusing it here would leave the last seconds of a stopped capture with video
 * and no audio. Refuse only once the ring is half full, which is the case this
 * guard was written for (a dead encoder, a running ALSA thread, and a writer
 * that could then never finish): 4 MiB is 22 s, more than any drain needs. */
static int aq_accepts(void)
{
    if (!aq) return 0;
    pthread_mutex_lock(&vq_mtx);
    int refuse = aq_closed || (vq_stopping && aq_count > AQ_BYTES / 2);
    pthread_mutex_unlock(&vq_mtx);
    return !refuse;
}

/* Put `n` bytes of whole stereo frames at the back of the audio ring, evicting
 * the oldest bytes when it will not all fit.  Split out of cap_feed_audio on
 * 2026-11-04 because there are now two producers: the PCM that came off the ADC
 * and the silence that stands in for PCM that did not. */
static void aq_push(const unsigned char *p, size_t n)
{
    if (!aq || !n) return;
    pthread_mutex_lock(&vq_mtx);
    size_t lost = 0, ev = 0, freeb = AQ_BYTES - aq_count;
    if (n > freeb) {
        size_t evictable = aq_count - aq_sent;      /* never touch in-flight */
        size_t need = n - freeb;
        ev = need < evictable ? need : evictable;
        aq_head = (aq_head + ev) % AQ_BYTES;
        aq_count -= ev;
        lost = need - ev;                           /* oldest gone, then truncate */
        if (lost > n) lost = n;
        n -= lost;
        /* Same policy as the picture queue: PCM the file does not contain is not
         * something to discover in the summary line of a finished tape.  Under
         * the coupled design this path means the ring has outlasted even 21 s
         * of cushion - the writer is not running at all. */
        if (!vq_want_stop) {
            vq_want_stop = 1;
            fprintf(stderr, "pctv-monitor: SINK STALLED: the audio ring is full"
                            " too (%llu B = %.1f s of sound had nowhere to go) -"
                            " ending the capture rather than writing a file whose"
                            " sound has holes in it.\n",
                    (unsigned long long)(ev + lost),
                    (double)(ev + lost) / 192000.0);
        }
    }
    if (n) {
        size_t tail = (aq_head + aq_count) % AQ_BYTES;
        size_t first = n < AQ_BYTES - tail ? n : AQ_BYTES - tail;
        memcpy(aq + tail, p, first);
        if (n > first) memcpy(aq, p + first, n - first);
        aq_count += n;
        pthread_cond_broadcast(&vq_cv);
    }
    pthread_mutex_unlock(&vq_mtx);

    if (lost || ev) {
        pthread_mutex_lock(&cap_mtx);
        cap_adrops++; cap_adrop_bytes += lost + ev;   /* the file will not hold
                                                       * any of these samples */
        pthread_mutex_unlock(&cap_mtx);
    }
}

/* PCM callback: copy the RAW frames into the ring, nothing else.
 *
 * Until 2026-11-04 this function resampled on the way in (and for a week before
 * that, it resampled and then queued the INPUT next to the output's length -
 * which is where the crackle documented at 9356e5c came from).  Resampling at
 * the ALSA thread was only ever correct when the drain was a dumb pipe;
 * once a commit owns its own 40 ms of sound, the ring is worth more raw: the
 * hole seams can then be ramped in the sample domain (below), and the writer
 * decides how much sound each picture actually gets.
 *
 * The only transform here is the fade-up after a hole (aq_fsin), applied to a
 * copy - the caller's buffer belongs to the ALSA read, and the input monitor
 * plays it unaltered.  Linear resampling at the drain preserves the envelope,
 * so the ramp reaches the file exactly as it leaves this thread. */
static void cap_feed_audio(const void *p, size_t n)
{
    /* The fade scratch: only this thread touches it, and its reads are
     * bounded by the 1024-frame readi in the ALSA loop. */
    static short scratch[1024 * 2];
    if (!aq) return;
    n &= ~(size_t)3;                            /* whole interleaved frames */
    size_t frames = n / 4;
    if (!frames || !aq_accepts()) return;
    if (frames > sizeof scratch / sizeof scratch[0] / 2) frames = 1024;  /* cannot */
    const short *in = (const short *)p;

    size_t done = 0;
    while (done < frames) {
        const short *src = in + done * 2;
        size_t k = frames - done;
        if (aq_fsin) {
            if (k > aq_fsin) k = aq_fsin;
            for (size_t i = 0; i < k; i++) {
                double g = (double)(RS_RAMP - aq_fsin + 1) / RS_RAMP;
                scratch[i * 2 + 0] = (short)lrint(in[(done + i) * 2 + 0] * g);
                scratch[i * 2 + 1] = (short)lrint(in[(done + i) * 2 + 1] * g);
                aq_fsin--;
            }
            src = scratch;
        }
        aq_push((const unsigned char *)src, k * 4);
        pthread_mutex_lock(&vq_mtx);
        aq_raw_frames += k;         /* real sound, faded or not: the ADC made it */
        aq_last_raw[0] = src[k * 2 - 2];      /* what the ring's tail actually is, */
        aq_last_raw[1] = src[k * 2 - 1];      /* so the next hole fades from that */
        pthread_mutex_unlock(&vq_mtx);
        done += k;
    }
}

/* Fill a hole the ADC left, at the instant it happened.  Called from the ALSA
 * thread with the number of frames the device failed to deliver; see the gap
 * note there for why this exists and what it costs.
 *
 * Both edges are soft, because the standing order since 2026-11-04 is that no
 * seam reaches a tape un-ramped: the fill runs DOWN over RS_RAMP frames from
 * aq_last_raw - the real sample pair at the ring's tail, so the silence starts
 * where the sound was, not at zero - and the first RS_RAMP frames the device
 * delivers again are faded up (aq_fsin, applied by cap_feed_audio).  The fill
 * is RAW (zeros into the ring, in front of the resampler), and linear
 * resampling cannot damage either ramp: a linear map of a fade is the same
 * fade.  What the file loses is exactly the hole, and only the hole; what it
 * keeps is everything on both sides of it sitting where the picture is. */
static void cap_feed_silence(size_t nframes)
{
    if (!nframes || !aq_accepts()) return;
    static unsigned char zbuf[8192];            /* zeroed once, never written */
    short ramp[RS_RAMP * 2];
    size_t down = nframes < (size_t)RS_RAMP ? nframes : (size_t)RS_RAMP;
    if (down) {
        for (size_t i = 0; i < down; i++) {
            double g = (double)(down - i) / (double)down;
            ramp[i * 2 + 0] = (short)lrint((double)aq_last_raw[0] * g);
            ramp[i * 2 + 1] = (short)lrint((double)aq_last_raw[1] * g);
        }
        aq_push((const unsigned char *)ramp, down * 4);
    }
    for (size_t sent = down; sent < nframes; ) {
        size_t k = nframes - sent > sizeof zbuf / 4 ? sizeof zbuf / 4
                                                    : nframes - sent;
        aq_push(zbuf, k * 4);
        sent += k;
    }
    pthread_mutex_lock(&vq_mtx);
    aq_last_raw[0] = aq_last_raw[1] = 0;    /* a second hole fades from silence,
                                             * which is a no-op ramp - correct,
                                             * that is what the tail now is */
    pthread_mutex_unlock(&vq_mtx);
    aq_fsin = RS_RAMP;                      /* whatever comes back fades up */
    cap_a_silence_bytes += nframes * 4;
    cap_a_gaps++;
}

/* ---- video queue -------------------------------------------------------
 * One slot per assembled frame.  Each slot is one 829 KB UYVY frame, so 24 =
 * 20 MB and 150 = 124 MB (PCTV_VQ_SLOTS sets it, VQ_SLOTS_MAX is the ceiling).
 * One slot is always reserved for the frame the writer owns, so vq_n-2 frames
 * can queue behind it.  The producer can never touch the reserved slot:
 * occupancy stays <= vq_n-1, so head+count never reaches the slot popped.
 *
 * NO PICTURE IS EVER DISCARDED HERE ANY MORE.  Evicting the oldest picture was
 * how 59688 pictures (40 minutes of tape) vanished from a 3 h recording on
 * 2026-11-02 while every counter looked alive: the oldest frame is as much of
 * the tape as the newest one, and a file with 22 % of its pictures silently
 * missing is worthless as an archive.  A full queue no longer overflows
 * anywhere but onto the local-disk spill (see the spill block below the queue:
 * pictures plus their sound wait in a scratch file, and the writer walks them
 * back); only when the file cannot take them - cap, disk error, or
 * PCTV_SPILL_MB=0 - does the capture end.  The two outcomes stand: a complete
 * file, or a short one with a loud reason.
 *
 * That makes the depth the whole guarantee, so it is sized in seconds of sink
 * stall rather than in frames of phase jitter.  Measured on 2026-11-02: a paced
 * 21 MB/s fsync'd writer to GEN8's NFS ds-public took 399 ms/chunk mean and
 * 681 ms worst over 180 chunks, while the MPEG-2 encoder on this box stalls in
 * bursts (24 slots = 960 ms was chosen because at 10 slots bursts were eating
 * ~20 frames a minute).  A lossless master to a network mount therefore starts
 * at VQ_SLOTS_SINK = 150 slots = 6 s. That ceiling is ffmpeg's, not the disk's:
 * its matroska muxer stops reading both pipes once the streams are more than its
 * 10 s interleave limit apart, and with a timestamp-less raw input a video
 * backlog IS that divergence - a deeper queue wedges the muxer instead of
 * absorbing the stall (see the audio ring above for the measurement). The MPEG-2
 * path stays at 24 because 124 MB for an encoder that already has its own 8 MiB
 * pipe would be silly.  Blocking here is NOT an option: the
 * parser is what fills this queue, and stalling it cascades into the probe's
 * byte ring, which really does drop bytes (silently, 32 KiB at a time). */
#define VQ_SLOTS_MAX 500      /* 415 MB even when PCTV_VQ_SLOTS asks for more */
#define VQ_SLOTS_DEFAULT 24
#define VQ_SLOTS_SINK 150   /* 6 s: the deepest cushion ffmpeg can be given */
static unsigned char *vq[VQ_SLOTS_MAX];
static int vq_n = VQ_SLOTS_DEFAULT;    /* runtime depth, clamped in main() */
/* vq_head/vq_count and FRAME_MS moved up next to vq_mtx - see rs_update. */
static int vq_held = -1;               /* slot the writer owns (also the dup src) */
static int vq_stop, vq_started;
static pthread_t vq_thr;
static unsigned long vq_last_ms;       /* when a picture last went out (dup watchdog) */
/* The audio half of the commit in flight.  One commit = one 829440 B picture
 * followed by exactly a_chunk_frames audio frames (40 ms at the negotiated
 * rate), written to the two pipes in that order and by nobody else.  Nothing
 * else in this program appends to the audio pipe, which is the whole A/V sync
 * guarantee: the muxer can never see one stream advance without the other.
 * a_chunk_frames is nonzero only between "picture done" and "its audio
 * done" - a chunk stalled in the pipe holds the NEXT picture back, so a stall
 * costs queue depth, never divergence. */
#define A_CHUNK_MAX 8192                /* 40 ms of audio frames: covers 205 kHz */
static short  a_chunk[A_CHUNK_MAX * 2];
static size_t a_chunk_frames, a_chunk_pos;
/* The picture in flight to ffmpeg: a RAM queue slot, or the spill staging
 * buffer when the commit is being read back from disk (see the spill block).
 * NULL = none.  It used to be a slot INDEX (vq_slot), which quietly assumed
 * every picture lives in RAM; the writer below is now agnostic, and
 * vq_cur_spill is what tells a spilled commit apart from a real one at
 * completion time (it is the one case where the picture must be copied into
 * the held slot to keep the duplicate-source invariant). */
static unsigned char *vq_cur;
static int vq_cur_spill;
static size_t vq_off;
static int vq_slot_dup;
#define VQ_GRACE_MS 30                 /* be late rather than duplicate */

/* ---- spill: local disk behind the RAM queue --------------------------------
 * A sink slower than tape - the §14.2b case, GEN8's NFS under the ~20.9 MB/s
 * a UYVY master needs - used to end the take the moment the 150-frame RAM
 * queue filled, because RAM was the only place a queued picture could wait.
 * The pictures are not the problem though; the waiting room is.  With a fast
 * local disk behind the box the sink may stay slow as long as it likes: every
 * picture the RAM queue cannot hold is appended to a scratch file on the SSD,
 * and it walks back into the queue path when the writer next asks for one.
 * The capture only ends when even the SSD says no (full, failing, disabled).
 *
 * A spill record is a PAIR - one picture plus the up-to-FRAME_MS of raw ring
 * sound it was captured with.  That is not tidiness, it is the coupling
 * invariant: the sound committed with a picture must be that picture's own,
 * and once the backlog outlives the 21.8 s ring (16 s after the queue fills -
 * minutes, not hours, for the chronic-slow case that started this) spilling
 * pictures alone would commit the wrong sound to the wrong picture, which is
 * the exact class of damage this file exists to prevent.  So the sound
 * travels with the picture: cut off the RING TAIL at spill time (the last
 * FRAME_MS delivered is the arriving picture's own exposure window; while
 * the file holds records the ALSA thread's bytes are claimed one window per
 * arrival, which is why the ring does NOT overflow during a spill epoch),
 * put ahead of the ring at restore time via rs_front, and every seam the
 * drain already knows how to make soft keeps working, because the spill
 * moves bytes the ring already accepted without inventing, reordering or
 * fading any of them.  The audio part is VARIABLE and each record says how
 * much it carries (struct spill_rec): the ring can hold anything from zero
 * to a full window (while spilling, ALSA delivers and extraction removes one
 * window per arrival, so the depth settles at a few ms), and zero-padding a
 * short window into a fixed one would splice silence into the middle of the
 * sound - truncation the record admits to beats a lie the drain commits.
 *
 * Ordering is one FIFO, and it is strict by position, which costs one
 * routing rule: WHILE THE FILE HOLDS A BACKLOG THE FILE IS THE ONLY PLACE A
 * NEW PAIR GOES, room in the RAM queue or not (see cap_feed_video).  The RAM
 * queue then keeps one contiguous block older than the file's one contiguous
 * block, and "oldest pending" is a fact about positions instead of about
 * timestamps nobody can compare.  Without that rule a frame could re-enter
 * RAM while older ones sat in the file, and the writer - which pops RAM
 * first, because that is what the audio stream (ring head = the RAM block's
 * own sound) requires - would commit the newer frame before them.  Producer
 * and writer touch opposite ends of the file, the fd is only ever closed
 * with both threads otherwise quiescent, so no disk op here waits on another.
 *
 * The clock cannot see any of this, and that is the point: a record carries
 * a picture and its own ring bytes, so E = queue_ms - ring_ms grows by the
 * same time on both sides and cancels (rs_update counts both terms - the
 * pictures via sp_count, the un-restored sound via sp_sound - and they only
 * cancel when nobody invents or loses samples, which is the same promise the
 * coupling makes inside the ring).
 *
 * Disk discipline: the file is mkstemp'd under a directory this tool owns
 * and UNLINKED at once, so a crash can leave nothing behind and space is
 * back the moment the fd closes; space is claimed with posix_fallocate in
 * chunks so ENOSPC surfaces before a picture is lost, not in someone's
 * writeback; the cap is PCTV_SPILL_MB, further clamped by the measured free
 * space at activation minus a 1 GiB floor for the host.  Producer side that
 * leaves the hot path: one memcpy, one bounded pwrite, no retries, and
 * nothing that waits for the sink.  A producer-side failure never closes or
 * rewinds the file: everything already appended is valid, drains back into
 * the take, and only the failing picture ends the capture.
 */
#define SPILL_CAP_DEFAULT_MB 32768ull  /* 32 GB = ~25 min of master at 20.9 MB/s */
#define SPILL_PREALLOC     (64ull << 20)
#define SPILL_HDR          64          /* one aligned header block per record */
#define SPILL_MAGIC        0x50435338u /* 'PCS8': this build's record layout */
struct spill_rec {
    unsigned magic;                    /* SPILL_MAGIC */
    unsigned audio;                    /* bytes of sound following the picture */
    unsigned long long reserved[7];    /* future: sequence, flags - all zero now */
};
_Static_assert(sizeof(struct spill_rec) == SPILL_HDR, "spill header size");

static const char *spill_dir = "/var/tmp";      /* PCTV_SPILL_DIR - local disk! */
static unsigned long long spill_cap_mb = SPILL_CAP_DEFAULT_MB;  /* 0 = off */
static unsigned char *sp_out, *sp_in;  /* producer / writer staging, vq_start */
#define SP_IN_MAX (SPILL_HDR + UV_SIZE + SPILL_AUDIO_MAX)
static int sp_fd = -1;                 /* >= 0: this take has a scratch file */
static unsigned long long sp_cap;      /* bytes, set at activation */
static size_t sp_rec, sp_audio;        /* max record size, max sound part of it */
static size_t sp_head, sp_tail, sp_pre;/* read offset, write offset, fallocated end */
                                        /* sp_count / sp_sound live with the
                                         * ring's counters, above rs_update */
static unsigned long long cap_spill_frames;  /* records written this take (stats) */
static int sp_fail_logged;             /* the SPILL FAILED line is a once */
static char sp_note[64];               /* file name for the log (pre-unlink) */

static const char *spill_why = "";     /* last failure, for the log */

/* Producer side, called with NO lock held (cap_feed_video dropped vq_mtx the
 * way it drops it for the 3/4 warning - disk I/O and queue locks do not
 * share a sentence).  Returns 0 when the pair is durably in the spill file,
 * nonzero when this picture is the last the sink will get, having said so. */
static int spill_append(const unsigned char *pic)
{
    if (!sp_out || !sp_in) { spill_why = "staging buffers never allocated"; goto fail; }
    if (sp_fd < 0) {
        /* activation: a directory we own, a name we will immediately unlink */
        if (mkdir(spill_dir, 0700) != 0 && errno != EEXIST) {
            spill_why = spill_dir; goto fail;
        }
        sp_audio = (size_t)aq_bytes_per_ms() * FRAME_MS;
        if (!cap_has_audio) sp_audio = 0;       /* nothing is born without sound */
        if (sp_audio > SPILL_AUDIO_MAX) { spill_why = "audio rate beyond the spill record"; goto fail; }
        sp_rec = SPILL_HDR + UV_SIZE + sp_audio;
        unsigned long long cap = spill_cap_mb << 20;
        struct statvfs sv;
        if (statvfs(spill_dir, &sv) == 0) {     /* never be the thing that kills
                                                 * the host's root disk */
            unsigned long long fr = (unsigned long long)sv.f_bavail * sv.f_frsize;
            unsigned long long keep = (1ull << 30) + SPILL_PREALLOC;
            if (fr > keep && fr - keep < cap) cap = fr - keep;
        }
        if (cap < sp_rec * 8) { spill_why = "no usable space on the spill disk"; goto fail; }
        char tmpl[PATH_MAX];
        snprintf(tmpl, sizeof tmpl, "%s/pctv-spill-XXXXXX", spill_dir);
        int fd = mkstemp(tmpl);
        if (fd < 0) { spill_why = tmpl; goto fail; }
        snprintf(sp_note, sizeof sp_note, "%.63s", strrchr(tmpl, '/') ? strrchr(tmpl, '/') + 1 : tmpl);
        unlink(tmpl);                           /* crash-clean by construction */
        sp_fd = fd; sp_cap = cap; sp_head = sp_tail = sp_pre = 0;
        fprintf(stderr, "pctv-monitor: SPILL ACTIVE: the sink is slower than the"
                        " tape, so queued pairs (picture + their sound) now"
                        " overflow to local disk (%s/%s, cap %.1f GB). Nothing is"
                        " dropped; the capture runs on, and spill done prints"
                        " when the sink has caught up again.\n",
                spill_dir, sp_note, (double)cap / 1073741824.0);
        show_overlay(20000);
    }
    struct spill_rec h = { SPILL_MAGIC, 0, { 0 } };
    size_t rec = SPILL_HDR + UV_SIZE;
    if (sp_audio) {
        /* Cut this picture's own sound off the tail of the ring.  Under the
         * lock, but only as a ring-move: the bytes go to producer-private
         * staging and aq_count simply shrinks from the tail - aq_head never
         * moves, so the writer's in-flight read window is untouched.  What
         * is NOT there is not taken: while the file holds records every
         * arrival claims a window the moment it is delivered, so the ring
         * runs shallow (a few ms), and a short record is a truncated window
         * the drain pads softly, not a failure.  The truncation is bounded
         * by the crystals (a window is 40 ms of card time, the ring got
         * 40 ms of ADC time) - never more than about a sample. */
        pthread_mutex_lock(&vq_mtx);
        size_t avail = (aq_count - aq_sent) & ~(size_t)3;   /* never touch the
                                                             * reserved window */
        size_t take = avail < sp_audio ? avail : sp_audio;
        aq_count -= take;
        size_t off = (aq_head + aq_count) % AQ_BYTES;
        size_t first = take < AQ_BYTES - off ? take : AQ_BYTES - off;
        memcpy(sp_out + SPILL_HDR + UV_SIZE, aq + off, first);
        if (first < take)
            memcpy(sp_out + SPILL_HDR + UV_SIZE + first, aq, take - first);
        h.audio = (unsigned)take;
        pthread_mutex_unlock(&vq_mtx);
        rec += take;
    }
    memcpy(sp_out, &h, sizeof h);
    while (sp_tail + rec > sp_pre) {            /* claim space before writing:
                                                 * ENOSPC must cost the take,
                                                 * not the page cache */
        if (sp_tail + rec > sp_cap) {
            spill_why = "the scratch file reached its cap (PCTV_SPILL_MB) while"
                        " the sink was still behind";
            goto fail;
        }
        unsigned long long len = sp_cap - sp_pre;
        if (len > SPILL_PREALLOC) len = SPILL_PREALLOC;
        int e = posix_fallocate(sp_fd, (off_t)sp_pre, (off_t)len);
        if (e == ENOSPC) { spill_why = "the spill disk ran out of space"; goto fail; }
        if (e != 0) { sp_pre = sp_cap; break; } /* no preallocation here (some
                                                 * filesystems refuse it): the
                                                 * pwrite below reports anyway */
        sp_pre += len;
    }
    ssize_t w;
    do w = pwrite(sp_fd, sp_out, rec, (off_t)sp_tail);
    while (w < 0 && errno == EINTR);
    if (w != (ssize_t)rec) { spill_why = strerror(errno ? errno : EIO); goto fail; }
    pthread_mutex_lock(&vq_mtx);
    sp_tail += rec;
    sp_sound += h.audio;
    sp_count++;
    pthread_mutex_unlock(&vq_mtx);
    cap_spill_frames++;
    if (cap_spill_frames % 250 == 0)
        fprintf(stderr, "pctv-monitor: spill: %llu pictures (%.1f GB) on local"
                        " disk, the sink is %llu s behind the tape\n",
                cap_spill_frames, (double)sp_tail / 1073741824.0,
                sp_count * FRAME_MS / 1000ull);
    return 0;
fail:
    /* The file keeps its fd and everything already appended: those records
     * are valid, the drain restores them, and only this picture - the one
     * that could not be written - ends the capture (the caller stops on any
     * nonzero return, exactly as the pre-spill design stopped at a full
     * queue).  Nothing recorded so far becomes a hole over a disk error. */
    if (!sp_fail_logged) {
        sp_fail_logged = 1;
        fprintf(stderr, "pctv-monitor: SPILL FAILED (%s): %s. The capture ends"
                        " where the pre-spill design used to end: what is in"
                        " the file is complete, nothing after this is"
                        " recorded.\n", sp_note[0] ? sp_note : "activation",
                spill_why);
    }
    return -1;
}

/* Discard everything the sink has not been given - RAM queue, spill file and
 * both sound buffers - counted, once, loudly through the drain's LOST
 * PICTURES line.  `inflight` = 1 when the caller's picture (pipe or staging)
 * should be counted with it.  This is now the only way a picture is lost, so
 * the spill gave-up-on is walked here too rather than leaking into the next
 * take. */
static void vq_abandon_all(int inflight)
{
    pthread_mutex_lock(&vq_mtx);
    unsigned long long gone = (unsigned long long)vq_count + (inflight ? 1 : 0)
                            + sp_count;
    unsigned long long agone = aq_count + sp_sound;
    vq_abandon = 1;
    aq_closed = 1;                     /* else the ALSA thread keeps refilling a
                                        * ring nobody drains and the writer can
                                        * never exit */
    aq_head = (aq_head + aq_sent) % AQ_BYTES;
    aq_count = 0; aq_sent = 0;
    vq_head = 0; vq_count = 0;
    sp_head = sp_tail = sp_pre = 0; sp_count = sp_sound = 0;
    if (sp_fd >= 0) { close(sp_fd); sp_fd = -1; }   /* unlinked: the space is
                                                     * back right now */
    pthread_mutex_unlock(&vq_mtx);
    rs_front_len = rs_front_pos = 0;
    pthread_mutex_lock(&cap_mtx);
    cap_vdrops += gone; cap_adrop_bytes += agone;
    pthread_mutex_unlock(&cap_mtx);
    vq_drain_dropped += gone;
}

/* A record that cannot be READ BACK is the worst case the spill design has:
 * the pictures were on disk and now they are not.  Fail the way the pre-spill
 * §14.2b stop fails - count everything still owed, end the take complete to
 * the last pair actually in the file - and never reorder to keep them: two
 * swapped segments of the sound stream are exactly the damage the coupling
 * exists to make impossible.  (Producer-side failures have their own path in
 * spill_append; they lose only the picture that failed to write.) */
static void spill_lost(const char *why)
{
    if (!sp_fail_logged) {
        sp_fail_logged = 1;
        fprintf(stderr, "pctv-monitor: SPILL FAILED (read %s): %s. The capture"
                        " ends on the last pair that really was in the scratch"
                        " file; the backlog that followed it is gone, and"
                        " counted.\n", sp_note[0] ? sp_note : "activation", why);
    }
    vq_abandon_all(0);
    vq_want_stop = 1;              /* ends the take; the file closes complete */
}
/* The last few frame arrivals, so the writer can tell the two reasons its queue
 * can be empty apart:
 *
 *   the SOURCE stopped producing pictures (a deck paused, an input switch, the
 *   card gone) - nothing will arrive until someone acts, so the picture has to
 *   repeat to keep the file at 25 fps, or
 *   the HOST was slow (a modal paint, an SSH login) and the frames are waiting in
 *   the probe's 2.4 s ring - they will turn up in a burst, and repeating the
 *   picture now would make the video track *longer* than the tape and walk the
 *   sound out of step.
 *
 * With the queue alone these look identical, and the first version of this got it
 * wrong in the expensive direction: a stalled monitor earned a second of repeats
 * and then the second of real pictures as well.  An arrival rate over the last
 * 400 ms separates them cleanly (a live source puts 10 pictures in it). */
#define ARR_N 8
#define ARR_WINDOW_MS 400
static unsigned long arr_t[ARR_N];
static int arr_i;

/* Is there stream data waiting that nobody has parsed yet?  This is how the
 * writer tells "the SOURCE has stopped" (nothing to parse - repeat the picture)
 * from "the HOST is behind" (the bytes are sitting in the pipe and will be
 * parsed the moment the main loop comes back).  Without it a 300 ms desktop
 * freeze earns a dozen repeated pictures *and* then the dozen real ones, which
 * makes the video track longer than the tape and walks the sound out of step. */
static int stream_pending(void)
{
    int avail = 0;
    if (rlen > 0) return 1;
    if (child_fd >= 0 && ioctl(child_fd, FIONREAD, &avail) == 0 && avail > 0)
        return 1;
    return 0;
}

/* Producer: one assembled frame in fuv => exactly one slot.  Never blocks,
 * never waits for the encoder.  `stale` says the picture is a repeat of the
 * one before it (a repeated field parity, a short field, or the good-frame
 * gate holding the last clean picture).
 *
 * It used to also cut 40 ms of audio here, on the theory that a repeated
 * picture means "40 ms of content the tape does not have".  That theory sent
 * the tape to posterity a second early: the sound of those 40 ms is exactly
 * what the tape has - the picture is what got lost - and pairing a held
 * picture with the LIVE sound of its moment (the room tone under a tracking
 * flutter, the crowd noise under a frozen frame) is what a still-sounding
 * video camera does too.  Since the 2026-11-04 coupling a stale frame simply
 * commits like any other and takes its 40 ms of the ring; nothing is cut, and
 * the queue aligns what the crystals will not.  The parameter stays because
 * the caller's gate really is worth logging one day. */
static void cap_feed_video(int stale)
{
    (void)stale;
    if (!vq_started) return;
    pthread_mutex_lock(&vq_mtx);
    if (vq_stopping) {
        /* A drain is already running: capture is over, so this picture belongs to
         * the tape the file will not contain. Refusing it here is what gives the
         * drain an END. Without it the parser (pump() runs while the encoder is
         * being reaped) queued behind the drain as fast as the drain emptied, so
         * the backlog never shrank and only the wall-clock deadline stopped the
         * shutdown - a stop that should take a second took 45, and looked from
         * outside exactly like the lockup this file keeps fixing. */
        vq_want_stop = 1;
        cap_vrefused++;
        pthread_mutex_unlock(&vq_mtx);
        return;
    }
    int full = vq_count + (vq_held >= 0 ? 1 : 0) >= vq_n - 1;
    /* Full in RAM, or the scratch file still holds a backlog: this pair goes
     * to the file (see the spill block - while it holds anything, the RAM
     * queue must stop receiving or the two blocks stop telling their order
     * by position alone).  No room and nowhere to put the pair - the capture
     * is over, exactly as it was before the spill existed. */
    if (full || sp_count > 0) {
        if (spill_cap_mb) {
            pthread_mutex_unlock(&vq_mtx);      /* disk I/O outside the lock */
            if (spill_append(fuv) == 0)
                return;                         /* the pair is on disk */
            pthread_mutex_lock(&vq_mtx);
        }
        vq_want_stop = 1;
        cap_vrefused++;
        pthread_mutex_unlock(&vq_mtx);
        if (full)
            fprintf(stderr, "pctv-monitor: SINK STALLED: the frame queue is full"
                            " (%d frames = %d ms of cushion) and the encoder/disk"
                            " is not taking pictures. Ending the capture: what is"
                            " in the file is complete, and nothing further is"
                            " recorded. Raise PCTV_VQ_SLOTS, give PCTV_SPILL_DIR"
                            " a bigger local disk to spill onto (PCTV_SPILL_MB"
                            " caps it, 0 turns the spill off), or capture to a"
                            " faster sink.\n",
                    vq_n, vq_n * FRAME_MS);
        else
            fprintf(stderr, "pctv-monitor: capture ends: the scratch file failed"
                            " while it still held the backlog, and this newer"
                            " picture cannot go into the RAM queue without being"
                            " committed before them (see the SPILL FAILED line"
                            " above). What is in the file is complete.\n");
        return;
    }
    arr_t[arr_i++ % ARR_N] = SDL_GetTicks();
    int tail = (vq_head + vq_count) % vq_n;
    if (!vq[tail]) {                        /* slot malloc failed at startup */
        vq_want_stop = 1;
        cap_vrefused++;
        pthread_mutex_unlock(&vq_mtx);
        return;
    }
    memcpy(vq[tail], fuv, UV_SIZE);
    vq_count++;
    if (vq_count > cap_qmax) cap_qmax = vq_count;
    vq_backlog = vq_count * 4 > vq_n;
    int warn = !vq_warned && vq_count >= (vq_n - 1) * 3 / 4;
    vq_warned = vq_warned || warn;
    int depth = vq_count;
    pthread_cond_broadcast(&vq_cv);
    pthread_mutex_unlock(&vq_mtx);
    /* After the push, never before it: the first version of this warning printed
     * and returned, which threw away the very picture it was announcing - a
     * silent loss on the code path whose entire purpose is that there are no
     * more silent losses. */
    if (warn) {
        fprintf(stderr, "pctv-monitor: warning: capture queue 3/4 full (%d of %d"
                        " frames) - the sink is slower than the tape. It will"
                        " stop the capture rather than drop pictures when it"
                        " fills (now at %d ms of cushion).\n",
                depth, vq_n, vq_n * FRAME_MS);
        show_overlay(20000);
    }
}

/* ---- the commit: build this picture's 40 ms of sound --------------------
 * Pulls RAW samples from the ring, resamples them to the file's demand and
 * stages exactly `need` audio frames in a_chunk - the sound half of the
 * picture that went into the video pipe just before this call.  Writer thread
 * only, and it is the only producer of the audio pipe, which is the whole
 * sync story: every byte of sound in the file sits in a chunk that was built
 * for a specific committed picture, in that picture's order.
 *
 * The ring is drained in RS_MAX_OUT-frame linearised passes (it wraps, and
 * rs_run_into wants contiguous input); bytes are reserved with aq_sent across
 * the resample so a producer eviction cannot eat what is mid-transform, and
 * only the consumed prefix is released - whatever the step did not reach
 * stays in the ring for the next picture, which is exactly where the phase
 * measurement (E, in rs_update) expects to find it.
 *
 * When the ring cannot cover the demand, the tail of the chunk is padded with
 * soft silence (rs_pad_into): that is the drain-side seam, and it opens when
 * live sound was not arriving - the device gone, the ALSA thread starved, or
 * the moment between cap_start and the first PCM.  Padding is not free and is
 * not pretending to be: the tracks stay equal, E still reports the true debt
 * afterwards, and the controller then stretches the samples that come back
 * (within RS_PPM_MAX) to walk the late sound onto its lips.
 *
 * Frame 0 is special: everything the ring holds beyond one queue-worth of
 * sound when the first picture commits is PRE-ROLL - sound captured before the
 * file's first picture existed.  It is dropped whole (inaudible, and nothing
 * later should pay for it), while the part the queued pictures own stays in
 * line.  Either way the take starts with the two backlogs equal, which is
 * what E = 0 means and why the clock has nothing invented to chase. */
static void a_make_chunk(void)
{
    size_t need = (size_t)((unsigned long long)audio_rate * FRAME_MS / 1000ull);
    if (need > A_CHUNK_MAX) need = A_CHUNK_MAX;         /* 205 kHz would be safe */
    if (!need) { a_chunk_frames = a_chunk_pos = 0; return; }

    pthread_mutex_lock(&vq_mtx);
    if (rs_vframes == 0) {                  /* first commit of this take: drop
                                             * the PRE-ROLL - the sound captured
                                             * before the file's first picture
                                             * existed (cap_start can wait up to
                                             * 2 s on the PCM coming up).  It is
                                             * inaudible (nothing of the tape
                                             * precedes it), and committing it
                                             * would hang a lip error over the
                                             * head of the take and charge it to
                                             * E for all of the take.  But the
                                             * queue keeps ITS sound: if the sink
                                             * was already behind when frame 0
                                             * landed, the oldest queued picture
                                             * is older than this moment and the
                                             * ring's oldest bytes are its audio,
                                             * not pre-roll.  Keeping exactly
                                             * queue-worth of ring drops the
                                             * pre-roll and nothing else, and
                                             * starts the take at E = 0.
                                             * (Clearing everything was the old
                                             * behaviour, and correct only for
                                             * the usual case of a queue that is
                                             * empty at frame 0.) */
        unsigned long long keep = ((unsigned long long)vq_count + 1)
                                * FRAME_MS * aq_bytes_per_ms();  /* bytes; +1 for
                                 * the frame being committed - it is vq_held, not
                                 * vq_count, and the ring's newest 40 ms is its
                                 * audio.  Forgetting it padded 40 ms of silence
                                 * onto the head of every take and left a 40 ms
                                 * lip error E could never see. */
        if ((unsigned long long)aq_count > keep) {
            size_t drop = (size_t)((unsigned long long)aq_count - keep);
            aq_head = (aq_head + drop) % AQ_BYTES;
            aq_count -= drop;
        }
        aq_raw_frames = 0;                  /* the crystal window starts here too:
                                             * pre-roll bytes never reached E and
                                             * must not reach the flow term */
    }
    size_t got = 0;
    for (;;) {
        /* The input stream is [rs_front .. ring] (see rs_front for why a
         * restored record lands in front of the ring instead of inside it:
         * the ring's own read window and the producer's eviction are both
         * ring-circular-buffer facts this keeps untouched).  The window is
         * overfed exactly like the pre-spill code overfed it - whatever the
         * step did not reach is replayed by the next call: in the ring by
         * the aq_sent release below, in the stub by a cursor that only
         * advances by what was consumed.  Two mechanisms, one stream. */
        size_t fneed = rs_front_len - rs_front_pos;
        size_t avail = (aq_count - aq_sent) & ~(size_t)3;
        size_t takeb = fneed + avail;
        if (takeb > (size_t)RS_MAX_OUT * 4) takeb = (size_t)RS_MAX_OUT * 4;
        if (!takeb || got >= need) break;             /* stream dry: pad below */
        size_t fromf = takeb < fneed ? takeb : fneed;
        if (fromf) memcpy(rs_buf, rs_front + rs_front_pos, fromf);
        if (takeb > fromf) {
            size_t off = (aq_head + aq_sent) % AQ_BYTES;
            size_t first = takeb - fromf;
            if (first > AQ_BYTES - off) first = AQ_BYTES - off;
            memcpy((char *)rs_buf + fromf, aq + off, first);
            if (takeb - fromf > first)
                memcpy((char *)rs_buf + fromf + first, aq, takeb - fromf - first);
        }
        size_t fromr = takeb - fromf;        /* only ring bytes need reserving */
        aq_sent += fromr;
        pthread_mutex_unlock(&vq_mtx);

        size_t used = 0;
        size_t produced = rs_run_into(rs_buf, takeb / 4, a_chunk + got,
                                      need - got, &used);
        got += produced;

        pthread_mutex_lock(&vq_mtx);
        /* Release what the resampler actually consumed, stub first: the stub
         * needs no release bookkeeping (it is a cursor, and an unfinished
         * residue at rs_front_len stays put for the NEXT picture - it is the
         * front of its chunk), while ring bytes leave the ring proper. */
        if (used) {
            size_t usedb = used * 4;
            size_t from_f = usedb <= fromf ? usedb : fromf;
            rs_front_pos += from_f;                 /* stub: a cursor, and an
                                                     * unfinished residue stays
                                                     * put for the next commit */
            size_t rel = usedb - from_f;            /* ring bytes consumed */
            if (rel) {
                aq_head = (aq_head + rel) % AQ_BYTES;
                aq_count -= rel;
            }
            aq_sent -= rel;                         /* exactly the pre-spill
                                                     * rule: what the window
                                                     * did not spend stays
                                                     * reserved for the next
                                                     * pass */
            if (rs_front_pos == rs_front_len)
                rs_front_len = rs_front_pos = 0;    /* stub drained: rewind */
        }
        if (!used && !produced) break;      /* cannot happen (4-byte frames);
                                             * bounded either way, no spin */
    }
    aq_sent = 0;                            /* release anything reserved unbuilt */
    pthread_mutex_unlock(&vq_mtx);

    if (got < need) {
        rs_pad_into(a_chunk, got, need - got);
        got = need;
    }
    a_chunk_frames = got;
    a_chunk_pos = 0;
}

static void *vq_thread(void *unused)
{
    /* Above the parser/renderer: this is the only consumer of both capture rings
     * and of ffmpeg's two pipes, so if it cannot run the producers' rings fill
     * and pictures are evicted.  Its own work is tiny (one 829 KB frame and the
     * audio backlog per pass) and every loop it has is bounded, so it cannot
     * starve the parser by being here. */
    pctv_thread_prio("pctv-monitor/writer", 9);
    int saw_capture = 0;            /* cap_on has been seen on: it is a teardown,
                                     * not the few milliseconds between starting
                                     * the writer thread and cap_start() setting
                                     * cap_on (clearing the rings there would
                                     * silently shave the head off the audio). */
    for (;;) {
        /* Wait for work.  The bounded nap IS the writer's clock (5 ms when there
         * is something to do, 20 ms when idle); the queue is what makes its
         * granularity free.  (CLOCK_REALTIME because that is what a default
         * condvar times out on - CLOCK_MONOTONIC waits for nearly forever.) */
        pthread_mutex_lock(&vq_mtx);
        /* A chunk of sound waiting for its picture's pipe is work; a ring
         * full of audio with no picture to pair it with is NOT - the coupled
         * design never drains audio on its own. */
        int idle = !vq_count && !sp_count && !vq_cur && !a_chunk_frames;
        int stopping = vq_stop;
        if (!stopping) {
            struct timespec ts;
            clock_gettime(CLOCK_REALTIME, &ts);
            ts.tv_nsec += (idle ? 20 : 5) * 1000000L;
            if (ts.tv_nsec >= 1000000000L) { ts.tv_nsec -= 1000000000L; ts.tv_sec++; }
            pthread_cond_timedwait(&vq_cv, &vq_mtx, &ts);
        }
        int work = vq_count || sp_count || vq_cur || a_chunk_frames;
        pthread_mutex_unlock(&vq_mtx);
        if (stopping && !work) break;

        int vfd, afd;
        if (cap_get(&vfd, &afd) < 0) {         /* capture ended / encoder died */
            if (stopping) break;
            /* Nothing can be written any more (cap_died() has already said so),
             * but the frames keep arriving.  Release them here rather than let
             * the queue fill up: a dead encoder used to be reported as thousands
             * of `skip's, which reads like the capture path lost the tape. */
            if (saw_capture) {
                pthread_mutex_lock(&vq_mtx);
                vq_head = 0; vq_count = 0; vq_held = -1;
                aq_head = aq_count = aq_sent = 0;
                sp_head = sp_tail = sp_pre = 0; sp_count = sp_sound = 0;
                if (sp_fd >= 0) { close(sp_fd); sp_fd = -1; }
                pthread_mutex_unlock(&vq_mtx);
                a_chunk_frames = a_chunk_pos = 0;   /* we own it: no lock needed */
                rs_front_len = rs_front_pos = 0;
                vq_cur = NULL; vq_cur_spill = 0; vq_off = 0;
            }
            usleep(20000);
            continue;
        }
        saw_capture = 1;

        /* ---- commit machine -------------------------------------------------
         * One commit = one picture + one audio chunk (the 40 ms over it),
         * written to the two pipes in that order, by this thread and by no
         * one else. That pairing is the entire A/V sync guarantee: since
         * nothing outside a commit appends to the audio pipe, the muxer can
         * never see one stream ahead of the other by more than a half
         * commit, the interleave limit cannot be reached, and the sound a
         * picture carries is the sound of that picture's own commit moment -
         * which moment, within RS_PPM_MAX of the samples, the phase
         * measurement E = queue - ring (see rs_update) decides.
         *
         * The stages advance one half-commit each and hand off:
         *
         *   chunk pending -> finish writing it. When it is in, the commit is
         *       complete: count the pair, re-measure the clock. Until it is
         *       in, the NEXT picture waits: a stall of the audio pipe costs
         *       queue depth, never divergence.
         *   picture in flight -> resume it. When it lands, build its chunk
         *       (a_make_chunk) and write that on this same pass.
         *   neither -> take the next picture: the queued one, or a duplicate
         *       if the SOURCE has stopped.
         *
         * CARD CLOCK, and since 2026-11-04 the only kind: a queued frame is
         * committed the moment it exists, so the file's cadence is the card's
         * and no crystal disagreement can evict a frame. The wall clock is
         * only a watchdog on a source that stopped producing at all (paused
         * deck, input switch, dead card): nothing arriving for a frame period
         * plus VQ_GRACE_MS and nothing waiting to be parsed, and the last
         * picture is repeated so the file stays 25 fps. A repeat now takes
         * the live sound from the ring exactly like a real frame - a still
         * picture with the room's hum under it, which is what the tape has
         * under a tracking hold too. (Cutting 40 ms of audio per repeat, the
         * pre-coupling rule, is what walked whole takes an early second:
         * see cap_feed_video.)
         *
         * Draining (stop pressed) is not the time to invent pictures: only
         * real queued frames go out - RAM block first, then the file's
         * records, oldest to newest - and when both are empty the thread is
         * done.  (Counting the duplicate source as "work" here is what
         * made cap_stop() hang: the writer re-sent the last frame into
         * ffmpeg forever, the main loop stopped pumping the probe, and 480 MB
         * of tape went past into a full stream queue.)
         */
        int linked = cap_has_audio && afd >= 0;   /* does this file carry sound? */
        for (int stage = 0; stage < 3; stage++) {
            if (vq_abandon) break;        /* sink gone: the rings are empty too */

            if (linked && a_chunk_frames) {
                /* The sound half of the picture that landed on the previous
                 * stage - resumable like everything else here. */
                size_t wantb = a_chunk_frames * 4 - a_chunk_pos;
                size_t d = 0;
                int st = pipe_write(afd, (const unsigned char *)a_chunk +
                                    a_chunk_pos, wantb, 3000, &d);
                a_chunk_pos += d;
                if (d) {
                    vq_progress_ms = SDL_GetTicks();
                    pthread_mutex_lock(&cap_mtx);
                    cap_abytes += d;
                    pthread_mutex_unlock(&cap_mtx);
                }
                if (st == 0) {
                    a_chunk_frames = a_chunk_pos = 0;
                    rs_vframes++;                 /* the pair is in the file */
                    rs_update();                  /* ADC and phase, live */
                } else if (st == -1) {            /* the reader is gone */
                    pthread_mutex_lock(&cap_mtx);
                    cap_adrops++;
                    cap_adrop_bytes += a_chunk_frames * 4 - a_chunk_pos;
                    pthread_mutex_unlock(&cap_mtx);
                    a_chunk_frames = a_chunk_pos = 0;
                    cap_died();
                }
                break;              /* -2: the audio pipe is full; next pass in */
            }

            if (vq_cur) {
                /* The picture half, resumed where the pipe last left off.  It
                 * lives in a RAM slot or in the spill staging buffer - the
                 * write itself cannot tell and does not need to. */
                unsigned long m = SDL_GetTicks();
                size_t done = 0;
                int st = pipe_write(vfd, vq_cur + vq_off, UV_SIZE - vq_off,
                                    3000, &done);
                vq_off += done;
                if (done) vq_progress_ms = SDL_GetTicks();   /* the sink is alive */
                if (st == 0) {
                    pthread_mutex_lock(&cap_mtx);
                    cap_vframes++;
                    if (vq_slot_dup) cap_vrepeats++;
                    pthread_mutex_unlock(&cap_mtx);
                    int dup = vq_slot_dup;
                    if (vq_cur_spill) {
                        /* Keep the duplicate-source invariant (see the queue
                         * block): the most recent picture must be in a RAM
                         * slot even when it arrived from disk, so a later
                         * duplicate never needs a disk read.  No lock: the
                         * writer owns vq_held - the producer never touches
                         * the held slot, and nothing popped since this commit
                         * was taken (a spilled commit is only ever taken with
                         * the RAM queue empty). */
                        if (vq_held >= 0 && vq_held < vq_n)
                            memcpy(vq[vq_held], sp_in, UV_SIZE);
                    }
                    vq_cur = NULL; vq_cur_spill = 0; vq_off = 0;
                    if (dup)
                        /* A repeat is not a real-time event, so the watchdog
                         * moves by exactly one frame instead of re-anchoring:
                         * a long stall emits one repeat per 40 ms until the
                         * file is back at real time, and not one longer. */
                        vq_last_ms += FRAME_MS;
                    else vq_last_ms = m;
                    if (linked) {
                        a_make_chunk();                 /* its sound, now ... */
                        continue;                       /* ... written this pass */
                    }
                    rs_vframes++;                       /* video-only: the frame
                                                         * IS the pair */
                    rs_update();
                    continue;
                } else if (st == -1) {          /* the reader is gone: EPIPE */
                    pthread_mutex_lock(&cap_mtx); cap_vdrops++;
                    pthread_mutex_unlock(&cap_mtx);
                    vq_cur = NULL; vq_cur_spill = 0; vq_off = 0;
                    a_chunk_frames = a_chunk_pos = 0;
                    cap_died();
                    break;
                } else if (stopping &&
                           ((long)(SDL_GetTicks() - vq_drain_deadline) >= 0 ||
                            (g_quit && (long)(SDL_GetTicks() - vq_progress_ms) >=
                                        (long)VQ_DRAIN_STALL_MS))) {
                    /* Give up on the WHOLE queue here, in one decision: giving
                     * up a frame at a time would cost a fresh pipe_write
                     * timeout for each of the ~150 queued pictures - 3 s x 148,
                     * longer than any tape, and from the outside
                     * indistinguishable from the lockup this file exists to
                     * prevent.  Two different waits, because they answer to two
                     * different people.  A stall nobody asked about keeps its
                     * full grace (30 s + 100 ms a frame): those queued
                     * pictures are tape, and a sink that was only slow does
                     * come back and takes them with it.  A QUIT is the operator
                     * overruling that - three seconds of silence and the rest
                     * is discarded, because an unkillable player is not what
                     * they asked for.  This is now the ONE way a picture can
                     * still be lost, so it is counted, named in the log, and
                     * only ever reaches the tail of the file - never a hole in
                     * the middle. */
                    /* The one way a picture is lost now: everything the sink
                     * never got - RAM queue, spill file, the in-flight commit
                     * and all of their sound - is counted and cleared in one
                     * place, because since the spill arrived the dropped set
                     * is bigger than the queue. */
                    vq_abandon_all(1);                /* 1: commit in flight */
                    vq_cur = NULL; vq_cur_spill = 0; vq_off = 0;
                    a_chunk_frames = a_chunk_pos = 0; /* the sound half of the
                                                       * frame given up on */
                    break;
                }
                /* st == -2: ffmpeg is behind. Keep the half-written frame and
                 * carry on - the ring in front is what a real backlog belongs
                 * in. */
                break;
            }

            /* ---- next picture ---------------------------------------------
             * The two reasons the queue can be empty get told apart here:
             * the SOURCE stopped producing (nothing will arrive until someone
             * acts - repeat the picture to keep the file at 25 fps) against
             * the HOST being slow (the bytes are waiting in the probe's ring
             * and will be parsed any moment - repeating now would make the
             * video track longer than the tape, see ARR_N and
             * stream_pending). */
            unsigned long m = SDL_GetTicks();
            pthread_mutex_lock(&vq_mtx);
            int queued = vq_count;
            unsigned long long spilled = sp_count;
            int arrivals = 0;
            for (int i = 0; i < ARR_N; i++)
                if (arr_t[i] && (long)(m - arr_t[i]) <= ARR_WINDOW_MS) arrivals++;
            pthread_mutex_unlock(&vq_mtx);

            int take = 0, want_dup = 0;
            if (stopping)
                take = queued > 0 || spilled > 0;   /* a drain drains BOTH */
            else if (queued > 0 || spilled > 0)
                take = 1;
            else if (arrivals < ARR_N / 2 && !stream_pending() &&
                     (long)(m - vq_last_ms) >= (long)(FRAME_MS + VQ_GRACE_MS)) {
                /* nothing queued, nothing on disk, nothing waiting to be
                 * parsed, nothing has arrived recently: the source has
                 * really stopped */
                take = 1;
                want_dup = 1;
            }
            if (!take) break;

            int slot = -1, dup = 0, from_spill = 0;
            if (queued == 0 && spilled > 0) {
                /* The RAM block is drained, so the file's head record IS the
                 * next pair (see the spill block's routing rule).  Two
                 * preads because a record's sound length lives in its
                 * header: the body then reads exactly what was written -
                 * never a short read off the end of the allocation, and
                 * never bytes of the record behind it.  No lock around the
                 * reads: sp_head is this thread's while sp_count > 0, the
                 * producer only appends at sp_tail, and the fd is never
                 * closed while a restore might be here. */
                struct spill_rec h;
                ssize_t r;
                do r = pread(sp_fd, &h, sizeof h, (off_t)sp_head);
                while (r < 0 && errno == EINTR);
                if (r != (ssize_t)sizeof h || h.magic != SPILL_MAGIC ||
                        h.audio > sp_audio) {
                    spill_lost("the scratch file's record header did not read"
                               " back intact (a disk error)");
                    break;
                }
                size_t body = UV_SIZE + h.audio;
                unsigned char *bp = sp_in + SPILL_HDR;
                size_t got = 0;
                while (got < body) {
                    do r = pread(sp_fd, bp + got, body - got,
                                 (off_t)(sp_head + SPILL_HDR + got));
                    while (r < 0 && errno == EINTR);
                    if (r <= 0) break;
                    got += (size_t)r;
                }
                if (got != body) {
                    spill_lost("a record did not read back from the scratch"
                               " file (a disk error)");
                    break;
                }
                pthread_mutex_lock(&vq_mtx);
                sp_head += SPILL_HDR + body; sp_count--; sp_sound -= h.audio;
                int drained = sp_count == 0;
                pthread_mutex_unlock(&vq_mtx);
                if (drained && cap_spill_frames)
                    fprintf(stderr, "pctv-monitor: spill done: the sink caught"
                                    " up, all %llu pairs that went to local"
                                    " disk this take are back in the file."
                                    " Continuing from live.\n",
                            cap_spill_frames);
                if (h.audio) {
                    /* The record's sound goes in FRONT of the ring: while
                     * the file holds records its head carries only crystal
                     * surplus (older than every record) and post-record
                     * live bytes (newer than all of them), and the chunk
                     * this commit builds has to see the capture-order
                     * stream [stub .. ring] (see rs_front).  Compact the
                     * previous commit's residue down first: small move, not
                     * a hot path. */
                    if (rs_front_pos) {
                        memmove(rs_front, rs_front + rs_front_pos,
                                rs_front_len - rs_front_pos);
                        rs_front_len -= rs_front_pos;
                        rs_front_pos = 0;
                    }
                    if (rs_front_len + h.audio > RS_FRONT_MAX) {
                        /* Two full records plus slack is the budget, a
                         * commit leaves a crystal fraction of one behind,
                         * and getting here means the drift outgrew that
                         * across the whole backlog - a fact, not a
                         * warning, and it lands like any other lost read
                         * rather than wrapping sound around the buffer. */
                        spill_lost("the drain stub overflowed: the ADC drift"
                                   " outgrew the spill accounting");
                        break;
                    }
                    memcpy(rs_front + rs_front_len, bp + UV_SIZE, h.audio);
                    rs_front_len += h.audio;
                }
                from_spill = 1;
            } else {
                pthread_mutex_lock(&vq_mtx);
                if (vq_count > 0) {
                    vq_held = vq_head;               /* the old one is released */
                    vq_head = (vq_head + 1) % vq_n;
                    vq_count--;
                    slot = vq_held;
                } else if (vq_held >= 0 && want_dup) {
                    slot = vq_held;                  /* nothing new: re-send it */
                    dup = 1;
                }
                pthread_mutex_unlock(&vq_mtx);
            }
            if (slot < 0 && !from_spill) break;      /* no picture yet */
            vq_cur = from_spill ? sp_in + SPILL_HDR : vq[slot];
            vq_cur_spill = from_spill;               /* ours until it is in */
            vq_off = 0;
            vq_slot_dup = dup;
        }
        cap_put();
    }
    return NULL;
}

/* Returns 0 when the queue is live (slots allocated, writer thread running),
 * -1 if it could not be - capture must then not start, because every frame
 * would have nowhere to go. */
static int vq_start(void)
{
    static int prefaulted;
    for (int i = 0; i < vq_n; i++)
        if (!vq[i]) vq[i] = malloc(UV_SIZE);
    for (int i = 0; i < vq_n; i++)
        if (!vq[i]) return -1;
    if (!aq) { aq = malloc(AQ_BYTES); if (!aq) return -1; }
    /* Pre-fault and lock the rings.  They are written from the frame assembly
     * (main thread) and the ALSA thread; a first-touch page fault in either is a
     * 4 KB disk-backed stall in the middle of a field.  20 MB of memset here
     * costs ~4 ms, once, instead.  mlock needs an `memlock` login limit (the
     * live-module gives @wheel one); it is refused harmlessly otherwise. */
    if (!prefaulted) {
        prefaulted = 1;
        for (int i = 0; i < vq_n; i++) {
            memset(vq[i], 0, UV_SIZE);
            if (mlock(vq[i], UV_SIZE) != 0) {
                fprintf(stderr, "pctv-monitor: mlock of the frame queue: %s "
                                "(pre-faulted anyway)\n", strerror(errno));
                break;
            }
        }
        memset(aq, 0, AQ_BYTES);
        mlock(aq, AQ_BYTES);
    }
    rs_reset();
    /* A new take starts with no scratch file and no backlog.  The staging
     * buffers are once per process (they are 830 KB each and cost nothing
     * idle); if their allocation ever failed the spill quietly degrades to
     * the pre-2026-11-04 behaviour - spill_append says so once, on the
     * first use, and the capture ends where it used to end. */
    if (!sp_out) sp_out = malloc(SP_IN_MAX);
    if (!sp_in)  sp_in  = malloc(SP_IN_MAX);
    if (sp_fd >= 0) { close(sp_fd); sp_fd = -1; }
    sp_head = sp_tail = sp_pre = 0; sp_count = sp_sound = 0;
    cap_spill_frames = 0; sp_fail_logged = 0; sp_note[0] = '\0';
    /* The hole detector starts from here, not from whenever the ALSA thread last
     * happened to read: an anchor from before this take would be read as one
     * enormous hole and filled with 2 s of invented silence in front of frame 0. */
    a_anchor_us = 0;
    a_content_us = 0;
    aq_reset();
    a_chunk_frames = a_chunk_pos = 0;
    vq_head = vq_count = vq_stop = 0;
    vq_stopping = 0;
    vq_abandon = 0;
    vq_want_stop = 0; vq_warned = 0;
    fprintf(stderr, "pctv-monitor: capture queue: %d slots = %d ms of sink-stall"
                    " cushion (%.0f MB)\n", vq_n, vq_n * FRAME_MS,
            (double)vq_n * UV_SIZE / 1048576.0);
    if (spill_cap_mb)
        fprintf(stderr, "pctv-monitor: spill: local-disk overflow on %s, cap"
                        " %llu MB (PCTV_SPILL_DIR, PCTV_SPILL_MB)\n",
                spill_dir, spill_cap_mb);
    else
        fprintf(stderr, "pctv-monitor: spill: DISABLED (PCTV_SPILL_MB=0): a full"
                        " queue ends the capture (the pre-2026-11-04"
                        " behaviour)\n");
    vq_held = -1;
    vq_cur = NULL; vq_cur_spill = 0; vq_off = 0; vq_slot_dup = 0;
    vq_last_ms = SDL_GetTicks();
    memset(arr_t, 0, sizeof arr_t);
    arr_i = 0;
    if (!vq_started) {
        if (pthread_create(&vq_thr, NULL, vq_thread, NULL) != 0) return -1;
        vq_started = 1;
    }
    return 0;
}

static void vq_stop_and_drain(void)
{
    if (!vq_started) return;
    /* Refuse new audio when the ring is filling up.  The writer exits when the
     * queue is empty, and the ALSA thread would otherwise keep filling it faster
     * than it can be drained - it did exactly that for 50 s and hung the whole
     * shutdown, and everything downstream of it with it (the main loop stops
     * pumping the probe while it waits).  Half a ring = 10.4 s is the bound, and
     * under the coupled design that number has a real meaning: no drain can
     * ever need more, because the deepest the picture queue is allowed to be is
     * 6 s and each of those frames wants exactly the 40 ms already in there.
     * (The 21 s ring, against the 10 s matroska interleave limit the old design
     * had to respect, is a luxury only the coupling can afford: the muxer sees
     * both streams move 40 ms at a time, together.) */
    pthread_mutex_lock(&vq_mtx);
    vq_stopping = 1;
    unsigned long qn = (unsigned)(vq_count + sp_count + (vq_held >= 0 ? 1 : 0));
    vq_drain_deadline = SDL_GetTicks() + 30000u + qn * 100u;
    vq_progress_ms = SDL_GetTicks();
    vq_stop = 1;
    pthread_cond_broadcast(&vq_cv);
    pthread_mutex_unlock(&vq_mtx);
    pthread_join(vq_thr, NULL);
    aq_closed = 1;
    if (vq_drain_dropped)
        fprintf(stderr, "pctv-monitor: LOST PICTURES: the sink stopped taking data"
                        " and the drain ran out of patience - %llu queued picture(s)"
                        " were dropped, so the file ends %0.1f s early. Everything up"
                        " to there is complete.\n",
                vq_drain_dropped, (double)vq_drain_dropped * FRAME_MS / 1000.0);
    vq_drain_dropped = 0;
    vq_started = 0;
    vq_held = -1;
    /* The writer is joined: nobody restores and nobody appends any more.  A
     * drained file is normally already at EOF-as-end; either way this is
     * where the unlinked file's space comes back. */
    if (sp_fd >= 0) { close(sp_fd); sp_fd = -1; }
}

static int cap_start(void)
{
    /* Resolve the audio device FIRST.  The audio thread opens the PCM
     * asynchronously, so give it up to 2 s rather than silently producing a
     * video-only file - and do it before vq_start(), because that is where the
     * rings are emptied: frames are now queued the moment they are assembled, so
     * anything the parse below produces during this wait would otherwise be real
     * pictures waiting in front of an encoder that is not running yet (and 2 s of
     * them is more than the ring holds). */
    if (cur_src != 0) {
        for (int wait = 0; wait < 40; wait++) {
            pthread_mutex_lock(&amtx);
            int up = audio_ok;
            pthread_mutex_unlock(&amtx);
            if (up) break;
            pump();                 /* keep the stream moving while we wait */
            usleep(50000);
        }
    }
    pthread_mutex_lock(&amtx);
    cap_has_audio = audio_ok;
    pthread_mutex_unlock(&amtx);

    if (vq_start() < 0) {          /* the writer thread that owns both pipes */
        fprintf(stderr, "pctv-monitor: cannot start the capture queue "
                        "(out of memory?) - not capturing\n");
        return -1;
    }
    int vp[2], ap[2];
    if (pipe(vp) < 0) return -1;
    if (pipe(ap) < 0) { close(vp[0]); close(vp[1]); return -1; }
    /* 8 MiB = 10 frames of cushion between the writer thread and ffmpeg's
     * encoder; the old unchecked 4 MiB request was silently refused (it is
     * above fs.pipe-max-size), leaving the default 64 KiB = two frames. */
    pipe_slack(vp[1], 8, "encoder video");
    pipe_slack(ap[1], 1, "encoder audio");
    /* Both ends stay BLOCKING now: the writer thread is the only writer, it is
     * nobody's deadline, and a stalled encoder should cost queue depth rather
     * than samples or pictures.  Dropping on EAGAIN was the old design's way of
     * keeping the main loop responsive; 5.5 s of audio ring and 480 ms of video
     * queue keep it far better than that ever did. */

    /* Both ends are NON-BLOCKING and stay that way: pipe_write() polls, waits up
     * to its deadline and then reports a drop, which is bounded; a blocking write
     * is not (see pipe_write).  The cushion against a slow encoder is the two
     * rings in front of it - 5.5 s of audio and 480 ms of video - plus the 8 MiB
     * pipe, not a thread parked in the kernel.
     *
     * And aq_closed matters at stop: ffmpeg's s16le input will happily wait for
     * samples it is never going to get, so refusing new audio at stop time must
     * be paired with writes that cannot block, or the muxer deadlocks against the
     * writer thread (observed: SIGTERM at 90 s, still hung 2 minutes later with
     * the writer parked in write() on a full video pipe). */
    {   int fl2;
        if ((fl2 = fcntl(vp[1], F_GETFL, 0)) >= 0) fcntl(vp[1], F_SETFL, fl2 | O_NONBLOCK);
        if ((fl2 = fcntl(ap[1], F_GETFL, 0)) >= 0) fcntl(ap[1], F_SETFL, fl2 | O_NONBLOCK);
    }

    /* Only mux audio if the capture stream is actually up - resolved above, so
     * this is now just the decision, not the wait. */
    stamp_name(cap_path, sizeof cap_path, "pctv-cap",
               cap_master == MASTER_DVD ? "mpg" : "mkv");

    char vsize[32], br[32], ar[32];
    snprintf(vsize, sizeof vsize, "%dx%d", W, H);
    snprintf(br, sizeof br, "%dk", mpeg2_kbps);
    snprintf(ar, sizeof ar, "%d", audio_rate);

    /* 64 slots, and the count is checked below: 48 looked like plenty until
     * -fps_mode pushed the DVD branch to exactly 49 argv entries and the NULL
     * terminator landed past the end of the array.  gcc -O0/-O2 disagree about
     * what that breaks - the nix-built binary then handed ffmpeg `-s ""` and died
     * with `Unable to parse "video_size" option value ""`, while the locally
     * built one happened to work.  Build the way it ships. */
    char *av[64]; int n = 0;
    av[n++] = ffmpeg_path;
    av[n++] = "-y";
    av[n++] = "-loglevel"; av[n++] = "error";
    av[n++] = "-f"; av[n++] = "rawvideo";
    av[n++] = "-pix_fmt"; av[n++] = "uyvy422";
    av[n++] = "-s"; av[n++] = vsize;
    av[n++] = "-r"; av[n++] = "25";
    /* The picture is top-field-first (derivation in the dvd branch below), and
     * for a raw source the command line is the only place ffmpeg will take that
     * from - so it goes on the INPUT, for EVERY master.  Measured on this box
     * with the same rawvideo demuxer the pipe uses, mpeg2video +ilme+ildct:
     *
     *     -field_order tt  before -i   -> field_order=tt, top_field_first=1  OK
     *     -field_order tt  on output   -> field_order=bb, top_field_first=0   WRONG
     *     (nothing)                    -> field_order=bb, top_field_first=0   WRONG
     *
     * The encoder records the order it is TOLD, and a raw demuxer tells it
     * nothing, so an output-side flag leaves the bitstream asserting
     * bottom-first.  This flag is metadata only: decoding the same encode with
     * and without it and diffing the frames gives PSNR inf, so it cannot move a
     * pixel - it only stops every downstream consumer (idet, yadif/bwdif, ffms2,
     * mpv, AviSynth+) from laying the two fields out in the wrong time order.
     * ffprobe's stream-level spelling `tb` for it is a separate ffmpeg quirk;
     * the frame flag is the operative one. */
    av[n++] = "-field_order"; av[n++] = "tt";
    av[n++] = "-i"; av[n++] = "pipe:0";
    if (cap_has_audio) {
        av[n++] = "-f"; av[n++] = "s16le"; av[n++] = "-ar"; av[n++] = ar;
        av[n++] = "-ac"; av[n++] = "2"; av[n++] = "-i"; av[n++] = "pipe:3";
    }
    if (cap_master == MASTER_DVD) {
        av[n++] = "-c:v"; av[n++] = "mpeg2video";
        av[n++] = "-b:v"; av[n++] = br;
        av[n++] = "-maxrate"; av[n++] = br;
        av[n++] = "-bufsize"; av[n++] = "1835008";
        av[n++] = "-g"; av[n++] = "15";
        av[n++] = "-flags"; av[n++] = "+ilme+ildct";
        /* No -field_order here: on the output side it does nothing at all (see
         * the table above - it was this line, plus the belief that "mpeg2video
         * ignores -field_order", that made every .mpg this tool ever wrote
         * assert bottom-first while carrying a top-first picture.  It doesn't
         * ignore it; it was never being told.  The INPUT-side flag is the one
         * that reaches the picture coding extension.)
         *
         * Why the picture IS top-first, which no measurement on this content can
         * show (idet on two synthetic clips differing only in which field is
         * temporally first voted TFF 9/BFF 10 and TFF 10/BFF 9 - docs/
         * pctv-analog-capture.md §10.3): the deframer's F-bit branch puts BT.656
         * field 1 on the EVEN lines, 625/50 numbers the field containing line 1
         * as field 1 (so field 1 IS the top field) and displays the field it
         * transmitted first - the same reason DV-PAL is always TFF.
         *
         * Consequence for files made BEFORE this fix: `top_field_first` is a
         * bitstream syntax element of the MPEG-2 picture coding extension, so no
         * lossless remux can change it (`-c copy -field_order tt` rewrites only
         * the container label while the frames keep reading 0).  Those files have
         * to be TOLD to be TFF downstream - `ffplay -top 1 FILE`, AssumeTFF() in
         * AviSynth+, SetFieldBased(1) in VapourSynth - or re-encoded from the
         * master.  New .mpg files need neither. */
        av[n++] = "-aspect"; av[n++] = "4:3";
        if (cap_has_audio) { av[n++] = "-c:a"; av[n++] = "mp2"; av[n++] = "-b:a"; av[n++] = "192k"; }
        else av[n++] = "-an";
        av[n++] = "-sn";
        av[n++] = "-fps_mode"; av[n++] = "cfr";
        av[n++] = "-f"; av[n++] = "mpeg";
    } else {
        /* A lossless master, for post-processing on a fast machine.
         *
         * Deliberately no -vf of any kind: no bob, no yadif/bwdif, no scale, no
         * crop.  50 Hz temporal smoothness and progressive scan cannot both be
         * had from an interlaced source at full height without expensive
         * motion-compensated interpolation, and this box can afford neither; the
         * fields *are* the 50 Hz information, so the capture's job is to keep
         * them untouched and let QTGMC/bwdif on the big machine produce 50p at
         * full 576 lines (docs/pctv-320cx.md).  uyvy additionally avoids any
         * colourspace conversion, because that pixel format is what the deframer
         * already produces.
         *
         * Audio is PCM for the same reason MP2 is not: free and lossless.  And
         * nothing in this branch is rate-controlled, which is the property that
         * keeps a hard scene from costing a frame: detail makes the file bigger,
         * never the encoder late. */
        av[n++] = "-c:v";
        av[n++] = cap_master == MASTER_UYVY ? "rawvideo"
                : cap_master == MASTER_UTVIDEO ? "utvideo" : "ffv1";
        if (cap_master == MASTER_FFV1) { av[n++] = "-g"; av[n++] = "1"; }
        av[n++] = "-aspect"; av[n++] = "4:3";
        if (cap_has_audio) { av[n++] = "-c:a"; av[n++] = "pcm_s16le"; }
        else av[n++] = "-an";
        av[n++] = "-sn";
        av[n++] = "-fps_mode"; av[n++] = "cfr";
        av[n++] = "-f"; av[n++] = "matroska";
    }
    av[n++] = cap_path;
    av[n] = NULL;
    if (n + 1 >= (int)(sizeof av / sizeof av[0])) {
        fprintf(stderr, "pctv-monitor: internal error: ffmpeg argument array full "
                        "(%d entries) - not capturing\n", n);
        close(vp[0]); close(vp[1]); close(ap[0]); close(ap[1]);
        return -1;
    }
    if (getenv("PCTV_FFMPEG_DEBUG")) {     /* the whole line, quotes and all */
        fputc('[', stderr);
        for (int i = 0; i < n; i++) fprintf(stderr, " %s", av[i]);
        fprintf(stderr, " ] -> %d entries\n", n + 1);
    }

    pid_t pid = fork();
    if (pid < 0) { close(vp[0]); close(vp[1]); close(ap[0]); close(ap[1]); return -1; }
    if (pid == 0) {
        dup2(vp[0], STDIN_FILENO);          /* ffmpeg reads the video pipe */
        if (cap_has_audio) dup2(ap[0], 3);  /* ...and the audio pipe on fd 3 */
        close(vp[0]); close(vp[1]); close(ap[0]); close(ap[1]);
        /* We are SCHED_FIFO, so the encoder inherits it - and an RT encoder on
         * 2 cores starves the thread feeding it (and PipeWire), which is the
         * one thing that guarantees a stall.  It is the only stage on the path
         * that is throughput-bound rather than deadline-bound, so drop it back
         * to normal scheduling and let the 8 MiB encoder pipe (10 frames) be
         * its cushion. */
        pctv_drop_rt("pctv-monitor/ffmpeg");
        execvp(ffmpeg_path, av);
        fprintf(stderr, "pctv-monitor: exec %s failed: %s\n", ffmpeg_path, strerror(errno));
        _exit(127);
    }
    /* the parent keeps the write ends and drops the read ends, so ffmpeg sees
     * EOF the moment we close them */
    close(vp[0]); close(ap[0]);
    pthread_mutex_lock(&cap_mtx);
    cap_pid = pid; cap_vfd = vp[1]; cap_afd = ap[1]; cap_on = 1; cap_live = 1;
    cap_vframes = cap_vdrops = cap_adrops = cap_abytes = 0;
    cap_vrepeats = cap_vskips = cap_adrop_bytes = 0;
    cap_vrefused = 0; vq_want_stop = 0; vq_warned = 0;
    cap_qmax = 0;
    cap_t0 = time(NULL);
    cap_t0_tick = SDL_GetTicks();
    pthread_mutex_unlock(&cap_mtx);
    /* The blue-screen window belongs to a file, not to the process: anything
     * pumped while starting up (cap_start() waits for the audio) happened
     * before frame 0, and a new file re-asks "has anything played yet?". */
    blue_rearm();
    if (cap_master == MASTER_DVD)
        fprintf(stderr, "pctv-monitor: note: 'dvd' is the watching format - rate-"
                        "controlled (%d kbps, 1.8 MB VBV), so a hard scene can cost "
                        "a frame; --master ffv1 cannot\n", mpeg2_kbps);
    fprintf(stderr, "pctv-monitor: %s capture -> %s (audio %s, %s, pid %d)\n",
            MASTER_NAME[cap_master], cap_path,
            cap_has_audio ? srcs[cur_src].label : "OFF",
            cap_master == MASTER_DVD ? br : "lossless", pid);
    return 0;
}

static void cap_stop(void)
{
    vq_stop_and_drain();   /* flush both rings to ffmpeg, then reap the writer */
    pthread_mutex_lock(&cap_mtx);
    if (!cap_on && cap_pid < 0) { pthread_mutex_unlock(&cap_mtx); return; }
    cap_closing = 1;
    while (cap_refs) pthread_cond_wait(&cap_cv, &cap_mtx);   /* let feeds finish */
    int vfd = cap_vfd, afd = cap_afd;
    pid_t pid = cap_pid;
    cap_on = 0; cap_vfd = cap_afd = -1; cap_pid = -1; cap_live = 0;
    unsigned long long vf = cap_vframes, vd = cap_vdrops, ad = cap_adrops,
                       rp = cap_vrepeats, sk = cap_vskips, adb = cap_adrop_bytes;
    unsigned long long rf = cap_vrefused;
    unsigned long long ab = cap_abytes;
    int qmax = cap_qmax;
    cap_closing = 0;
    pthread_cond_broadcast(&cap_cv);
    pthread_mutex_unlock(&cap_mtx);

    if (vfd >= 0) close(vfd);                  /* EOF -> ffmpeg finalises the PS */
    if (afd >= 0) close(afd);
    if (pid > 0) {
        int st = 0, waited = 0;
        /* Ten seconds of "give it time to finalise the file" is right for an
         * encoder that is behind but alive, and madness for one the writer already
         * gave up on (or that has a full queue behind it): it is not going to flush.
         * One second there, ten otherwise. */
        int flush_ms = vq_abandon ? 1000 : 10000;
        while (waited < flush_ms) {            /* give it time to flush */
            pid_t r = waitpid(pid, &st, WNOHANG);
            if (r == pid) { pid = 0; break; }
            if (r < 0) { pid = 0; break; }
            pump();                           /* the live stream keeps running */
            usleep(10000); waited += 10;
        }
        /* A stopped or wedged child never sees SIGTERM: the signal is queued and
         * delivered only once it is continued, and the plain waitpid() that used to
         * follow this blocked forever.  That is the 2026-11-02 quit lockup one stage
         * further down the pipe from the probe - same circular wait, different
         * child - and it is reachable by pressing stop while the encoder is behind.
         * So: TERM, wake it, wait a bounded time; KILL, wake it, wait a bounded
         * time again; then walk away.  A zombie is reparented and reaped when this
         * process exits.  Nothing on a shutdown path is worth an unkillable
         * monitor. */
        for (int phase = 0; pid > 0 && phase < 2; phase++) {
            if (kill(pid, phase ? SIGKILL : SIGTERM) != 0 && errno == ESRCH) break;
            kill(pid, SIGCONT);
            for (int w = 0; w < 300; w++) {          /* up to 3 s per signal */
                pid_t r = waitpid(pid, &st, WNOHANG);
                if (r == pid || r < 0) { pid = 0; break; }
                pump();
                usleep(10000);
            }
        }
        if (pid > 0)
            fprintf(stderr, "pctv-monitor: encoder pid %d ignored SIGTERM and SIGKILL"
                            " (stopped or in uninterruptible sleep) - leaving it and"
                            " carrying on\n", (int)pid);
    }
    off_t sz = -1;
    struct stat sb;
    if (stat(cap_path, &sb) == 0) sz = sb.st_size;
    /* dup = the source stopped producing pictures for longer than a frame period
     * and the last one had to be repeated.  skip used to be "the encoder could
     * not keep up, so the oldest queued picture was evicted" - that policy is
     * gone, so any nonzero skip is a bug.  refused is the replacement: pictures
     * that arrived after the queue filled, i.e. the tape the file does NOT
     * contain because the capture was ended out loud.  None of them can be
     * caused by the two crystals disagreeing - that is the ppm figure below,
     * which is what the audio resampler is correcting. */
    /* The last three figures are the ones that decide whether this file can be
     * watched, and none of them used to exist: `silence` is sound the ADC lost
     * and the monitor stood in for (the tape's picture stays true to the tape's
     * sound either way - the only question is whether the hole sits where it
     * happened or is smeared over the rest of the take), `xruns` is how often
     * ALSA said so out loud, and `A/V phase` is what the two tracks disagree by
     * as the file closes.  That last one is a lip-sync error in milliseconds and
     * until 2026-11-04 nothing measured it, which is why a 2 h take could finish
     * 1.183 s out of step with every counter in this line reading zero. */
    unsigned long long sil = cap_a_silence_bytes, gaps = cap_a_gaps, xr = xruns_total;
    /* What the ring still held when the take ended: raw sound captured after
     * (or during) the last committed picture, which under the coupled design
     * is precisely the part of E the drain could not pay back.  A few hundred
     * ms is normal - it is the sound of the moment the stop button was
     * pressed, and a tape ends with the room, not on a lip.  Several seconds
     * means the picture queue was deep at the end and those frames were given
     * up on, and `drops` above names them. */
    pthread_mutex_lock(&vq_mtx);
    unsigned long long ring_tail = aq_count;
    pthread_mutex_unlock(&vq_mtx);
    unsigned long long bpm = aq_bytes_per_ms();
    int ring_tail_ms = bpm ? (int)(ring_tail / bpm) : 0;
    fprintf(stderr, "pctv-monitor: capture stopped: %s (%lld B, %llu frames "
                    "[dup %llu, skip %llu, refused %llu, spill %llu, qmax %d/%d frames = %d ms], "
                    "%llu B audio "
                    "(%llu B silence for %llu PCM holes, %llu B padded at the drain), "
                    "%llu video drops, %llu audio drops/%llu B, %llu xruns, "
                    "ADC %+d ppm vs the card, A/V phase %+d ms, ring tail %d ms, "
                    "%llu clock windows discarded)\n",
            cap_path, (long long)sz, vf, rp, sk, rf, cap_spill_frames, qmax, vq_n, vq_n * FRAME_MS, ab,
            sil, gaps, rs_pad_frames * 2u * 2u,
            vd, ad, adb, xr,
            (int)lrint((rs_step - 1.0) * 1e6), rs_phase_ms, ring_tail_ms,
            rs_bad_windows);
    if (abs(rs_phase_ms) > 100)
        fprintf(stderr, "pctv-monitor: this file's sound is %d ms %s the picture at"
                        " the point it stopped - the resampler could not pay that"
                        " back inside the tape it had left. Watch the tail, not the"
                        " head.\n",
                abs(rs_phase_ms), rs_phase_ms > 0 ? "ahead of" : "behind");
    /* Only ffv1 and rawvideo write the field order into the file; utvideo (and
     * every other lossless codec available here) writes neither the bitstream
     * flag nor a container element, so a plain player sees progressive frames
     * and either combs or drops to 25p.  One stream copy fixes the container. */
    if (cap_master == MASTER_UTVIDEO)
        fprintf(stderr, "pctv-monitor: utvideo carries no field-order flag - run "
                        "`pctv-field-order --relabel %s` to make it top-field-first\n",
                cap_path);
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
    unsigned long cl_t = clip_last_t;
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

    snprintf(t, sizeof t, "L %6.1f  R %6.1f  pk %6.1f  gain %+.1f dB%s", p0, p1,
             h0 > h1 ? h0 : h1, g + bo,
             agc ? "  [AGC]" : (bo != 0.0 ? "  (cap + boost)" : ""));
    draw_text(ren, x, y + 2 * bh + 9, 1, t);

    const char *verdict;
    unsigned char col[3] = { 235, 235, 235 };
    double pk = h0 > h1 ? h0 : h1;
    /* TOO HOT is about clipping now, not about a clip that happened once: the
     * counter is cumulative and would keep the warning up forever. */
    int hot = (SDL_GetTicks() - cl_t) < 2000;
    if (muted) { verdict = "MUTED (m)"; col[0] = 200; col[1] = 200; col[2] = 60; }
    else if (hot) { verdict = agc ? "TOO HOT - AGC reducing" : "TOO HOT - lower gain (-)"; col[0] = 230; col[1] = 60; col[2] = 60; }
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

/* Every line the monitor writes.  Launched from the desktop there is no
 * terminal, so stderr goes wherever the launcher puts it - which is nowhere -
 * and the counters that make a capture diagnosable (dup, skip, held, gaps,
 * xruns) are thrown away with it.  When stderr is not a terminal, append to a
 * log file instead; a run in a terminal still prints.  PCTV_LOG=<path> forces a
 * file, PCTV_LOG=0 turns this off.  The probe and FFmpeg inherit fd 2, so one
 * file holds the whole story. */
static void log_to_file(const char *why)
{
    const char *e = getenv("PCTV_LOG");
    if (e && !strcmp(e, "0")) return;
    if (isatty(2) && !e) return;
    char path[512];
    if (e)
        snprintf(path, sizeof path, "%s", e);
    else {
        const char *st = getenv("XDG_STATE_HOME");
        snprintf(path, sizeof path, "%s/pctv-monitor.log",
                 (st && *st) ? st
                             : (getenv("HOME") ? "/home/cjdell/.local/state" : "/tmp"));
        if (!(st && *st)) {
            char *slash = strrchr(path, '/');
            if (slash) { *slash = 0; mkdir(path, 0755); *slash = '/'; }
        }
    }
    int fd = open(path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0644);
    if (fd < 0) return;
    dup2(fd, 2);
    close(fd);
    char ts[32];
    time_t now = time(NULL);
    struct tm tmv;
    localtime_r(&now, &tmv);
    strftime(ts, sizeof ts, "%Y-%m-%d %H:%M:%S", &tmv);
    fprintf(stderr, "pctv-monitor: %s at %s: logging to %s\n", why, ts, path);
}

int main(int argc, char **argv)
{
    char saved[200];
    int want_capture = 0;
    long capture_secs = 0;
    int gain_pct = -1, boost_step = -1, agc_cli = -1, mon_cli = 0;
    const char *audio_arg = NULL;

    /* Outrank the desktop before SDL, the ALSA capture thread and the probe
     * exist, so every one of them inherits SCHED_FIFO (pctv-rt.h). */
    pctv_become_rt("pctv-monitor", 8);
    log_to_file("session start");

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
        env = getenv("PCTV_MASTER");
        if (env) cap_master = master_from_name(env);
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
        } else if (!strcmp(argv[i], "--master") && i + 1 < argc) {
            cap_master = master_from_name(argv[++i]);
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
            usage(argv[0], stdout);
            return 0;
        } else {
            fprintf(stderr, "pctv-monitor: unexpected argument '%s'\n", argv[i]);
            usage(argv[0], stderr);
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

    /* Capture queue depth: how many seconds of sink stall the capture can ride
     * out.  The MPEG-2 path keeps 24 (960 ms - it has its own 8 MiB pipe and the
     * encoder is the variable in it); a lossless/raw master defaults to 600 =
     * 24 s because that is what a network sink needs (see the VQ block: 681 ms
     * was the worst measured stall to GEN8 over NFS, and 2026-11-02 lost 40 min
     * of tape with a 960 ms cushion in front of a local encoder).  RAM is the
     * only cost: 829 KB per slot. */
    {   /* spill: where and how much local disk the queue may overflow onto.
         * The default directory must be LOCAL disk (on the capture host
         * /var/tmp is the SSD; /tmp is not the same bet on every box), and
         * the cap exists so a chronic-slow NFS sink can never be what
         * fills the host's root filesystem: the effective figure is further
         * min()'d with measured free space minus a 1 GiB floor at
         * activation.  0 disables the spill entirely: a full queue then
         * ends the capture, the pre-2026-11-04 behaviour. */
        const char *v = getenv("PCTV_SPILL_MB");
        if (v) {
            unsigned long long n = strtoull(v, NULL, 10);
            spill_cap_mb = n > 4194304ull ? 4194304ull : n;   /* 4 TiB guard */
        }
        v = getenv("PCTV_SPILL_DIR");
        if (v && *v) spill_dir = v;
    }
    {
        const char *s = getenv("PCTV_VQ_SLOTS");
        if (cap_master != MASTER_DVD && vq_n == VQ_SLOTS_DEFAULT)
            vq_n = VQ_SLOTS_SINK;
        if (s) {
            int n = atoi(s);
            vq_n = n < 4 ? 4 : (n > VQ_SLOTS_MAX ? VQ_SLOTS_MAX : n);
        }
    }
    /* PCTV_CLOCK was retired on 2026-11-04, together with the whole
     * audio-as-master clock.  There is no mode any more: the card is the
     * clock, the sound is paired to each picture at the commit, and the
     * resampling ratio is what the crystals disagreement is spent on rather
     * than a mode switch.  A set-but-ignored environment variable in a systemd
     * unit is how a stale A/B flag survives into production, so say so out
     * loud instead of silently dropping it. */
    {   const char *s = getenv("PCTV_CLOCK");
        if (s && *s)
            fprintf(stderr, "pctv-monitor: PCTV_CLOCK=%s is retired and ignored: "
                            "the capture is always card-clocked now, with the "
                            "audio coupled to each picture at the commit "
                            "(see the header note)\n", s);
    }
    {   /* end-of-tape policy, see the detector above */
        const char *s = getenv("PCTV_HOLD_SECS");
        if (s) hold_secs = atoi(s);
        if (hold_secs < 0) hold_secs = 0;
        s = getenv("PCTV_HOLD_RESUME");
        if (s) hold_resume = atoi(s);
        if (hold_resume < 2) hold_resume = 2;
        s = getenv("PCTV_HOLD_MAX");
        if (s) hold_max_secs = atoi(s);
        s = getenv("PCTV_HOLD_STRESS");
        if (s) hold_stress = atoi(s);
        s = getenv("PCTV_BLUE_SECS");
        if (s) blue_secs = atoi(s);
        if (blue_secs < 0) blue_secs = 0;
        if (hold_max_secs && hold_max_secs < hold_secs)
            hold_max_secs = hold_secs;   /* quitting cannot precede the close */
        if (hold_secs)
            fprintf(stderr, "pctv-monitor: end-of-tape hold on: %d s of unchanged"
                            " picture closes the file and resumes on motion%s%s\n",
                    hold_secs, hold_max_secs ? ", " : "",
                    hold_max_secs ? "then ends the run" : "");
        else
            fprintf(stderr, "pctv-monitor: end-of-tape hold off - a frozen frame"
                            " will be recorded for as long as it lasts\n");
        if (hold_stress)
            fprintf(stderr, "pctv-monitor: PCTV_HOLD_STRESS=%d: SELF-TEST, reporting"
                            " a frozen picture for the first %d s whatever the"
                            " deck is doing\n", hold_stress, hold_stress);
        if (blue_secs)
            fprintf(stderr, "pctv-monitor: no-content blue on: %d s of the deck's"
                            " blue screen ends the run and releases the card"
                            " (PCTV_BLUE_SECS=0 turns it off)\n", blue_secs);
        else
            fprintf(stderr, "pctv-monitor: no-content blue off - a blue screen is"
                            " recorded until the deck or the operator stops it\n");
    }

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

    rbuf = malloc(RBUF);
    if (!rbuf) die("out of memory for the parse buffer");
    rlen = 0;
    int running = 1;
    int hold_auto = 0;            /* the detector closed the file, not a person:
                                   * it owes the tape a new one */
    unsigned long long last_frames = 0, snap_after = 0;
    { const char *s = getenv("PCTV_SNAP_AFTER"); if (s) snap_after = strtoull(s, NULL, 0); }
    double last_t = (double)SDL_GetTicks() / 1000.0, fps = 0;

    if (want_capture) {
        if (frames > 0) cap_start();
        else cap_pending = 1;
        fprintf(stderr, "pctv-monitor: capture queued, starting with the first frame "
                        "(input %s, master %s)\n", INPUT_LABEL[cur_input],
                master_name(cap_master));
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
                case SDLK_f:
                    gate_on = !gate_on; gate_holds = 0;
                    fprintf(stderr, "pctv-monitor: frame gate %s\n",
                            gate_on ? "on - bad frames are replaced by the last "
                                    "good one" : "off - every frame is shown");
                    show_overlay(2000);
                    break;
                case SDLK_s: snapshot_ppm(); break;
                case SDLK_r: rec_toggle(); break;
                case SDLK_c:
                    hold_rearm();
                    hold_auto = 0;
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

        /* drain the child's stdout and decode it (pump() also covers the
         * buffer-full/no-sync case); stop when the probe dies */
        unsigned long t_stage = SDL_GetTicks();
        if (pump()) running = 0;

        /* The sink stopped taking pictures.  Close the file - everything in it
         * is complete - and do not reopen it behind the operator's back. */
        if (vq_want_stop) {
            vq_want_stop = 0;
            if (cap_on) {
                hold_auto = 0;              /* the hold logic must not reopen */
                hold_rearm();
                cap_stop();
                show_overlay(30000);
            }
        }

        /* ------------------------------------------------ end-of-tape hold
         * Act out here, never from the parser: cap_start() pumps the stream
         * while it waits for the audio thread and cap_stop() pumps it while it
         * waits for ffmpeg, so either called from field_commit() would re-enter
         * the parser that is calling it. */
        if (hold_want_stop) {
            hold_want_stop = 0;
            if (cap_on) {
                char was[512];
                snprintf(was, sizeof was, "%s", cap_path);
                cap_stop();
                hold_auto = 1;
                fprintf(stderr, "pctv-monitor: the picture has not changed for %d s"
                                " - closed %s and still watching; a blank stretch"
                                " between two recordings resumes by itself"
                                " (PCTV_HOLD_SECS=0 turns this off)\n",
                        hold_secs, was);
                show_overlay(20000);
            }
        }
        if (hold_want_start) {
            hold_want_start = 0;
            if (hold_auto) {
                hold_auto = 0;
                if (cap_start())
                    fprintf(stderr, "pctv-monitor: the picture came back but the"
                                    " encoder would not start - NOT capturing\n");
                else {
                    fprintf(stderr, "pctv-monitor: picture again -> %s\n", cap_path);
                    show_overlay(20000);
                }
            }
        }
        if (hold_quit) {
            hold_quit = 0;
            fprintf(stderr, "pctv-monitor: still the same frame after %d s of"
                            " holding - ending the run and releasing the card\n",
                    hold_max_secs);
            running = 0;
        }

        /* A blue screen is the deck saying there is nothing to play: end the
         * run, not just the file.  Only while capturing - a person watching the
         * live view of a stopped deck should not have the window disappear -
         * and blue_update() only gets here after a real picture was seen, so a
         * capture started in front of a stopped deck is not cut short. */
        if (blue_hit) {
            blue_hit = 0;
            blue_run = 0;
            if (cap_on) {
                char was[512];
                snprintf(was, sizeof was, "%s", cap_path);
                hold_auto = 0;
                hold_rearm();
                fprintf(stderr, "pctv-monitor: no picture - the deck has shown its"
                                " blue screen for %d s, so the tape is finished;"
                                " closed %s and releasing the card"
                                " (PCTV_BLUE_SECS=0 turns this off)\n",
                        blue_secs, was);
                cap_stop();
                running = 0;
            }
        }

        /* a complete interlaced frame is ready for the encoder */
        {   /* parse stage: stream read + BT.656 decode, top of loop to here */
            unsigned long d = SDL_GetTicks() - t_stage;
            if (d > stage_max[0]) stage_max[0] = d;
        }
        if (cap_pending && !cap_on && frames > 0) {
            /* Start the encoder on the first frame, not on the key press: both
             * streams then get PTS 0 at the same instant, and the audio cannot
             * run ahead by the decoder's lock time (8 s with no source).
             * Acted out here, never from field_commit(): cap_start() pumps the
             * stream while it waits for the audio thread, so calling it from the
             * parser would re-enter it.  The frame itself was already queued
             * where it was born; the first one after this is the file's frame 0. */
            cap_pending = 0;
            cap_start();
            show_overlay(4000);
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
                         "c capture (%s)   o monitor   r raw   s snap   g grey   f frame gate   space pause   q quit",
                         MASTER_NAME[cap_master]);
                draw_panel(ren, 10, 8 + 7 * 2 + 12 + 12, hint, 1);
            }
        }
        draw_audio_panel(ren);

        /* `H' - the key reference, left up until H is pressed again */
        if (help_on) {
            const char *hl[14];
            char h0[200], h1[200], h2[200], h3[200], h4[200], h5[200], h6[200],
                 h7[200], h8[200], h9[200], h10[200], h11[200], h12[200], h13[200];
            snprintf(h0, sizeof h0, "HELP (press H to close)");
            snprintf(h1, sizeof h1, " 1 / 2 / Tab   video input: Composite, S-Video");
            snprintf(h2, sizeof h2, " a             audio input (cycle)      A  automatic gain");
            snprintf(h3, sizeof h3, " - / +         capture gain             b  input boost");
            snprintf(h4, sizeof h4, " m             mute capture             g  colour / grey");
            snprintf(h5, sizeof h5, " c             start/stop capture          r  raw BT.656 dump");
            snprintf(h6, sizeof h6, " s             snapshot frame (PPM)     space  freeze display");
            snprintf(h7, sizeof h7, " o             monitor input on speakers (hear the gain first)");
            pthread_mutex_lock(&amtx);
            snprintf(h8, sizeof h8, " audio: %s  gain %+.1f dB (cap %+.1f + boost %+.1f)  AGC %s (ref %.1f dBFS)",
                     srcs[cur_src].label, gain_db + boost_db, gain_db, boost_db,
                     agc_on ? "on" : "off", agc_slow_src);
            pthread_mutex_unlock(&amtx);
            snprintf(h9, sizeof h9, " video: %s  720x576 interlaced 25 fps  %d kbps", INPUT_LABEL[cur_input], mpeg2_kbps);
            snprintf(h10, sizeof h10, " out: %.180s", out_dir);
            snprintf(h11, sizeof h11, " q/ESC quit - Ctrl-C also finalises a capture; H closes this");
            snprintf(h12, sizeof h12,
                     " f             frame gate (%s): hold the last good frame instead of "
                     "showing one that is spliced, short or 40 ms out of step - held %llu/%llu",
                     gate_on ? "on" : "off", frames_held, frames);
            /* What `c' will actually write, and what it will cost per minute: the
             * question is always "am I about to put 151 GB on this disk?" */
            {
                static const char *const RATE[] =
                    { "6 MB/min", "1.25 GB/min", "0.42 GB/min", "0.44 GB/min" };
                pthread_mutex_lock(&amtx);
                snprintf(h13, sizeof h13, " master: %s  %s  sound: %s%s",
                         MASTER_NAME[cap_master], RATE[cap_master],
                         cap_has_audio ? srcs[cur_src].label : "NONE (--no-audio)",
                         cap_master == MASTER_DVD ? "  (MPEG-2 + MP2, DVD-shaped)" : "");
                pthread_mutex_unlock(&amtx);
            }
            hl[0] = h0; hl[1] = h1; hl[2] = h2; hl[3] = h3; hl[4] = h4; hl[5] = h5;
            hl[6] = h6; hl[7] = h7; hl[8] = h8; hl[9] = h9; hl[10] = h10; hl[11] = h11;
            hl[12] = h12; hl[13] = h13;
            draw_panel_lines(ren, 10, 70, hl, 14, 1);
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
            snprintf(l1, sizeof l1, "%llu frames  dup %llu  skip %llu  drops %llu/%llu",
                     cap_vframes, cap_vrepeats, cap_vskips, cap_vdrops, cap_adrops);
            pthread_mutex_unlock(&cap_mtx);
            pthread_mutex_lock(&vq_mtx);
            int qd = vq_count;
            pthread_mutex_unlock(&vq_mtx);
            snprintf(l2, sizeof l2, "audio %s  q %d/%d  card clock  %+d ppm  ph %+d ms",
                     cap_has_audio ? srcs[cur_src].label : "OFF", qd, vq_n - 2,
                     (int)lrint((rs_step - 1.0) * 1e6), rs_phase_ms);
            lines[0] = l1; lines[1] = l2;
            int wpx = text_w(l1, 1) > text_w(l2, 1) ? text_w(l1, 1) : text_w(l2, 1);
            draw_panel_lines(ren, W - wpx - 24, 8 + 16 * 2 + 10, lines, 2, 1);
        }

        /* The state that used to be invisible: the deck has stopped, so nothing
         * is happening, and the only clue was a file that had stopped growing.
         * Say what it is and what happens next - and say it differently when a
         * person is in charge (`c') than when the detector is. */
        if (hold_state && !cap_on) {
            const char *lines[1];
            char l0[200];
            unsigned s = (SDL_GetTicks() - hold_since) / 1000;
            if (hold_auto)
                snprintf(l0, sizeof l0, "STILL %02u:%02u - file closed, waiting",
                         s / 60, s % 60);
            else
                snprintf(l0, sizeof l0, "STILL %02u:%02u - not recording (c forces)",
                         s / 60, s % 60);
            lines[0] = l0;
            draw_panel_lines(ren, W - text_w(l0, 2) - 30, 8, lines, 1, 2);
        }

        /* The other no-content state, and the one that is allowed to end the
         * run: a blue screen is not a frozen frame (its subcarrier beats every
         * frame), so it gets its own line and its own countdown. */
        if (blue_run && !hold_state) {
            const char *lines[1];
            char l0[200];
            unsigned s = (SDL_GetTicks() - blue_since) / 1000;
            if (blue_secs > 0)
                snprintf(l0, sizeof l0, "NO SIGNAL %02u:%02u - blue, ends the run"
                                        " at %02d:%02d",
                         s / 60, s % 60, blue_secs / 60, blue_secs % 60);
            else
                snprintf(l0, sizeof l0, "NO SIGNAL %02u:%02u - blue screen",
                         s / 60, s % 60);
            lines[0] = l0;
            draw_panel_lines(ren, W - text_w(l0, 2) - 30, 8, lines, 1, 2);
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

            char recmode[32] = "";
            if (cap_on)
                snprintf(recmode, sizeof recmode, " [REC %s]",
                         MASTER_NAME[cap_master]);
            else if (hold_state)
                snprintf(recmode, sizeof recmode, " [STILL]");
            else if (blue_run)
                snprintf(recmode, sizeof recmode, " [NO SIGNAL]");

            char title[256];
            snprintf(title, sizeof title,
                     "PCTV 320cx - %s%s%s%s - %.0f fields/s",
                     INPUT_LABEL[cur_input], grey ? " [grey]" : "",
                     recording ? " [RAW]" : "", recmode, fps);
            SDL_SetWindowTitle(win, title);
            if (getenv("PCTV_VERBOSE")) {
                stage_max[1] = feed_max_ms; feed_max_ms = 0;
                pthread_mutex_lock(&vq_mtx);
                int qdbg = vq_count;
                unsigned long long rdbg = aq_count;
                pthread_mutex_unlock(&vq_mtx);
                unsigned long long bpms = aq_bytes_per_ms();
                int ringdbg = bpms ? (int)(rdbg / bpms) : 0;
                pthread_mutex_lock(&amtx);
                fprintf(stderr, "monitor: %s | in %llu B rlen %zu | maxgap %lums "
                                "(%s %lums %s %lums %s %lums) q %d/%d dup %llu "
                                "skip %llu | ring %dms ph %+d | "
                                "held %llu/%llu | still %d/%d%s | blue %lum%s | "
                                "audio %s ok=%d L %.1f R %.1f pk %.1f clips %u gain %+.1f dB\n",
                        title, bytes_in, rlen, gap_max,
                        stage_name[0], stage_max[0], stage_name[1], stage_max[1],
                        stage_name[2], stage_max[2], qdbg, vq_n - 2,
                        cap_vrepeats, cap_vskips,
                        ringdbg, rs_phase_ms,
                        frames_held, frames,
                        hold_same, hold_diff, hold_state ? "*" : "",
                        blue_run ? (SDL_GetTicks() - blue_since) / 1000 : 0,
                        blue_hit ? "!" : "",
                        srcs[cur_src].label, audio_ok, pk_db[0], pk_db[1],
                        hold_db[0] > hold_db[1] ? hold_db[0] : hold_db[1], clips,
                        gain_db + boost_db);
                pthread_mutex_unlock(&amtx);
                /* The colour predicate's own numbers: a deck showing its blue
                 * screen must read U ~206, Y ~47, and programme U ~123. */
                fprintf(stderr, "monitor: blue: Y %5.1f U %5.1f V %5.1f | %s"
                                " %lus of %ds (needs U>=%.0f, Y<=%.0f, drift<=%.0f)\n",
                        frame_y, frame_u, frame_v,
                        blue_run ? "IN RUN"
                                 : blue_is ? (blue_seen ? "blue"
                                                         : "blue, no picture seen yet")
                                           : "not blue",
                        blue_run ? (SDL_GetTicks() - blue_since) / 1000 : 0,
                        blue_secs, BLUE_U_MIN, BLUE_Y_MAX, BLUE_TOL);
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
    fprintf(stderr, "pctv-monitor: %llu fields (%llu short = lines lost, "
                    "%llu stale-field feeds, %llu stream gaps of %llu B/%llu rows, "
                    "%llu repaired at the seam, %llu false sync words ignored, "
                    "%llu fields dropped), %llu encoded frames (%llu dup, %llu skip), "
                    "%llu held (gate), %llu B from the probe\n",
            frames, fields_short, fields_repeat, fields_gap, gap_bytes, gap_lines,
            gap_repaired, false_syncs, fields_dropped, cap_vframes, cap_vrepeats,
            cap_vskips, frames_held, bytes_in);
    fprintf(stderr, "pctv-monitor: anomalies (S=short field, R=stale field, "
                    "G=stream gap, g=gap repaired, D=field dropped, H=frame held): ");
    for (int i = 0; i < nanom; i++) fprintf(stderr, " %c@%lums", anom[i].kind, anom[i].t);
    fprintf(stderr, "\n");
    SDL_DestroyTexture(tex);
    SDL_DestroyRenderer(ren);
    SDL_DestroyWindow(win);
    SDL_Quit();
    return 0;
}
