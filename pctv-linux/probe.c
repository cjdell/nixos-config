/* SPDX-License-Identifier: GPL-2.0
 *
 * pctv_probe - userspace probe / experiment harness for the Pinnacle PCTV 320cx
 *              (DiBcom DiB0700 USB bridge + DIB7000P demod + CX2584x A/V decoder).
 *
 * USB id: 2304:022e  (Pinnacle Systems, Inc. "PCTV 320cx")
 *
 * The DiB0700 control protocol is implemented entirely through vendor control
 * requests on EP0 plus bulk OUT EP1 (firmware download) and bulk IN EP2/EP3
 * (transport / video stream).  This tool speaks that protocol directly so the
 * analog (composite / S-Video) path can be explored without a kernel driver.
 *
 * Vendor request map (from Linux drivers/media/usb/dvb-usb/dib0700.h and the
 * Pinnacle "Ltn_hyd7700pc" Windows driver, which uses the same set):
 *
 *   0x08 JUMPRAM          bulk OUT ep1, 8 bytes: 08 00 00 00 <addr BE>
 *   0x09 RESET
 *   0x0a MASTER_RESET
 *   0x0b SET_CLOCK        wr 10 bytes
 *   0x0c SET_GPIO         wr  3 bytes
 *   0x0d SPI
 *   0x0e I2C_WRITE        legacy
 *   0x0f I2C_READ         legacy
 *   0x10 SET_I2C_PARAM    wr  8 bytes
 *   0x11 POLL_RC
 *   0x12 NEW_I2C_WRITE   wr  4+N bytes
 *   0x13 NEW_I2C_READ     rd
 *   0x14 SET_USB_XFER_LEN wr  3 bytes
 *   0x15 GET_VERSION      rd 16 bytes
 *   0x16 GET_GPIO_VAL     rd  2 bytes
 *   0x17 GET_ADAPT_INFO
 *   0x18 GET_ADAPT_STATE
 *   0x19 MASTER_ADAPT_INFO
 *   0x80..0x8f DIB7000P/7070P demod access
 *   0x90..0x9f DIB3000P/3000MC tuner access
 *   0xa0..0xbf DIB0700 internal (EEPROM / streaming / analog)
 *
 * Build (NixOS):
 *   nix shell nixpkgs#clang nixpkgs#libusb1 nixpkgs#gcc --command \
 *     cc -O2 -Wall -o pctv_probe probe.c $(pkg-config --cflags --libs libusb-1.0)
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <unistd.h>
#include <time.h>
#include <getopt.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <fcntl.h>
#include <signal.h>
#include <libusb-1.0/libusb.h>

#define VID 0x2304
#define PID 0x022e

/* ---- vendor requests (drivers/media/usb/dvb-usb/dib0700.h) ---- */
#define RQ_SET_USB_XFER_LEN   0x00   /* fw >= 1.21 only */
#define RQ_I2C_READ           0x02   /* legacy i2c (pre-1.20) */
#define RQ_I2C_WRITE          0x03   /* legacy i2c */
#define RQ_POLL_RC            0x04   /* deprecated in fw 1.20 */
#define RQ_JUMPRAM            0x08
#define RQ_SET_CLOCK          0x0b
#define RQ_SET_GPIO           0x0c
#define RQ_ENABLE_VIDEO       0x0f   /* MPEG2 vs ANALOG streaming */
#define RQ_SET_I2C_PARAM      0x10
#define RQ_SET_RC             0x11
#define RQ_NEW_I2C_READ       0x12
#define RQ_NEW_I2C_WRITE      0x13
#define RQ_GET_VERSION        0x15

/* not in dib0700.h - kept for probing only */
#define RQ_GET_GPIO_VAL       0x16

static libusb_device_handle *dev;
static uint8_t ep_in = 0x82;   /* interface 0, alt 0 -> 0x82, alt 1 -> 0x83 */
static int verbose = 1;
/* The Pinnacle DiB0700 on this stick answers vendor requests with recipient=4
 * (bmRequestType 0xC4 / 0x44).  The Linux dib0700 driver sends recipient=0
 * (0xC0 / 0x40) and every request stalls.  Default to the form that works. */
static int rec4 = 1;

static int type_in(void)  { return rec4 ? 0xC4 : (LIBUSB_ENDPOINT_IN  | LIBUSB_REQUEST_TYPE_VENDOR | LIBUSB_RECIPIENT_DEVICE); }
static int type_out(void) { return rec4 ? 0x44 : (LIBUSB_ENDPOINT_OUT | LIBUSB_REQUEST_TYPE_VENDOR | LIBUSB_RECIPIENT_DEVICE); }

static void hexdump(const char *tag, const unsigned char *b, int len)
{
    int i;
    if (!len) { printf("%s: (empty)\n", tag); return; }
    printf("%s: %d byte(s):", tag, len);
    for (i = 0; i < len; i++) {
        if (i % 16 == 0) printf("\n  %04x: ", i);
        printf("%02x ", b[i]);
    }
    printf("\n");
}

static int ctrl_in(uint8_t request, uint16_t value, uint16_t index,
                   unsigned char *buf, int len)
{
    int r = libusb_control_transfer(dev, type_in(),
            request, value, index, buf, (uint16_t)len, 5000);
    if (verbose) {
        if (r < 0)
            printf("  ctrl_in rq=0x%02x value=0x%04x index=0x%04x -> %s\n",
                   request, value, index, libusb_strerror(r));
        else
            printf("  ctrl_in rq=0x%02x value=0x%04x index=0x%04x -> %d\n",
                   request, value, index, r);
    }
    return r;
}

static int ctrl_out(const unsigned char *buf, int len)
{
    int r = libusb_control_transfer(dev, type_out(),
            buf[0], 0, 0, (unsigned char *)buf, (uint16_t)len, 5000);
    if (verbose)
        printf("  ctrl_out len=%d rq=0x%02x -> %s\n", len, buf[0],
               r < 0 ? libusb_strerror(r) : "ok");
    return r;
}

/* dib0700_ctrl_wr(): buf[0] = request, whole buffer written on EP0 */
static int wr(const unsigned char *b, int len)
{
    return ctrl_out(b, len);
}

/* dib0700_ctrl_rd(): tx[0]=request tx[1..3] -> wValue/wIndex, read rxlen */
static int rd(const unsigned char *tx, int txlen, unsigned char *rx, int rxlen)
{
    uint16_t value = 0, index = 0;
    if (txlen < 2 || txlen > 4) return -1;
    value = ((txlen - 2) << 8) | tx[1];
    if (txlen > 2) index |= tx[2] << 8;
    if (txlen > 3) index |= tx[3];
    return ctrl_in(tx[0], value, index, rx, rxlen);
}

/* ---------------- firmware ---------------- */
/* linux-firmware dvb-usb-dib0700-1.20.fw is a stream of records:
 *   [len][addr_hi][addr_lo][type][data:len][checksum]
 * (the Intel-hex payload without the ':' / ascii encoding). */
static int download_firmware(const char *path)
{
    FILE *f = fopen(path, "rb");
    if (!f) { perror("open fw"); return -1; }
    fseek(f, 0, SEEK_END); long sz = ftell(f); fseek(f, 0, SEEK_SET);
    unsigned char *fw = malloc(sz);
    if (!fw || fread(fw, 1, sz, f) != (size_t)sz) { fclose(f); free(fw); return -1; }
    fclose(f);

    long pos = 0; int nrec = 0;
    while (pos + 5 <= sz) {
        unsigned char len = fw[pos];
        unsigned char type = fw[pos + 3];
        if (pos + 4 + len + 1 > sz) break;
        int blen = len + 5;
        unsigned char *b = malloc(blen);
        b[0] = len;
        b[1] = fw[pos + 1];
        b[2] = fw[pos + 2];
        b[3] = type;
        memcpy(b + 4, fw + pos + 4, len);
        b[4 + len] = fw[pos + 4 + len];
        int xfer = 0;
        int r = libusb_bulk_transfer(dev, 0x01, b, blen, &xfer, 2000);
        free(b);
        if (r < 0) { printf("fw download failed at %ld: %s\n", pos, libusb_strerror(r)); free(fw); return -1; }
        pos += 4 + len + 1;
        nrec++;
        if (type == 0x01) break;   /* EOF record */
    }
    free(fw);
    printf("firmware: %d record(s) written\n", nrec);

    /* jumpram -> 0x70000000 */
    unsigned char j[8] = { RQ_JUMPRAM, 0, 0, 0, 0x70, 0, 0, 0 };
    int xfer = 0;
    int r = libusb_bulk_transfer(dev, 0x01, j, 8, &xfer, 2000);
    if (r < 0) { printf("jumpram failed: %s\n", libusb_strerror(r)); return -1; }
    printf("jumpram -> 0x70000000 ok\n");
    usleep(500000);
    return 0;
}

/* ---------------- i2c (new 1.20 API) ---------------- */
/* bus_mode: 0 = eeprom bus, 1 = frontend bus.  gen_mode 0 = master i2c. */
static int i2c_read_new(uint8_t addr7, unsigned char *rx, int rxlen, int bus_mode)
{
    uint16_t value, index;
    uint8_t i2c_dest = addr7 << 1;
    value = ((1u << 7) | (1u << 6) | (rxlen & 0x3f)) << 8 | i2c_dest;
    index = ((0u << 6) & 0xc0) | ((bus_mode << 4) & 0x30);
    return ctrl_in(RQ_NEW_I2C_READ, value, index, rx, rxlen);
}

static int i2c_write_new(uint8_t addr7, const unsigned char *data, int len, int bus_mode)
{
    unsigned char b[260];
    if (len > 200) return -1;
    b[0] = RQ_NEW_I2C_WRITE;
    b[1] = addr7 << 1;
    b[2] = (1u << 7) | (1u << 6) | (len & 0x3f);
    b[3] = ((0u << 6) & 0xc0) | ((bus_mode << 4) & 0x30);
    memcpy(b + 4, data, len);
    return ctrl_out(b, len + 4);
}

/* ---------------- commands ---------------- */

/* legacy (pre-1.20) i2c: REQUEST_I2C_READ 0x0f / REQUEST_I2C_WRITE 0x0e */
static int i2c_read_legacy(uint8_t addr7, unsigned char *reg, int reglen,
                          unsigned char *rx, int rxlen)
{
    unsigned char tx[8];
    int txlen = 0, i;
    tx[txlen++] = RQ_I2C_READ;
    tx[txlen++] = (addr7 << 1) | 1;
    for (i = 0; i < reglen; i++) tx[txlen++] = reg[i];
    return rd(tx, txlen, rx, rxlen);
}

static int i2c_write_legacy(uint8_t addr7, const unsigned char *data, int len)
{
    unsigned char b[260];
    int i;
    b[0] = RQ_I2C_WRITE;
    b[1] = addr7 << 1;
    for (i = 0; i < len; i++) b[2 + i] = data[i];
    return ctrl_out(b, len + 2);
}

static int cmd_version(void)
{
    unsigned char b[16];
    int r = ctrl_in(RQ_GET_VERSION, 0, 0, b, 16);
    if (r < 0) { printf("GET_VERSION failed -> device is COLD (no firmware running)\n"); return r; }
    hexdump("GET_VERSION", b, r);
    if (r >= 16) {
        unsigned hw   = (b[0]<<24)|(b[1]<<16)|(b[2]<<8)|b[3];
        unsigned rom  = (b[4]<<24)|(b[5]<<16)|(b[6]<<8)|b[7];
        unsigned ram  = (b[8]<<24)|(b[9]<<16)|(b[10]<<8)|b[11];
        unsigned fwty = (b[12]<<24)|(b[13]<<16)|(b[14]<<8)|b[15];
        printf("  hw=0x%08x rom=0x%08x ram=0x%08x fwtype=0x%08x\n", hw, rom, ram, fwty);
    }
    return 0;
}

static int cmd_fw(const char *path)
{
    return download_firmware(path);
}

static int cmd_clock(void)
{
    /* dib0700_ctrl_clock(d, 72, clock_out_gp3=1):
     *   dib0700_set_clock(d, en_pll=1, pll_src=0, pll_range=1, clock_gpio3=1,
     *                     pll_prediv=2, pll_loopdiv=24, free_div=0, dsuScaler=0x4c) */
    int prediv = 2, loopdiv = 24, freediv = 0, scaler = 0x4c;
    const char *e;
    if ((e = getenv("PCTV_PREDIV")))  prediv  = atoi(e);
    if ((e = getenv("PCTV_LOOPDIV"))) loopdiv = atoi(e);
    if ((e = getenv("PCTV_FREEDIV"))) freediv = atoi(e);
    if ((e = getenv("PCTV_SCALER")))  scaler  = atoi(e);
    unsigned char b[10] = { RQ_SET_CLOCK, (1 << 7) | (0 << 6) | (1 << 5) | (1 << 4),
                            (unsigned char)((prediv >> 8) & 0xff), (unsigned char)(prediv & 0xff),
                            (unsigned char)((loopdiv >> 8) & 0xff), (unsigned char)(loopdiv & 0xff),
                            (unsigned char)((freediv >> 8) & 0xff), (unsigned char)(freediv & 0xff),
                            (unsigned char)((scaler >> 8) & 0xff), (unsigned char)(scaler & 0xff) };
    printf("SET_CLOCK prediv=%d loopdiv=%d freediv=%d scaler=%04x (PLL=6MHz*%d/%d=%d Hz)\n",
           prediv, loopdiv, freediv, scaler, loopdiv, prediv, 6000000 * loopdiv / prediv);
    return wr(b, 10);
}

static int cmd_i2cparam(int khz)
{
    unsigned char b[8];
    unsigned d;
    b[0] = RQ_SET_I2C_PARAM; b[1] = 0;
    d = 30000 / khz; b[2] = d >> 8; b[3] = d & 0xff;
    d = 72000 / khz; b[4] = d >> 8; b[5] = d & 0xff;
    d = 72000 / khz; b[6] = d >> 8; b[7] = d & 0xff;
    return wr(b, 8);
}

static int cmd_scan(int bus_mode)
{
    int found = 0;
    printf("I2C scan on bus_mode=%d (%s)\n", bus_mode,
           bus_mode ? "frontend bus" : "eeprom bus");
    for (int a = 0x08; a <= 0x77; a++) {
        unsigned char rx[4];
        int r = i2c_read_new(a, rx, 1, bus_mode);
        if (r > 0) { printf("  ACK at 0x%02x (8-bit 0x%02x) -> %02x\n", a, a<<1, rx[0]); found++; }
    }
    printf("scan done: %d device(s)\n", found);
    return 0;
}

static int cmd_rd(int bus_mode, int addr, int reg)
{
    unsigned char w[1] = { (unsigned char)reg };
    unsigned char rx[8];
    int r = i2c_write_new(addr, w, 1, bus_mode);
    if (r < 0) { printf("write reg failed: %s\n", libusb_strerror(r)); return r; }
    r = i2c_read_new(addr, rx, 2, bus_mode);
    if (r < 0) { printf("read failed: %s\n", libusb_strerror(r)); return r; }
    hexdump("i2c read", rx, r);
    return 0;
}

static int cmd_wr(int bus_mode, int addr, int reg, int val)
{
    unsigned char w[2] = { (unsigned char)reg, (unsigned char)val };
    return i2c_write_new(addr, w, 2, bus_mode);
}

static int cmd_gpio(int gpio, int dir, int val)
{
    unsigned char b[3] = { RQ_SET_GPIO, (unsigned char)gpio,
                           (unsigned char)(((dir & 1) << 7) | ((val & 1) << 6)) };
    return wr(b, 3);
}

static int cmd_getgpio(void)
{
    unsigned char b[2];
    int r = ctrl_in(RQ_GET_GPIO_VAL, 0, 0, b, 2);
    if (r > 0) hexdump("GET_GPIO_VAL", b, r);
    return r;
}

/*
 * REQUEST_ENABLE_VIDEO (0x0f) - the analog/MPEG switch.
 * dib0700.h:
 *   byte1: 4MSB 1=enable streaming 0=disable ; 4LSB video mode: 0=MPEG2 188B, 1=Analog
 *   byte2: MPEG2 mode: 4MSB master/slave, 4LSB channel bits
 *   byte2: analog mode: 4MSB 0=625 lines, 1=525 lines
 */
static int cmd_video(int on, int analog, int lines525, int xferlen)
{
    unsigned char b[4];
    b[0] = RQ_ENABLE_VIDEO;
    b[1] = ((on & 1) << 4) | (analog ? 1 : 0);
    b[2] = analog ? ((lines525 & 1) << 4) : 0x10;  /* mpeg: master mode */
    b[3] = 0;
    if (xferlen > 0) {
        unsigned char c[3] = { RQ_SET_USB_XFER_LEN, (xferlen >> 8) & 0xff, xferlen & 0xff };
        wr(c, 3);
    }
    return wr(b, 4);
}

static int cmd_xferlen(int n)
{
    unsigned char b[3] = { RQ_SET_USB_XFER_LEN, (n >> 8) & 0xff, n & 0xff };
    return wr(b, 3);
}

static int cmd_cap(int endpoint, int nbytes, const char *outfile)
{
    unsigned char *buf = malloc(nbytes);
    int got = 0, total = 0, r;
    FILE *out = outfile ? fopen(outfile, "wb") : NULL;
    const char *e = getenv("PCTV_XFER");
    int xfer = e ? atoi(e) : 65536;
    if (xfer < 512) xfer = 512;
    printf("capturing from ep 0x%02x (xfer %d) ...\n", endpoint, xfer);
    for (int i = 0; i < 40000 && total < nbytes; i++) {
        int want = nbytes - total;
        if (want > xfer) want = xfer;
        r = libusb_bulk_transfer(dev, endpoint, buf, want, &got, 1500);
        if (r == LIBUSB_ERROR_TIMEOUT) continue;   /* prime: keep polling */
        if (r < 0) { printf("  bulk: %s\n", libusb_strerror(r)); break; }
        if (out) fwrite(buf, 1, got, out);
        if (total == 0) hexdump("first 64", buf, got < 64 ? got : 64);
        total += got;
    }
    if (out) fclose(out);
    free(buf);
    printf("captured %d bytes\n", total);
    return total;
}

/* ---- asynchronous capture --------------------------------------------
 * libusb_bulk_transfer leaves a gap between the completion of one read and
 * the submission of the next.  With a small device FIFO that is enough for
 * the bridge to overflow and drop lines, which shows up as the regular
 * 32-delivered/16-dropped pattern.  Keep N URBs in flight instead. */
#define ACAP_URBS 24
#define ACAP_BUFSZ 32768

struct acap_ctx {
    FILE *out;
    unsigned long long total;
    struct timespec t0;
    int secs;
    int inflight;
    int done;
};

static struct acap_ctx g_acap;

