/*
 * libnfs_retry.c — LD_PRELOAD open-retry library for BeeGFS/NFS intermittent ENOENT
 *
 * BeeGFS on DTU HPC intermittently fails open() on files that exist:
 *   stat(path) → 0 (success, metadata cached)
 *   open(path) → ENOENT (content unavailable for a moment)
 *
 * Strategy: when open() returns ENOENT, stat() the path.
 *   - stat() also fails → genuine ENOENT (file doesn't exist) → return immediately.
 *   - stat() succeeds  → spurious ENOENT (BeeGFS bug)         → retry with delays.
 *
 * This requires NO path filtering: it works correctly on any filesystem because
 * genuine ENOENT always fails stat() too. Python's module-search misses (trying
 * a path where a module doesn't exist) return immediately after one extra stat().
 *
 * Retry timing (two-phase):
 *   Fast burst: 3 × 50ms  → catches brief metadata-cache glitches (~99% of cases)
 *   Patient:    5s + 20s  → handles longer BeeGFS fabric events
 *   Max delay if all retries fail: ~25.15s
 *
 * Functions intercepted: open, open64, openat, openat64, fopen, fopen64
 *
 * Build:
 *   gcc -O2 -Wall -fPIC -shared \
 *       -o bin/libnfs_retry.so \
 *       bin/libnfs_retry.c \
 *       -ldl -Wl,-soname,libnfs_retry.so
 */

#define _GNU_SOURCE
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <stdarg.h>
#include <stdio.h>
#include <sys/stat.h>
#include <time.h>

/* Two-phase retry delays in nanoseconds. */
static const long RETRY_WAITS_NS[] = {
    50000000L,    /* 50ms  */
    50000000L,    /* 50ms  */
    50000000L,    /* 50ms  */
    5000000000L,  /* 5s    */
    20000000000L, /* 20s   */
};
#define NUM_RETRIES (int)(sizeof(RETRY_WAITS_NS) / sizeof(RETRY_WAITS_NS[0]))

/* nanosleep() loop — handles EINTR correctly. */
static void sleep_ns(long ns)
{
    struct timespec req, rem;
    req.tv_sec  = ns / 1000000000L;
    req.tv_nsec = ns % 1000000000L;
    while (nanosleep(&req, &rem) == -1 && errno == EINTR)
        req = rem;
}

/* ── open / open64 ──────────────────────────────────────────────────────── */

typedef int (*open_fn)(const char *, int, ...);

static open_fn real_open   = NULL;
static open_fn real_open64 = NULL;

int open(const char *path, int flags, ...)
{
    if (!real_open)
        real_open = (open_fn)dlsym(RTLD_NEXT, "open");

    mode_t mode = 0;
    if (flags & O_CREAT) {
        va_list ap;
        va_start(ap, flags);
        mode = (mode_t)va_arg(ap, int);
        va_end(ap);
    }

    int fd = real_open(path, flags, mode);
    if (fd >= 0 || errno != ENOENT)
        return fd;

    /* Spurious ENOENT check: stat() succeeds iff file exists but open failed. */
    struct stat st;
    int saved = errno;
    if (stat(path, &st) != 0) {
        errno = saved; /* genuine ENOENT — restore and return */
        return -1;
    }

    for (int i = 0; i < NUM_RETRIES; i++) {
        sleep_ns(RETRY_WAITS_NS[i]);
        fd = real_open(path, flags, mode);
        if (fd >= 0 || errno != ENOENT)
            return fd;
    }
    return fd;
}

int open64(const char *path, int flags, ...)
{
    if (!real_open64)
        real_open64 = (open_fn)dlsym(RTLD_NEXT, "open64");

    mode_t mode = 0;
    if (flags & O_CREAT) {
        va_list ap;
        va_start(ap, flags);
        mode = (mode_t)va_arg(ap, int);
        va_end(ap);
    }

    int fd = real_open64(path, flags, mode);
    if (fd >= 0 || errno != ENOENT)
        return fd;

    struct stat st;
    int saved = errno;
    if (stat(path, &st) != 0) {
        errno = saved;
        return -1;
    }

    for (int i = 0; i < NUM_RETRIES; i++) {
        sleep_ns(RETRY_WAITS_NS[i]);
        fd = real_open64(path, flags, mode);
        if (fd >= 0 || errno != ENOENT)
            return fd;
    }
    return fd;
}

