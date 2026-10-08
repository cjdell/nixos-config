/* fwtest - is the DiB0700's 8051 reachable at all?  (PCTV 320cx, 2304:022e)
 *
 * Written while diagnosing "no V4L2 video since the kernel bump to 7.2.9": the
 * node registers but every vendor control request stalls and the firmware
 * download never starts the bridge's 8051.  This tool A/B-tests the download in
 * different transfer shapes and probes the endpoints, so "short packets are
 * mangled" / "data toggle lost" / "the 8051 is not running" can be told apart.
 * It is separate from probe.c on purpose: probe.c assumes a warm bridge.
 *
 * Build (NixOS, no pkg-config in the shell):
 *   DEV=$(nix build --no-link --print-out-paths nixpkgs#libusb1.dev)
 *   RUN=$(nix build --no-link --print-out-paths nixpkgs#libusb1)
 *   nix shell nixpkgs#gcc --command sh -c \
 *     "cc -O2 -Wall -I$DEV/include -o fwtest fwtest.c -L$RUN/lib -lusb-1.0"
 *   sudo LD_LIBRARY_PATH=$RUN/lib ./fwtest <cmd> [fwfile]
 *
 * Commands:  ver | echo | clear | dlrec | dltwice | dlstream | ack | kick | rawout
 *   ver      GET_VERSION with recipient 0 then 4 (the self-boot / warm test)
 *   echo     bulk OUT a marker on EP1, then read EP1 IN/EP2 IN/EP3 IN
 *   clear    clear_halt on EP1..EP3 both directions, then ver
 *   dlrec    mainline shape: one bulk transfer per record (all short packets)
 *   dltwice  same, every record sent twice (data-toggle resync)
 *   dlstream one continuous byte stream in full-512-byte chunks
 *   ack      drain EP1 IN, download, jumpram, print what the bridge reports
 *            (run it on the stock blob and on a blob with one data byte
 *            flipped + its record checksum fixed: identical output means the
 *            reply says nothing about our payload)
 *   kick     download + jumpram, then RESET 0x09 / MASTER_RESET 0x0a, ver after
 *            each
 *   rawout   control OUT: <rq> <bytes...> (e.g. rawout 09 01)
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <libusb-1.0/libusb.h>

#define VID 0x2304
#define PID 0x022e
#define RQ_GET_VERSION 0x15
#define EP_FW_OUT 0x01
#define EP_FW_IN  0x81

static libusb_device_handle *dev;

static int ctrl_in(int type, unsigned char rq, unsigned value, unsigned index,
                   unsigned char *buf, int len)
{
    int r = libusb_control_transfer(dev, type | LIBUSB_ENDPOINT_IN | LIBUSB_REQUEST_TYPE_VENDOR,
                                    rq, value, index, buf, len, 1000);
    if (r < 0) printf("  ctrl_in(type=%02x rq=0x%02x) -> %s\n", type, rq, libusb_strerror(r));
    return r;
}

static int ver(const char *tag)
{
    unsigned char b[16];
    int r = ctrl_in(LIBUSB_RECIPIENT_DEVICE, RQ_GET_VERSION, 0, 0, b, 16);
    if (r < 0)
        r = ctrl_in(LIBUSB_RECIPIENT_INTERFACE, RQ_GET_VERSION, 0, 0, b, 16);
    if (r < 16) { printf("%s: GET_VERSION DEAD\n", tag); return -1; }
    printf("%s: GET_VERSION ALIVE hw=%02x %02x %02x %02x rom=%02x %02x %02x %02x "
           "ram=%02x %02x %02x %02x fw=%02x %02x %02x %02x\n", tag,
           b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7],
           b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]);
    return 0;
}

static unsigned char *read_fw(const char *path, long *sz)
{
    FILE *f = fopen(path, "rb");
    if (!f) { perror("open fw"); return NULL; }
    fseek(f, 0, SEEK_END); long s = ftell(f); fseek(f, 0, SEEK_SET);
    unsigned char *fw = malloc(s);
    if (fread(fw, 1, s, f) != (size_t)s) { fclose(f); free(fw); return NULL; }
    fclose(f); *sz = s; return fw;
}

static void jumpram(void)
{
    unsigned char j[8] = { 0x08, 0, 0, 0, 0x70, 0, 0, 0 };
    int x = 0, r = libusb_bulk_transfer(dev, EP_FW_OUT, j, 8, &x, 2000);
    printf("jumpram: %s (%d bytes)\n", r < 0 ? libusb_strerror(r) : "ok", x);
}

/* A: mainline shape - one bulk transfer per record (every one a short packet) */
static int dl_rec(const char *path, int twice)
{
    long sz; unsigned char *fw = read_fw(path, &sz);
    if (!fw) return -1;
    long pos = 0; int nrec = 0, errs = 0;
    while (pos + 5 <= sz) {
        unsigned char len = fw[pos], type = fw[pos + 3];
        if (pos + 4 + len + 1 > sz) break;
        int blen = len + 5;
        unsigned char *b = malloc(blen);
        memcpy(b, fw + pos, blen);
        for (int rep = 0; rep < (twice ? 2 : 1); rep++) {
            int x = 0;
            int r = libusb_bulk_transfer(dev, EP_FW_OUT, b, blen, &x, 2000);
            if (r < 0) { printf("rec %d rep %d: %s\n", nrec, rep, libusb_strerror(r)); errs++; }
            if (x != blen) printf("rec %d rep %d: short write %d/%d\n", nrec, rep, x, blen);
        }
        free(b);
        pos += 4 + len + 1; nrec++;
        if (type == 0x01) break;
    }
    printf("dl_rec%s: %d records, %d errors\n", twice ? "-twice" : "", nrec, errs);
    free(fw); jumpram(); usleep(600000); return 0;
}

