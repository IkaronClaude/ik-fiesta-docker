/* wine_sleep_tick - make Wine's Sleep() as coarse as Windows' default timer tick (LD_PRELOAD, opt-in).
 *
 * WHY: the Fiesta exes poll with short sleeps - the zone main loop calls Sleep(1) every other pass when idle
 * (SleepManager::sm_Sleep 0x5AA5E9), the DB bridges run dozens of threads looping on Sleep(2) - and none of them
 * raises the timer resolution (no timeBeginPeriod import). On Windows a Sleep(1) therefore lasts one timer tick,
 * 15.625 ms. Wine sleeps the exact millisecond, so the same loops wake ~15x as often: measured 2026-09-25 on the
 * local stack with nobody playing, Account.exe did ~61,000 context switches a second (77 threads asleep in
 * select), every DB bridge sat at ~86 % CPU and every zone at 95-140 %.
 *
 * WHAT: Wine 9's NtDelayExecution (the body of Sleep / SleepEx) waits with select(0, NULL, NULL, NULL, &tv). This
 * library wraps select() and, for exactly that shape - no descriptors, a positive timeout - rounds the timeout UP to
 * a whole number of ticks. Every other select() (real descriptors, a zero poll, no timeout) is passed through
 * untouched, and Sleep(0) / SwitchToThread are sched_yield in Wine, not select, so they are unaffected.
 *
 * ENABLE: LD_PRELOAD='/usr/$LIB/wine_sleep_tick.so' WINE_SLEEP_TICK_US=15625. Without WINE_SLEEP_TICK_US (or 0)
 * the library does nothing. Build both the i386 and x86_64 copies (build.sh): the Wine processes that run the exes
 * are i386, and ld.so's $LIB token picks the matching copy so 64-bit helpers (wineserver64, bash) load theirs
 * instead of logging a wrong-ELF-class warning.
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdlib.h>
#include <sys/select.h>

typedef int (*select_fn)(int, fd_set*, fd_set*, fd_set*, struct timeval*);

static long tick_us = -1;

static long tick(void) {
    if (tick_us < 0) {
        const char* s = getenv("WINE_SLEEP_TICK_US");
        long v = s ? strtol(s, NULL, 10) : 0;
        tick_us = v > 0 && v <= 1000000 ? v : 0;
    }
    return tick_us;
}

static long long round_up(long long us, long t) { return (us + t - 1) / t * t; }

int select(int nfds, fd_set* r, fd_set* w, fd_set* e, struct timeval* tv) {
    static select_fn real;
    if (!real) real = (select_fn)dlsym(RTLD_NEXT, "select");
    long t = tick();
    if (t && nfds == 0 && !r && !w && !e && tv) {
        long long us = (long long)tv->tv_sec * 1000000 + tv->tv_usec;
        if (us > 0) {
            long long up = round_up(us, t);
            tv->tv_sec = (long)(up / 1000000);
            tv->tv_usec = (long)(up % 1000000);
        }
    }
    return real(nfds, r, w, e, tv);
}

/* The i386 Wine on Ubuntu 24.04 is built with 64-bit time_t, and glibc then redirects select() to __select64,
 * which takes a timeval with 64-bit fields - Wine's ntdll.so imports __select64, not select (checked 2026-09-25:
 * the first build wrapped only select and changed nothing - Account.exe still did ~61,000 context switches/s). */
struct timeval64 { long long tv_sec; long long tv_usec; };
typedef int (*select64_fn)(int, fd_set*, fd_set*, fd_set*, struct timeval64*);

int __select64(int nfds, fd_set* r, fd_set* w, fd_set* e, struct timeval64* tv) {
    static select64_fn real;
    if (!real) real = (select64_fn)dlsym(RTLD_NEXT, "__select64");
    if (!real) return -1;
    long t = tick();
    if (t && nfds == 0 && !r && !w && !e && tv) {
        long long us = tv->tv_sec * 1000000 + tv->tv_usec;
        if (us > 0) {
            long long up = round_up(us, t);
            tv->tv_sec = up / 1000000;
            tv->tv_usec = up % 1000000;
        }
    }
    return real(nfds, r, w, e, tv);
}