static void acap_cb(struct libusb_transfer *t)
{
    struct acap_ctx *c = t->user_data;
    if (t->status == LIBUSB_TRANSFER_COMPLETED && t->actual_length > 0) {
        if (c->out) fwrite(t->buffer, 1, t->actual_length, c->out);
        c->total += t->actual_length;
    }
    if (c->done) { c->inflight--; return; }
    struct timespec now;
    clock_gettime(CLOCK_MONOTONIC, &now);
    double el = (now.tv_sec - c->t0.tv_sec) + 1e-9 * (now.tv_nsec - c->t0.tv_nsec);
    if (el >= c->secs || libusb_submit_transfer(t) < 0) { c->done = 1; c->inflight--; }
}

static int cmd_cap_async(int endpoint, int secs, const char *outfile)
{
    struct libusb_transfer *tr[ACAP_URBS];
    unsigned char *buf[ACAP_URBS];
    const char *eu = getenv("PCTV_URB");
    int bufsz = eu ? atoi(eu) : ACAP_BUFSZ;
    if (bufsz < 512) bufsz = 512;
    g_acap.out = outfile ? fopen(outfile, "wb") : NULL;
    g_acap.total = 0; g_acap.done = 0; g_acap.secs = secs; g_acap.inflight = 0;
    clock_gettime(CLOCK_MONOTONIC, &g_acap.t0);
    printf("async-capturing from ep 0x%02x for %d s (%d URBs x %d bytes) ...\n",
           endpoint, secs, ACAP_URBS, bufsz);
    for (int i = 0; i < ACAP_URBS; i++) {
        buf[i] = malloc(bufsz);
        tr[i] = libusb_alloc_transfer(0);
        libusb_fill_bulk_transfer(tr[i], dev, endpoint, buf[i], bufsz,
                                  acap_cb, &g_acap, 1000);
        g_acap.inflight++;
        if (libusb_submit_transfer(tr[i]) < 0) {
            printf("submit %d failed\n", i);
            g_acap.inflight--; g_acap.done = 1;
        }
    }
    while (!g_acap.done && g_acap.inflight > 0) {
        struct timeval tv = { 0, 100000 };
        libusb_handle_events_timeout_completed(NULL, &tv, NULL);
    }
    g_acap.done = 1;
    for (int i = 0; i < ACAP_URBS; i++) libusb_cancel_transfer(tr[i]);
    while (g_acap.inflight > 0) {
        struct timeval tv = { 0, 100000 };
        libusb_handle_events_timeout_completed(NULL, &tv, NULL);
    }
    for (int i = 0; i < ACAP_URBS; i++) { libusb_free_transfer(tr[i]); free(buf[i]); }
    if (g_acap.out) fclose(g_acap.out);
    struct timespec t1;
    clock_gettime(CLOCK_MONOTONIC, &t1);
    double el = (t1.tv_sec - g_acap.t0.tv_sec) + 1e-9 * (t1.tv_nsec - g_acap.t0.tv_nsec);
    printf("async captured %llu bytes in %.2f s = %.0f B/s\n",
           g_acap.total, el, g_acap.total / el);
    return 0;
}

static int read_word_new(int bus, int addr7, int reg, unsigned int *out);
static int demod_wr(int addr8, int reg, int val);

/* timed capture: read for <secs>, report the byte rate */
static int cmd_cap2(int endpoint, int secs, const char *outfile)
{
    unsigned char *buf = malloc(65536);
    int got = 0, total = 0, r, nreads = 0, nzero = 0;
    struct timespec t0, t1, last;
    FILE *out = outfile ? fopen(outfile, "wb") : NULL;
    clock_gettime(CLOCK_MONOTONIC, &t0);
    last = t0;
    printf("capturing from ep 0x%02x for %d s ...\n", endpoint, secs);
    while (1) {
        clock_gettime(CLOCK_MONOTONIC, &t1);
        double el = (double)(t1.tv_sec - t0.tv_sec) + 1e-9 * (t1.tv_nsec - t0.tv_nsec);
        if (el >= secs) break;
        r = libusb_bulk_transfer(dev, endpoint, buf, 65536, &got, 1000);
        if (r == LIBUSB_ERROR_TIMEOUT) { nzero++; continue; }
        if (r < 0) { printf("  bulk: %s\n", libusb_strerror(r)); break; }
        if (out) fwrite(buf, 1, got, out);
        if (total == 0) hexdump("first 64", buf, got < 64 ? got : 64);
        total += got; nreads++;
        clock_gettime(CLOCK_MONOTONIC, &t1);
        double el2 = (double)(t1.tv_sec - last.tv_sec) + 1e-9 * (t1.tv_nsec - last.tv_nsec);
        if (el2 > 1.0) { printf("  +%.2fs: %d bytes (gap %.2fs)\n", el, total, el2); last = t1; }
    }
    if (out) fclose(out);
    free(buf);
    clock_gettime(CLOCK_MONOTONIC, &t1);
    double el = (double)(t1.tv_sec - t0.tv_sec) + 1e-9 * (t1.tv_nsec - t0.tv_nsec);
    printf("captured %d bytes in %.2f s = %.0f B/s (%d reads, %d timeouts)\n",
           total, el, total / el, nreads, nzero);
    return total;
}

/* send an arbitrary control OUT payload given as hex digits, e.g. 0f100100 */
static int cmd_arm(const char *hex)
{
    unsigned char b[64]; int n = 0;
    while (hex[0] && hex[1] && n < 64) {
        unsigned int v; sscanf(hex, "%02x", &v);
        b[n++] = (unsigned char)v; hex += 2;
    }
    int r = wr(b, n);
    printf("arm %s -> %s\n", hex, r < 0 ? libusb_strerror(r) : "ok");
    return r;
}

/* demod power: mirror dib7000p_set_power_mode(DIB7000P_POWER_ALL) */
static int cmd_pwron(int all)
{
    unsigned int cur = 0;
    read_word_new(1, 0x40, 1280, &cur);
    unsigned int v1280 = all ? (cur & 0x01ff) : (0xfe00u | (cur & 0x01ff));
    demod_wr(0x80, 774, all ? 0 : 0x3fff);
    demod_wr(0x80, 775, all ? 0 : 0xffff);
    demod_wr(0x80, 776, all ? 0 : 0x0007);
    demod_wr(0x80, 899, all ? 0 : 0x0003);
    demod_wr(0x80, 1280, v1280);
    printf("pwron %s: 774/775/776/899=%04x 1280=%04x (was %04x)\n",
           all ? "ALL" : "IF_ONLY", all ? 0 : 0x3fff, v1280, cur);
    return 0;
}

/* mirror dib7000p_demod_reset() for the non-SOC7090 parts */
static int cmd_demodreset(void)
{
    int a = 0x80;
    unsigned int w = 0;
    demod_wr(a, 1287, 0x0003);                    /* sram lead in, rdy */
    cmd_pwron(1);                                 /* DIB7000P_POWER_ALL */
    if (read_word_new(1, 0x40, 908, &w) == 2)     /* VBG enable */
        demod_wr(a, 908, w & ~(1 << 15));
    demod_wr(a, 770, 0xffff);
    demod_wr(a, 771, 0xffff);
    demod_wr(a, 772, 0x001f);
    demod_wr(a, 1280, 0x001f - ((1 << 4) | (1 << 3)));
    demod_wr(a, 770, 0);
    demod_wr(a, 771, 0);
    demod_wr(a, 772, 0);
    demod_wr(a, 1280, 0);
    demod_wr(a, 898, 0x0003);
    demod_wr(a, 898, 0);
    /* reset_gpio (stk7700ph: dir 0x7f, val 0x00) */
    demod_wr(a, 1029, 0x007f);
    demod_wr(a, 1030, 0x0000);
    demod_wr(a, 1032, 0x0000);
    demod_wr(a, 1037, 0x0000);
    /* slow adc on + sad calib + off */
    if (read_word_new(1, 0x40, 909, &w) == 2)
        demod_wr(a, 909, w | (1 << 1) | (1 << 0));
    demod_wr(a, 73, 0);
    demod_wr(a, 74, 776);
    demod_wr(a, 73, 1 << 0);
    demod_wr(a, 73, 0);
    usleep(2000);
    if (read_word_new(1, 0x40, 909, &w) == 2)
        demod_wr(a, 909, w | (1 << 1) | (1 << 0));
    /* unforce divstr */
    if (read_word_new(1, 0x40, 1285, &w) == 2)
        demod_wr(a, 1285, w & ~(1 << 1));
    /* set_bandwidth(8000): timf = cfg bw timf * (8000/50) / 160 */
    demod_wr(a, 23, 0x0000);
    demod_wr(a, 24, 0x0000);
    demod_wr(a, 36, 0x1f55);
    printf("demodreset done\n");
    return 0;
}

/* enable the DIB7000P diversity INPUT path: external parallel TS -> host bus.
 * dib7000p_set_diversity_in(1) + dib7000p_set_output_mode(OUTMODE_DIVERSITY) */
static int cmd_diversity(int on, int r1286)
{
    int a = 0x80;
    if (on) {
        demod_wr(a, 207, (0 << 4) | (1 << 2) | (2 << 0));
        demod_wr(a, 204, 6);
        demod_wr(a, 205, 16);
    } else {
        demod_wr(a, 204, 1);
        demod_wr(a, 205, 0);
    }
    unsigned int w = 0;
    if (read_word_new(1, 0x40, 235, &w) == 2)
        demod_wr(a, 235, (w & 0x0050) | (1 << 1));
    demod_wr(a, 236, 1792);
    demod_wr(a, 1286, r1286);
    printf("diversity %s: 204/205/207 %d/%d/5, 235=%04x, 236=1792, 1286=%04x\n",
           on ? "IN" : "OFF", on ? 6 : 1, on ? 16 : 0, w & 0x0050 | 2, r1286);
    return 0;
}

/* Configure the DIB7000P "DibStream Rx" (parallel/serial stream RECEIVER):
 * mirror of dib7090_cfg_DibRx() in dib7000p.c — regs 1536..1544 + 1554 strobe. */
static int cmd_dibrx(int kin, int kout, int syncmode, int insync,
                     unsigned int syncword, int syncsize, int outrate)
{
    int a = 0x80;
    if (kin && kout) {
        /* dib7090_calcSyncFreq: syncFreq = 20000000 * Kout / (Kin * syncSize) */
        unsigned int sf = (unsigned int)(20000000.0 * kout / (kin * (syncsize ? syncsize : 1)));
        demod_wr(a, 1542, sf & 0xffff);
        printf("dibrx: 1542 = %u\n", sf);
    }
    demod_wr(a, 1554, 1);
    demod_wr(a, 1536, kin);
    demod_wr(a, 1537, kout);
    demod_wr(a, 1539, syncmode);
    demod_wr(a, 1540, (syncword >> 16) & 0xffff);
    demod_wr(a, 1541, syncword & 0xffff);
    demod_wr(a, 1543, syncsize);
    demod_wr(a, 1544, outrate);
    demod_wr(a, 1554, 0);
    printf("dibrx: 1536=%d 1537=%d 1539=%d 1540/41=%04x/%04x 1543=%d 1544=%d\n",
           kin, kout, syncmode, (syncword >> 16) & 0xffff, syncword & 0xffff, syncsize, outrate);
    return 0;
}

static int cmd_adapt(int rq)
{
    unsigned char b[64];
    int r = ctrl_in(rq, 0, 0, b, 64);
    if (r > 0) hexdump("adapt", b, r);
    else printf("  -> %s\n", libusb_strerror(r));
    return r;
}

static int cmd_demod(int rq)
{
    unsigned char b[64];
    int r = ctrl_in(rq, 0, 0, b, 64);
    if (r > 0) hexdump("demod rd", b, r);
    else printf("  -> %s\n", libusb_strerror(r));
    return r;
}

static int cmd_scan_legacy(void)
{
    int found = 0;
    printf("legacy I2C scan (0x0f read, 1 byte)\n");
    for (int a = 0x08; a <= 0x77; a++) {
        unsigned char rx[4];
        int r = i2c_read_legacy(a, NULL, 0, rx, 1);
        if (r > 0) { printf("  ACK at 0x%02x -> %02x\n", a, rx[0]); found++; }
    }
    printf("legacy scan done: %d device(s)\n", found);
    return 0;
}

/* arbitrary control transfer, for probing unknown requests:
 *   raw in  <rq> <value> <index> <len>
 *   raw out <rq> <b1> <b2> ...            (b1 is written after rq) */
static int cmd_raw(int argc, char **argv)
{
    if (argc < 3) return 2;
    if (!strcmp(argv[2], "in")) {
        uint8_t rq = strtol(argv[3], 0, 0);
        uint16_t v = strtol(argv[4], 0, 0), ix = strtol(argv[5], 0, 0);
        int len = atoi(argv[6]);
        unsigned char *b = calloc(1, len);
        int r = ctrl_in(rq, v, ix, b, len);
        if (r > 0) hexdump("raw in", b, r);
        free(b);
        return r;
    } else {
        int n = argc - 3;
        unsigned char *b = calloc(1, n + 1);
        b[0] = strtol(argv[3], 0, 0);
        for (int i = 0; i < n; i++) b[i + 1] = strtol(argv[4 + i], 0, 0);
        int r = ctrl_out(b, n + 1);
        free(b);
        return r;
    }
}

static int cmd_bulkout(int argc, char **argv)
{
    int n = argc - 2;
    unsigned char *b = calloc(1, n);
    int xfer = 0;
    for (int i = 0; i < n; i++) b[i] = strtol(argv[2 + i], 0, 0);
    int r = libusb_bulk_transfer(dev, 0x01, b, n, &xfer, 2000);
    printf("bulk out %d bytes -> %s (%d)\n", n, r < 0 ? libusb_strerror(r) : "ok", xfer);
    free(b);
    return r;
}

/* firmware download with per-record ACK read on bulk IN ep1 */
static int download_firmware2(const char *path)
{
    FILE *f = fopen(path, "rb");
    if (!f) { perror("open fw"); return -1; }
    fseek(f, 0, SEEK_END); long sz = ftell(f); fseek(f, 0, SEEK_SET);
    unsigned char *fw = malloc(sz);
    if (!fw || fread(fw, 1, sz, f) != (size_t)sz) { fclose(f); free(fw); return -1; }
    fclose(f);

    unsigned char *b = malloc(300);
    unsigned char rx[300];
    long pos = 0; int nrec = 0; int ack_fails = 0;
    while (pos + 5 <= sz) {
        unsigned char len = fw[pos];
        unsigned char type = fw[pos + 3];
        if (pos + 4 + len + 1 > sz) break;
        int blen = len + 5;
        b[0] = len; b[1] = fw[pos+1]; b[2] = fw[pos+2]; b[3] = type;
        memcpy(b + 4, fw + pos + 4, len);
        b[4 + len] = fw[pos + 4 + len];
        int xfer = 0;
        int r = libusb_bulk_transfer(dev, 0x01, b, blen, &xfer, 2000);
        if (r < 0) { printf("fw write failed at %ld: %s\n", pos, libusb_strerror(r)); free(fw); free(b); return -1; }
        int rr = libusb_bulk_transfer(dev, 0x81, rx, sizeof(rx), &xfer, 300);
        if (rr == 0 && xfer > 0) {
            printf("  rec %4d addr %02x%02x type %02x len %3d -> ack %d:",
                   nrec, fw[pos+1], fw[pos+2], type, len, xfer);
            for (int i = 0; i < xfer && i < 24; i++) printf(" %02x", rx[i]);
            printf("\n");
        }
        pos += 4 + len + 1;
        nrec++;
        if (type == 0x01) break;
    }
    printf("firmware: %d record(s) written\n", nrec);

    unsigned char j[8] = { RQ_JUMPRAM, 0, 0, 0, 0x70, 0, 0, 0 };
    int xfer = 0;
    int r = libusb_bulk_transfer(dev, 0x01, j, 8, &xfer, 2000);
    printf("jumpram write: %s (%d)\n", r < 0 ? libusb_strerror(r) : "ok", xfer);
    int rr = libusb_bulk_transfer(dev, 0x81, rx, sizeof(rx), &xfer, 1000);
    if (rr == 0 && xfer > 0) {
        printf("jumpram ack %d:", xfer);
        for (int i = 0; i < xfer && i < 32; i++) printf(" %02x", rx[i]);
        printf("\n");
    }
    usleep(600000);
    free(fw); free(b);
    return 0;
}

/* generic 2-byte-register i2c read, both APIs
 *   i2c2 <api 0=legacy 1=new> <bus 0|1> <addr7> <reghi> <reglo> <n> */
static int cmd_i2c2(int api, int bus, int addr, int reghi, int reglo, int n)
{
    unsigned char rx[64];
    int r;
    if (api == 1) {
        unsigned char w[6] = { RQ_NEW_I2C_WRITE,
                               (unsigned char)(addr << 1),
                               (unsigned char)((1 << 7) | (1 << 6) | 2),
                               (unsigned char)((bus << 4) & 0x30),
                               (unsigned char)reghi, (unsigned char)reglo };
        r = ctrl_out(w, 6);
        if (r < 0) { printf("  new write failed: %s\n", libusb_strerror(r)); return r; }
        r = i2c_read_new(addr, rx, n, bus);
    } else {
        unsigned char tx[4] = { RQ_I2C_READ, (unsigned char)((addr << 1) | 1),
                                (unsigned char)reghi, (unsigned char)reglo };
        r = rd(tx, 4, rx, n);
    }
    if (r > 0) hexdump("i2c2 read", rx, r);
    return r;
}

/* generic 2-byte-register i2c write */
static int cmd_i2c2w(int api, int bus, int addr, int reghi, int reglo, int val)
{
    int r;
    if (api == 1) {
        unsigned char w[7] = { RQ_NEW_I2C_WRITE,
                               (unsigned char)(addr << 1),
                               (unsigned char)((1 << 7) | (1 << 6) | 3),
                               (unsigned char)((bus << 4) & 0x30),
                               (unsigned char)reghi, (unsigned char)reglo,
                               (unsigned char)val };
        r = ctrl_out(w, 7);
    } else {
        unsigned char w[5] = { RQ_I2C_WRITE, (unsigned char)(addr << 1),
                               (unsigned char)reghi, (unsigned char)reglo,
                               (unsigned char)val };
        r = ctrl_out(w, 5);
    }
    return r;
}

/* full cold bring-up in one process, mirroring the kernel's probe sequence:
 *   download fw -> jumpram -> GET_VERSION -> SET_CLOCK -> SET_I2C_PARAM -> i2c scan */
