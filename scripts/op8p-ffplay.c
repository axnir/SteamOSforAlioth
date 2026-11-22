/* freestanding aarch64 FF trigger for bq... aw8697 (input event2) */
typedef unsigned int u32; typedef unsigned short u16; typedef long long s64;

static long sys6(long n, long a, long b, long c, long d, long e, long f) {
    register long x8 __asm__("x8") = n;
    register long x0 __asm__("x0") = a;
    register long x1 __asm__("x1") = b;
    register long x2 __asm__("x2") = c;
    register long x3 __asm__("x3") = d;
    register long x4 __asm__("x4") = e;
    register long x5 __asm__("x5") = f;
    __asm__ volatile("svc #0" : "+r"(x0) :
        "r"(x8), "r"(x1), "r"(x2), "r"(x3), "r"(x4), "r"(x5) : "memory", "cc");
    return x0;
}

void _start(void) {
    unsigned char eff[48];
    unsigned char ev[24];
    unsigned char ts[16];
    int i;
    long fd = sys6(56, -100L, (long)"/dev/input/event2", 2L, 0L, 0L, 0L); /* openat O_RDWR */
    if (fd < 0) sys6(93, 1L, 0L, 0L, 0L, 0L, 0L);
    for (i = 0; i < 48; i++) eff[i] = 0;
    for (i = 0; i < 24; i++) ev[i] = 0;
    for (i = 0; i < 16; i++) ts[i] = 0;
    eff[0] = 0x50; eff[1] = 0x00;   /* type = FF_RUMBLE */
    eff[2] = 0xff; eff[3] = 0xff;   /* id = -1 (new effect) */
    eff[4] = 0x00; eff[5] = 0x40;   /* direction = 0x4000 */
    eff[12] = 0x20; eff[13] = 0x03; /* replay.length = 800 ms */
    eff[16] = 0x00; eff[17] = 0x80; /* strong_magnitude = 0x8000 */
    eff[18] = 0x00; eff[19] = 0x40; /* weak_magnitude = 0x4000 */
    if (sys6(29, fd, 0x40304580L, (long)eff, 0L, 0L, 0L) < 0) { long e = -(sys6(29, fd, 0x40204580L, (long)eff, 0L, 0L, 0L)); if (e > 90) e = 90; sys6(93, 90L + e, 0L, 0L, 0L, 0L, 0L); }
    ev[8] = 0x1f; ev[9] = 0x00;     /* type = EV_FF */
    ev[10] = eff[2]; ev[11] = eff[3]; /* code = assigned effect id */
    ev[14] = 0x01;                  /* value = 1 (play) */
    sys6(64, fd, (long)ev, 24L, 0L, 0L, 0L);
    ts[8] = 0x00; ts[9] = 0x08; ts[10] = 0xaf; ts[11] = 0xf5; ts[12] = 0x02; /* 800ms */
    sys6(101, (long)ts, 0L, 0L, 0L, 0L, 0L);
    ev[14] = 0x00; ev[18] = 0x00;   /* value = 0 (stop) */
    sys6(64, fd, (long)ev, 24L, 0L, 0L, 0L);
    sys6(57, fd, 0L, 0L, 0L, 0L, 0L);
    sys6(93, 0L, 0L, 0L, 0L, 0L, 0L);
}
