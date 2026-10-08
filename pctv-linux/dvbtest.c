/* dvbtest: tune the DVB-T frontend with explicit params and read the DVR.
 * Diagnostic: does ANY data flow through the dib0700 bridge? */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <poll.h>
#include <sys/ioctl.h>
#include <linux/dvb/frontend.h>
#include <linux/dvb/dvr.h>

int main(int argc, char **argv)
{
    int fe = open("/dev/dvb/adapter0/frontend0", O_RDWR);
    if (fe < 0) { perror("frontend0"); return 1; }
    int dvr = open("/dev/dvb/adapter0/dvr0", O_RDWR);
    if (dvr < 0) { perror("dvr0"); return 1; }

    struct dtv_property p[] = {
        { .cmd = DTV_FREQUENCY, .u.u32 = 226500000 },
        { .cmd = DTV_BAND,      .u.u32 = BAND_T },
        { .cmd = DTV_BANDWIDTH, .u.u32 = BANDWIDTH_8_MHZ },
        { .cmd = DTV_TRANSMISSION_MODE, .u.u32 = TRANSMISSION_MODE_8K },
        { .cmd = DTV_GUARD_INTERVAL,    .u.u32 = GUARD_INTERVAL_1_32 },
        { .cmd = DTV_INVERSION,         .u.u32 = SPECTRUM_INVERSION_OFF },
        { .cmd = DTV_MODULATION,        .u.u32 = QAM_16 },
        { .cmd = DTV_INNER_FEC,        .u.u32 = FEC_2_3 },
        { .cmd = DTV_INNER_FEC,        .u.u32 = FEC_2_3 },
        { .cmd = DTV_HIERARCHY,        .u.u32 = HIERARCHY_NONE },
    };
    struct dtv_properties props = { .num = sizeof(p)/sizeof(p[0]), .props = p };
    if (ioctl(fe, FE_SET_PROPERTY, &props) < 0) perror("FE_SET_PROPERTY");
    printf("tuned (errors are fine)\n");

    int total = 0;
    unsigned char buf[40 * 188];
    for (int i = 0; i < 20; i++) {
        struct pollfd pf = { .fd = dvr, .events = POLLIN };
        int r = poll(&pf, 1, 1000);
        if (r <= 0) { printf("poll %d: %s\n", i, r == 0 ? "timeout" : strerror(errno)); break; }
        ssize_t n = read(dvr, buf, sizeof buf);
        if (n < 0) { printf("read: %s\n", strerror(errno)); break; }
        total += n;
        if (total <= 512) {
            printf("chunk %zd:", n);
            for (ssize_t j = 0; j < n && j < 32; j++) printf(" %02x", buf[j]);
            printf("\n");
        }
    }
    printf("read %d bytes from dvr0\n", total);
    enum fe_status st;
    ioctl(fe, FE_READ_STATUS, &st);
    printf("status = %02x%s%s%s%s%s\n", st,
        (st & FE_HAS_SIGNAL) ? " SIGNAL" : "", (st & FE_HAS_CARRIER) ? " CARRIER" : "",
        (st & FE_HAS_VITERBI) ? " VITERBI" : "", (st & FE_HAS_SYNC) ? " SYNC" : "",
        (st & FE_HAS_LOCK) ? " LOCK" : "");
    return 0;
}
