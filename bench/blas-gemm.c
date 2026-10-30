// The C twin of blas-gemm.nex: the same matrices, the same 20 products through `cblas_dgemm` of the
// same BLAS, timed the same way, each written over one buffer allocated once — the least a C caller
// does.
//
//     clang -O2 blas-gemm.c -framework Accelerate -o blas-gemm-c

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>

#define CBLAS_COL_MAJOR 102
#define CBLAS_NO_TRANS 111

void cblas_dgemm(int, int, int, int, int, int, double, const double *, int, const double *, int,
                 double, double *, int);

int main(void) {
    int n = 1000;
    double *a = malloc(sizeof(double) * n * n);
    double *b = malloc(sizeof(double) * n * n);
    double *c = NULL;

    for (int j = 1; j <= n; j++)
        for (int i = 1; i <= n; i++) {
            a[(i - 1) + (j - 1) * n] = 1.0 / (i + j);
            b[(i - 1) + (j - 1) * n] = (double)((i * 7 + j * 3) % 11) - 5.0;
        }

    // One product first, as the nex kernel makes `c` before the clock starts.
    c = malloc(sizeof(double) * n * n);
    cblas_dgemm(CBLAS_COL_MAJOR, CBLAS_NO_TRANS, CBLAS_NO_TRANS, n, n, n, 1.0, a, n, b, n, 0.0, c, n);

    uint64_t start = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW);

    for (int r = 0; r < 20; r++) {
        cblas_dgemm(CBLAS_COL_MAJOR, CBLAS_NO_TRANS, CBLAS_NO_TRANS, n, n, n, 1.0, a, n, b, n, 0.0, c,
                    n);
    }

    uint64_t stop = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW);

    printf("%llu\n", (unsigned long long)((stop - start) / 20000));

    double s = 0.0;

    for (int i = 0; i < n * n; i++)
        s += c[i];

    printf("%.17g\n", s);
    return 0;
}
