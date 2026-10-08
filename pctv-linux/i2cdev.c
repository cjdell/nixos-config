/* i2cdev.c — talk to the PCTV 320cx i2c devices through the KERNEL adapter
 * (/dev/i2c-N) with I2C_RDWR, i.e. exactly the path the driver uses.
 *
 *   i2cdev scan <bus>                     probe every 7-bit address
 *   i2cdev r  <bus> <addr7> <reg> [n]     write reg (1 byte), read n bytes
 *   i2cdev r2 <bus> <addr7> <reg16> [n]   write 16-bit reg, read n bytes
 *   i2cdev w  <bus> <addr7> <reg> <val>   1-byte register write
 *   i2cdev w2 <bus> <addr7> <reg16> <val16>  16-bit register write
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <linux/i2c.h>
#include <linux/i2c-dev.h>
#include <sys/ioctl.h>

static int bus_open(const char *n)
{
    char p[64];
    snprintf(p, sizeof p, "/dev/i2c-%s", n);
    int fd = open(p, O_RDWR);
    if (fd < 0) fprintf(stderr, "open %s: %s\n", p, strerror(errno));
    return fd;
}

static int xfer(int fd, int addr, struct i2c_msg *msgs, int n)
{
    struct i2c_rdwr_ioctl_data x = { .msgs = msgs, .nmsgs = n };
    return ioctl(fd, I2C_RDWR, &x) < 0 ? -errno : 0;
}

static int rd(int fd, int addr, unsigned char *regbuf, int reglen, int n)
{
    unsigned char rx[64] = {0};
    struct i2c_msg m[2] = {
        { .addr = addr, .flags = 0, .len = reglen, .buf = regbuf },
        { .addr = addr, .flags = I2C_M_RD, .len = n, .buf = rx },
    };
    int r = xfer(fd, addr, m, 2);
    if (r) { printf("  addr 0x%02x reg %d: %s\n", addr,
                    reglen == 2 ? (regbuf[0] << 8) | regbuf[1] : regbuf[0], strerror(-r)); return r; }
    printf("  addr 0x%02x reg %d ->", addr,
           reglen == 2 ? (regbuf[0] << 8) | regbuf[1] : regbuf[0]);
    for (int i = 0; i < n; i++) printf(" %02x", rx[i]);
    printf("\n");
    return 0;
}

int main(int argc, char **argv)
{
    if (argc < 3) { fprintf(stderr, "see source for usage\n"); return 2; }
    int fd = bus_open(argv[2]);
    if (fd < 0) return 1;

    if (!strcmp(argv[1], "scan")) {
        for (int a = 0x08; a <= 0x77; a++) {
            unsigned char reg = 0;
            struct i2c_msg m = { .addr = a, .flags = 0, .len = 1, .buf = &reg };
            int r = xfer(fd, a, &m, 1);
            if (r == 0) printf("  ACK at 7-bit 0x%02x (8-bit 0x%02x)\n", a, a << 1);
        }
        printf("scan done\n");
    } else if (!strcmp(argv[1], "r") && argc >= 5) {
        unsigned char reg = (unsigned char)strtol(argv[4], NULL, 0);
        rd(fd, strtol(argv[3], NULL, 0), &reg, 1, argc > 5 ? atoi(argv[5]) : 1);
    } else if (!strcmp(argv[1], "r2") && argc >= 5) {
        long reg = strtol(argv[4], NULL, 0);
        unsigned char rb[2] = { (unsigned char)(reg >> 8), (unsigned char)reg };
        rd(fd, strtol(argv[3], NULL, 0), rb, 2, argc > 5 ? atoi(argv[5]) : 2);
    } else if (!strcmp(argv[1], "w") && argc >= 6) {
        unsigned char d[2] = { (unsigned char)strtol(argv[4], NULL, 0),
                               (unsigned char)strtol(argv[5], NULL, 0) };
        struct i2c_msg m = { .addr = strtol(argv[3], NULL, 0), .flags = 0, .len = 2, .buf = d };
        int r = xfer(fd, m.addr, &m, 1);
        if (r) printf("write: %s\n", strerror(-r));
    } else if (!strcmp(argv[1], "w2") && argc >= 6) {
        long v = strtol(argv[5], NULL, 0);
        unsigned char d[4] = { (unsigned char)(strtol(argv[4], NULL, 0) >> 8),
                               (unsigned char)strtol(argv[4], NULL, 0),
                               (unsigned char)(v >> 8), (unsigned char)v };
        struct i2c_msg m = { .addr = strtol(argv[3], NULL, 0), .flags = 0, .len = 4, .buf = d };
        int r = xfer(fd, m.addr, &m, 1);
        if (r) printf("write: %s\n", strerror(-r));
    } else {
        fprintf(stderr, "bad arguments\n"); return 2;
    }
    close(fd);
    return 0;
}