static int cmd_init(const char *fwpath)
{
    printf("-- download firmware --\n");
    if (download_firmware(fwpath) < 0) return -1;
    printf("-- GET_VERSION --\n");
    if (cmd_version() < 0) printf("   (firmware not responding)\n");
    printf("-- SET_CLOCK 72MHz --\n"); cmd_clock();
    printf("-- SET_I2C_PARAM 100kHz --\n"); cmd_i2cparam(100);
    printf("-- legacy i2c scan (rq 0x02) --\n"); cmd_scan_legacy();
    printf("-- new i2c scan (rq 0x12/0x13) bus 1 --\n"); cmd_scan(1);
    printf("-- new i2c scan bus 0 --\n"); cmd_scan(0);
    return 0;
}

/* watch: poll for the device appearing and immediately read GET_VERSION.
 * Used to see what the device does on a clean power-up, before anyone touches it. */
static int cmd_watch(int secs)
{
    time_t end = time(NULL) + secs;
    int seen = 0;
    printf("watching for %d s ... unplug the device now, wait 20 s, plug it back\n", secs);
    while (time(NULL) < end) {
        dev = libusb_open_device_with_vid_pid(NULL, VID, PID);
        if (!dev) { usleep(200000); continue; }
        libusb_detach_kernel_driver(dev, 0);
        libusb_claim_interface(dev, 0);
        unsigned char b[16];
        time_t t0 = time(NULL);
        int r = ctrl_in(RQ_GET_VERSION, 0, 0, b, 16);
        printf("[%ld] GET_VERSION -> %d\n", (long)t0, r);
        if (r == 16) {
            printf("    hw=%08x rom=%08x ram=%08x fwtype=%08x  ** SELF-BOOTED FIRMWARE **\n",
                   (b[0]<<24)|(b[1]<<16)|(b[2]<<8)|b[3],
                   (b[4]<<24)|(b[5]<<16)|(b[6]<<8)|b[7],
                   (b[8]<<24)|(b[9]<<16)|(b[10]<<8)|b[11],
                   (b[12]<<24)|(b[13]<<16)|(b[14]<<8)|b[15]);
            seen = 1;
        }
        libusb_release_interface(dev, 0);
        libusb_close(dev); dev = NULL;
        if (seen) return 0;
        usleep(300000);
    }
    return -1;
}

static int reopen(void)
{
    if (dev) { libusb_close(dev); dev = NULL; }
    for (int i = 0; i < 20; i++) {
        dev = libusb_open_device_with_vid_pid(NULL, VID, PID);
        if (dev) {
            libusb_detach_kernel_driver(dev, 0);
            if (libusb_claim_interface(dev, 0) < 0)
                libusb_claim_interface(dev, 1);
            return 0;
        }
        usleep(500000);
    }
    return -1;
}

/* arbitrary control transfer, for probing unknown requests:
 *   raw in  <rq> <value> <index> <len>
 *   raw out <rq> <b1> <b2> ...            (b1 is written after rq)
 * The "4" variants use recipient=4 (bmRequestType 0xC4 / 0x44), which is what
 * the Pinnacle Windows driver uses against the DiB0700 boot ROM. */
static int ctrl_in4(uint8_t request, uint16_t value, uint16_t index,
                    unsigned char *buf, int len)
{
    int r = libusb_control_transfer(dev, 0xC4, request, value, index, buf, (uint16_t)len, 5000);
    printf("  IN4 rq=0x%02x value=0x%04x index=0x%04x -> %s", request, value, index,
           r < 0 ? libusb_strerror(r) : "ok");
    if (r > 0) { printf("  ["); for (int i = 0; i < r; i++) printf("%02x ", buf[i]); printf("]"); }
    printf("\n");
    return r;
}

static int ctrl_out4(const unsigned char *buf, int len)
{
    int r = libusb_control_transfer(dev, 0x44, buf[0], 0, 0, (unsigned char *)buf, (uint16_t)len, 5000);
    printf("  OUT4 len=%d rq=0x%02x -> %s\n", len, buf[0], r < 0 ? libusb_strerror(r) : "ok");
    return r;
}

static int cmd_raw4(int argc, char **argv)
{
    if (argc < 4) return 2;
    if (!strcmp(argv[2], "in")) {
        if (argc < 7) { fprintf(stderr, "raw4 in <rq> <value> <index> <len>\n"); return 2; }
        uint8_t rq = strtol(argv[3], 0, 0);
        uint16_t v = strtol(argv[4], 0, 0), ix = strtol(argv[5], 0, 0);
        int len = atoi(argv[6]);
        unsigned char *b = calloc(1, len);
        int r = ctrl_in4(rq, v, ix, b, len);
        free(b);
        return r;
    } else {
        int n = argc - 4;
        if (n < 1) { fprintf(stderr, "raw4 out <rq> <b1> [<b2> ...]\n"); return 2; }
        unsigned char *b = calloc(1, n + 1);
        b[0] = strtol(argv[3], 0, 0);
        for (int i = 0; i < n; i++) b[i + 1] = strtol(argv[4 + i], 0, 0);
        int r = ctrl_out4(b, n + 1);
        free(b);
        return r;
    }
}

/* dump the EEPROM image the way the Windows driver does */
/* legacy i2c read with an explicit register phase (txlen 3): this is the form
 * the Pinnacle firmware actually accepts.  tx = [0x02, (addr<<1)|1, reg] */
static int cmd_scan3(void)
{
    int found = 0;
    printf("i2c scan (legacy 0x02, 3-byte tx, recipient 4)\n");
    for (int a = 0x03; a <= 0x77; a++) {
        unsigned char rx[4];
        uint16_t v = 0x0100 | (uint16_t)((a << 1) | 1);
        int r = ctrl_in(0x02, v, 0x0000, rx, 1);
        if (r > 0) { printf("  ACK 0x%02x (8-bit 0x%02x) -> %02x\n", a, a << 1, rx[0]); found++; }
    }
    printf("scan3: %d device(s) answered\n", found);
    return 0;
}

/* read a 1-byte-register device */
static int cmd_rd1(int addr, int reg, int n)
{
    unsigned char rx[64];
    uint16_t v = 0x0100 | (uint16_t)((addr << 1) | 1);
    int r = ctrl_in(0x02, v, (uint16_t)(reg << 8), rx, n);
    if (r > 0) hexdump("rd1", rx, r);
    return r;
}

/* read a 2-byte-register device (CX2584x style) */
static int cmd_rd2(int addr, int hi, int lo, int n)
{
    unsigned char rx[64];
    uint16_t v = 0x0200 | (uint16_t)((addr << 1) | 1);
    int r = ctrl_in(0x02, v, (uint16_t)((hi << 8) | lo), rx, n);
    if (r > 0) hexdump("rd2", rx, r);
    return r;
}

/* write to a device: legacy 0x03, tx = [0x03, addr<<1, reg, val...] */
static int cmd_wr1(int addr, int reg, int val)
{
    unsigned char b[4] = { 0x03, (unsigned char)(addr << 1), (unsigned char)reg, (unsigned char)val };
    return ctrl_out(b, 4);
}

static int cmd_eeprom(void)
{
    unsigned char b[8];
    for (int ix = 0; ix <= 0x4800; ix += 0x800) {
        int r = libusb_control_transfer(dev, 0xC4, 0x02, 0x01a0, ix, b, 8, 5000);
        if (r < 0) { printf("  eeprom read at %04x -> %s\n", ix, libusb_strerror(r)); continue; }
        printf("  %04x: ", ix);
        for (int i = 0; i < r; i++) printf("%02x ", b[i]);
        printf(" |");
        for (int i = 0; i < r; i++) putchar(b[i] >= 32 && b[i] < 127 ? b[i] : '.');
        printf("|\n");
    }
    return 0;
}

/* map the firmware's vendor-request API: try every request number, IN and OUT */
static int cmd_probeall(int out_mode, int from, int to, int rec4)
{
    unsigned char b[16];
    int type_in  = rec4 ? 0xC4 : (LIBUSB_ENDPOINT_IN  | LIBUSB_REQUEST_TYPE_VENDOR | LIBUSB_RECIPIENT_DEVICE);
    int type_out = rec4 ? 0x44 : (LIBUSB_ENDPOINT_OUT | LIBUSB_REQUEST_TYPE_VENDOR | LIBUSB_RECIPIENT_DEVICE);
    printf("probing vendor requests 0x%02x..0x%02x (%s, bmRequestType %02x)\n",
           from, to, out_mode ? "OUT" : "IN", rec4 ? (out_mode ? 0x44 : 0xC4) : (out_mode ? 0x40 : 0xC0));
    for (int rq = from; rq <= to; rq++) {
        int r;
        if (out_mode) {
            unsigned char o[4] = { (unsigned char)rq, 0, 0, 0 };
            r = libusb_control_transfer(dev, type_out, rq, 0, 0, o, 4, 800);
        } else {
            r = libusb_control_transfer(dev, type_in, rq, 0, 0, b, 16, 800);
        }
        const char *cls;
        switch (r) {
        case LIBUSB_ERROR_PIPE:    cls = "STALL";  break;
        case LIBUSB_ERROR_TIMEOUT: cls = "timeout"; break;
        default: cls = r < 0 ? libusb_strerror(r) : "OK"; break;
        }
        if (r > 0) {
            printf("  rq 0x%02x: %-8s %2d bytes:", rq, cls, r);
            for (int i = 0; i < r; i++) printf(" %02x", b[i]);
            printf("\n");
        } else if (r != LIBUSB_ERROR_TIMEOUT) {
            printf("  rq 0x%02x: %s\n", rq, cls);
        }
        if (r == LIBUSB_ERROR_PIPE) {
            libusb_clear_halt(dev, 0x82);
            libusb_clear_halt(dev, 0x83);
            libusb_clear_halt(dev, 0x02);
        }
        if (r == LIBUSB_ERROR_NO_DEVICE) {
            printf("  (device re-enumerated; reopening)\n");
            if (reopen() < 0) { printf("  reopen failed, aborting\n"); break; }
            printf("  reopened\n");
        }
    }
    return 0;
}

/* ================================================================== *
 *  ROM-bootloader window catcher ("romwin")
 *
 *  The DiB0700's 8051 normally self-boots firmware from its config
 *  EEPROM; when that fails it either sits in the mask ROM (GET_VERSION
 *  returns ram=0x00000001) or stops answering EP0 altogether.  That
 *  window is rare and is provoked by host activity, so this watches, then
 *  the instant the bridge answers it dumps everything (both GET_VERSION
 *  forms, the full EEPROM, GET_GPIO, the vendor-request map).
 *
 *  It is strictly READ-ONLY: it never writes the EEPROM.  The only thing
 *  it sends to the device is the ordinary RAM firmware download (which is
 *  non-persistent and already proven harmless), and optionally a USB port
 *  reset.
 * ================================================================== */

#define BE32(p) (((unsigned)(p)[0] << 24) | ((unsigned)(p)[1] << 16) | \
                 ((unsigned)(p)[2] << 8)  |  (unsigned)(p)[3])

static unsigned long long now_ms(void)
{
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return (unsigned long long)t.tv_sec * 1000ull + t.tv_nsec / 1000000ull;
}

static void stamp(char *buf, size_t n)
{
    time_t t = time(NULL);
    struct tm tm;
    localtime_r(&t, &tm);
    strftime(buf, n, "%H:%M:%S", &tm);
}

/* mkdir -p (single component paths and nested paths, no shell-out) */
static int mkdir_p(const char *path)
{
    char tmp[512];
    size_t len = strlen(path);
    if (len == 0 || len >= sizeof tmp) return -1;
    memcpy(tmp, path, len + 1);
    if (tmp[len - 1] == '/') tmp[len - 1] = 0;
    for (char *p = tmp + 1; *p; p++) {
        if (*p == '/') { *p = 0; mkdir(tmp, 0777); *p = '/'; }
    }
    return mkdir(tmp, 0777);
}

/* Read GET_VERSION.  The ROM and the running firmware are reached through
 * different bmRequestType recipients, so the caller tries both. */
static int read_version(unsigned char *b, int len, int recip4)
{
    if (!dev) return LIBUSB_ERROR_NO_DEVICE;
    return libusb_control_transfer(dev, recip4 ? 0xC4 : 0xC0, RQ_GET_VERSION,
                                   0, 0, b, (uint16_t)len, 1000);
}

/* The DiB0700 exposes the config EEPROM through GET_EEPROM: recipient 4,
 * request 0x02, wValue 0x01a0 (0x01 = read, 0xa0 = I2C address byte of the
 * EEPROM at 0x50), 8 bytes per window.  This is the read the Windows driver
 * performs at cold start.
 *
 * MEASURED 2026-10-08 (ROM window, 12 index points, all consistent):
 * the 8 bytes returned are a SLIDING WINDOW that starts at EEPROM byte
 * (wIndex >> 8) - the ROM's index register is the HIGH byte of wIndex, it is
 * 8 bits wide, and it wraps (the window at 0xff00 ends with byte 0 again).
 * So the byte address is wIndex>>8, NOT wIndex: the old form (wIndex = off)
 * re-reads the same byte 32 times and only ever reaches bytes 0..max/256.
 * With a 16-bit wIndex that caps the reachable EEPROM at 256 bytes. */
#define EEP_RQ   0x02
#define EEP_VAL  0x01a0

/* one 8-byte window starting at EEPROM byte `off` */
static int eep_at(int off, unsigned char *b)
{
    if (!dev) return LIBUSB_ERROR_NO_DEVICE;
    return libusb_control_transfer(dev, 0xC4, EEP_RQ, EEP_VAL,
                                   (uint16_t)((off << 8) & 0xffff), b, 8, 2000);
}

/* raw GET_EEPROM with an explicit wValue/wIndex (for form discovery) */
static int eep_raw(int recip4, unsigned value, unsigned index, unsigned char *b, int len)
{
    if (!dev) return LIBUSB_ERROR_NO_DEVICE;
    return libusb_control_transfer(dev, recip4 ? 0xC4 : 0xC0, EEP_RQ,
                                   (uint16_t)value, (uint16_t)index, b,
                                   (uint16_t)len, 1500);
}

static int cmd_eepromdump(unsigned maxbytes, const char *outpath, int quiet)
{
    unsigned char b[8];
    unsigned off, ok = 0, bad = 0;
    FILE *f = outpath ? fopen(outpath, "wb") : NULL;
    if (outpath && !f) perror(outpath);
    if (!maxbytes) maxbytes = 256;
    if (maxbytes > 0x100) maxbytes = 0x100;  /* the ROM index is 8-bit */
    for (off = 0; off < maxbytes; off += 8) {
        if (!dev) break;
        int r = eep_at((int)off, b);
        if (r != 8) {
            bad++;
            if (bad <= 4)
                printf("  eeprom %04x -> %s\n", off,
                       r < 0 ? libusb_strerror(r) : "short read");
            if (r == LIBUSB_ERROR_NO_DEVICE) { dev = NULL; break; }
            memset(b, 0xdb, 8);   /* keep the image byte-aligned */
        } else
            ok++;
        if (f) fwrite(b, 1, 8, f);
        if (!quiet) {
            printf("  %03x: ", off);
            for (int i = 0; i < 8; i++) printf("%02x ", b[i]);
            printf("  |");
            for (int i = 0; i < 8; i++) putchar(b[i] >= 32 && b[i] < 127 ? b[i] : '.');
            printf("|\n");
        }
    }
    if (f) fclose(f);
    printf("eepromdump: %u window(s) ok, %u bad, bytes 0..%02x%s\n",
           ok, bad, maxbytes ? maxbytes - 1 : 0, outpath ? " (saved)" : "");
    /* cross-check: the window at 0xff must run past byte 255 back to byte 0 */
    if (dev && !quiet) {
        unsigned char w[8];
        int rw = eep_at(0xff, w);
        printf("  wrap check @255 -> %s", rw < 0 ? libusb_strerror(rw) : "ok");
        if (rw == 8) { printf("  "); for (int i = 0; i < 8; i++) printf("%02x ", w[i]); }
        printf("\n");
    }
    return bad ? 1 : 0;
}

static int snapshot_window(const char *dir, int idx, int quiet, int do_map)
{
    char path[600], tb[16];
    unsigned char b[16];
    stamp(tb, sizeof tb);
    printf("\n*** ROM WINDOW #%d at %s ***\n", idx, tb);
    fflush(stdout);

    int r0 = read_version(b, 16, 0);
    printf("  [%s] GET_VERSION recipient0 -> %s", tb,
           r0 < 0 ? libusb_strerror(r0) : "ok");
    if (r0 > 0) { printf("  "); for (int i = 0; i < r0; i++) printf("%02x ", b[i]); }
    printf("\n");
    if (r0 == 16)
        printf("    hw=%08x rom=%08x ram=%08x fwtype=%08x\n",
               BE32(b), BE32(b + 4), BE32(b + 8), BE32(b + 12));

    int r4 = read_version(b, 16, 1);
    printf("  [%s] GET_VERSION recipient4 -> %s", tb,
           r4 < 0 ? libusb_strerror(r4) : "ok");
    if (r4 > 0) { printf("  "); for (int i = 0; i < r4; i++) printf("%02x ", b[i]); }
    printf("\n");
    if (r4 == 16)
        printf("    hw=%08x rom=%08x ram=%08x fwtype=%08x\n",
               BE32(b), BE32(b + 4), BE32(b + 8), BE32(b + 12));

    if (r0 <= 0 && r4 <= 0) {
        printf("  (window closed before snapshot)\n");
        return 0;
    }

    unsigned char g[2];
    int rg = libusb_control_transfer(dev, 0xC4, RQ_GET_GPIO_VAL, 0, 0, g, 2, 1000);
    printf("  [%s] GET_GPIO_VAL -> %s", tb, rg < 0 ? libusb_strerror(rg) : "ok");
    if (rg > 0) { printf("  "); for (int i = 0; i < rg; i++) printf("%02x ", g[i]); }
    printf("\n");

    snprintf(path, sizeof path, "%s/eeprom-window%d.bin", dir, idx);
    printf("  [%s] EEPROM dump -> %s\n", tb, path);
    cmd_eepromdump(0x4000, path, quiet);

    /* The vendor-request map is DESTRUCTIVE to the very service we are
     * hunting: the map sends rq 0x02 (I2C-in) with wValue 0, i.e. I2C address
     * byte 0x00, and that wedges the ROM's I2C engine - measured 2026-10-08,
     * GET_EEPROM answered 2048 times in a row and STALLs from the map probe
     * onwards, while GET_VERSION kept answering.  This is the mechanism behind
     * the old "probing every request number wedges the stick" note.  So the
     * map is opt-in (--map), never part of the default snapshot. */
    printf("  [%s] vendor request map (recipient 4, IN, 0x00..0xff): %s\n", tb,
           do_map ? "running (wedges the I2C/EEPROM service)" : "SKIPPED (use --map)");
    if (dev && do_map) cmd_probeall(0, 0, 0xff, 1);

    return 1;
}

