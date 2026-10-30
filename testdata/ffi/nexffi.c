// The C library the FFI tests call: `clang -c` builds it and `llvm-ar` archives it as `libnexffi.a`,
// which a program links with `@link("nexffi")` and `-L` naming its directory. Each function has the
// shape of a real C or BLAS interface, so a wrong pointer, stride, extension or register shows up as
// a wrong number.

#include <complex.h>
#include <pthread.h>
#include <stdbool.h>
#include <stdint.h>
#include <string.h>

#include "../../include/nex_desc.h"

// BLAS's `ddot`: `x` and `y` read every `incx`-th and `incy`-th element.
double nf_ddot(int32_t n, const double *x, int32_t incx, const double *y, int32_t incy) {
    double s = 0.0;
    for (int32_t i = 0; i < n; i++) s += x[i * incx] * y[i * incy];
    return s;
}

// BLAS's `dscal`: every `incx`-th element of `x` multiplied by `a`, in place.
void nf_dscal(int32_t n, double a, double *x, int32_t incx) {
    for (int32_t i = 0; i < n; i++) x[i * incx] *= a;
}

// BLAS's `dswap`, at unit stride: `x` and `y` exchanged.
void nf_dswap(int32_t n, double *x, double *y) {
    for (int32_t i = 0; i < n; i++) {
        double t = x[i];
        x[i] = y[i];
        y[i] = t;
    }
}

// `n` contiguous elements weighted by position, so a misplaced one changes the sum.
double nf_weighted(int32_t n, const double *x) {
    double s = 0.0;
    for (int32_t i = 0; i < n; i++) s += (i + 1) * x[i];
    return s;
}

// `x[i] = 10 * (i + 1)` over `n` contiguous elements.
void nf_fill(int32_t n, double *x) {
    for (int32_t i = 0; i < n; i++) x[i] = 10.0 * (i + 1);
}

// An `m` by `n` column-major matrix with leading dimension `lda`, each element weighted by its row
// and column.
double nf_mat_weighted(int32_t m, int32_t n, const double *a, int32_t lda) {
    double s = 0.0;
    for (int32_t j = 0; j < n; j++)
        for (int32_t i = 0; i < m; i++) s += (i + 1) * 100.0 * (j + 1) * a[i + j * lda];
    return s;
}

// Every element of an `m` by `n` column-major matrix with leading dimension `lda` incremented.
void nf_mat_bump(int32_t m, int32_t n, double *a, int32_t lda) {
    for (int32_t j = 0; j < n; j++)
        for (int32_t i = 0; i < m; i++) a[i + j * lda] += 1.0;
}

// An `n1` by `n2` by `n3` dense column-major block, each element weighted by its position.
double nf_block_weighted(int32_t n1, int32_t n2, int32_t n3, const double *a) {
    double s = 0.0;
    for (int32_t k = 0; k < n1 * n2 * n3; k++) s += (k + 1) * a[k];
    return s;
}

// Where an array's first element lies, so a program can tell a copy from the array itself.
int64_t nf_addr(const double *x) { return (int64_t)(intptr_t)x; }
int64_t nf_addr2(const double *x) { return (int64_t)(intptr_t)x; }
int64_t nf_addr_strided(const double *x) { return (int64_t)(intptr_t)x; }

void nf_iota(int32_t n, int32_t *a) {
    for (int32_t i = 0; i < n; i++) a[i] = i + 1;
}

int32_t nf_count_true(int32_t n, const bool *b) {
    int32_t c = 0;
    for (int32_t i = 0; i < n; i++) c += b[i] ? 1 : 0;
    return c;
}

double _Complex nf_csum(int32_t n, const double _Complex *z) {
    double _Complex s = 0;
    for (int32_t i = 0; i < n; i++) s += (i + 1) * z[i];
    return s;
}

