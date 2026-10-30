// A counter of large heap allocations, loaded into a benchmark with `DYLD_INSERT_LIBRARIES`, so that
// the nex kernel and its Fortran twin are measured by one instrument: every `malloc`, `calloc`,
// `realloc`, `posix_memalign` and `aligned_alloc` of at least `ALLOC_COUNT_MIN` bytes (1 MiB by
// default) is counted, and the count is written to standard error at exit as `large allocations: N`.
// A kernel's arrays are 10⁷ elements, so a temporary the size of one is counted and a string or a
// small buffer is not.
//
//     clang -O2 -dynamiclib alloc-count.c -o alloc-count.dylib

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static size_t threshold = 1u << 20;
static volatile long large = 0;

static void note(size_t n) {
    if (n >= threshold) __atomic_add_fetch(&large, 1, __ATOMIC_RELAXED);
}

static void *count_malloc(size_t n) {
    note(n);
    return malloc(n);
}

static void *count_calloc(size_t k, size_t n) {
    note(k * n);
    return calloc(k, n);
}

static void *count_realloc(void *p, size_t n) {
    note(n);
    return realloc(p, n);
}

static int count_posix_memalign(void **p, size_t a, size_t n) {
    note(n);
    return posix_memalign(p, a, n);
}

static void *count_aligned_alloc(size_t a, size_t n) {
    note(n);
    return aligned_alloc(a, n);
}

// dyld's interposing table: each pair is (replacement, original).
__attribute__((used)) static struct {
    const void *replacement;
    const void *original;
} interposers[] __attribute__((section("__DATA,__interpose"))) = {
    {(const void *)count_malloc, (const void *)malloc},
    {(const void *)count_calloc, (const void *)calloc},
    {(const void *)count_realloc, (const void *)realloc},
    {(const void *)count_posix_memalign, (const void *)posix_memalign},
    {(const void *)count_aligned_alloc, (const void *)aligned_alloc},
};

__attribute__((constructor)) static void start(void) {
    const char *min = getenv("ALLOC_COUNT_MIN");

    if (min != NULL) threshold = (size_t)strtoull(min, NULL, 10);
}

__attribute__((destructor)) static void report(void) {
    char line[64];
    int len = snprintf(line, sizeof line, "large allocations: %ld\n", large);

    write(2, line, (size_t)len);
}
