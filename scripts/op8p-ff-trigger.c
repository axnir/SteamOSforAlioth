/* 免 libc 的 aarch64 FF 触发器：给 aw8697（input event2）上传一个 FF_RUMBLE 并播放。
 *
 * 历史：这个文件的偏移一共错过两次，两次的表现都是「EVIOCSFF 返回 0、dmesg
 * 干净、马达一动不动」，而且都不报错：
 *   第一版：input_event 的 type 写在偏移 8（实际 16），播放事件根本没发出去；
 *   第二版：照着「ff_effect 里 length 大约在 18、strong 在 24」推测着改，
 *           而在这套内核头上 replay.length 在 10、strong 在 16 —— 写进 24
 *           就落进 union 之前/之后的 padding，驱动读到 level=0，与初值相同，
 *           play_effect 直接 return（不播放、不报错）。
 *
 * 结论：**偏移必须量，不能推。** 下面每个数字都是在 aarch64 + 这套内核头里用
 * offsetof 打印出来的（容器里 gcc + <linux/input.h>）：
 *
 *   sizeof(struct ff_effect) = 48
 *     0   __u16 type
 *     2   __s16 id            <- EVIOCSFF 会把驱动分配的 id 写回这里
 *     4   __u16 direction
 *    10   replay.length (__u16)
 *    12   replay.delay  (__u16)
 *    16   u.rumble.strong_magnitude (__u16)
 *    18   u.rumble.weak_magnitude   (__u16)
 *
 *   sizeof(struct input_event) = 24
 *     0   struct timeval time（16 字节：tv_sec@0, tv_usec@8）
 *    16   __u16 type          <- EV_FF = 0x15，不是 0x1f
 *    18   __u16 code          <- 效果 id
 *    20   __s32 value         <- 1 播放 / 0 停止
 *
 *   nanosleep 的 timespec：tv_sec@0（8 字节），tv_nsec@8（8 字节）。
 *   800 ms = 800000000 ns = 0x2FAF0800，写成 0x02F5AF0800 就是 12.7 秒。
 *
 * 编译（容器里有原生 aarch64 gcc）：
 *   gcc -O2 -nostdlib -static -o ffplay ffplay.c
 */
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
    eff[2] = 0xff; eff[3] = 0xff;   /* id = -1（新建） */
    eff[4] = 0x00; eff[5] = 0x40;   /* direction = 0x4000 */
    /* 下面的偏移是**量出来的**，不是推的：在 aarch64 + 这套内核头下
     * offsetof(struct ff_effect, replay.length) = 10、strong = 16、weak = 18、
     * sizeof = 48（trigger 只占 4 字节，envelope 在 union 里）。
     * 之前两版各错一半：一版 strong 对但事件偏移错，另一版事件对却把 strong
     * 写到 24（padding 区）→ 驱动读到 level=0 → 与初值相同 → 直接 return。 */
    eff[10] = 0x20; eff[11] = 0x03; /* replay.length = 800 ms */
    eff[16] = 0xff; eff[17] = 0xff; /* strong_magnitude = 0xFFFF（满量程） */
    eff[18] = 0xff; eff[19] = 0xff; /* weak_magnitude   = 0xFFFF */

    /* EVIOCSFF；失败则用旧尺寸 0x40204580 再试一次，用退出码报原因 */
    if (sys6(29, fd, 0x40304580L, (long)eff, 0L, 0L, 0L) < 0) {
        long e = -(sys6(29, fd, 0x40204580L, (long)eff, 0L, 0L, 0L));
        if (e > 90) e = 90;
        sys6(93, 90L + e, 0L, 0L, 0L, 0L, 0L);
    }

    ev[16] = 0x15; ev[17] = 0x00;      /* type = EV_FF */
    ev[18] = eff[2]; ev[19] = eff[3];  /* code = 驱动分配的 id */
    ev[20] = 0x01;                     /* value = 1（播放） */
    sys6(64, fd, (long)ev, 24L, 0L, 0L, 0L);

    ts[8] = 0x00; ts[9] = 0x08; ts[10] = 0xaf; ts[11] = 0x2f; /* 800 ms */
    sys6(101, (long)ts, 0L, 0L, 0L, 0L, 0L);

    ev[20] = 0x00;                     /* value = 0（停止） */
    sys6(64, fd, (long)ev, 24L, 0L, 0L, 0L);
    sys6(57, fd, 0L, 0L, 0L, 0L, 0L);
    sys6(93, 0L, 0L, 0L, 0L, 0L, 0L);
}