/* usage: romwin [secs] [dir] [--fw file] [--no-fw] [--reset-every N]
 *                [--max N] [--quiet]
 * env:   ROMWIN_FW etc. are not used; keep it explicit on the command line. */
static int cmd_romwin(int argc, char **argv)
{
    int secs = 1800, reset_every = 0, max_windows = 0, quiet = 0, do_map = 0;
    const char *dir = NULL, *fw = "firmware/win_fw.bin";
    int positional = 0;

    for (int i = 2; i < argc; i++) {
        if (!strcmp(argv[i], "--fw") && i + 1 < argc)        fw = argv[++i];
        else if (!strcmp(argv[i], "--no-fw"))                 fw = NULL;
        else if (!strcmp(argv[i], "--reset-every") && i + 1 < argc) reset_every = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--max") && i + 1 < argc)   max_windows = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--secs") && i + 1 < argc)  secs = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--quiet"))                 quiet = 1;
        else if (!strcmp(argv[i], "--map"))                    do_map = 1;
        else if (argv[i][0] != '-') {
            if (positional == 0) { secs = atoi(argv[i]); positional = 1; }
            else if (positional == 1) { dir = argv[i]; positional = 2; }
        }
    }

    char default_dir[256];
    if (!dir) {
        snprintf(default_dir, sizeof default_dir, "logs/romwin-%ld", (long)time(NULL));
        dir = default_dir;
    }
    mkdir_p(dir);
    if (max_windows <= 0) max_windows = 1 << 30;

    printf("romwin: secs=%d dir=%s fw=%s reset_every=%d max_windows=%s quiet=%d\n",
           secs, dir, fw ? fw : "(none)", reset_every,
           (max_windows == (1 << 30)) ? "unlimited" : "set", quiet);
    fflush(stdout);

    unsigned long long deadline = now_ms() + (unsigned long long)secs * 1000ull;
    int iter = 0, windows = 0;

    while (now_ms() < deadline && windows < max_windows) {
        iter++;
        if (!dev) {
            if (reopen() < 0) { usleep(200000); continue; }
        }

        unsigned char b[16];
        int r0 = read_version(b, 16, 0);
        int r4 = (r0 <= 0) ? read_version(b, 16, 1) : 0;

        if (r0 == LIBUSB_ERROR_NO_DEVICE || r4 == LIBUSB_ERROR_NO_DEVICE) {
            libusb_close(dev); dev = NULL;
            continue;
        }

        if (r0 > 0 || r4 > 0) {
            windows++;
            snapshot_window(dir, windows, quiet, do_map);
            fflush(stdout);
            if (!dev) continue;
        }

        if (fw && fw[0] && dev) {
            download_firmware(fw);
        }

        if (reset_every > 0 && (iter % reset_every) == 0) {
            char tb[16]; stamp(tb, sizeof tb);
            printf("[%s] iter %d: USB port reset\n", tb, iter);
            fflush(stdout);
            if (dev) libusb_reset_device(dev);
            if (dev) libusb_close(dev);
            dev = NULL;
            usleep(300000);
            continue;
        }

        if (!quiet && (iter % 25) == 0) {
            char tb[16]; stamp(tb, sizeof tb);
            printf("[%s] iter %d: cold, %d window(s) so far\n", tb, iter, windows);
            fflush(stdout);
        }
        usleep(100000);
    }

    printf("romwin: finished after %d iteration(s), %d window(s), dir=%s\n",
           iter, windows, dir);
    return windows ? 0 : 1;
}

/* =====================================================================
 *  EEPROM-window catcher ("eepromwin")
 *
 *  Caught 2026-10-08 15:53: inside a ROM window the bridge also services
 *  GET_EEPROM (c4 02 01a0) - 2048 reads in a row, zero errors - and that
 *  service then DIES (after the vendor-request-map probe) while GET_VERSION
 *  keeps answering.  So the EEPROM-read window is rarer than the ROM window.
 *  This watches for it and, the instant request 0x02 answers, takes
 *  everything reachable in one burst: the full 256-byte image (with the
 *  measured index = off<<8), the wrap cross-check, the wValue/wIndex form
 *  map (hunting an index wider than 8 bits - the only thing between us and
 *  the rest of the EEPROM) and the I2C address-byte map (which tells us the
 *  EEPROM chip variant / page bits).
 *
 *  Read-only: request 0x02 is a read; nothing here writes the EEPROM.
 * ===================================================================== */
static void eeprom_forms(void)
{
    static const unsigned vals[] = {
        0x01a0, 0x02a0, 0x04a0, 0x08a0, 0x10a0, 0x20a0,
        0x01a1, 0x01a2, 0x01a4, 0x01a6, 0x01a8, 0x01aa, 0x01ac, 0x01ae,
        0x00a0, 0x03a0
    };
    static const unsigned ixs[] = { 0x0000, 0x0100, 0x0008, 0x1000, 0xff00 };
    unsigned char b[8];

    printf("  GET_EEPROM form map (hunting an index wider than 8 bits;\n"
           "    v low byte = I2C address byte, ix high byte = index):\n");
    for (unsigned i = 0; i < sizeof vals / sizeof *vals; i++) {
        for (unsigned j = 0; j < sizeof ixs / sizeof *ixs; j++) {
            int r = eep_raw(1, vals[i], ixs[j], b, 8);
            printf("    v=%04x ix=%04x -> %s", vals[i], ixs[j],
                   r < 0 ? libusb_strerror(r) : "ok");
            if (r > 0) { printf("  "); for (int k = 0; k < r; k++) printf("%02x ", b[k]); }
            printf("\n");
            if (r == LIBUSB_ERROR_NO_DEVICE) return;
        }
    }
    int r = eep_raw(0, EEP_VAL, 0, b, 8);
    printf("    recip0 v=01a0 ix=0000 -> %s", r < 0 ? libusb_strerror(r) : "ok");
    if (r > 0) { printf("  "); for (int k = 0; k < r; k++) printf("%02x ", b[k]); }
    printf("\n");
    fflush(stdout);
}

/* Measured 2026-10-08 18:01, in the same burst that read the image: wValue
 * 0x02a0 is the SAME 8-bit index but with a +1 offset and NO wrap -
 * ix=0x0000 -> byte 1, 0x0100 -> byte 2, 0x1000 -> byte 16, 0xff00 -> byte 256.
 * That is the only way found to look one byte past the 1-byte window, and byte
 * 256 - exactly where an aligned firmware image would have to start - is 0xff
 * (erased).  These forms are valid address bytes, so they do not wedge the
 * engine; the destructive sweep lives in eeprom_forms() and is opt-in. */
static void eeprom_extended(void)
{
    static const unsigned ixs[] = {
        0x0000, 0x0100, 0x0200, 0x1000, 0x2000, 0xfe00, 0xff00
    };
    unsigned char b[8];

    printf("  extended index probe (wValue 0x02a0: same 8-bit index, +1 offset, no wrap;\n"
           "    ix=ff00 therefore reads byte 256, the first byte past the 1-byte window):\n");
    for (unsigned j = 0; j < sizeof ixs / sizeof *ixs; j++) {
        int r = eep_raw(1, 0x02a0, ixs[j], b, 8);
        printf("    v=02a0 ix=%04x -> %s", ixs[j], r < 0 ? libusb_strerror(r) : "ok");
        if (r > 0) { printf("  "); for (int k = 0; k < r; k++) printf("%02x ", b[k]); }
        printf("\n");
        if (r == LIBUSB_ERROR_NO_DEVICE) return;
    }

    /* Is the demod reachable on the same I2C engine right now?  Valid address
     * bytes only (0x80/0x82 = DiB7000P at 0x40). */
    static const unsigned addrs[] = { 0x0180, 0x0182 };
    for (unsigned j = 0; j < sizeof addrs / sizeof *addrs; j++) {
        int r = eep_raw(1, addrs[j], 0, b, 8);
        printf("    I2C-in demod v=%04x -> %s", addrs[j], r < 0 ? libusb_strerror(r) : "ok");
        if (r > 0) { printf("  "); for (int k = 0; k < r; k++) printf("%02x ", b[k]); }
        printf("\n");
        if (r == LIBUSB_ERROR_NO_DEVICE) return;
    }
    fflush(stdout);
}

static void eeprom_grab(const char *dir)
{
    char path[600], tb[16];
    unsigned char b[8], img[256], v[16];
    int off, ok = 0, bad = 0;

    snprintf(path, sizeof path, "%s/eeprom-%ld.bin", dir, (long)time(NULL));
    stamp(tb, sizeof tb);
    printf("\n*** EEPROM WINDOW at %s -> %s ***\n", tb, path);
    fflush(stdout);

    int r0 = read_version(v, 16, 0);
    printf("  GET_VERSION recip0 -> %s", r0 < 0 ? libusb_strerror(r0) : "ok");
    if (r0 == 16)
        printf("  hw=%08x rom=%08x ram=%08x fwtype=%08x",
               BE32(v), BE32(v + 4), BE32(v + 8), BE32(v + 12));
    printf("\n");
    int r4 = read_version(v, 16, 1);
    printf("  GET_VERSION recip4 -> %s", r4 < 0 ? libusb_strerror(r4) : "ok");
    if (r4 == 16)
        printf("  hw=%08x rom=%08x ram=%08x fwtype=%08x",
               BE32(v), BE32(v + 4), BE32(v + 8), BE32(v + 12));
    printf("\n");

    memset(img, 0xdb, sizeof img);
    for (off = 0; off < 256; off += 8) {
        int r = eep_at(off, b);
        if (r == LIBUSB_ERROR_NO_DEVICE) {
            libusb_close(dev); dev = NULL;
            printf("  (device vanished at byte %03x)\n", off);
            break;
        }
        if (r == 8) { ok++; memcpy(img + off, b, 8); }
        else {
            bad++;
            if (bad <= 3) printf("  eep %03x -> %s\n", off, r < 0 ? libusb_strerror(r) : "short");
        }
    }

    FILE *f = fopen(path, "wb");
    if (f) { fwrite(img, 1, sizeof img, f); fclose(f); }
    else perror(path);
    printf("eepromwin: %d/32 window(s) ok, %d bad, %zu bytes -> %s\n",
           ok, bad, sizeof img, path);
    for (off = 0; off < 256; off += 16) {
        printf("  %03x: ", off);
        for (int i = 0; i < 16; i++) printf("%02x ", img[off + i]);
        printf(" |");
        for (int i = 0; i < 16; i++)
            putchar(img[off + i] >= 32 && img[off + i] < 127 ? img[off + i] : '.');
        printf("|\n");
    }

    int rw = eep_at(0xff, b);
    printf("  wrap check @255 -> %s", rw < 0 ? libusb_strerror(rw) : "ok");
    if (rw == 8) { printf("  "); for (int i = 0; i < 8; i++) printf("%02x ", b[i]); }
    printf("\n");
    fflush(stdout);
}

/* usage: eepromwin [secs] [dir] [--fw file] [--no-fw] [--max N] [--quiet] */
static int cmd_eepromwin(int argc, char **argv)
{
    int secs = 1800, max_windows = 1, quiet = 0, do_map = 0;
    const char *dir = NULL, *fw = "firmware/win_fw.bin";
    int positional = 0;

    for (int i = 2; i < argc; i++) {
        if (!strcmp(argv[i], "--fw") && i + 1 < argc)       fw = argv[++i];
        else if (!strcmp(argv[i], "--no-fw"))               fw = NULL;
        else if (!strcmp(argv[i], "--max") && i + 1 < argc) max_windows = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--quiet"))               quiet = 1;
        else if (!strcmp(argv[i], "--map"))                  do_map = 1;
        else if (argv[i][0] != '-') {
            if (positional == 0) { secs = atoi(argv[i]); positional = 1; }
            else if (positional == 1) { dir = argv[i]; positional = 2; }
        }
    }

    char default_dir[256];
    if (!dir) {
        snprintf(default_dir, sizeof default_dir, "logs/eepromwin-%ld", (long)time(NULL));
        dir = default_dir;
    }
    mkdir_p(dir);
    if (max_windows <= 0) max_windows = 1 << 30;

    printf("eepromwin: secs=%d dir=%s fw=%s max_windows=%s quiet=%d map=%d\n",
           secs, dir, fw ? fw : "(none)",
           (max_windows == (1 << 30)) ? "unlimited" : "set", quiet, do_map);
    fflush(stdout);

    unsigned long long deadline = now_ms() + (unsigned long long)secs * 1000ull;
    int iter = 0, windows = 0;

    while (now_ms() < deadline && windows < max_windows) {
        iter++;
        if (!dev) {
            if (reopen() < 0) { usleep(200000); continue; }
        }

        unsigned char b[8];
        int r = eep_at(0, b);           /* the probe: does GET_EEPROM answer? */
        if (r == LIBUSB_ERROR_NO_DEVICE) {
            libusb_close(dev); dev = NULL;
            continue;
        }
        if (r == 8) {
            windows++;
            eeprom_grab(dir);
            /* order matters: the image and the safe extended probes come first,
             * the invalid-address sweep last and only on request - it is what
             * wedges the I2C engine (see the --map note in rom-window.sh). */
            if (dev) eeprom_extended();
            if (dev && do_map) eeprom_forms();
            if (!dev) continue;
            if (windows >= max_windows) break;
        }

        if (fw && fw[0] && dev) download_firmware(fw);

        if (!quiet && (iter % 50) == 0) {
            char tb[16]; stamp(tb, sizeof tb);
            printf("[%s] iter %d: no EEPROM read service, %d window(s) so far\n",
                   tb, iter, windows);
            fflush(stdout);
        }
        usleep(100000);
    }

    printf("eepromwin: finished after %d iteration(s), %d window(s), dir=%s\n",
           iter, windows, dir);
    return windows ? 0 : 1;
}

/* the analog bring-up: clock, i2c speed, the stk7700ph GPIO sequence,
 * REQUEST_ENABLE_VIDEO in ANALOG mode, then capture from a bulk IN endpoint */
static int cmd_analog(int argc, char **argv)
{
    int l525 = (argc > 2 && !strcmp(argv[2], "525")) ? 1 : 0;
    int ep   = (argc > 3) ? strtol(argv[3], 0, 0) : 0x82;
    int n    = (argc > 4) ? atoi(argv[4]) : 4096;
    const char *out = (argc > 5) ? argv[5] : "/tmp/pctv/analog.raw";

    printf("-- GET_VERSION --\n"); cmd_version();
    printf("-- SET_CLOCK 72MHz --\n"); cmd_clock();
    printf("-- SET_I2C_PARAM 100kHz --\n"); cmd_i2cparam(100);

    /* stk7700ph_frontend_attach GPIO sequence (320cx variant: GPIO6 = 0) */
    printf("-- GPIO sequence --\n");
    cmd_gpio(6, 1, 0); usleep(20000);
    cmd_gpio(9, 1, 1);
    cmd_gpio(4, 1, 1);
    cmd_gpio(7, 1, 1);
    cmd_gpio(10, 1, 0); usleep(10000);
    cmd_gpio(10, 1, 1); usleep(20000);
    cmd_gpio(0, 1, 1); usleep(10000);

    printf("-- i2c scan --\n"); cmd_scan_legacy();

    printf("-- ENABLE_VIDEO: streaming on, ANALOG, %s --\n", l525 ? "525 lines" : "625 lines");
    cmd_video(1, 1, l525, 0);

    printf("-- capture from ep 0x%02x --\n", ep);
    return cmd_cap(ep, n, out);
}

/* read the DIB7000P chip id pair (reg 768 = 0x01b3, reg 769 = 0x4000) */
static int demod_id(unsigned char *rx)
{
    int r = ctrl_in(0x02, 0x0281, 0x0300, rx, 2);
    return r;
}

/* One dib7000p-style word read: write the 16-bit register address (no stop),
 * then read 16 bits back. This is exactly dib7000p_read_word(). */
static int read_word_new(int bus, int addr7, int reg, unsigned int *out)
{
    unsigned char w[6] = { RQ_NEW_I2C_WRITE,
                           (unsigned char)(addr7 << 1),
                           (unsigned char)((1 << 7) | (1 << 6) | 2),
                           (unsigned char)((bus << 4) & 0x30),
                           (unsigned char)(reg >> 8), (unsigned char)(reg & 0xff) };
    int r = ctrl_out(w, 6);
    if (r < 0) return r;
    unsigned char rx[2];
    r = i2c_read_new((unsigned char)addr7, rx, 2, bus);
    if (r == 2) { *out = (rx[0] << 8) | rx[1]; return 2; }
    return r < 0 ? r : -1;
}

/* dib7000p_identify(): reg 768 == 0x01b3 (vendor), reg 769 == 0x4000 (device).
 * Mainline tries 8-bit 0x80 (7-bit 0x40) then falls back to default_addr 18
 * (8-bit 0x12 == 7-bit 0x09) - and the Windows driver's dib7000p register
 * writes (1285/1286/1287) all go to 8-bit 0x12. The legacy 0x02/0x03 requests
 * never report a NACK (they return zeros / always "succeed"), so this sweep is
 * the only honest way to find out whether the demod answers, and where. */
static int cmd_identify(int bus)
{
    static const int addrs[] = { 0x40, 0x41, 0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0x0e,
                                 0x10, 0x18, 0x19, 0x30, 0x31, 0x60, 0x61, 0x62,
                                 0x63, 0x70, 0x71 };
    printf("dib7000p identify sweep, bus %d (want 768=01b3 769=4000)\n", bus);
    int hits = 0;
    for (unsigned i = 0; i < sizeof addrs / sizeof *addrs; i++) {
        int a = addrs[i];
        /* dib7000p_i2c_enumeration writes reg 1287 = 0x0003 (sram lead-in, rdy)
         * immediately before identify - replicate it. */
        unsigned char ld[8] = { RQ_NEW_I2C_WRITE, (unsigned char)(a << 1),
                                (unsigned char)((1 << 7) | (1 << 6) | 4),
                                (unsigned char)((bus << 4) & 0x30),
                                0x05, 0x07, 0x00, 0x03 };
        ctrl_out(ld, 8);
        libusb_clear_halt(dev, 0);
        unsigned int v768 = 0xdead, v769 = 0xdead;
        int r1 = read_word_new(bus, a, 768, &v768);
        int r2 = read_word_new(bus, a, 769, &v769);
        printf("  7bit 0x%02x (8-bit 0x%02x): 768=%s 769=%s",
               a, a << 1,
               r1 == 2 ? "" : libusb_strerror(r1 < 0 ? r1 : LIBUSB_ERROR_IO),
               r2 == 2 ? "" : libusb_strerror(r2 < 0 ? r2 : LIBUSB_ERROR_IO));
        if (r1 == 2) printf("  768=%04x", v768);
        if (r2 == 2) printf("  769=%04x", v769);
        if (v768 == 0x01b3) { printf("   <== DiBcom vendor ID: demod answers here!"); hits++; }
        else if (r1 == 2 && (v768 || v769)) printf("   (non-zero - worth a look)");
        printf("\n");
        if (r1 < 0 || r2 < 0) libusb_clear_halt(dev, 0);
    }
    printf("identify: %d address(es) with the DiBcom vendor ID\n", hits);
    return hits ? 0 : 1;
}