// Scalars of every width, each passed and returned as C's ABI has it.
int8_t nf_neg8(int8_t x) { return (int8_t)-x; }
uint8_t nf_inc8(uint8_t x) { return (uint8_t)(x + 1); }
int16_t nf_neg16(int16_t x) { return (int16_t)-x; }
uint16_t nf_inc16(uint16_t x) { return (uint16_t)(x + 1); }
int64_t nf_mul64(int64_t a, int64_t b) { return a * b; }
uint32_t nf_xor32(uint32_t a, uint32_t b) { return a ^ b; }
bool nf_not(bool b) { return !b; }
float nf_halve32(float x) { return x / 2.0f; }
_Float16 nf_twice16(_Float16 x) { return x * 2; }

// The sum of each of eleven narrow arguments read at its own width: the caller's widening shows.
int64_t nf_narrow_sum(int8_t a, uint8_t b, int16_t c, uint16_t d, bool e, int8_t f, uint8_t g,
                      int16_t h, uint16_t i, bool j, int8_t k) {
    return (int64_t)a + b + c + d + e + f + g + h + i + j + k;
}

// `inout` scalars: C writes through the pointers.
void nf_divmod(int32_t a, int32_t b, int32_t *q, int32_t *r) {
    *q = a / b;
    *r = a % b;
}

void nf_accumulate(double x, double *total, int64_t *count) {
    *total += x;
    *count += 1;
}

int32_t nf_strlen(const char *s) { return (int32_t)strlen(s); }

// Complexes by value: more than fit the eight FP argument registers, and a `float _Complex`.
double _Complex nf_cmul(double _Complex a, double _Complex b) { return a * b; }
float _Complex nf_cconj32(float _Complex z) { return conjf(z); }
double _Complex nf_cpoly(double _Complex a, double _Complex b, double _Complex c, double _Complex d,
                         double _Complex e, double x) {
    return a + 2 * b + 3 * c + 4 * d + 5 * e + x;
}

// A struct C lays out with padding after `live` and `tag`, and one holding it.
typedef struct {
    int32_t id;
    double mass;
    bool live;
    int8_t tag;
    double _Complex z;
    float w;
} Body;

typedef struct {
    Body a;
    int16_t n;
    Body b;
} Pair;

double nf_body_read(const Body *b) {
    return b->id * 1000.0 + b->mass + (b->live ? 0.5 : 0.0) + b->tag * 0.01 + creal(b->z) * 100.0 +
           cimag(b->z) * 10.0 + b->w;
}

void nf_body_step(Body *b) {
    b->id += 1;
    b->mass *= 2.0;
    b->live = !b->live;
    b->tag = (int8_t)(b->tag - 3);
    b->z = b->z * I;
    b->w += 0.25f;
}

void nf_pair_swap(Pair *p) {
    Body t = p->a;
    p->a = p->b;
    p->b = t;
    p->n = (int16_t)(p->n * -2);
}

int64_t nf_sizeof_body(void) { return (int64_t)sizeof(Body); }

// Composite Simpson's rule over [a, b] in n panels (n even), of f with its user data, as GSL's
// integrators take a function and a `void *`.
double nf_integrate(double (*f)(double, void *), void *data, double a, double b, int32_t n) {
    double h = (b - a) / n;
    double s = f(a, data) + f(b, data);
    for (int32_t i = 1; i < n; i++) s += f(a + i * h, data) * (i % 2 ? 4.0 : 2.0);
    return s * h / 3.0;
}

// The same with a bare function pointer.
double nf_integrate_plain(double (*f)(double), double a, double b, int32_t n) {
    double h = (b - a) / n;
    double s = f(a) + f(b);
    for (int32_t i = 1; i < n; i++) s += f(a + i * h) * (i % 2 ? 4.0 : 2.0);
    return s * h / 3.0;
}

// x[0..n) sorted by cmp, with qsort's contract: negative, zero or positive.
void nf_sort(int32_t n, double *x, int32_t (*cmp)(double, double)) {
    for (int32_t i = 1; i < n; i++)
        for (int32_t j = i; j > 0 && cmp(x[j - 1], x[j]) > 0; j--) {
            double t = x[j];
            x[j] = x[j - 1];
            x[j - 1] = t;
        }
}

