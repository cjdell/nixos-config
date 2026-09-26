/*
 * NanoThermistor.c - dual NTC thermistor temperature node
 *
 * Target : Arduino Nano (ATmega328P, 16 MHz), bare-metal avr-gcc.
 * Purpose: read two 100k NTC thermistors with a 4.7k pullup each and
 *          stream the result as one ASCII line per sample.
 *
 * This is the "spare Arduino Nano as an external ADC" node for the
 * Smoothieboard whose on-board thermistor channels read implausibly
 * (see docs/klipper-3d-printer.md section 6).  It is deliberately
 * *standalone*: it prints raw counts, resistance and temperature, and
 * makes no assumption about what consumes the data.
 *
 * Wiring (see docs/klipper-3d-printer.md section 9):
 *
 *   +5V --- [4.7k 1%] ---+--- A0 (extruder NTC) --- NTC --- GND
 *                        |
 *                     [100nF]
 *                        |
 *                       GND
 *
 *   (identical network on A1 for the bed NTC)
 *
 * The pullup MUST go to the same 5 V rail that powers the Nano (AVcc is
 * the ADC reference, so the measurement is ratiometric) - and it must
 * NOT be the Smoothieboard's suspect analog rail.
 *
 * Serial: 115200 8N1 on the Nano's UART0 (D1=TX, D0=RX), i.e. the
 * CH340/FTDI USB-serial bridge.
 *
 * Protocol - one line per sample, 2 Hz:
 *
 *   TH <seq> <a0> <a1> <r0> <r1> <t0> <t1> <crc>\n
 *
 *     seq : monotonically increasing sample counter
 *     aN  : oversampled raw ADC counts, 0..32736 (32 x 10-bit sums;
 *           divide by 32 for the plain 0..1023 reading)
 *     rN  : NTC resistance in ohms
 *     tN  : temperature in milli-degrees Celsius
 *     crc : CRC-8 (poly 0x07) over everything between "TH " and the
 *           space before the crc field
 *
 *   Send 'i' to the node to print the identity/config banner.
 *
 * Build/flash: ./flash.sh
 */

#ifndef F_CPU
#define F_CPU 16000000UL
#endif

#include <avr/io.h>
#include <avr/pgmspace.h>
#include <util/delay.h>
#include <stdint.h>
#include <stdlib.h>
#include <math.h>

#define UART_BAUD 115200UL

/* Number of hardware ADC samples summed per reading.  32 sums give a
 * 15-bit result (full scale 32*1023 = 32736) which is plenty to smooth
 * a 10-bit converter; the conversion stays ratiometric. */
#define OVERSAMPLE 32UL
#define ADC_FULLSCALE ((uint32_t)OVERSAMPLE * 1023UL)

#define NCH 2

typedef struct {
    uint8_t  adc_ch;     /* 0 = A0, 1 = A1, ... */
    uint16_t pullup;     /* pullup resistance, ohms */
    uint32_t r0;         /* nominal resistance, ohms */
    uint16_t beta;       /* B25/85, kelvin */
    const char *name;
} ntc_ch_t;

/* Extruder: ATC Semitec 104GT-2 (100k, B=4267 K)
 * Bed     : Honeywell 100K 135-104LAG-J01 (100k, B=3974 K)
 *
 * These two-parameter Beta values are good to a degree or two.  For a
 * strict match with Klipper's built-in tables, compare against the
 * resistance/temperature table in klippy/extras/thermistor.py and, if
 * you need exactness, swap in a Steinhart-Hart fit. */
static ntc_ch_t chans[NCH] = {
    { 0, 4700, 100000UL, 4267, "extruder" },
    { 1, 4700, 100000UL, 3974, "bed"      },
};

/* ------------------------------------------------------------------ */
/* UART0                                                              */
/* ------------------------------------------------------------------ */

static void uart_init(void)
{
    /* U2X=1 for the smaller baud error at 16 MHz */
    uint16_t ubrr = (uint16_t)(F_CPU / (8UL * UART_BAUD) - 1UL);
    UBRR0H = (uint8_t)(ubrr >> 8);
    UBRR0L = (uint8_t)(ubrr & 0xFF);
    UCSR0A = (1 << U2X0);
    UCSR0B = (1 << TXEN0) | (1 << RXEN0);
    UCSR0C = (1 << UCSZ01) | (1 << UCSZ00);
}

static void uart_putc(char c)
{
    while (!(UCSR0A & (1 << UDRE0))) { }
    UDR0 = c;
}

static void uart_puts(const char *s)
{
    while (*s)
        uart_putc(*s++);
}

static int uart_rx_ready(void)
{
    return (UCSR0A & (1 << RXC0)) != 0;
}

static char uart_getc(void)
{
    return UDR0;
}

/* ------------------------------------------------------------------ */
/* ADC                                                                */
/* ------------------------------------------------------------------ */

static void adc_init(void)
{
    /* AVcc reference (REFS0), prescaler /128 -> 125 kHz ADC clock */
    ADMUX  = (1 << REFS0);
    ADCSRA = (1 << ADEN) | (1 << ADPS2) | (1 << ADPS1) | (1 << ADPS0);
    (void)ADCL;
    (void)ADCH;
}