/* read one dib7000p word: idrd <bus> <addr7> <reg> */
static int cmd_idrd(int bus, int addr, int reg)
{
    unsigned int v;
    int r = read_word_new(bus, addr, reg, &v);
    if (r == 2) printf("bus%d addr7 0x%02x reg %d (0x%03x) = %04x\n", bus, addr, reg, reg, v);
    else printf("bus%d addr7 0x%02x reg %d: %s\n", bus, addr, reg,
                r < 0 ? libusb_strerror(r) : "short read");
    return r;
}

/* The firmware stalls EP0 when the underlying i2c transaction fails, so a
 * write scan reveals which addresses really ACK (a read scan does not: a
 * failed read just returns zero bytes). */
static int cmd_scanw(void)
{
    int ack = 0;
    printf("i2c write scan (legacy 0x03, one data byte 0x00)\n");
    for (int a = 0x03; a <= 0x77; a++) {
        unsigned char b[3] = { 0x03, (unsigned char)(a << 1), 0x00 };
        int r = libusb_control_transfer(dev, 0x44, 0x03, 0, 0, b, 3, 1500);
        if (r >= 0) { printf("  ACK 0x%02x (8-bit 0x%02x)\n", a, a << 1); ack++; }
        else if (r != LIBUSB_ERROR_TIMEOUT) printf("  --  0x%02x: %s\n", a, libusb_strerror(r));
        else printf("  --  0x%02x: timeout\n", a);
        if (r == LIBUSB_ERROR_PIPE) libusb_clear_halt(dev, 0);
    }
    printf("write scan: %d address(es) ACKed\n", ack);
    return 0;
}

/* replay a Windows analog bring-up sequence captured with usbmon
 * (logs/analog-seq-ordered.txt, produced by extract_analog_seq.py):
 *   wr <addr8-hex> <reg-dec> <val-dec>   16-bit register write
 *   rd <addr8-hex> <reg-dec>             16-bit register read
 * other lines (gpio, SETUP_DEMOD, ...) are skipped - GPIO bring-up is done
 * with the kernel's stk7700ph sequence before calling this. */
static int cmd_regseq(const char *path)
{
    FILE *f = fopen(path, "r");
    if (!f) { perror("open sequence"); return 1; }
    char line[256];
    int nw = 0, nr = 0, nerr = 0;
    while (fgets(line, sizeof line, f)) {
        char op[8] = {0}, sa[16] = {0}, sr[16] = {0}, sv[16] = {0};
        int n = sscanf(line, "%7s %15s %15s %15s", op, sa, sr, sv);
        if (n < 3) continue;
        if (!strcmp(op, "gpio")) {
            /* "gpio 0c <pin> <ctrl>" - ctrl = (dir<<7)|(val<<6), exactly the
             * kernel's REQUEST_SET_GPIO payload. Windows drives pins 0,5,8,10,
             * 14,15 here; the kernel's stk7700ph sequence only uses 6,9,4,7,10,0
             * - the extra pins are very likely decoder reset / AV input select. */
            unsigned char b[3] = { RQ_SET_GPIO,
                                   (unsigned char)strtol(sr, NULL, 16),
                                   (unsigned char)strtol(sv, NULL, 16) };
            int r = ctrl_out(b, 3);
            if (r < 0) printf("  gpio %s %s: %s\n", sa, sr, libusb_strerror(r));
            usleep(20000);
            continue;
        }
        if (n < 3) continue;
        int a   = (int)strtol(sa, NULL, 16);   /* 8-bit i2c address, hex */
        int reg = (int)strtol(sr, NULL, 10);
        int val = n > 3 ? (int)strtol(sv, NULL, 10) : 0;
        if (!strcmp(op, "wr")) {
            unsigned char w[8] = { RQ_NEW_I2C_WRITE, (unsigned char)a,
                                   (unsigned char)((1 << 7) | (1 << 6) | 4), 0x10,
                                   (unsigned char)(reg >> 8), (unsigned char)reg,
                                   (unsigned char)(val >> 8), (unsigned char)val };
            int r = ctrl_out(w, 8);
            if (r < 0) {
                printf("  wr 0x%02x reg %4d = %5d : %s\n", a, reg, val, libusb_strerror(r));
                nerr++; libusb_clear_halt(dev, 0);
            } else nw++;
        } else if (!strcmp(op, "rd")) {
            unsigned int v = 0;
            int r = read_word_new(1, a >> 1, reg, &v);
            printf("  rd 0x%02x reg %4d = %s\n", a, reg,
                   r == 2 ? "" : (r < 0 ? libusb_strerror(r) : "short read"));
            if (r == 2) { printf("      -> %04x (%u)\n", v, v); nr++; }
            else nerr++;
        }
    }
    fclose(f);
    printf("replay: %d write(s), %d read(s), %d error(s)\n", nw, nr, nerr);
    return 0;
}

/* one-shot analog attempt in a single process: bridge bring-up, the kernel's
 * stk7700ph GPIO sequence, the Windows demod register replay, then
 * ENABLE_VIDEO in analog mode and a bulk-IN capture. */
static int cmd_analogseq(const char *seqfile, int ep, int nbytes)
{
    cmd_clock(); cmd_i2cparam(100);
    cmd_gpio(6, 1, 0); usleep(20000);
    cmd_gpio(9, 1, 1); cmd_gpio(4, 1, 1); cmd_gpio(7, 1, 1);
    cmd_gpio(10, 1, 0); usleep(10000);
    cmd_gpio(10, 1, 1); usleep(20000);
    cmd_gpio(0, 1, 1); usleep(10000);
    cmd_regseq(seqfile);

    static const int eps[] = { 0x82, 0x83 };
    /* the Windows driver's analog enable, from the usbmon trace
     * (logs/full-seq.txt: "SETUP_DEMOD data=110100"), plus the variants the
     * kernel's comment implies (bit4 = on, bit0 = analog, byte2 = line std) */
    static const unsigned char pats[][3] = {
        { 0x11, 0x01, 0x00 },   /* exactly what Windows sent */
        { 0x11, 0x00, 0x00 },
        { 0x11, 0x11, 0x00 },
        { 0x10, 0x00, 0x10 },   /* mpeg2 master mode - sanity check */
        { 0x14, 0x00, 0x00 },
        { 0x15, 0x01, 0x00 },
    };
    int e0 = ep ? ep : 0;
    for (int round = 0; round < (e0 ? 1 : 2); round++) {
        int e = e0 ? e0 : eps[round];
        for (unsigned p = 0; p < sizeof pats / sizeof *pats; p++) {
            unsigned char b[4] = { RQ_ENABLE_VIDEO, pats[p][0], pats[p][1], pats[p][2] };
            int r = wr(b, 4);
            printf("ENABLE_VIDEO %02x %02x %02x: %s\n", b[1], b[2], b[3],
                   r < 0 ? libusb_strerror(r) : "ok");
            usleep(150000);
            int got = cmd_cap(e, nbytes, NULL);
            printf("  pattern %02x %02x %02x ep 0x%02x -> %d bytes\n", b[1], b[2], b[3], e, got);
            if (got > 0) return got;
        }
    }
    printf("analogseq: no bulk-IN data\n");
    return 0;
}

/* honest i2c device map: the NEW_I2C_WRITE request stalls EP0 when the target
 * NACKs (verified - 0x80/7bit 0x40 answers, everything else stalls). So a
 * write scan reports the real devices, unlike the legacy 0x02/0x03 requests
 * which never report a NACK. */
static int cmd_scannew(int bus)
{
    printf("NEW_I2C write scan, bus %d (no stall == ACK)\n", bus);
    int found = 0;
    for (int a = 0x03; a <= 0x77; a++) {
        unsigned char w[5] = { RQ_NEW_I2C_WRITE, (unsigned char)(a << 1),
                               (unsigned char)((1 << 7) | (1 << 6) | 1),
                               (unsigned char)((bus << 4) & 0x30), 0x00 };
        int r = ctrl_out(w, 5);
        if (r >= 0) { printf("  ACK at 7bit 0x%02x (8-bit 0x%02x)\n", a, a << 1); found++; }
        else libusb_clear_halt(dev, 0);
    }
    printf("scannew: %d device(s)\n", found);
    return found;
}

/* 1-byte-register access (CX2584x / TVP5150 style): nrd1/nwr1 */
static int cmd_nrd1(int bus, int addr, int reg, int n)
{
    unsigned char w[6] = { RQ_NEW_I2C_WRITE, (unsigned char)(addr << 1),
                           (unsigned char)((1 << 7) | (0 << 6) | 1),
                           (unsigned char)((bus << 4) & 0x30),
                           (unsigned char)reg };
    int r = ctrl_out(w, 5);
    if (r < 0) { printf("nrd1 write: %s\n", libusb_strerror(r)); libusb_clear_halt(dev, 0); return r; }
    unsigned char rx[64];
    r = i2c_read_new((unsigned char)addr, rx, n, bus);
    if (r > 0) hexdump("nrd1", rx, r);
    else printf("nrd1 read: %s\n", r < 0 ? libusb_strerror(r) : "short");
    return r;
}

static int cmd_nwr1(int bus, int addr, int reg, int val)
{
    unsigned char w[6] = { RQ_NEW_I2C_WRITE, (unsigned char)(addr << 1),
                           (unsigned char)((1 << 7) | (1 << 6) | 2),
                           (unsigned char)((bus << 4) & 0x30),
                           (unsigned char)reg, (unsigned char)val };
    int r = ctrl_out(w, 6);
    if (r < 0) libusb_clear_halt(dev, 0);
    return r;
}

/* proper 2-message read: write the register with start+no-stop, then read with
 * no-start+stop - exactly what the kernel's i2c-xfer does for cx25840. */
static int cmd_nrd2(int bus, int addr, int reg, int n)
{
    unsigned char w[5] = { RQ_NEW_I2C_WRITE, (unsigned char)(addr << 1),
                           (unsigned char)((1 << 7) | (0 << 6) | 1),
                           (unsigned char)((bus << 4) & 0x30),
                           (unsigned char)reg };
    int r = ctrl_out(w, 5);
    if (r < 0) { printf("nrd2 write: %s\n", libusb_strerror(r)); libusb_clear_halt(dev, 0); return r; }
    uint16_t value = ((0u << 7) | (1u << 6) | (n & 0x3f)) << 8 | (unsigned char)(addr << 1);
    uint16_t index = ((bus << 4) & 0x30);
    unsigned char rx[64];
    r = ctrl_in(RQ_NEW_I2C_READ, value, index, rx, n);
    if (r > 0) hexdump("nrd2", rx, r);
    else printf("nrd2 read: %s\n", r < 0 ? libusb_strerror(r) : "short");
    return r;
}

/* Devices behind the DIB7000P (tuner, and very likely the CX2584x video
 * decoder) are reached through the demod's i2c gate - dibx000_i2c_gate_ctrl:
 * write demod reg 1025 (base_reg 1024 + 1) = addr7 << 9 to open, = 0x0100 to
 * close. The Windows trace does exactly this ("wr 80 1025 256"). */
static int i2c_gate(int onoff, int addr7)
{
    unsigned int val = onoff ? ((unsigned int)addr7 << 9) : 0x100;
    unsigned char w[8] = { RQ_NEW_I2C_WRITE, 0x80,
                           (unsigned char)((1 << 7) | (1 << 6) | 4), 0x10,
                           0x04, 0x01, (unsigned char)(val >> 8), (unsigned char)val };
    int r = ctrl_out(w, 8);
    if (r < 0) libusb_clear_halt(dev, 0);
    return r;
}

/* gated 1-byte-register read: grd1 <addr7> <reg> [n] */
static int cmd_grd1(int addr, int reg, int n)
{
    if (i2c_gate(1, addr) < 0) printf("  gate open failed\n");
    int r = cmd_nrd2(1, addr, reg, n);
    i2c_gate(0, 0);
    return r;
}

/* gated 1-byte-register write: gwr1 <addr7> <reg> <val> */
static int cmd_gwr1(int addr, int reg, int val)
{
    if (i2c_gate(1, addr) < 0) printf("  gate open failed\n");
    int r = cmd_nwr1(1, addr, reg, val);
    i2c_gate(0, 0);
    return r;
}

/* CX2584x style access: the register address is ALWAYS 16-bit (0x00xx for the
 * 8-bit page, 0x40d/0x804... for the extended pages) - cx25840_read() writes
 * two address bytes then reads one data byte. */
static int cmd_nrd16(int bus, int addr, int reg, int n)
{
    unsigned char w[6] = { RQ_NEW_I2C_WRITE, (unsigned char)(addr << 1),
                           (unsigned char)((1 << 7) | (0 << 6) | 2),
                           (unsigned char)((bus << 4) & 0x30),
                           (unsigned char)(reg >> 8), (unsigned char)reg };
    int r = ctrl_out(w, 6);
    if (r < 0) { printf("nrd16 write: %s\n", libusb_strerror(r)); libusb_clear_halt(dev, 0); return r; }
    uint16_t value = ((0u << 7) | (1u << 6) | (n & 0x3f)) << 8 | (unsigned char)(addr << 1);
    uint16_t index = ((bus << 4) & 0x30);
    unsigned char rx[64];
    r = ctrl_in(RQ_NEW_I2C_READ, value, index, rx, n);
    if (r > 0) hexdump("nrd16", rx, r);
    else printf("nrd16 read: %s\n", r < 0 ? libusb_strerror(r) : "short");
    return r;
}

static int cmd_nwr16(int bus, int addr, int reg, int val)
{
    unsigned char w[7] = { RQ_NEW_I2C_WRITE, (unsigned char)(addr << 1),
                           (unsigned char)((1 << 7) | (1 << 6) | 3),
                           (unsigned char)((bus << 4) & 0x30),
                           (unsigned char)(reg >> 8), (unsigned char)reg,
                           (unsigned char)val };
    int r = ctrl_out(w, 7);
    if (r < 0) libusb_clear_halt(dev, 0);
    return r;
}

static int cmd_gpiosweep(int addr)
{
    unsigned char rx[8];
    cmd_clock(); cmd_i2cparam(100);
    /* baseline: the kernel's stk7700ph sequence for the 320cx */
    cmd_gpio(6, 1, 0); usleep(20000);
    cmd_gpio(9, 1, 1); cmd_gpio(4, 1, 1); cmd_gpio(7, 1, 1);
    cmd_gpio(10, 1, 0); usleep(10000);
    cmd_gpio(10, 1, 1); usleep(20000);
    cmd_gpio(0, 1, 1); usleep(10000);
    int r = demod_id(rx);
    printf("baseline demod id (legacy, 8-bit 0x81) -> %s %02x %02x\n",
           r > 0 ? "read" : libusb_strerror(r),
           r > 0 ? rx[0] : 0, r > 0 ? rx[1] : 0);

    for (int g = 0; g <= 15; g++) {
        for (int v = 1; v >= 0; v--) {
            cmd_gpio(g, 1, v);
            usleep(30000);
            unsigned int w;
            r = read_word_new(1, addr, 768, &w);
            rx[0] = w >> 8; rx[1] = w & 0xff;
            int nz = (r > 0) && (rx[0] || rx[1]);
            printf("  GPIO%-2d = %d  demod768 = %02x %02x%s\n", g, v,
                   r > 0 ? rx[0] : 0xff, r > 0 ? rx[1] : 0xff, nz ? "   <== CHANGED" : "");
        }
    }
    return 0;
}

/* sweep REQUEST_ENABLE_VIDEO byte patterns and look for any bulk-IN data */
static int cmd_videosweep(void)
{
    static const int b1s[] = { 0x10, 0x11, 0x14, 0x15, 0x01, 0x00, 0x12, 0x13 };
    static const int b2s[] = { 0x00, 0x10, 0x01, 0x11, 0x20, 0x30 };
    static const int eps[] = { 0x82, 0x83 };
    unsigned char buf[4096];
    cmd_clock(); cmd_i2cparam(100);
    for (unsigned i = 0; i < sizeof(b1s)/sizeof(*b1s); i++) {
        for (unsigned j = 0; j < sizeof(b2s)/sizeof(*b2s); j++) {
            for (unsigned k = 0; k < sizeof(eps)/sizeof(*eps); k++) {
                unsigned char b[4] = { 0x0f, (unsigned char)b1s[i], (unsigned char)b2s[j], 0 };
                int w = ctrl_out(b, 4);
                if (w < 0) { printf("  0f %02x %02x -> write %s\n", b1s[i], b2s[j], libusb_strerror(w)); continue; }
                int xfer = 0;
                int r = libusb_bulk_transfer(dev, eps[k], buf, sizeof(buf), &xfer, 700);
                if (r == 0 && xfer > 0) {
                    printf("  0f %02x %02x ep %02x -> %d BYTES:", b1s[i], b2s[j], eps[k], xfer);
                    for (int t = 0; t < xfer && t < 32; t++) printf(" %02x", buf[t]);
                    printf("\n");
                }
            }
        }
    }
    printf("videosweep done\n");
    return 0;
}

/* Replay the exact analog bring-up captured from the Windows driver
 * (logs/analog-seq-ordered.txt, produced by extract_ordered.py), then arm the
 * stream and capture.  Windows' Run() failed before it could arm, so the arm
 * command is supplied here instead (default = the payload the Linux kernel
 * driver uses successfully for DVB: 0f 11 00 00 via bmRequestType 0x44).
 *   replay <seqfile> [arm-hex] [ep] [bytes] [outfile]
 * Line forms:  wr <i2c8hex> <regdec> <valdec> | gpio 0c <pin> <val> |
 *              SETUP_DEMOD data=<hex>        | rd ... (skipped)          */