/* B: one continuous byte stream - only full 512-byte packets until the tail */
static int dl_stream(const char *path)
{
    long sz; unsigned char *fw = read_fw(path, &sz);
    if (!fw) return -1;
    /* walk the records so the stream is exactly the record bytes, nothing else */
    long end = 0, pos = 0, nrec = 0;
    while (pos + 5 <= sz) {
        unsigned char len = fw[pos], type = fw[pos + 3];
        if (pos + 4 + len + 1 > sz) break;
        pos += 4 + len + 1; nrec++; end = pos;
        if (type == 0x01) break;
    }
    long off = 0; int errs = 0;
    while (off < end) {
        long chunk = end - off;
        if (chunk > 512 * 16) chunk = 512 * 16;
        chunk = (chunk / 512) * 512;              /* keep every packet full-size */
        if (chunk == 0) chunk = end - off;        /* the tail may be short */
        int x = 0;
        int r = libusb_bulk_transfer(dev, EP_FW_OUT, fw + off, chunk, &x, 3000);
        if (r < 0) { printf("stream @%ld: %s\n", off, libusb_strerror(r)); errs++; break; }
        if (x != chunk) printf("stream @%ld: short write %ld/%ld\n", off, (long)x, chunk);
        off += chunk;
    }
    printf("dl_stream: %ld bytes (%d records) in full-512 chunks, %d errors\n", end, (int)nrec, errs);
    free(fw); jumpram(); usleep(600000); return 0;
}

/* C: is EP1 IN an echo of EP1 OUT?  (bulk-OUT integrity, no firmware needed) */
static int echo_test(void)
{
    static const unsigned char pat[16] = {
        0xde, 0xad, 0xbe, 0xef, 0x11, 0x22, 0x33, 0x44,
        0x55, 0x66, 0x77, 0x88, 0x99, 0xaa, 0xbb, 0xcc };
    unsigned char rx[512];
    int x = 0, r = libusb_bulk_transfer(dev, EP_FW_OUT, (unsigned char *)pat, 16, &x, 1000);
    printf("echo: wrote 16 -> %s (%d)\n", r < 0 ? libusb_strerror(r) : "ok", x);
    for (int ep = 0x81; ep <= 0x83; ep++) {
        int got = 0;
        int q = libusb_bulk_transfer(dev, ep, rx, sizeof(rx), &got, 700);
        printf("  ep %02x: %s", ep, q < 0 ? libusb_strerror(q) : "data");
        if (got > 0) { printf(" %d bytes:", got);
            for (int i = 0; i < got && i < 32; i++) printf(" %02x", rx[i]); }
        printf("\n");
    }
    return 0;
}

/* D: does the payload actually land?  Drain EP1 IN, download, jumpram, then
 * read the bridge's status bytes.  Same blob twice must give the same status;
 * a blob with one data byte flipped must give a DIFFERENT one if the RAM was
 * written from our bytes. */