// The same with the user data first, where BSD's qsort_r passes it.
void nf_sort_r(int32_t n, double *x, void *data, int32_t (*cmp)(void *, double, double)) {
    for (int32_t i = 1; i < n; i++)
        for (int32_t j = i; j > 0 && cmp(data, x[j - 1], x[j]) > 0; j--) {
            double t = x[j];
            x[j] = x[j - 1];
            x[j - 1] = t;
        }
}

// f applied twice: a complex crossing to the callback and back by value.
double _Complex nf_twice(double _Complex (*f)(double _Complex), double _Complex z) { return f(f(z)); }

float _Complex nf_twice32(float _Complex (*f)(float _Complex, void *), void *data, float _Complex z) {
    return f(f(z, data), data);
}

// How many of x[0..n) pred holds for: narrow integers and a bool crossing to the callback and back.
int32_t nf_count_if(int32_t n, const int8_t *x, bool (*pred)(int8_t, uint16_t, void *), void *data, uint16_t k) {
    int32_t c = 0;
    for (int32_t i = 0; i < n; i++)
        if (pred(x[i], k, data)) c++;
    return c;
}

// f(k) for k = 1 … n, a callback with no result.
void nf_each(int32_t n, void (*f)(int32_t, void *), void *data) {
    for (int32_t k = 1; k <= n; k++) f(k, data);
}

// f(1) + … + f(n), and how many calls C made, whatever the callbacks did.
static int32_t calls_made;

double nf_sum_calls(double (*f)(double, void *), void *data, int32_t n) {
    double s = 0.0;
    calls_made = 0;
    for (int32_t k = 1; k <= n; k++) {
        s += f(k, data);
        calls_made++;
    }
    return s;
}

int32_t nf_calls_made(void) { return calls_made; }

// f(x) called on a thread C starts.
typedef struct {
    double (*f)(double);
    double x;
    double y;
} Job;

static void *run_job(void *p) {
    Job *j = p;
    j->y = j->f(j->x);
    return NULL;
}

double nf_call_on_thread(double (*f)(double), double x) {
    Job j = {f, x, 0.0};
    pthread_t t;
    pthread_create(&t, NULL, run_job, &j);
    pthread_join(t, NULL);
    return j.y;
}

// A callback C keeps past the call that passed it, and calls later.
static double (*kept)(double);

void nf_keep(double (*f)(double)) { kept = f; }

double nf_call_kept(double x) { return kept(x); }

// -- `[*; ..]` descriptors (nex DESIGN §10.7) ---------------------------------------------------------

// The value of part `part` (0 the real part, 1 the imaginary) of the element at `p` of type `type`.
static double desc_part(int32_t type, const char *p, int part) {
    switch (type) {
    case NEX_INT8: return *(const int8_t *)p;
    case NEX_INT16: return *(const int16_t *)p;
    case NEX_INT32: return *(const int32_t *)p;
    case NEX_INT64: return (double)*(const int64_t *)p;
    case NEX_UINT8: return *(const uint8_t *)p;
    case NEX_UINT16: return *(const uint16_t *)p;
    case NEX_UINT32: return *(const uint32_t *)p;
    case NEX_UINT64: return (double)*(const uint64_t *)p;
    case NEX_REAL16: return (double)*(const _Float16 *)p;
    case NEX_REAL32: return *(const float *)p;
    case NEX_REAL64: return *(const double *)p;
    case NEX_COMPLEX_REAL16: return (double)((const _Float16 *)p)[part];
    case NEX_COMPLEX_REAL32: return ((const float *)p)[part];
    case NEX_COMPLEX_REAL64: return ((const double *)p)[part];
    case NEX_BOOL: return *(const uint8_t *)p;
    default: return -1.0;
    }
}