static int cmd_replay(int argc, char **argv)
{
    const char *file = argv[2];
    const char *arm  = argc > 3 ? argv[3] : "0f110000";
    int ep     = argc > 4 ? strtol(argv[4], 0, 0) : 0x82;
    int nbytes = argc > 5 ? atoi(argv[5]) : 200000;
    const char *out = argc > 6 ? argv[6] : "logs/analog-capture.bin";

    FILE *f = fopen(file, "r");
    if (!f) { fprintf(stderr, "open %s failed\n", file); return 1; }

    char line[512];
    int nw = 0, ng = 0, nb = 0, err = 0;
    while (fgets(line, sizeof line, f)) {
        unsigned char b[512];
        int a, reg, val;
        if (!strncmp(line, "bulk ", 5)) {
            const char *h = line + 5;
            int n = 0;
            while (n < (int)sizeof b && h[0] && h[1]) {
                unsigned int x;
                if (sscanf(h, "%2x", &x) != 1) break;
                b[n++] = (unsigned char)x; h += 2;
            }
            int xfer = 0;
            int r = libusb_bulk_transfer(dev, 0x01, b, n, &xfer, 2000);
            if (r < 0) { printf("bulk OUT (%d bytes) -> %s\n", n, libusb_strerror(r)); err++; }
            nb++;
        } else if (sscanf(line, "wr %2x %d %d", &a, &reg, &val) == 3) {
            b[0] = 0x03; b[1] = (unsigned char)a;
            b[2] = (reg >> 8) & 0xff; b[3] = reg & 0xff;
            b[4] = (val >> 8) & 0xff; b[5] = val & 0xff;
            if (ctrl_out(b, 6) < 0) err++;
            nw++;
        } else if (!strncmp(line, "gpio ", 5)) {
            const char *h = line + 5;
            int n = 0;
            while (n < 16 && h[0] && h[1]) {
                unsigned int x;
                if (sscanf(h, "%2x", &x) != 1) break;
                b[n++] = (unsigned char)x; h += 2;
            }
            if (ctrl_out(b, n) < 0) err++;
            ng++;
        } else if (!strncmp(line, "SETUP_DEMOD data=", 17)) {
            const char *h = line + 17;
            int n = 0;
            while (n < 16 && h[0] && h[1]) {
                unsigned int x;
                if (sscanf(h, "%2x", &x) != 1) break;
                b[n++] = (unsigned char)x; h += 2;
            }
            printf("SETUP_DEMOD:");
            for (int i = 0; i < n; i++) printf(" %02x", b[i]);
            printf("\n");
            if (ctrl_out(b, n) < 0) err++;
        }
    }
    fclose(f);
    printf("replayed %d bulk OUT + %d register writes + %d gpio ops (%d errors)\n",
           nb, nw, ng, err);

    /* arm the stream */
    unsigned char ab[16];
    int an = 0;
    while (an < 16 && arm[0] && arm[1]) {
        unsigned int x;
        if (sscanf(arm, "%2x", &x) != 1) break;
        ab[an++] = (unsigned char)x; arm += 2;
    }
    printf("arming with bmRequestType 0x44:");
    for (int i = 0; i < an; i++) printf(" %02x", ab[i]);
    printf("\n");
    if (ctrl_out4(ab, an) < 0) printf("  arm FAILED\n");

    return cmd_cap(ep, nbytes, out);
}

static int analog_setup(int a, int smo, int thresh);
/* reg 1286 output mode (dib7000p_set_output_mode): 0x04c0 = OUTMODE_ANALOG_ADC,
 * 0x0800 = OUTMODE_DIVERSITY, 0x0000 = OUTMODE_HIGH_Z.
 * reg 1287 = sram lead-in / rdy; the Windows trace uses 0x0003 everywhere. */
static int analog_outreg = 0x04c0;
static int analog_mc1287 = 0x0003;

/* Replay the full Windows sequence (firmware + init), then try a list of
 * ENABLE_VIDEO (0x0f) payload variants, polling every bulk IN endpoint after
 * each one, to find the payload that actually starts the analog stream.
 *   armsweep <seqfile> [outfile]                                        */
static int cmd_armsweep(int argc, char **argv)
{
    /* replay first (reuses the same code path via a temp pass) */
    static const char *arms[] = {
        /* derived from dib0700_streaming_ctrl(): buf[0]=0x0f,
         * buf[1]=(onoff<<4), buf[2]=(0x01<<4)|channel_state, buf[3]=0 */
        "0f101100", "0f101000", "0f101300", "0f100100",
        "0f111000", "0f110000", "0f101110", "0f101f00",
    };
    static const int eps[] = { 0x81, 0x82, 0x83 };

    char *fake[] = { "replay", argv[2], (char *)"0f000000", (char *)"0x81", (char *)"0", "/dev/null" };
    cmd_replay(6, fake);   /* firmware + init only (arm payload harmless) */
    analog_setup(0x80, 0x0022, 1792);   /* power + ADC + mux, which Windows never does */

    for (unsigned ai = 0; ai < sizeof arms / sizeof *arms; ai++) {
        unsigned char ab[16]; const char *h = arms[ai]; int an = 0;
        while (an < 16 && h[0] && h[1]) {
            unsigned int x; if (sscanf(h, "%2x", &x) != 1) break;
            ab[an++] = (unsigned char)x; h += 2;
        }
        printf("\n--- arm %s ---\n", arms[ai]);
        for (int recip = 0; recip < 2; recip++) {
            if (recip == 0) { if (ctrl_out(ab, an) < 0) printf("  recip0 rejected\n"); }
            else            { if (ctrl_out4(ab, an) < 0) printf("  recip4 rejected\n"); }
            for (unsigned e = 0; e < sizeof eps / sizeof *eps; e++) {
                unsigned char buf[4096]; int got = 0, tot = 0;
                for (int k = 0; k < 3; k++) {
                    int r = libusb_bulk_transfer(dev, eps[e], buf, sizeof buf, &got, 600);
                    if (r == 0 && got > 0) tot += got;
                }
                if (tot) printf("  ep 0x%02x: %d BYTES\n", eps[e], tot);
            }
        }
    }
    printf("\narmsweep done - no output above an arm line means zero bytes everywhere\n");
    return 0;
}

/* Finish the OUTMODE_ANALOG_ADC path the Windows driver leaves incomplete.
 * Windows sets reg 1286 = 0x0800 (host-bus enable, mode bits 0 = the
 * ANALOG_ADC/DIBTX case) but NEVER writes reg 1288, so the ADC is never
 * routed onto the DIBstream Tx nor the Tx onto the host bus - which is why
 * nothing ever reaches the USB endpoints, in Windows or in Linux.
 *
 * Values are from drivers/media/dvb-frontends/dib7000p.c:
 *   dib7090_cfg_DibTx(20, 5, 10, 0, 0, 0)  -> regs 1615/1603/1605/1606/1608/1609/1610/1612
 *   dib7090_setDibTxMux(ADC_ON_DIBTX)      -> reg 1288 bit 7
 *   dib7090_setHostBusMux(DIBTX_ON_HOSTBUS)-> reg 1288 bit 5
 *   dib7090_enMpegMux(0)                   -> reg 1287 bit 7
 *   set_output_mode tail: reg 235 = 0x22, reg 236 = 1792, reg 1286 = 1<<10
 */
static int demod_wr(int addr8, int reg, int val)
{
    unsigned char b[6] = { 0x03, (unsigned char)addr8,
                           (unsigned char)((reg >> 8) & 0xff), (unsigned char)(reg & 0xff),
                           (unsigned char)((val >> 8) & 0xff), (unsigned char)(val & 0xff) };
    return ctrl_out(b, 6);
}

/* Full demod-side analog path: power up, ADC on, DibTx config, and the
 * ADC -> DIBstream Tx -> host bus mux.  See comments inline. */
static int analog_setup(int a, int smo, int thresh)
{
    /* power up the demod: DIB7000P_POWER_ALL from dib7000p_set_power_mode()
     * (the live chip sat at 774=0x3fff 775=0xffff 776=0x0007 899=0x0003
     *  1280=0x8a00 = everything powered DOWN) */
    printf("power: DIB7000P_POWER_ALL (774/775/776/899 = 0, 1280 = 0)\n");
    demod_wr(a, 774, 0x0000);
    demod_wr(a, 775, 0x0000);
    demod_wr(a, 776, 0x0000);
    demod_wr(a, 899, 0x0000);
    demod_wr(a, 1280, 0x0000);

    /* enable the ADC: DIBX000_VBG_ENABLE + DIBX000_ADC_ON (non-SOC7090 path,
     * version reg 897 = 0x4000).  Live values were 908 = 0x3000 and
     * 909 = 0x007b, i.e. the ADC_OFF patterns (908 bits 12-14, 909 bits 2-5). */
    printf("adc: 908 = 0x0000 (VBG_ENABLE & ADC_ON), 909 = 0x0003\n");
    demod_wr(a, 908, 0x0000);
    demod_wr(a, 909, 0x0003);

    static const struct { int reg, val; } cfg[] = {
        { 1615, 1 }, { 1603, 20 }, { 1605, 5 }, { 1606, 10 },
        { 1608, 0 }, { 1609, 0 }, { 1610, 0 }, { 1612, 0 }, { 1615, 0 },
    };
    printf("DibTx config (ADC_ON_DIBTX recipe)\n");
    for (unsigned i = 0; i < sizeof cfg / sizeof *cfg; i++)
        if (demod_wr(a, cfg[i].reg, cfg[i].val) < 0)
            printf("  reg %d = %d FAILED\n", cfg[i].reg, cfg[i].val);

    printf("mux: reg 1288 = 0x00a0 (ADC_ON_DIBTX | DIBTX_ON_HOSTBUS)\n");
    if (demod_wr(a, 1288, 0x00a0) < 0) printf("  1288 FAILED\n");
    /* Output mode, per dib7000p_set_output_mode() in the kernel:
     *   OUTMODE_ANALOG_ADC   reg 1286 = (1<<10)|(3<<6) = 0x04c0  <-- the ADC path
     *   OUTMODE_DIVERSITY    reg 1286 = (1<<11)        = 0x0800  (what we used
     *                        to write - that is the diversity pin, not the
     *                        host bus; it is also what the Windows driver
     *                        writes at 0x12 during i2c enumeration only)
     *   OUTMODE_HIGH_Z       reg 1286 = 0 (the Windows value at 0x80)
     * reg 235 = smo_mode = (rd(235)&0x50) | (1<<1) [| (1<<5) if 188-byte] = 0x22
     * reg 236 = fifo_threshold = 1792 (0x700)  - both confirmed by the trace. */
    printf("reg 1287 = 0x%04x, 235 = 0x%x, 236 = %d, 1286 = 0x%04x\n",
           analog_mc1287, smo, thresh, analog_outreg);
    demod_wr(a, 1287, analog_mc1287);
    demod_wr(a, 235, smo);
    demod_wr(a, 236, thresh);
    demod_wr(a, 1286, analog_outreg);
    return 0;
}

/* ---- analog2: everything in one process, no bind/unbind race ---- */
static int cxg_r(int reg, int *out)
{
    i2c_gate(1, 0x44);
    unsigned char w[6] = { RQ_NEW_I2C_WRITE, 0x88,
                           (unsigned char)((1 << 7) | (0 << 6) | 2), 0x10,
                           (unsigned char)(reg >> 8), (unsigned char)reg };
    int r = ctrl_out(w, 6);
    if (r < 0) { i2c_gate(0, 0); return r; }
    unsigned char rx[8];
    uint16_t value = (uint16_t)((((0u << 7) | (1u << 6) | 1) << 8) | 0x88);
    r = ctrl_in(RQ_NEW_I2C_READ, value, 0x10, rx, 1);
    i2c_gate(0, 0);
    if (r > 0 && out) *out = rx[0];
    return r;
}
static int cxg_w(int reg, int val)
{
    i2c_gate(1, 0x44);
    int r = cmd_nwr16(1, 0x44, reg, val);
    i2c_gate(0, 0);
    return r;
}
static int cxg_or(int reg, int mask, int val)
{
    int v = 0;
    if (cxg_r(reg, &v) < 0) return -1;
    return cxg_w(reg, (v & mask) | val);
}

/* burst i2c write to the CX25843 (2-byte sub-address + n data bytes) */
static int cx_burst(int reg, const unsigned char *data, int n)
{
    unsigned char w[4 + 2 + 64];
    int len = n + 2;
    if (len + 4 > (int)sizeof(w)) return -1;
    w[0] = RQ_NEW_I2C_WRITE; w[1] = 0x88;
    w[2] = (unsigned char)((1 << 7) | (1 << 6) | len);
    w[3] = 0x10;
    w[4] = (unsigned char)(reg >> 8); w[5] = (unsigned char)reg;
    memcpy(w + 6, data, n);
    i2c_gate(1, 0x44);
    int r = ctrl_out(w, len + 4);
    i2c_gate(0, 0);
    if (r < 0) printf("cx_burst reg %03x len %d: %s\n", reg, len, libusb_strerror(r));
    return r;
}

/* cx25840_initialize() + cx25840_loadfw(), over the raw tunnel */
static int cx_init(const char *fwpath)
{
    int v = 0;
    if (cxg_r(0x803, &v) > 0) cxg_w(0x803, v & ~0x10);   /* halt MCU */
    cxg_w(0x000, 0x04);
    cxg_w(0x159, 0x23); cxg_w(0x15a, 0x87); cxg_w(0x15b, 0x06); usleep(10);
    cxg_w(0x159, 0xe1); usleep(10); cxg_w(0x15a, 0x86); cxg_w(0x159, 0xe0);
    cxg_w(0x159, 0xe1); cxg_w(0x15b, 0x10);
    cxg_w(0x15d, 0xe3); cxg_w(0x15e, 0x86); cxg_w(0x15f, 0x06); usleep(10);
    cxg_w(0x15d, 0xe1); cxg_w(0x15d, 0xe0); cxg_w(0x15d, 0xe1);
    cxg_w(0x136, 0x0a); cxg_w(0x13c, 0x01); cxg_w(0x13c, 0x00);

    FILE *f = fopen(fwpath, "rb");
    if (f) {
        fseek(f, 0, SEEK_END); long size = ftell(f); fseek(f, 0, SEEK_SET);
        unsigned char *fw = malloc(size);
        if (fw && fread(fw, 1, size, f) == (size_t)size) {
            cxg_w(0x800, 0); cxg_w(0x801, 0); cxg_w(0x803, 0x0b); cxg_w(0x000, 0x20);
            long off = 0; int bad = 0;
            while (off < size) {
                int len = (int)(size - off); if (len > 46) len = 46;
                if (cx_burst(0x802, fw + off, len) < 0) { bad = (int)off; break; }
                off += len;
            }
            cxg_w(0x000, 0); cxg_w(0x803, 0x03);
            int hi = 0, lo = 0;
            cxg_r(0x801, &hi); cxg_r(0x800, &lo);
            printf("firmware: counter %d / %ld -> %s%s\n", (hi << 8) | lo, size,
                   ((hi << 8) | lo) == size ? "OK" : "FAILED",
                   bad ? " (stalled at offset " : "");
            if (bad) printf("%d)\n", bad);
        }
        free(fw); fclose(f);
    } else printf("firmware: cannot open %s\n", fwpath);

    cxg_w(0x115, 0x8c); cxg_w(0x116, 0x07); cxg_w(0x118, 0x02);
    cxg_w(0x4a5, 0x80); cxg_w(0x4a5, 0x00); cxg_w(0x402, 0x00);
    cxg_or(0x401, ~0x18, 0);
    cxg_or(0x4a2, ~0x10, 0x10);
    cxg_w(0x8d3, 0x1f); cxg_w(0x8e3, 0x03);
    cxg_w(0x914, 0xa0); cxg_w(0x918, 0xa0); cxg_w(0x919, 0x01);
    cxg_w(0x809, 0x04); cxg_w(0x8cf, 0x0f);
    cxg_or(0x803, ~0x10, 0x10);            /* start microcontroller */
    int mc = 0; cxg_r(0x803, &mc);
    printf("cx25843 initialized: 0x803=%02x (bit4 = MCU running)\n", mc);
    return 0;
}

/* read/write CX25843 through the demod i2c gate with 2-byte register
 * addressing (the form cxdump/cx_init use and the one that actually works) */
static int cmd_cxr(int argc, char **argv)
{
    if (argc < 3) return 2;
    int reg0 = (int)strtol(argv[2], 0, 0);
    int n = argc > 3 ? atoi(argv[3]) : 1;
    for (int i = 0; i < n; i++) {
        int v = 0;
        int r = cxg_r(reg0 + i, &v);
        if (r > 0) printf("cx %03x = %02x\n", reg0 + i, v);
        else printf("cx %03x = ERR\n", reg0 + i);
    }
    return 0;
}

static int cmd_cxw(int argc, char **argv)
{
    if (argc < 4) return 2;
    int reg = (int)strtol(argv[2], 0, 0), val = (int)strtol(argv[3], 0, 0);
    cxg_w(reg, val);
    int v = 0;
    int r = cxg_r(reg, &v);
    printf("cx %03x: wrote %02x read %s%02x\n", reg, val, r > 0 ? "" : "ERR ", v);
    return 0;
}

/* read-only dump of the chip state left by another driver (no writes at all) */
static int cmd_cxdump(int argc, char **argv)
{
    static const int cxregs[] = {
        0x100, 0x101, 0x115, 0x116, 0x118, 0x144, 0x145, 0x146, 0x147,
        0x160, 0x164, 0x103, 0x401, 0x402, 0x404, 0x405, 0x406,
        0x40c, 0x40d, 0x40e, 0x470, 0x471, 0x472, 0x473, 0x474, 0x475,
        0x476, 0x477, 0x47a, 0x47b, 0x47c, 0x47d, 0x47e, 0x47f,
        0x49f, 0x4a2, 0x4a5, 0x803, 0x809, 0x8cf, 0x8d3, 0x8e3, 0x914, 0x918, 0x919, 0
    };
    printf("CX25843 (read-only):\n");
    char hex[16];
    for (int i = 0; cxregs[i]; i++) {
        int v = 0;
        int r = cxg_r(cxregs[i], &v);
        if (r > 0) { snprintf(hex, sizeof hex, "%02x", v); printf("  0x%03x = %s\n", cxregs[i], hex); }
        else printf("  0x%03x = ERR\n", cxregs[i]);
    }
    printf("demod (read-only):\n");
    static const int dregs[] = { 36, 90, 91, 235, 236, 237, 774, 775, 776, 899, 1280, 1285, 1286, 1287, 0 };
    for (int i = 0; dregs[i]; i++) {
        unsigned int v = 0;
        int r = read_word_new(1, 0x40, dregs[i], &v);
        if (r > 0) { snprintf(hex, sizeof hex, "%04x", v); printf("  reg %-5d = %s\n", dregs[i], hex); }
        else printf("  reg %-5d = ERR\n", dregs[i]);
    }
    return 0;
}

