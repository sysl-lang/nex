/* The runtime the toolchain proofs link against: printing, in nex's spelling.
 *
 * nex prints a real the way its reference interpreter's formatValue does:
 *   nan, inf, -inf                      for the non-finite values;
 *   <integer>.0                         for a whole value below 1e15 in magnitude (so -0.0 is 0.0);
 *   Java's Double.toString otherwise    shortest round-trip digits, plain decimal for
 *                                       1e-3 <= |x| < 1e7, else d.dddE<exp>.
 * A complex is <re><sign><|im|>i, with the sign taken from im >= 0.
 *
 * Arrays arrive as MLIR memref descriptors through `llvm.emit_c_interface`, so the printer honours
 * the descriptor's offset and strides and a strided view prints with no copy.
 */

#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef struct {
    double *allocated;
    double *aligned;
    int64_t offset;
    int64_t sizes[1];
    int64_t strides[1];
} nex_memref_1d_f64;

typedef struct {
    double re;
    double im;
} nex_complex;

typedef struct {
    nex_complex *allocated;
    nex_complex *aligned;
    int64_t offset;
    int64_t sizes[1];
    int64_t strides[1];
} nex_memref_1d_c64;

/* The shortest decimal digits that read back as v (v finite, non-zero), as a digit string with no
 * point and the decimal exponent of its first digit: 0.001 is ("1", -3).
 *
 * The search starts at two digits because Java's does: its output always has two ("5.0"), so among
 * the candidates it picks the closest two-digit one, which is why the smallest subnormal is 4.9E-324
 * and not 5.0E-324. A trailing zero is dropped afterwards, so 0.5 is still ("5", -1).
 *
 * Correctly rounded %.*e is the closest decimal of each length, which is Java's choice except where
 * the rounding interval is lopsided (at a power of two) and a farther decimal of the same length
 * fits when the closest does not. A Ryu-style shortest-digits routine has no such gap. */
static void nex_shortest(double v, char *digits, int *exp10) {
    char buf[40];

    for (int p = 2; p <= 17; p++) {
        snprintf(buf, sizeof buf, "%.*e", p - 1, v);
        if (strtod(buf, NULL) == v) break;
    }

    char *d = digits;
    char *s = buf;

    if (*s == '-') s++;
    for (; *s != 'e'; s++)
        if (*s != '.') *d++ = *s;
    while (d - digits > 1 && d[-1] == '0') d--;
    *d = 0;
    *exp10 = atoi(s + 1);
}

static void nex_format_real(double v, char *out) {
    if (isnan(v)) { strcpy(out, "nan"); return; }
    if (isinf(v)) { strcpy(out, v > 0 ? "inf" : "-inf"); return; }
    if (fabs(v) < 1e15 && v == (double)(long long)v) {
        sprintf(out, "%lld.0", (long long)v);
        return;
    }

    char digits[24];
    int e;
    nex_shortest(v, digits, &e);

    int n = (int)strlen(digits);
    char *o = out;

    if (v < 0) *o++ = '-';

    if (e >= -3 && e < 7) {
        if (e < 0) {
            *o++ = '0';
            *o++ = '.';
            for (int i = -1; i > e; i--) *o++ = '0';
            memcpy(o, digits, n);
            o += n;
        } else {
            for (int i = 0; i <= e; i++) *o++ = i < n ? digits[i] : '0';
            *o++ = '.';
            if (n > e + 1) {
                memcpy(o, digits + e + 1, n - e - 1);
                o += n - e - 1;
            } else {
                *o++ = '0';
            }
        }
        *o = 0;
    } else {
        *o++ = digits[0];
        *o++ = '.';
        if (n > 1) {
            memcpy(o, digits + 1, n - 1);
            o += n - 1;
        } else {
            *o++ = '0';
        }
        sprintf(o, "E%d", e);
    }
}

static void nex_put_real(double v) {
    char out[40];
    nex_format_real(v, out);
    fputs(out, stdout);
}

static void nex_put_complex(double re, double im) {
    nex_put_real(re);
    putchar(im >= 0 ? '+' : '-');
    nex_put_real(fabs(im));
    putchar('i');
}

/* A trap writes its message to stderr and aborts, as the reference's runtime does when no
 * `assert_traps` is catching. */
void nex_trap_complex_div_zero(void) {
    fflush(stdout);
    fputs("trap: complex division by zero\n", stderr);
    abort();
}

void nex_print_int(int64_t v) {
    printf("%lld\n", (long long)v);
}

void nex_print_real(double v) {
    nex_put_real(v);
    putchar('\n');
}

void nex_print_complex(double re, double im) {
    nex_put_complex(re, im);
    putchar('\n');
}

void _mlir_ciface_nex_print_array_real(nex_memref_1d_f64 *a) {
    putchar('[');
    for (int64_t i = 0; i < a->sizes[0]; i++) {
        if (i > 0) fputs(", ", stdout);
        nex_put_real(a->aligned[a->offset + i * a->strides[0]]);
    }
    fputs("]\n", stdout);
}

void _mlir_ciface_nex_print_array_complex(nex_memref_1d_c64 *a) {
    putchar('[');
    for (int64_t i = 0; i < a->sizes[0]; i++) {
        if (i > 0) fputs(", ", stdout);
        nex_complex z = a->aligned[a->offset + i * a->strides[0]];
        nex_put_complex(z.re, z.im);
    }
    fputs("]\n", stdout);
}
