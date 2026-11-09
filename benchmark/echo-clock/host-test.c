#define _POSIX_C_SOURCE 200809L
#include "mimalloc.h"
#include <assert.h>
#include <stdint.h>
#include <string.h>

/* Count actual releases without changing the allocator under test. */
static size_t frees;
static void counted_free(void *ptr) { frees++; mi_free(ptr); }
#define mi_free counted_free
#define main platform_main
#include "host.c"
#undef main
#undef mi_free

void roc_main(uint64_t argument) { (void)argument; }

int main(void) {
    for (size_t alignment = 1; alignment <= 256; alignment *= 2) {
        uint8_t *p = roc_alloc(37, alignment);
        assert((uintptr_t)p % alignment == 0);
        assert(mi_is_in_heap_region(p));
        memset(p, 0x5a, 37);
        p = roc_realloc(p, 4096, alignment);
        assert((uintptr_t)p % alignment == 0);
        for (size_t i = 0; i < 37; i++) assert(p[i] == 0x5a);
        p = roc_realloc(p, 7, alignment);
        assert((uintptr_t)p % alignment == 0);
        for (size_t i = 0; i < 7; i++) assert(p[i] == 0x5a);
        p = roc_realloc(p, 0, alignment);
        assert(p != NULL);
        roc_dealloc(p, alignment);
        p = roc_alloc(0, alignment);
        assert(p != NULL);
        roc_dealloc(p, alignment);
    }
    size_t before = frees;
    RocStr small = {0};
    memcpy(&small, "a\0b", 3);
    ((uint8_t *)&small)[sizeof(small) - 1] = 0x83;
    roc_echo(small);
    assert(frees == before);

    /* A static long string must never be released. */
    static struct { size_t rc; uint8_t bytes[32]; } constant = {0, "abcdefghijklmnopqrstuvwxyz"};
    roc_echo((RocStr){.bytes = constant.bytes, .length = 26});
    assert(constant.rc == 0 && frees == before);

    /* Two owned references, the second a slice: release exactly once, using
     * the original allocation rather than the slice's visible start. */
    size_t *rc = roc_alloc(sizeof(size_t) + 26, _Alignof(size_t));
    *rc = 2;
    uint8_t *bytes = (uint8_t *)(rc + 1);
    memcpy(bytes, constant.bytes, 26);
    roc_echo((RocStr){.bytes = bytes, .capacity_or_alloc_ptr = 26 << 1, .length = 26});
    assert(*rc == 1 && frees == before);
    roc_echo((RocStr){.bytes = bytes + 2, .capacity_or_alloc_ptr = (uintptr_t)bytes | 1, .length = 24});
    assert(frees == before + 1);

    uint64_t first = roc_now(), previous = first;
    for (size_t i = 0; i < 10000; i++) {
        uint64_t next = roc_now();
        assert(next >= previous);
        previous = next;
    }
    assert(previous > first);
    fprintf(stderr, "PASS allocation, echo ownership, monotonic clock\n");
    return 0;
}