static int ack(const char *path)
{
    long sz; unsigned char *fw = read_fw(path, &sz);
    if (!fw) return -1;
    printf("ack: draining ep1 IN\n");
    for (int i = 0; i < 5; i++) {
        unsigned char d[512]; int g = 0;
        int r = libusb_bulk_transfer(dev, EP_FW_IN, d, sizeof(d), &g, 300);
        printf("  drain %d: %s", i, r < 0 ? libusb_strerror(r) : "data");
        if (g > 0) { printf(" %d bytes:", g); for (int j = 0; j < g && j < 24; j++) printf(" %02x", d[j]); }
        printf("\n");
        if (r < 0) break;
    }
    long pos = 0; int nrec = 0;
    while (pos + 5 <= sz) {
        unsigned char len = fw[pos], type = fw[pos + 3];
        if (pos + 4 + len + 1 > sz) break;
        int blen = len + 5, x = 0;
        int r = libusb_bulk_transfer(dev, EP_FW_OUT, fw + pos, blen, &x, 2000);
        if (r < 0) { printf("rec %d: %s\n", nrec, libusb_strerror(r)); break; }
        pos += 4 + len + 1; nrec++;
        if (type == 0x01) break;
    }
    printf("ack: sent %d records\n", nrec);
    jumpram();
    usleep(600000);
    for (int i = 0; i < 3; i++) {
        unsigned char rx[512]; int g = 0;
        int r = libusb_bulk_transfer(dev, EP_FW_IN, rx, sizeof(rx), &g, 800);
        printf("  status %d: %s", i, r < 0 ? libusb_strerror(r) : "data");
        if (g > 0) { printf(" %d bytes:", g); for (int j = 0; j < g && j < 48; j++) printf(" %02x", rx[j]); }
        printf("\n");
    }
    free(fw);
    return ver("after-ack");
}

/* E: control OUT with arbitrary payload (RESET 0x09, MASTER_RESET 0x0a, ...). */
static int rawout(int argc, char **argv)
{
    unsigned char b[64]; int n = 0;
    for (int i = 0; i < argc && n < 64; i++) b[n++] = (unsigned char)strtol(argv[i], NULL, 16);
    int r = libusb_control_transfer(dev, LIBUSB_ENDPOINT_OUT | LIBUSB_REQUEST_TYPE_VENDOR |
                                    LIBUSB_RECIPIENT_DEVICE, b[0], 0, 0, b, n, 1000);
    printf("rawout %02x (%d bytes): %s\n", b[0], n, r < 0 ? libusb_strerror(r) : "ok");
    return r;
}

/* F: download, jumpram, then every reset the bridge knows about, checking the
 * 8051 after each one. */
static int kick(const char *path)
{
    dl_rec(path, 0);
    if (ver("after-jumpram") == 0) return 0;
    rawout(2, (char *[]){ (char *)"09", (char *)"01" });
    usleep(300000); if (ver("after-reset-09") == 0) return 0;
    rawout(1, (char *[]){ (char *)"0a" });
    usleep(300000); if (ver("after-master-reset") == 0) return 0;
    rawout(2, (char *[]){ (char *)"09", (char *)"00" });
    usleep(300000); return ver("after-reset-09-00");
}

static int clear_halt(void)
{
    for (int ep = 1; ep <= 3; ep++) {
        printf("  clear 0x%02x: %s\n", ep, libusb_strerror(libusb_clear_halt(dev, ep)));
        printf("  clear 0x%02x: %s\n", ep | 0x80, libusb_strerror(libusb_clear_halt(dev, ep | 0x80)));
    }
    return 0;
}

int main(int argc, char **argv)
{
    const char *cmd = argc > 1 ? argv[1] : "ver";
    const char *fw = argc > 2 ? argv[2] : "dvb-usb-dib0700-1.20.fw";

    if (libusb_init(NULL) < 0) { fprintf(stderr, "libusb_init\n"); return 1; }
    dev = libusb_open_device_with_vid_pid(NULL, VID, PID);
    if (!dev) { fprintf(stderr, "device not found\n"); return 1; }
    if (libusb_kernel_driver_active(dev, 0) == 1) {
        libusb_detach_kernel_driver(dev, 0);
        printf("detached kernel driver\n");
    }
    int c = libusb_claim_interface(dev, 0);
    if (c < 0) printf("claim intf0: %s\n", libusb_strerror(c));

    int rc = 1;
    if (!strcmp(cmd, "ver"))            rc = ver("ver");
    else if (!strcmp(cmd, "echo"))      rc = echo_test();
    else if (!strcmp(cmd, "clear"))     { clear_halt(); rc = ver("after-clear"); }
    else if (!strcmp(cmd, "dlrec"))     { dl_rec(fw, 0); rc = ver("after-dlrec"); }
    else if (!strcmp(cmd, "dltwice"))   { dl_rec(fw, 2); rc = ver("after-dltwice"); }
    else if (!strcmp(cmd, "dlstream"))  { dl_stream(fw); rc = ver("after-dlstream"); }
    else if (!strcmp(cmd, "ack"))       rc = ack(fw);
    else if (!strcmp(cmd, "kick"))      rc = kick(fw);
    else if (!strcmp(cmd, "rawout"))    rc = rawout(argc - 2, argv + 2);
    else fprintf(stderr, "unknown command %s\n", cmd);

    libusb_close(dev); libusb_exit(NULL);
    return rc == 0 ? 0 : 2;
}