static uint16_t adc_once(uint8_t ch)
{
    ADMUX = (uint8_t)((1 << REFS0) | (ch & 0x07));
    ADCSRA |= (1 << ADSC);
    while (ADCSRA & (1 << ADSC)) { }
    return ADC;   /* reading the 16-bit macro latches ADCL then ADCH */
}

static uint32_t adc_oversample(uint8_t ch)
{
    uint32_t sum = 0;
    uint8_t i;
    (void)adc_once(ch);                 /* discard first (mux settle) */
    for (i = 0; i < OVERSAMPLE; i++)
        sum += adc_once(ch);
    return sum;
}

/* Divider: +5V -- pullup -- node -- NTC -- GND, node -> ADC.
 * ratio = sum/fullscale = R/(pullup+R)  =>  R = pullup*sum/(fullscale-sum) */
static uint32_t resistance(uint32_t sum, uint16_t pullup)
{
    if (sum == 0)
        return 0;                       /* shorted / very hot */
    if (sum >= ADC_FULLSCALE)
        return 0xFFFFFFFFUL;            /* open / disconnected */
    return (uint32_t)(((uint64_t)pullup * (uint64_t)sum) /
                      (ADC_FULLSCALE - sum));
}

/* Beta equation: 1/T = 1/T0 + ln(R/R0)/B  (T in kelvin) */
static int32_t temp_millic(uint32_t r, const ntc_ch_t *c)
{
    float rf, tk, tc;
    if (r == 0)
        return 999000;                  /* impossible, flag clearly */
    if (r == 0xFFFFFFFFUL)
        return -999000;
    rf = (float)r;
    tk = 1.0f / (1.0f / 298.15f + (float)log((double)rf / (double)c->r0) / (float)c->beta);
    tc = tk - 273.15f;
    return (int32_t)(tc * 1000.0f + (tc >= 0.0f ? 0.5f : -0.5f));
}

/* ------------------------------------------------------------------ */
/* formatting helpers (no printf on AVR)                              */
/* ------------------------------------------------------------------ */

static char *ap_u(char *p, uint32_t v)
{
    char b[11];
    const char *q = ultoa(v, b, 10);
    while (*q)
        *p++ = *q++;
    return p;
}

static char *ap_s(char *p, int32_t v)
{
    char b[12];
    const char *q = ltoa(v, b, 10);
    while (*q)
        *p++ = *q++;
    return p;
}

static uint8_t crc8(const char *s, uint8_t len)
{
    uint8_t crc = 0, i;
    while (len--) {
        crc ^= (uint8_t)*s++;
        for (i = 0; i < 8; i++)
            crc = (crc & 0x80) ? (uint8_t)((crc << 1) ^ 0x07) : (uint8_t)(crc << 1);
    }
    return crc;
}

static void banner(void)
{
    uint8_t i;
    uart_puts("\r\nNanoThermistor - dual 100k NTC node, 115200 8N1\r\n");
    for (i = 0; i < NCH; i++) {
        uart_puts("  ch");
        uart_putc((char)('0' + i));
        uart_puts(" ");
        uart_puts(chans[i].name);
        uart_puts(": A");
        uart_putc((char)('0' + chans[i].adc_ch));
        uart_puts(" pullup=");
        char b[11];
        ultoa(chans[i].pullup, b, 10);
        uart_puts(b);
        uart_puts(" R25=");
        ultoa(chans[i].r0, b, 10);
        uart_puts(b);
        uart_puts(" B=");
        ultoa(chans[i].beta, b, 10);
        uart_puts(b);
        uart_puts("\r\n");
    }
}

/* ------------------------------------------------------------------ */

int main(void)
{
    uint32_t seq = 0;
    uint8_t i;
    char buf[128];

    uart_init();
    adc_init();
    DDRB |= (1 << 5);                   /* D13 LED */
    _delay_ms(100);
    banner();

    for (;;) {
        uint32_t a[NCH], r[NCH];
        int32_t t[NCH];
        char *p = buf, *payload;
        uint8_t len, crc;

        for (i = 0; i < NCH; i++) {
            a[i] = adc_oversample(chans[i].adc_ch);
            r[i] = resistance(a[i], chans[i].pullup);
            t[i] = temp_millic(r[i], &chans[i]);
        }

        *p++ = 'T';
        *p++ = 'H';
        *p++ = ' ';
        payload = p;
        p = ap_u(p, seq++);
        *p++ = ' ';
        p = ap_u(p, a[0]);
        *p++ = ' ';
        p = ap_u(p, a[1]);
        *p++ = ' ';
        p = ap_u(p, r[0]);
        *p++ = ' ';
        p = ap_u(p, r[1]);
        *p++ = ' ';
        p = ap_s(p, t[0]);
        *p++ = ' ';
        p = ap_s(p, t[1]);
        len = (uint8_t)(p - payload);
        crc = crc8(payload, len);
        *p++ = ' ';
        p = ap_u(p, crc);
        *p++ = '\n';
        *p = '\0';
        uart_puts(buf);

        PINB |= (1 << 5);              /* heartbeat */

        /* ~500 ms, servicing any incoming command byte */
        for (i = 0; i < 50; i++) {
            if (uart_rx_ready()) {
                char c = uart_getc();
                if (c == 'i' || c == 'I')
                    banner();
            }
            _delay_ms(10);
        }
    }
}