/* ── openat / openat64 ──────────────────────────────────────────────────── */

typedef int (*openat_fn)(int, const char *, int, ...);

static openat_fn real_openat   = NULL;
static openat_fn real_openat64 = NULL;

int openat(int dirfd, const char *path, int flags, ...)
{
    if (!real_openat)
        real_openat = (openat_fn)dlsym(RTLD_NEXT, "openat");

    mode_t mode = 0;
    if (flags & O_CREAT) {
        va_list ap;
        va_start(ap, flags);
        mode = (mode_t)va_arg(ap, int);
        va_end(ap);
    }

    int fd = real_openat(dirfd, path, flags, mode);
    if (fd >= 0 || errno != ENOENT)
        return fd;

    struct stat st;
    int saved = errno;
    if (fstatat(dirfd, path, &st, 0) != 0) {
        errno = saved;
        return -1;
    }

    for (int i = 0; i < NUM_RETRIES; i++) {
        sleep_ns(RETRY_WAITS_NS[i]);
        fd = real_openat(dirfd, path, flags, mode);
        if (fd >= 0 || errno != ENOENT)
            return fd;
    }
    return fd;
}

int openat64(int dirfd, const char *path, int flags, ...)
{
    if (!real_openat64)
        real_openat64 = (openat_fn)dlsym(RTLD_NEXT, "openat64");

    mode_t mode = 0;
    if (flags & O_CREAT) {
        va_list ap;
        va_start(ap, flags);
        mode = (mode_t)va_arg(ap, int);
        va_end(ap);
    }

    int fd = real_openat64(dirfd, path, flags, mode);
    if (fd >= 0 || errno != ENOENT)
        return fd;

    struct stat st;
    int saved = errno;
    if (fstatat(dirfd, path, &st, 0) != 0) {
        errno = saved;
        return -1;
    }

    for (int i = 0; i < NUM_RETRIES; i++) {
        sleep_ns(RETRY_WAITS_NS[i]);
        fd = real_openat64(dirfd, path, flags, mode);
        if (fd >= 0 || errno != ENOENT)
            return fd;
    }
    return fd;
}

/* ── fopen / fopen64 ────────────────────────────────────────────────────── */

typedef FILE *(*fopen_fn)(const char *, const char *);

static fopen_fn real_fopen   = NULL;
static fopen_fn real_fopen64 = NULL;

FILE *fopen(const char *path, const char *mode)
{
    if (!real_fopen)
        real_fopen = (fopen_fn)dlsym(RTLD_NEXT, "fopen");

    FILE *fp = real_fopen(path, mode);
    if (fp != NULL || errno != ENOENT)
        return fp;

    struct stat st;
    int saved = errno;
    if (stat(path, &st) != 0) {
        errno = saved;
        return NULL;
    }

    for (int i = 0; i < NUM_RETRIES; i++) {
        sleep_ns(RETRY_WAITS_NS[i]);
        fp = real_fopen(path, mode);
        if (fp != NULL || errno != ENOENT)
            return fp;
    }
    return fp;
}

FILE *fopen64(const char *path, const char *mode)
{
    if (!real_fopen64)
        real_fopen64 = (fopen_fn)dlsym(RTLD_NEXT, "fopen64");

    FILE *fp = real_fopen64(path, mode);
    if (fp != NULL || errno != ENOENT)
        return fp;

    struct stat st;
    int saved = errno;
    if (stat(path, &st) != 0) {
        errno = saved;
        return NULL;
    }

    for (int i = 0; i < NUM_RETRIES; i++) {
        sleep_ns(RETRY_WAITS_NS[i]);
        fp = real_fopen64(path, mode);
        if (fp != NULL || errno != ENOENT)
            return fp;
    }
    return fp;
}