static int analog2_bringup(const char *inp, int ntsc, const char *arm,
                           int r1286, const char *fwpath, const char *gspec)
{
    /* board init: the kernel's stk7700ph sequence for the 320cx */
    cmd_clock(); cmd_i2cparam(100);
    cmd_gpio(6, 1, 0); usleep(20000);
    cmd_gpio(9, 1, 1); cmd_gpio(4, 1, 1); cmd_gpio(7, 1, 1);
    cmd_gpio(10, 1, 0); usleep(10000); cmd_gpio(10, 1, 1); usleep(20000);
    cmd_gpio(0, 1, 1); usleep(10000);

    /* extra GPIOs (the ones mainline never drives) applied after board init */
    if (gspec) {
        const char *p = gspec;
        while (*p) {
            int pin = 0, val = 0;
            if (sscanf(p, "%d:%d", &pin, &val) == 2) {
                cmd_gpio(pin, 1, val); usleep(30000);
                printf("extra gpio %d = %d\n", pin, val);
            }
            const char *q = strchr(p, ',');
            p = q ? q + 1 : p + strlen(p);
        }
    }

    unsigned char id[4] = {0};
    if (demod_id(id) > 0) printf("demod id: %02x %02x (want 01 b3)\n", id[0], id[1]);
    else printf("demod id: NO REPLY\n");
    if (getenv("PCTV_DRESET")) cmd_demodreset();

    int d0 = 0, d1 = 0, mcu = 0;
    cxg_r(0x100, &d0); cxg_r(0x101, &d1);
    printf("cx25843 id: 0x100=%02x 0x101=%02x (want 34 84)\n", d0, d1);
    cxg_r(0x803, &mcu);
    printf("cx25843 0x803=%02x (bit4 = MCU/firmware running)\n", mcu);
    if (!(mcu & 0x10) || d0 != 0x34) cx_init(fwpath);

    /* input mux */
    int vid, comp = 1;
    if (!strncmp(inp, "composite", 9)) vid = atoi(inp + 9);
    else { static const int map[5] = {0, 0x510, 0x620, 0x730, 0x840};
           vid = map[atoi(inp + 6) > 0 && atoi(inp + 6) <= 4 ? atoi(inp + 6) : 1]; }
    int reg;
    if (vid >= 1 && vid <= 8) reg = 0xf0 + (vid - 1);
    else {
        int luma = vid & 0xf0, chroma = vid & 0xf00;
        comp = 0;
        reg = 0xf0 + ((luma - 0x10) >> 4);
        if (chroma >= 0x700) { reg &= 0x3f; reg |= (chroma - 0x700) >> 2; }
        else                 { reg &= 0xcf; reg |= (chroma - 0x400) >> 4; }
    }
    cxg_w(0x103, reg);
    cxg_or(0x401, ~0x6, comp ? 0x00 : 0x02);
    printf("input %s: mux 0x103=%02x INPUT_MODE=%s\n", inp, reg, comp ? "composite" : "s-video");

    /* std_setup (kernel-faithful) */
    int hblank, hactive, burst, vblank, vactive, vblank656, sc, comb, luma_lpf, uv_lpf;
    cxg_w(0x49f, ntsc ? 0x14 : 0x11);
    if (!ntsc) { hblank = 132; hactive = 720; burst = 93; vblank = 36; vactive = 580;
                 vblank656 = 40; sc = 688739; comb = 0x20; luma_lpf = 2; uv_lpf = 1; }
    else       { hblank = 122; hactive = 720; vactive = 487; luma_lpf = 1; uv_lpf = 1;
                 vblank = 26; vblank656 = 26; burst = 0x5b; comb = 0x66; sc = 556063; }
    cxg_w(0x470, hblank);
    cxg_w(0x471, (((hblank >> 8) & 0x3) | (hactive << 4)) & 0xff);
    cxg_w(0x472, hactive >> 4);
    cxg_w(0x473, burst);
    cxg_w(0x474, vblank);
    cxg_w(0x475, (((vblank >> 8) & 0x3) | (vactive << 4)) & 0xff);
    cxg_w(0x476, vactive >> 4);
    cxg_w(0x477, vblank656);
    cxg_w(0x478, 0x21f & 0xff);
    cxg_w(0x479, (0x21f >> 8) & 0xff);
    cxg_w(0x47a, luma_lpf << 6 | ((uv_lpf << 4) & 0x30));
    cxg_w(0x47b, comb);
    cxg_w(0x47c, sc);
    cxg_w(0x47d, (sc >> 8) & 0xff);
    cxg_w(0x47e, (sc >> 16) & 0xff);
    cxg_w(0x47f, ntsc ? 0x00 : 0x01);

    int v = 0, v2 = 0;
    if (getenv("PCTV_NOSTREAM")) {
        /* control experiment: actively disable the decoder's parallel output */
        if (cxg_r(0x115, &v) > 0) cxg_w(0x115, v & ~0x0c);
        if (cxg_r(0x116, &v2) > 0) cxg_w(0x116, v2 & ~0x04);
        printf("PCTV_NOSTREAM: decoder parallel output DISABLED (0x115=%02x 0x116=%02x)\n",
               v & ~0x0c, v2 & ~0x04);
    } else {
        if (cxg_r(0x115, &v) > 0) cxg_w(0x115, v | 0x0c);
        if (cxg_r(0x116, &v) > 0) cxg_w(0x116, v | 0x04);
    }

    /* poll for a real lock */
    int fd = 0, fe = 0;
    for (int i = 0; i < 16; i++) {
        usleep(500000);
        cxg_r(0x40d, &fd); cxg_r(0x40e, &fe);
        if (fe & 0x20) break;
    }
    printf("decoder: 0x40d=%02x 0x40e=%02x -> %s\n", fd, fe,
           (fe & 0x20) ? "SIGNAL PRESENT" : "no signal");

    /* demod: release the parallel bus, keep the FIFO path configured */
    int r235 = 0x0022, r236 = 1792;
    { const char *e; if ((e = getenv("PCTV_236"))) r236 = strtol(e, 0, 0); }
    {
        const char *e;
        if ((e = getenv("PCTV_235"))) r235 = strtol(e, 0, 0);
        if ((e = getenv("PCTV_236"))) r236 = strtol(e, 0, 0);
    }
    demod_wr(0x80, 1286, r1286);
    demod_wr(0x80, 1287, 0x0003);
    demod_wr(0x80, 235, r235);
    demod_wr(0x80, 236, r236);
    if (getenv("PCTV_DIV")) {
        int d207 = 0x0005, d204 = 6, d205 = 16;
        { const char *e; if ((e = getenv("PCTV_DIV207"))) d207 = strtol(e, 0, 0);
                        if ((e = getenv("PCTV_DIV204"))) d204 = strtol(e, 0, 0);
                        if ((e = getenv("PCTV_DIV205"))) d205 = strtol(e, 0, 0); }
        demod_wr(0x80, 207, d207);
        demod_wr(0x80, 204, d204);
        demod_wr(0x80, 205, d205);
        printf("diversity IN: 207=%04x 204=%d 205=%d\n", d207, d204, d205);
    }
    unsigned int w1286 = 0, w235 = 0;
    read_word_new(1, 0x40, 1286, &w1286);
    read_word_new(1, 0x40, 235, &w235);
    printf("demod 1286 wrote %04x read %04x | 235 wrote %04x read %04x\n",
           r1286, w1286, r235, w235);

    unsigned char ab[16]; const char *h = arm; int an = 0;
    while (an < 16 && h[0] && h[1]) {
        unsigned int x; if (sscanf(h, "%2x", &x) != 1) break;
        ab[an++] = (unsigned char)x; h += 2;
    }
    printf("arm:"); for (int i = 0; i < an; i++) printf(" %02x", ab[i]); printf("\n");
    int ar = ctrl_out(ab, an);
    printf("  arm -> %s\n", ar < 0 ? libusb_strerror(ar) : "ok");
    { const char *e = getenv("PCTV_ARMDELAY");
      if (e) { int ms = atoi(e); printf("arm delay %d ms\n", ms); usleep(ms * 1000); } }

    return 0;
}

static int cmd_analog2(int argc, char **argv)
{
    const char *inp = argc > 2 ? argv[2] : "composite1";
    int ntsc = argc > 3 && !strcmp(argv[3], "ntsc");
    const char *arm = argc > 4 ? argv[4] : "0f101100";
    int ep     = argc > 5 ? strtol(argv[5], 0, 0) : 0x82;
    int nbytes = argc > 6 ? atoi(argv[6]) : 1000000;
    const char *out = argc > 7 ? argv[7] : "/tmp/analog2.bin";
    int r1286 = argc > 8 ? strtol(argv[8], 0, 0) : 0x0000;
    const char *fwpath = argc > 9 ? argv[9] : "/tmp/v4l-cx25840.fw";
    const char *gspec = argc > 10 ? argv[10] : NULL;

    int rc = analog2_bringup(inp, ntsc, arm, r1286, fwpath, gspec);
    if (rc) return rc;
    return cmd_cap(ep, nbytes, out);
}

/* ---- continuous userspace streaming -------------------------------
 * The "userspace driver": the same bring-up as analog2, then raw BT.656
 * from the bulk-IN endpoint to stdout until SIGINT/SIGTERM.  Consumers
 * (pctv-monitor, mpv, ...) parse the BT.656 sync words themselves.
 *
 * Stdout is best-effort and non-blocking from the libusb callback: if the
 * consumer stalls we drop that chunk rather than stalling the USB event loop
 * (the parser resyncs on the next SAV, so a dropped chunk costs at most a
 * few lines, never a wedged stream).  Bring-up diagnostics go to stderr.
 */
static volatile sig_atomic_t stream_stop;
static int stream_inflight;
static void stream_on_sig(int sig) { (void)sig; stream_stop = 1; }

static void stream_cb(struct libusb_transfer *t)
{
    if (t->status == LIBUSB_TRANSFER_COMPLETED && t->actual_length > 0) {
        ssize_t off = 0;
        int len = t->actual_length;
        while (off < len) {
            ssize_t w = write(STDOUT_FILENO, t->buffer + off, len - off);
            if (w < 0) {
                if (errno == EINTR) continue;
                break;   /* EAGAIN/EPIPE: drop the rest of this chunk */
            }
            off += w;
        }
    }
    if (!stream_stop) {
        if (libusb_submit_transfer(t) < 0) stream_stop = 1;
    } else {
        stream_inflight--;
    }
}

/* Is the DiB0700 bridge microcontroller running 1.2.0 firmware? */
static unsigned bridge_ram(void)
{
    unsigned char b[16];
    if (ctrl_in(RQ_GET_VERSION, 0, 0, b, 16) < 16) return 0;
    return (b[8] << 24) | (b[9] << 16) | (b[10] << 8) | b[11];
}

static int cmd_stream(int argc, char **argv)
{
    const char *inp    = argc > 2 ? argv[2] : "composite1";
    int ntsc           = argc > 3 && !strcmp(argv[3], "ntsc");
    const char *fwpath = argc > 4 ? argv[4] :
        (getenv("PCTV_DECODER_FW") ? getenv("PCTV_DECODER_FW")
                                    : "/tmp/pctv-fw/v4l-cx25840.fw");
    int ep             = argc > 5 ? strtol(argv[5], 0, 0) : 0x82;
    const char *gspec  = getenv("PCTV_GPIO");

    /* Keep stdout pure BT.656: bounce the bring-up chatter to stderr. */
    int saved_out = dup(STDOUT_FILENO);
    dup2(STDERR_FILENO, STDOUT_FILENO);

    if (bridge_ram() != 0x00010200) {
        const char *bfw = getenv("PCTV_BRIDGE_FW");
        if (!bfw) bfw = "firmware/dvb-usb-dib0700-1.20.fw";
        fprintf(stderr, "stream: bridge not running -> downloading %s\n", bfw);
        if (download_firmware(bfw) == 0) {
            unsigned ram = bridge_ram();
            fprintf(stderr, "stream: after download ram=0x%08x -> %s\n", ram,
                    ram == 0x00010200 ? "RUNNING" : "still cold/ROM-idle");
        } else {
            fprintf(stderr, "stream: bridge firmware download failed\n");
        }
    } else {
        fprintf(stderr, "stream: bridge firmware already running\n");
    }

    if (analog2_bringup(inp, ntsc, "0f000000", 0x0000, fwpath, gspec) < 0) {
        dup2(saved_out, STDOUT_FILENO);
        close(saved_out);
        return -1;
    }

    /* The mode-2 arm is only accepted after an off->on transition (arming it
     * straight out of bring-up STALLs with a pipe error and the bridge then
     * emits non-BT.656 garbage).  This mirrors the proven capture-live.sh
     * sequence: bring up with video off, then arm mode 2. */
    usleep(150000);
    {
        unsigned char arm2[4] = { 0x0f, 0x12, 0x01, 0x00 };
        int ok = 0;
        for (int i = 0; i < 8 && !ok; i++) {
            if (ctrl_out(arm2, 4) >= 0) ok = 1;
            else usleep(200000);
        }
        if (!ok) fprintf(stderr, "stream: WARNING: mode-2 arm kept failing\n");
    }
    /* Prime: discard a little so the stream starts on a clean line boundary. */
    {
        unsigned char *p = malloc(65536);
        int got = 0;
        for (int i = 0; i < 24; i++)
            if (libusb_bulk_transfer(dev, ep, p, 65536, &got, 500) < 0) break;
        free(p);
    }

    dup2(saved_out, STDOUT_FILENO);
    close(saved_out);
    int fl = fcntl(STDOUT_FILENO, F_GETFL, 0);
    if (fl >= 0) fcntl(STDOUT_FILENO, F_SETFL, fl | O_NONBLOCK);
    signal(SIGINT, stream_on_sig);
    signal(SIGTERM, stream_on_sig);
    signal(SIGPIPE, SIG_IGN);

    const char *eu = getenv("PCTV_URB");
    int bufsz = eu ? atoi(eu) : ACAP_BUFSZ;
    if (bufsz < 512) bufsz = 512;
    struct libusb_transfer *tr[ACAP_URBS];
    unsigned char *buf[ACAP_URBS];
    for (int i = 0; i < ACAP_URBS; i++) {
        buf[i] = malloc(bufsz);
        tr[i] = libusb_alloc_transfer(0);
        libusb_fill_bulk_transfer(tr[i], dev, ep, buf[i], bufsz, stream_cb, NULL, 1000);
        if (libusb_submit_transfer(tr[i]) == 0) stream_inflight++;
    }
    fprintf(stderr, "stream: ep 0x%02x, %d URBs x %d B -> stdout (Ctrl-C to stop)\n",
            ep, ACAP_URBS, bufsz);

    while (!stream_stop && stream_inflight > 0) {
        struct timeval tv = { 0, 100000 };
        libusb_handle_events_timeout_completed(NULL, &tv, NULL);
    }
    stream_stop = 1;
    for (int i = 0; i < ACAP_URBS; i++) libusb_cancel_transfer(tr[i]);
    for (int t = 0; t < 100 && stream_inflight > 0; t++) {
        struct timeval tv = { 0, 50000 };
        libusb_handle_events_timeout_completed(NULL, &tv, NULL);
    }
    for (int i = 0; i < ACAP_URBS; i++) { libusb_free_transfer(tr[i]); free(buf[i]); }
    fprintf(stderr, "stream: stopped\n");
    return 0;
}

static int cmd_analogout(int argc, char **argv)
{
    const char *arm  = argc > 2 ? argv[2] : "0f110000";
    int ep     = argc > 3 ? strtol(argv[3], 0, 0) : 0x82;
    int nbytes = argc > 4 ? atoi(argv[4]) : 200000;
    const char *out = argc > 5 ? argv[5] : "logs/analog-capture3.bin";
    int a = argc > 6 ? strtol(argv[6], 0, 0) : 0x80;   /* demod i2c 8-bit addr */

    if (argc > 7) analog_outreg  = strtol(argv[7], 0, 0);
    if (argc > 8) analog_mc1287  = strtol(argv[8], 0, 0);
    analog_setup(a, argc > 9  ? strtol(argv[9], 0, 0)  : 0x0022,
                    argc > 10 ? strtol(argv[10], 0, 0) : 1792);

    unsigned char ab[16]; const char *h = arm; int an = 0;
    while (an < 16 && h[0] && h[1]) {
        unsigned int x; if (sscanf(h, "%2x", &x) != 1) break;
        ab[an++] = (unsigned char)x; h += 2;
    }
    printf("arm:"); for (int i = 0; i < an; i++) printf(" %02x", ab[i]); printf("\n");
    if (ctrl_out(ab, an) < 0) printf("  recip0 arm rejected\n");
    if (ctrl_out4(ab, an) < 0) printf("  recip4 arm rejected\n");

    return cmd_cap(ep, nbytes, out);
}

