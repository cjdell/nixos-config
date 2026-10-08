/* SPDX-License-Identifier: GPL-2.0
 * i2cprobe - scan / talk to devices on an I2C adapter exposed by /dev/i2c-N
 * (works on adapters that only implement master_xfer, e.g. the DiB0700 USB bus,
 * where i2cdetect fails with "Bus doesn't support detection commands").
 *
 * usage:
 *   i2cprobe scan  <bus>                    1-byte read at every 7-bit address
 *   i2cprobe rd    <bus> <addr> <nbytes>    plain read
 *   i2cprobe rd2   <bus> <addr> <reghi> <reglo> <n>   2-byte-register read (CX2584x style)
 *   i2cprobe rd1   <bus> <addr> <reg> <n>   1-byte-register read
 *   i2cprobe wr2   <bus> <addr> <reghi> <reglo> <val>
 *   i2cprobe wr1   <bus> <addr> <reg> <val>
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <sys/ioctl.h>
#include <linux/i2c.h>
#include <linux/i2c-dev.h>

static int open_bus(int bus)
{
    char p[64];
    snprintf(p, sizeof p, "/dev/i2c-%d", bus);
    int fd = open(p, O_RDWR);
    if (fd < 0) { perror(p); exit(1); }
    return fd;
}

static int xfer(int fd, int addr, struct i2c_msg *msgs, int n)
{
    struct i2c_rdwr_ioctl_data d = { msgs, n };
    return ioctl(fd, I2C_RDWR, &d);
}

static int do_read(int fd, int addr, unsigned char *reg, int reglen,
                   unsigned char *rx, int rxlen)
{
    struct i2c_msg m[2];
    int n = 0;
    if (reglen) {
        m[n].addr = addr; m[n].flags = 0; m[n].len = reglen; m[n].buf = reg;
        n++;
    }
    m[n].addr = addr; m[n].flags = I2C_M_RD; m[n].len = rxlen; m[n].buf = rx;
    n++;
    return xfer(fd, addr, m, n);
}

static int do_write(int fd, int addr, unsigned char *data, int len)
{
    struct i2c_msg m = { .addr = addr, .flags = 0, .len = len, .buf = data };
    return xfer(fd, addr, &m, 1);
}

static void hexdump(const char *t, unsigned char *b, int n)
{
    printf("%s:", t);
    for (int i = 0; i < n; i++) printf(" %02x", b[i]);
    printf("\n");
}

int main(int argc, char **argv)
{
    if (argc < 3) { fprintf(stderr, "see source header for usage\n"); return 2; }
    int bus = atoi(argv[2]);
    int fd = open_bus(bus);
    unsigned char buf[64];

    if (!strcmp(argv[1], "scan")) {
        int found = 0;
        for (int a = 0x03; a <= 0x77; a++) {
            if (do_read(fd, a, NULL, 0, buf, 1) >= 0) {
                printf("  ACK 0x%02x (8-bit 0x%02x) first byte %02x\n", a, a << 1, buf[0]);
                found++;
            }
        }
        printf("scan of bus %d: %d device(s) answered\n", bus, found);
        return 0;
    }
    if (!strcmp(argv[1], "wscan")) {
        int found = 0;
        for (int a = 0x03; a <= 0x77; a++) {
            unsigned char d[1] = { 0x00 };
            if (do_write(fd, a, d, 1) >= 0) { printf("  ACK 0x%02x (8-bit 0x%02x)\n", a, a << 1); found++; }
        }
        printf("write scan of bus %d: %d device(s) ACKed\n", bus, found);
        return 0;
    }
    if (!strcmp(argv[1], "rd")) {
        int a = strtol(argv[3], 0, 0), n = atoi(argv[4]);
        int r = do_read(fd, a, NULL, 0, buf, n);
        if (r < 0) { printf("read failed: %s\n", strerror(errno)); return 1; }
        hexdump("rd", buf, n); return 0;
    }
    if (!strcmp(argv[1], "rd1")) {
        int a = strtol(argv[3], 0, 0), reg = strtol(argv[4], 0, 0), n = atoi(argv[5]);
        unsigned char regb[1] = { (unsigned char)reg };
        int r = do_read(fd, a, regb, 1, buf, n);
        if (r < 0) { printf("read failed: %s\n", strerror(errno)); return 1; }
        hexdump("rd1", buf, n); return 0;
    }
    if (!strcmp(argv[1], "rd2")) {
        int a = strtol(argv[3], 0, 0), hi = strtol(argv[4], 0, 0), lo = strtol(argv[5], 0, 0), n = atoi(argv[6]);
        unsigned char regb[2] = { (unsigned char)hi, (unsigned char)lo };
        int r = do_read(fd, a, regb, 2, buf, n);
        if (r < 0) { printf("read failed: %s\n", strerror(errno)); return 1; }
        hexdump("rd2", buf, n); return 0;
    }
    if (!strcmp(argv[1], "wr1")) {
        int a = strtol(argv[3], 0, 0), reg = strtol(argv[4], 0, 0), v = strtol(argv[5], 0, 0);
        unsigned char d[2] = { (unsigned char)reg, (unsigned char)v };
        if (do_write(fd, a, d, 2) < 0) { printf("write failed: %s\n", strerror(errno)); return 1; }
        return 0;
    }
    if (!strcmp(argv[1], "wr2")) {
        int a = strtol(argv[3], 0, 0), hi = strtol(argv[4], 0, 0), lo = strtol(argv[5], 0, 0), v = strtol(argv[6], 0, 0);
        unsigned char d[3] = { (unsigned char)hi, (unsigned char)lo, (unsigned char)v };
        if (do_write(fd, a, d, 3) < 0) { printf("write failed: %s\n", strerror(errno)); return 1; }
        return 0;
    }
    fprintf(stderr, "unknown command\n");
    return 2;
}