// The element at `p` of type `type` set to `v`, an imaginary part of `-v` where it is complex, and
// a `bool` true where `v` is odd.
static void desc_store(int32_t type, char *p, int64_t v) {
    switch (type) {
    case NEX_INT8: *(int8_t *)p = (int8_t)v; break;
    case NEX_INT16: *(int16_t *)p = (int16_t)v; break;
    case NEX_INT32: *(int32_t *)p = (int32_t)v; break;
    case NEX_INT64: *(int64_t *)p = v; break;
    case NEX_UINT8: *(uint8_t *)p = (uint8_t)v; break;
    case NEX_UINT16: *(uint16_t *)p = (uint16_t)v; break;
    case NEX_UINT32: *(uint32_t *)p = (uint32_t)v; break;
    case NEX_UINT64: *(uint64_t *)p = (uint64_t)v; break;
    case NEX_REAL16: *(_Float16 *)p = (_Float16)v; break;
    case NEX_REAL32: *(float *)p = (float)v; break;
    case NEX_REAL64: *(double *)p = (double)v; break;
    case NEX_COMPLEX_REAL16: ((_Float16 *)p)[0] = (_Float16)v; ((_Float16 *)p)[1] = (_Float16)-v; break;
    case NEX_COMPLEX_REAL32: ((float *)p)[0] = (float)v; ((float *)p)[1] = (float)-v; break;
    case NEX_COMPLEX_REAL64: ((double *)p)[0] = (double)v; ((double *)p)[1] = (double)-v; break;
    case NEX_BOOL: *(uint8_t *)p = (uint8_t)(v & 1); break;
    }
}

// The next index of `d` in column-major order, nex's first axis fastest.
static void desc_next(const nex_desc *d, int64_t *idx) {
    for (int32_t k = 0; k < d->rank; k++) {
        if (++idx[k] < d->dim[k].extent) return;
        idx[k] = 0;
    }
}

// What `d` says, written to `out` for nex to print: its type code, element size, rank, contiguity
// and writability, each axis's extent and byte stride, then every element in column-major order,
// a complex as its two parts. The count written.
int32_t nf_desc_read(const nex_desc *d, double *out) {
    int32_t n = 0;
    out[n++] = d->type;
    out[n++] = (double)d->elem_size;
    out[n++] = d->rank;
    out[n++] = d->contiguous;
    out[n++] = d->writable;
    for (int32_t k = 0; k < d->rank; k++) {
        out[n++] = (double)d->dim[k].extent;
        out[n++] = (double)d->dim[k].stride;
    }
    int64_t idx[16] = {0};
    int parts = d->type >= NEX_COMPLEX_REAL16 && d->type <= NEX_COMPLEX_REAL64 ? 2 : 1;
    for (int64_t e = 0; e < nex_desc_count(d); e++) {
        const char *p = nex_desc_at(d, idx);
        out[n++] = desc_part(d->type, p, 0);
        if (parts == 2) out[n++] = desc_part(d->type, p, 1);
        desc_next(d, idx);
    }
    return n;
}

// The number of elements `d` describes.
int64_t nf_desc_count(const nex_desc *d) { return nex_desc_count(d); }

// Every element of a writable `d` set to its position in column-major order, from 1.
void nf_desc_fill(const nex_desc *d) {
    if (!d->writable) return;
    int64_t idx[16] = {0};
    for (int64_t e = 0; e < nex_desc_count(d); e++) {
        desc_store(d->type, nex_desc_at(d, idx), e + 1);
        desc_next(d, idx);
    }
}

// Two descriptors in one call: the elements of `b` added into `a`, both real64 of one shape.
void nf_desc_add(const nex_desc *a, const nex_desc *b) {
    int64_t idx[16] = {0};
    for (int64_t e = 0; e < nex_desc_count(a); e++) {
        *(double *)nex_desc_at(a, idx) += *(const double *)nex_desc_at(b, idx);
        desc_next(a, idx);
    }
}