static void usage(const char *p)
{
    printf(
"usage: %s <command> [args]\n"
"  ver                     GET_VERSION (cold/warm test)\n"
"  fw <file>               download dib0700 firmware + jumpram\n"
"  clock                   SET_CLOCK 72MHz\n"
"  i2cparam <kHz>          SET_I2C_PARAM\n"
"  scan [bus]              i2c bus scan (bus 0=eeprom 1=frontend, default 1)\n"
"  rd <bus> <addr> <reg>   i2c read  (addr = 7-bit)\n"
"  wr <bus> <addr> <reg> <val>\n"
"  gpio <n> <dir> <val>\n"
"  getgpio\n"
"  video <on|off> <mpeg|analog> [525|625] [xferlen]\n"
"  xferlen <n>\n"
"  cap <ep> <bytes> [file]\n"
"  adapt <0x17|0x18|0x19>\n"
"  demod <rq>\n"
"  lscan                 legacy (0x0f) i2c bus scan\n"
"  lrd <addr> <reg> <len> legacy i2c read\n"
"  lwr <addr> <reg> <val> legacy i2c write\n"
"  raw in <rq> <value> <index> <len>\n"
"  raw out <rq> <b1> <b2> ...\n"
"  bulkout <b1> <b2> ...\n"
"  watch <secs>          log the first GET_VERSION after a power cycle\n"
"  init [fwfile]         full cold bring-up + i2c scan\n"
"  fw2 <file>            download with per-record ACK read\n"
"  i2c2 <api> <bus> <addr> <reghi> <reglo> <n>\n"
"  i2c2w <api> <bus> <addr> <reghi> <reglo> <val>\n"
"  raw4 in <rq> <value> <index> <len>   (bmRequestType 0xC4)\n"
"  raw4 out <rq> <b1> <b2> ...          (bmRequestType 0x44)\n"
"  scan3                 i2c scan with register phase (the form that works)\n"
"  rd1 <addr> <reg> <n>  1-byte-register read\n"
"  rd2 <addr> <hi> <lo> <n>  2-byte-register read (CX2584x)\n"
"  wr1 <addr> <reg> <val>\n"
"  scanw                 i2c scan by WRITE (reveals real ACKs)\n"
"  gpiosweep [addr7]     toggle every GPIO and watch the demod chip id (default addr 0x09)\n"
"  grd1/gwr1 <addr7> <reg> [n|val]  cx2584x access through the demod i2c gate\n"
"  cxr <reg> [n]         read n CX25843 regs (2-byte addr, gated)\n"
"  cxw <reg> <val>       write one CX25843 reg (2-byte addr, gated)\n"
"  scannew [bus]         NEW_I2C write scan - stalls mean NACK, this is the real map\n"
"  nrd1/nwr1 <bus> <addr7> <reg> [n|val]  1-byte-register access (cx2584x/tvp5150)\n"
"  regseq [file]        replay the Windows analog register sequence\n"
"  analogseq [file] [ep] [n]  bring-up + regseq + analog streaming + bulk-IN read\n"
"  identify [bus]        sweep i2c addrs for the DiBcom vendor ID (reg 768 = 01b3)\n"
"  idrd <bus> <addr7> <reg>  read one dib7000p word (16-bit reg, 16-bit value)\n"
"  analog2 <input> <pal|ntsc> [arm] [ep] [bytes] [file] [r1286]  one-process decoder+bridge capture\n"
"  stream <input> [pal|ntsc] [fw] [ep]    bring up + stream raw BT.656 to stdout (userspace driver)\n"
"  dwr <reg> <val> [addr8]   write one dib7000p word + read it back (default addr 0x80)\n"
"  videosweep            sweep ENABLE_VIDEO and watch EP2/EP3 for data\n"
"  analog [525|625] [ep] [bytes] [file]  full analog bring-up + capture\n"
"  eeprom                dump the DiB0700 EEPROM via c4 02 01a0\n"
"  eepromdump [max] [file] config EEPROM read, correct index (off<<8), max 256 B\n"
"  romwin [secs] [dir] [--fw file] [--no-fw] [--reset-every N] [--max N] [--map] [--quiet]\n"
"                        catch the fleeting ROM-bootloader window and dump EEPROM+state\n"
"  eepromwin [secs] [dir] [--fw file] [--no-fw] [--max N] [--quiet]\n"
"                        watch for the (rarer) GET_EEPROM read service and grab the\n"
"                        whole 256 B image + index-form map the moment it answers\n"
"  probeall [from] [to]  scan all vendor requests (IN, recipient 0)\n"
"  probe4    [from] [to] scan all vendor requests (IN, recipient 4)\n"
"  probeout4 [from] [to] scan all vendor requests (OUT, recipient 4)\n"
"  analogout [arm-hex] [ep] [bytes] [file] [i2caddr] [r1286] [r1287] [r235] [r236]\n"
"                        complete the ANALOG_ADC mux + arm + capture\n"
"                        (defaults: i2c 0x80, 1286=0x04c0 OUTMODE_ANALOG_ADC,\n"
"                         1287=0x0003, 235=0x22, 236=1792)\n"
"  armsweep <seqfile>      replay full sequence then sweep ENABLE_VIDEO payloads\n"
"  replay <seqfile> [arm-hex] [ep] [bytes] [file]  replay Windows analog init + arm + capture\n"
"  reset\n"
"  cap2 <ep> <secs> [file]  timed capture, reports B/s\n"
"  cap3 <ep> <secs> [file]  async (multi-URB) capture, reports B/s\n"
"  arm <hexpayload>         e.g. arm 0f100100 (ENABLE_VIDEO, slave)\n"
"  pwron <all|off>          dib7000p_set_power_mode mirror (774/775/776/899/1280)\n"
"  demodreset               dib7000p_demod_reset() mirror\n"
"  diversity <on|off> [1286]  external parallel TS input -> host bus\n"
"  dibrx <Kin> <Kout> [syncmode] [insync] [syncword] [syncsize] [outrate]\n"
"                        configure the DIB7000P DibStream RECEIVER (1536-1554)\n", p);
}

int main(int argc, char **argv)
{
    int r;
    setvbuf(stdout, NULL, _IOLBF, 0);
    if (argc < 2) { usage(argv[0]); return 2; }

    r = libusb_init(NULL);
    if (r < 0) { fprintf(stderr, "libusb_init: %s\n", libusb_strerror(r)); return 1; }

    dev = libusb_open_device_with_vid_pid(NULL, VID, PID);
    if (!dev && strcmp(argv[1], "romwin") && strcmp(argv[1], "eepromwin")) {
        fprintf(stderr,
            "device %04x:%04x not found (or held by qemu/usbfs).\n"
            "Stop the Win7 VM first: virsh shutdown win7\n", VID, PID);
        libusb_exit(NULL);
        return 1;
    }
    if (!dev)
        fprintf(stderr, "%s: device not present yet, will wait for it\n", argv[1]);

    /* detach whatever kernel driver is bound (dvb_usb_dib0700) */
    if (dev) {
        if (libusb_kernel_driver_active(dev, 0) == 1) {
            r = libusb_detach_kernel_driver(dev, 0);
            printf("detach kernel driver: %s\n", r ? libusb_strerror(r) : "ok");
        }
        r = libusb_claim_interface(dev, 0);
        if (r < 0) fprintf(stderr, "claim if0: %s (continuing anyway)\n", libusb_strerror(r));
    }

    const char *c = argv[1];
    int rc = 0;

    if (!strcmp(c, "ver")) {
        rc = cmd_version();
    } else if (!strcmp(c, "reset")) {
        /* USB port reset: pulls the device's reset line, which is the only way
         * to get the dib0700 (and the demod behind it) out of a wedged state
         * without physically unplugging it. The handle dies; re-open after. */
        r = libusb_reset_device(dev);
        printf("libusb_reset_device: %s\n", r ? libusb_strerror(r) : "ok");
        rc = 0;
    } else if (!strcmp(c, "fw")) {
        rc = cmd_fw(argc > 2 ? argv[2] : "dvb-usb-dib0700-1.20.fw");
    } else if (!strcmp(c, "clock")) {
        rc = cmd_clock();
    } else if (!strcmp(c, "i2cparam")) {
        rc = cmd_i2cparam(argc > 2 ? atoi(argv[2]) : 100);
    } else if (!strcmp(c, "scan")) {
        rc = cmd_scan(argc > 2 ? atoi(argv[2]) : 1);
    } else if (!strcmp(c, "rd")) {
        if (argc < 5) { usage(argv[0]); rc = 2; }
        else rc = cmd_rd(atoi(argv[2]), strtol(argv[3], 0, 0), strtol(argv[4], 0, 0));
    } else if (!strcmp(c, "wr")) {
        if (argc < 6) { usage(argv[0]); rc = 2; }
        else rc = cmd_wr(atoi(argv[2]), strtol(argv[3], 0, 0),
                         strtol(argv[4], 0, 0), strtol(argv[5], 0, 0));
    } else if (!strcmp(c, "gpio")) {
        rc = cmd_gpio(atoi(argv[2]), atoi(argv[3]), atoi(argv[4]));
    } else if (!strcmp(c, "getgpio")) {
        rc = cmd_getgpio();
    } else if (!strcmp(c, "video")) {
        int on = strcmp(argv[2], "off") ? 1 : 0;
        int analog = strcmp(argv[3], "analog") ? 0 : 1;
        int l525 = (argc > 4 && !strcmp(argv[4], "525")) ? 1 : 0;
        int xl   = (argc > 5) ? atoi(argv[5]) : 0;
        rc = cmd_video(on, analog, l525, xl);
    } else if (!strcmp(c, "xferlen")) {
        rc = cmd_xferlen(atoi(argv[2]));
    } else if (!strcmp(c, "cap")) {
        rc = cmd_cap(strtol(argv[2], 0, 0), atoi(argv[3]), argc > 4 ? argv[4] : NULL);
    } else if (!strcmp(c, "cap2")) {
        rc = cmd_cap2(strtol(argv[2], 0, 0), atoi(argv[3]), argc > 4 ? argv[4] : NULL);
    } else if (!strcmp(c, "cap3")) {
        rc = cmd_cap_async(strtol(argv[2], 0, 0), atoi(argv[3]), argc > 4 ? argv[4] : NULL);
    } else if (!strcmp(c, "arm")) {
        rc = cmd_arm(argv[2]);
    } else if (!strcmp(c, "pwron")) {
        rc = cmd_pwron(strcmp(argv[2], "off") ? 1 : 0);
    } else if (!strcmp(c, "demodreset")) {
        rc = cmd_demodreset();
    } else if (!strcmp(c, "diversity")) {
        rc = cmd_diversity(strcmp(argv[2], "off") ? 1 : 0,
                           argc > 3 ? strtol(argv[3], 0, 0) : 0x0400);
    } else if (!strcmp(c, "dibrx")) {
        rc = cmd_dibrx(strtol(argv[2], 0, 0), strtol(argv[3], 0, 0),
                       argc > 4 ? strtol(argv[4], 0, 0) : 0,
                       argc > 5 ? strtol(argv[5], 0, 0) : 0,
                       argc > 6 ? (unsigned)strtoul(argv[6], 0, 0) : 0,
                       argc > 7 ? strtol(argv[7], 0, 0) : 0,
                       argc > 8 ? strtol(argv[8], 0, 0) : 0);
    } else if (!strcmp(c, "adapt")) {
        rc = cmd_adapt(strtol(argv[2], 0, 0));
    } else if (!strcmp(c, "demod")) {
        rc = cmd_demod(strtol(argv[2], 0, 0));
    } else if (!strcmp(c, "lscan")) {
        rc = cmd_scan_legacy();
    } else if (!strcmp(c, "lrd")) {
        unsigned char reg[4] = { (unsigned char)strtol(argv[3], 0, 0) };
        unsigned char rx[64];
        int r = i2c_read_legacy(strtol(argv[2], 0, 0), reg, 1, rx, argc > 4 ? atoi(argv[4]) : 1);
        if (r > 0) hexdump("lrd", rx, r);
        rc = r;
    } else if (!strcmp(c, "lwr")) {
        unsigned char d[2] = { (unsigned char)strtol(argv[3], 0, 0),
                               (unsigned char)strtol(argv[4], 0, 0) };
        rc = i2c_write_legacy(strtol(argv[2], 0, 0), d, 2);
    } else if (!strcmp(c, "raw")) {
        rc = cmd_raw(argc, argv);
    } else if (!strcmp(c, "bulkout")) {
        rc = cmd_bulkout(argc, argv);
    } else if (!strcmp(c, "watch")) {
        rc = cmd_watch(argc > 2 ? atoi(argv[2]) : 60);
    } else if (!strcmp(c, "init")) {
        rc = cmd_init(argc > 2 ? argv[2] : "dvb-usb-dib0700-1.20.fw");
    } else if (!strcmp(c, "fw2")) {
        rc = download_firmware2(argc > 2 ? argv[2] : "dvb-usb-dib0700-1.20.fw");
    } else if (!strcmp(c, "i2c2")) {
        if (argc < 8) { usage(argv[0]); rc = 2; }
        else rc = cmd_i2c2(atoi(argv[2]), atoi(argv[3]), strtol(argv[4], 0, 0),
                           strtol(argv[5], 0, 0), strtol(argv[6], 0, 0), atoi(argv[7]));
    } else if (!strcmp(c, "i2c2w")) {
        if (argc < 8) { usage(argv[0]); rc = 2; }
        else rc = cmd_i2c2w(atoi(argv[2]), atoi(argv[3]), strtol(argv[4], 0, 0),
                            strtol(argv[5], 0, 0), strtol(argv[6], 0, 0),
                            strtol(argv[7], 0, 0));
    } else if (!strcmp(c, "raw4")) {
        rc = cmd_raw4(argc, argv);
    } else if (!strcmp(c, "scan3")) {
        rc = cmd_scan3();
    } else if (!strcmp(c, "rd1")) {
        rc = cmd_rd1(strtol(argv[2], 0, 0), strtol(argv[3], 0, 0), argc > 4 ? atoi(argv[4]) : 1);
    } else if (!strcmp(c, "rd2")) {
        rc = cmd_rd2(strtol(argv[2], 0, 0), strtol(argv[3], 0, 0), strtol(argv[4], 0, 0), atoi(argv[5]));
    } else if (!strcmp(c, "wr1")) {
        rc = cmd_wr1(strtol(argv[2], 0, 0), strtol(argv[3], 0, 0), strtol(argv[4], 0, 0));
    } else if (!strcmp(c, "scanw")) {
        rc = cmd_scanw();
    } else if (!strcmp(c, "nrd16")) {
        if (argc < 5) { usage(argv[0]); rc = 2; }
        else rc = cmd_nrd16(atoi(argv[2]), strtol(argv[3], 0, 0), strtol(argv[4], 0, 0),
                            argc > 5 ? atoi(argv[5]) : 1);
    } else if (!strcmp(c, "nwr16")) {
        if (argc < 6) { usage(argv[0]); rc = 2; }
        else rc = cmd_nwr16(atoi(argv[2]), strtol(argv[3], 0, 0), strtol(argv[4], 0, 0),
                            strtol(argv[5], 0, 0));
    } else if (!strcmp(c, "grd1")) {
        if (argc < 4) { usage(argv[0]); rc = 2; }
        else rc = cmd_grd1(strtol(argv[2], 0, 0), strtol(argv[3], 0, 0),
                           argc > 4 ? atoi(argv[4]) : 1);
    } else if (!strcmp(c, "gwr1")) {
        if (argc < 5) { usage(argv[0]); rc = 2; }
        else rc = cmd_gwr1(strtol(argv[2], 0, 0), strtol(argv[3], 0, 0), strtol(argv[4], 0, 0));
    } else if (!strcmp(c, "nrd2")) {
        if (argc < 5) { usage(argv[0]); rc = 2; }
        else rc = cmd_nrd2(atoi(argv[2]), strtol(argv[3], 0, 0), strtol(argv[4], 0, 0),
                           argc > 5 ? atoi(argv[5]) : 1);
    } else if (!strcmp(c, "scannew")) {
        rc = cmd_scannew(argc > 2 ? atoi(argv[2]) : 1);
    } else if (!strcmp(c, "nrd1")) {
        if (argc < 5) { usage(argv[0]); rc = 2; }
        else rc = cmd_nrd1(atoi(argv[2]), strtol(argv[3], 0, 0), strtol(argv[4], 0, 0),
                           argc > 5 ? atoi(argv[5]) : 1);
    } else if (!strcmp(c, "nwr1")) {
        if (argc < 6) { usage(argv[0]); rc = 2; }
        else rc = cmd_nwr1(atoi(argv[2]), strtol(argv[3], 0, 0), strtol(argv[4], 0, 0),
                           strtol(argv[5], 0, 0));
    } else if (!strcmp(c, "regseq")) {
        rc = cmd_regseq(argc > 2 ? argv[2] : "logs/analog-seq-ordered.txt");
    } else if (!strcmp(c, "analogseq")) {
        rc = cmd_analogseq(argc > 2 ? argv[2] : "logs/analog-seq-ordered.txt",
                           argc > 3 ? strtol(argv[3], 0, 0) : 0,
                           argc > 4 ? atoi(argv[4]) : 4096);
    } else if (!strcmp(c, "gpiosweep")) {
        rc = cmd_gpiosweep(argc > 2 ? strtol(argv[2], 0, 0) : 0x09);
    } else if (!strcmp(c, "identify")) {
        rc = cmd_identify(argc > 2 ? atoi(argv[2]) : 1);
    } else if (!strcmp(c, "idrd")) {
        if (argc < 5) { usage(argv[0]); rc = 2; }
        else rc = cmd_idrd(atoi(argv[2]), strtol(argv[3], 0, 0), strtol(argv[4], 0, 0));
    } else if (!strcmp(c, "cxdump")) {
        rc = cmd_cxdump(argc, argv);
    } else if (!strcmp(c, "cxr")) {
        rc = cmd_cxr(argc, argv);
    } else if (!strcmp(c, "cxw")) {
        rc = cmd_cxw(argc, argv);
    } else if (!strcmp(c, "analog2")) {
        rc = cmd_analog2(argc, argv);
    } else if (!strcmp(c, "stream")) {
        rc = cmd_stream(argc, argv);
    } else if (!strcmp(c, "dwr")) {
        if (argc < 4) { usage(argv[0]); rc = 2; }
        else {
            int reg = strtol(argv[2], 0, 0), val = strtol(argv[3], 0, 0);
            int a = (argc > 4) ? strtol(argv[4], 0, 0) : 0x80;
            demod_wr(a, reg, val);
            unsigned int v = 0;
            read_word_new(1, a >> 1, reg, &v);
            printf("demod reg %d: wrote %04x, read back %04x\n", reg, val, v);
        }
    } else if (!strcmp(c, "videosweep")) {
        rc = cmd_videosweep();
    } else if (!strcmp(c, "analog")) {
        rc = cmd_analog(argc, argv);
    } else if (!strcmp(c, "eepromdump")) {
        rc = cmd_eepromdump(argc > 2 ? (unsigned)strtoul(argv[2], 0, 0) : 0,
                            argc > 3 ? argv[3] : NULL, 0);
    } else if (!strcmp(c, "romwin")) {
        rc = cmd_romwin(argc, argv);
    } else if (!strcmp(c, "eepromwin")) {
        rc = cmd_eepromwin(argc, argv);
    } else if (!strcmp(c, "eeprom")) {
        rc = cmd_eeprom();
    } else if (!strcmp(c, "probeall")) {
        rc = cmd_probeall(0, argc > 2 ? strtol(argv[2], 0, 0) : 0,
                             argc > 3 ? strtol(argv[3], 0, 0) : 0xff, 0);
    } else if (!strcmp(c, "probe4")) {
        rc = cmd_probeall(0, argc > 2 ? strtol(argv[2], 0, 0) : 0,
                             argc > 3 ? strtol(argv[3], 0, 0) : 0xff, 1);
    } else if (!strcmp(c, "probeout4")) {
        rc = cmd_probeall(1, argc > 2 ? strtol(argv[2], 0, 0) : 0,
                             argc > 3 ? strtol(argv[3], 0, 0) : 0xff, 1);
    } else if (!strcmp(c, "probeout")) {
        rc = cmd_probeall(1, argc > 2 ? strtol(argv[2], 0, 0) : 0,
                             argc > 3 ? strtol(argv[3], 0, 0) : 0xff, 0);
    } else if (!strcmp(c, "analogout")) {
        rc = cmd_analogout(argc, argv);
    } else if (!strcmp(c, "armsweep")) {
        if (argc < 3) { usage(argv[0]); rc = 2; }
        else rc = cmd_armsweep(argc, argv);
    } else if (!strcmp(c, "replay")) {
        if (argc < 3) { usage(argv[0]); rc = 2; }
        else rc = cmd_replay(argc, argv);
    } else if (!strcmp(c, "reset")) {
        rc = libusb_reset_device(dev);
        printf("reset: %s\n", rc ? libusb_strerror(rc) : "ok");
    } else {
        usage(argv[0]); rc = 2;
    }

    if (dev) {
        libusb_release_interface(dev, 0);
        libusb_close(dev);
    }
    libusb_exit(NULL);
    return rc < 0 ? 1 : (rc ? 0 : 0);
}
