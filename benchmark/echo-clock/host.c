#define _POSIX_C_SOURCE 200809L
#include "roc_platform_abi.h"
#include "mimalloc.h"

#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

static _Noreturn void fail(const char *message) {
    fprintf(stderr, "echo-clock: %s\n", message);
    exit(1);
}

/* Link mimalloc directly: no libc allocator or preload dependency. */
void *roc_alloc(size_t length, size_t alignment) {
    void *ptr = alignment <= _Alignof(max_align_t)
        ? mi_malloc(length ? length : 1)
        : mi_malloc_aligned(length ? length : 1, alignment);
    if (!ptr) fail("out of memory");
    return ptr;
}

void roc_dealloc(void *ptr, size_t alignment) {
    (void)alignment;
    mi_free(ptr);
}

void *roc_realloc(void *ptr, size_t length, size_t alignment) {
    void *result = alignment <= _Alignof(max_align_t)
        ? mi_realloc(ptr, length ? length : 1)
        : mi_realloc_aligned(ptr, length ? length : 1, alignment);
    if (!result) fail("out of memory");
    return result;
}

/* Hosted calls own their Roc arguments. Heap strings, including seamless
 * slices, must release that reference after echo; static strings have rc=0. */
void roc_echo(RocStr str) {
    const uint8_t *inline_bytes = (const uint8_t *)&str;
    bool small = (inline_bytes[sizeof(str) - 1] & 0x80) != 0;
    size_t length = small ? inline_bytes[sizeof(str) - 1] & 0x7f : str.length;
    const uint8_t *bytes = small ? inline_bytes : str.bytes;
    if ((length && fwrite(bytes, 1, length, stdout) != length) ||
        fputc('\n', stdout) == EOF) fail("stdout write failed");
    if (!small && str.bytes) {
        uint8_t *allocation = (str.capacity_or_alloc_ptr & 1)
            ? (uint8_t *)(str.capacity_or_alloc_ptr & ~(uintptr_t)1) : str.bytes;
        size_t *rc = (size_t *)allocation - 1;
        if (*rc != 0 && --*rc == 0) roc_dealloc(rc, _Alignof(size_t));
    }
}

uint64_t roc_now(void) {
    struct timespec ts;
    if (clock_gettime(CLOCK_MONOTONIC, &ts) != 0) fail("monotonic clock failed");
    return (uint64_t)ts.tv_sec * UINT64_C(1000000000) + (uint64_t)ts.tv_nsec;
}

void roc_dbg(const uint8_t *bytes, size_t length) {
    fwrite(bytes, 1, length, stderr);
    fputc('\n', stderr);
}

void roc_expect_failed(const uint8_t *bytes, size_t length) {
    roc_dbg(bytes, length);
    exit(1);
}

void roc_crashed(const uint8_t *bytes, size_t length) {
    roc_dbg(bytes, length);
    exit(1);
}

int main(int argc, char **argv) {
    uint64_t argument = 0;
    if (argc > 2) fail("expected at most one unsigned integer argument");
    if (argc == 2) {
        char *end;
        errno = 0;
        unsigned long long value = strtoull(argv[1], &end, 10);
        if (errno || !argv[1][0] || *end || argv[1][0] == '-')
            fail("invalid unsigned integer argument");
        argument = (uint64_t)value;
    }
    roc_main(argument);
    if (fflush(stdout) == EOF) fail("stdout flush failed");
    return 0;
}
