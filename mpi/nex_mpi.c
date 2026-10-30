/*
 * The shim of nex's `mpi` module (DESIGN §9.6): the one place that includes `mpi.h`.
 *
 * It is compiled by the MPI the program links against (`mpicc`, or the flags `pkg-config` gives),
 * so every handle and constant here is that implementation's own, read from its header. What it
 * hands nex is what nex can hold: a communicator as its Fortran handle (`MPI_Comm_c2f`), an `int32`
 * in every MPI, and a constant as an integer.
 *
 * `nex_mpi_init` is called by the program's C `main` before anything else runs. It initialises MPI
 * and tells the runtime which rank this process is and how to end the job (`nex_mpi_joined`): the
 * runtime ends it with `MPI_Abort` after a trap nothing caught or `stop n` with `n` not zero, and
 * with `MPI_Finalize` when `main` returns or `stop 0` runs.
 *
 * Every buffer arrives as a `nex_desc` (`nex_desc.h`, DESIGN §10.7): any element type, any rank, a
 * window or a strided view. A point-to-point buffer moves where it lies: a dense block as its bytes,
 * any other view as an MPI datatype built from the descriptor's extents and byte strides and cached
 * (`buffer_of`), so nothing is copied; a collective packs its operand in nex's element order. The
 * `exchange` block's requests are kept per open block until its end waits for them, or a trap
 * leaving it cancels them. The collectives the compiler types (`elab_mpi.sysl`) check that the ranks'
 * shapes agree before any data moves, every rank seeing every rank's shape, so a mismatch traps on
 * all of them with the same message. A reduction with a built-in operator combines the ranks'
 * contributions here, in DESIGN §9.2.1's pairwise tree over the rank numbers, so its bits do not
 * depend on how the MPI brackets a sum; `fast` hands it to the MPI's own operator instead.
 */

#include <mpi.h>
#include <limits.h>
#include <math.h>
#include <pthread.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "nex_desc.h"

/* Each product and sum rounded on its own, as nex computes them: never fused into one. */
#pragma STDC FP_CONTRACT OFF

/* The runtime's: this process is rank `rank`, the two ways its part in the job ends, and what a
 * caught trap calls before it frees the arrays of the frames it leaves (`unwound`, below). */
extern void nex_mpi_joined(int32_t rank, void (*abort_job)(int32_t), void (*finalize_job)(void), void (*unwind)(int32_t));

static void unwound(int32_t depth);

/* The thread that joined the job, the only one that calls MPI. */
static pthread_t joining_thread;

/* The runtime's trap, which writes the message with the rank in front and ends the job, or returns
 * to an `assert_traps` that catches it. */
extern void nex_trap(const char *message) __attribute__((noreturn));

static void abort_job(int32_t code) {
    MPI_Abort(MPI_COMM_WORLD, code);
    /* MPI_Abort does not return; were an implementation's to, the process still ends. */
    _Exit(code);
}

static void finalize_job(void) {
    int finalized = 0;

    MPI_Finalized(&finalized);
    if (!finalized) MPI_Finalize();
}

void nex_mpi_init(void) {
    int provided = 0;
    int rank = 0;

    if (MPI_Init_thread(NULL, NULL, MPI_THREAD_SINGLE, &provided) != MPI_SUCCESS) {
        fputs("trap: mpi: MPI_Init_thread failed\n", stderr);
        exit(134);
    }

    MPI_Comm_rank(MPI_COMM_WORLD, &rank);
    joining_thread = pthread_self();
    nex_mpi_joined(rank, abort_job, finalize_job, unwound);
}

static MPI_Comm comm_of(int32_t comm) { return MPI_Comm_f2c((MPI_Fint) comm); }

int32_t nex_mpi_world(void) { return (int32_t) MPI_Comm_c2f(MPI_COMM_WORLD); }

int32_t nex_mpi_self(void) { return (int32_t) MPI_Comm_c2f(MPI_COMM_SELF); }

int64_t nex_mpi_rank(int32_t comm) {
    int rank = 0;

    MPI_Comm_rank(comm_of(comm), &rank);
    return rank;
}

int64_t nex_mpi_size(int32_t comm) {
    int size = 0;

    MPI_Comm_size(comm_of(comm), &size);
    return size;
}

void nex_mpi_barrier(int32_t comm) { MPI_Barrier(comm_of(comm)); }

int64_t nex_mpi_proc_null(void) { return MPI_PROC_NULL; }

int64_t nex_mpi_any_source(void) { return MPI_ANY_SOURCE; }

int64_t nex_mpi_any_tag(void) { return MPI_ANY_TAG; }

/* -- traps ------------------------------------------------------------------------------------ */

/* A trap's message, kept where the runtime can read it after this frame is gone. */
static char message[512];

#define TRAP(...)                                             \
    do {                                                      \
        snprintf(message, sizeof message, __VA_ARGS__);       \
        nex_trap(message);                                    \
    } while (0)

/* The collectives in the order `elab_mpi.sysl`'s `COLLECTIVES` gives their codes. */
enum {
    ALLREDUCE, REDUCE_TO, SCAN, BCAST, GATHER, ALLGATHER, GATHER_CONCAT, ALLGATHER_CONCAT, SCATTER,
    SCATTER_CONCAT, ALLTOALL, GLOBAL_SUM, GLOBAL_DOT, GLOBAL_NORM2
};

static const char *const NAMES[] = {
    "allreduce", "reduce_to", "scan", "bcast", "gather", "allgather", "gather_concat",
    "allgather_concat", "scatter", "scatter_concat", "alltoall", "global_sum", "global_dot",
    "global_norm2"
};

/* The built-in operators, by `elab_mpi.sysl`'s codes. */
enum { OP_ADD = 1, OP_MUL, OP_MIN, OP_MAX, OP_AND, OP_OR, OP_MINLOC, OP_MAXLOC };

/* An int of the bytes `n` counts, which every MPI count is; a trap where it is not one. */
static int counted(const char *name, int64_t n) {
    if (n > INT_MAX) TRAP("%s: %lld bytes in one message, more than MPI counts (%d)", name, (long long) n, INT_MAX);
    return (int) n;
}

static void *allocated(int64_t bytes) {
    void *p = malloc(bytes > 0 ? (size_t) bytes : 1);

    if (p == NULL) TRAP("mpi: out of memory for %lld bytes", (long long) bytes);
    return p;
}

/* -- buffers ---------------------------------------------------------------------------------- */

/* The most axes a buffer crosses with. */
#define AXES 32

static void axes_checked(const char *name, const nex_desc *d) {
    if (d->rank > AXES) TRAP("%s: an array of %d axes; mpi moves up to %d", name, d->rank, AXES);
}

/* The bytes of every element `d` describes, in nex's order (the first axis fastest), into `out`. */
static void copy_out(const nex_desc *d, char *out) {
    int64_t n = nex_desc_count(d);
    int64_t es = d->elem_size;
    int64_t at[AXES] = {0};

    if (n == 0) return;

    if (d->rank == 0 || d->contiguous) {
        memcpy(out, d->base, (size_t) (n * es));
        return;
    }

    for (int64_t k = 0; k < n; k++) {
        memcpy(out + k * es, nex_desc_at(d, at), (size_t) es);

        for (int32_t a = 0; a < d->rank; a++) {
            if (++at[a] < d->dim[a].extent) break;
            at[a] = 0;
        }
    }
}

/* The elements `d` describes written from `in`, in nex's order. */
static void copy_in(const nex_desc *d, const char *in) {
    int64_t n = nex_desc_count(d);
    int64_t es = d->elem_size;
    int64_t at[AXES] = {0};

    if (n == 0) return;

    if (d->rank == 0 || d->contiguous) {
        memcpy(d->base, in, (size_t) (n * es));
        return;
    }

    for (int64_t k = 0; k < n; k++) {
        memcpy(nex_desc_at(d, at), in + k * es, (size_t) es);

        for (int32_t a = 0; a < d->rank; a++) {
            if (++at[a] < d->dim[a].extent) break;
            at[a] = 0;
        }
    }
}

/* `d`'s elements, packed into a new buffer the caller frees. */
static char *packed(const nex_desc *d) {
    char *out = allocated(nex_desc_count(d) * d->elem_size);

    copy_out(d, out);
    return out;
}

/* -- datatypes -------------------------------------------------------------------------------- */

/* A buffer as a point-to-point call takes it: an address, a count and a datatype. */
typedef struct buffer {
    void *base;
    int count;
    MPI_Datatype type;
} buffer;

/* A committed datatype and the layout it describes. */
typedef struct layout {
    int64_t elem_size;
    int32_t rank;
    int64_t extent[AXES];
    int64_t stride[AXES];
    MPI_Datatype type;
} layout;

/* The datatypes built so far, the oldest replaced once every slot holds one. A datatype replaced
 * while a request still uses it is freed when the request completes (MPI_Type_free). */
#define CACHED 64

static layout cache[CACHED];
static int cached = 0;
static int replaced = 0;

static bool lays_out(const layout *l, const nex_desc *d) {
    if (l->elem_size != d->elem_size || l->rank != d->rank) return false;

    for (int32_t a = 0; a < d->rank; a++)
        if (l->extent[a] != d->dim[a].extent || l->stride[a] != d->dim[a].stride) return false;

    return true;
}

/* The datatype of `d`'s elements from its first: one element's bytes, the leading axes that are
 * one dense run folded into them, then one `hvector` per remaining axis, innermost first, each with
 * the axis's own byte stride — negative where the view is reversed along it. */
static MPI_Datatype built(const char *name, const nex_desc *d) {
    MPI_Datatype t;
    MPI_Datatype next;
    int64_t run = d->elem_size;
    int32_t a = 0;

    while (a < d->rank && (d->dim[a].stride == run || d->dim[a].extent == 1)) {
        run *= d->dim[a].extent;
        a++;
    }

    MPI_Type_contiguous(counted(name, run), MPI_BYTE, &t);

    for (; a < d->rank; a++) {
        if (d->dim[a].extent == 1) continue;

        MPI_Type_create_hvector(counted(name, d->dim[a].extent), 1, (MPI_Aint) d->dim[a].stride, t, &next);
        MPI_Type_free(&t);
        t = next;
    }

    MPI_Type_commit(&t);
    return t;
}

/* `d` as MPI takes it, where it lies (DESIGN §9.6.3): a dense block as its bytes, any other view
 * as one element of a datatype describing it, from the cache where one was built before. */
static buffer buffer_of(const char *name, const nex_desc *d) {
    int64_t n = nex_desc_count(d);
    int bytes = counted(name, n * d->elem_size);

    if (n == 0 || d->rank == 0 || d->contiguous) return (buffer){d->base, bytes, MPI_BYTE};

    for (int k = 0; k < cached; k++)
        if (lays_out(&cache[k], d)) return (buffer){d->base, 1, cache[k].type};

    MPI_Datatype t = built(name, d);
    int slot = cached;

    if (cached < CACHED) {
        cached++;
    } else {
        slot = replaced;
        replaced = (replaced + 1) % CACHED;
        MPI_Type_free(&cache[slot].type);
    }

    layout *l = &cache[slot];

    l->elem_size = d->elem_size;
    l->rank = d->rank;

    for (int32_t a = 0; a < d->rank; a++) {
        l->extent[a] = d->dim[a].extent;
        l->stride[a] = d->dim[a].stride;
    }

    l->type = t;
    return (buffer){d->base, 1, t};
}

/* How many datatypes the cache holds: what a test reads to see a loop build each once. */
int64_t nex_mpi_datatypes(void) { return cached; }

/* -- shapes ----------------------------------------------------------------------------------- */

/* A shape as it crosses: the rank, then that many extents. */
#define SHAPE (AXES + 1)

static void shape_of(const nex_desc *d, int64_t *s) {
    memset(s, 0, SHAPE * sizeof *s);
    s[0] = d->rank;

    for (int32_t a = 0; a < d->rank; a++) s[1 + a] = d->dim[a].extent;
}

/* `[2, 3]`, or `a scalar`. */
static const char *shape_text(const int64_t *s, char *out, size_t cap) {
    size_t at = 0;

    if (s[0] == 0) {
        snprintf(out, cap, "a scalar");
        return out;
    }

    at += (size_t) snprintf(out + at, cap - at, "[");

    for (int64_t a = 0; a < s[0] && at < cap; a++)
        at += (size_t) snprintf(out + at, cap - at, a == 0 ? "%lld" : ", %lld", (long long) s[1 + a]);

    if (at < cap) snprintf(out + at, cap - at, "]");
    return out;
}

/* Every rank's shape of `d`, rank q's at `q * SHAPE`, in a buffer the caller frees. */
static int64_t *all_shapes(const nex_desc *d, MPI_Comm c, int p) {
    int64_t mine[SHAPE];
    int64_t *all = allocated((int64_t) p * SHAPE * (int64_t) sizeof *all);

    shape_of(d, mine);
    MPI_Allgather(mine, SHAPE, MPI_INT64_T, all, SHAPE, MPI_INT64_T, c);
    return all;
}

/* Whether shapes `a` and `b` agree, on every axis or, where `but_last`, on all but the last. */
static bool agree(const int64_t *a, const int64_t *b, bool but_last) {
    if (a[0] != b[0]) return false;

    for (int64_t k = 0; k < a[0] - (but_last ? 1 : 0); k++)
        if (a[1 + k] != b[1 + k]) return false;

    return true;
}

/* A trap, on every rank alike, where some rank's shape is not `against`'s (rank `who`'s). */
static void same_shapes(const char *name, const int64_t *all, int p, int who, bool but_last, int64_t *scratch) {
    for (int q = 0; q < p; q++) {
        if (agree(all + (int64_t) q * SHAPE, all + (int64_t) who * SHAPE, but_last)) continue;

        char mine[200];
        char theirs[200];

        shape_text(all + (int64_t) q * SHAPE, mine, sizeof mine);
        shape_text(all + (int64_t) who * SHAPE, theirs, sizeof theirs);
        free(scratch);

        if (but_last)
            TRAP("%s: the pieces agree on every axis but the last, and rank %d's is %s where rank %d's is %s", name, q, mine, who, theirs);

        TRAP("%s: every rank's operand has one shape, and rank %d's is %s where rank %d's is %s", name, q, mine, who, theirs);
    }
}

static int size_of(MPI_Comm c) {
    int p = 0;

    MPI_Comm_size(c, &p);
    return p;
}

static int rank_in(MPI_Comm c) {
    int r = 0;

    MPI_Comm_rank(c, &r);
    return r;
}

static void root_checked(const char *name, int64_t root, int p) {
    if (root < 0 || root >= p) TRAP("%s: root %lld is no rank of a communicator of %d", name, (long long) root, p);
}

/* -- arithmetic ------------------------------------------------------------------------------- */

static const char *int_name(int32_t type) {
    switch (type) {
    case NEX_INT8: return "int8";
    case NEX_INT16: return "int16";
    case NEX_INT32: return "int32";
    case NEX_INT64: return "int64";
    case NEX_UINT8: return "uint8";
    case NEX_UINT16: return "uint16";
    case NEX_UINT32: return "uint32";
    default: return "uint64";
    }
}

/* IEEE 754's minimumNumber and maximumNumber, as nex's `min` and `max` of reals are (DESIGN §7.4):
 * a number beats a `nan`, and -0 is below +0. */
#define LOWER(T)                                                                    \
    static T lower_##T(T a, T b) {                                                  \
        if (a != a) return b;                                                       \
        if (b != b) return a;                                                       \
        if (a < b) return a;                                                        \
        if (b < a) return b;                                                        \
        return signbit((double) a) ? a : b;                                         \
    }                                                                               \
    static T upper_##T(T a, T b) {                                                  \
        if (a != a) return b;                                                       \
        if (b != b) return a;                                                       \
        if (a > b) return a;                                                        \
        if (b > a) return b;                                                        \
        return signbit((double) a) ? b : a;                                         \
    }

typedef _Float16 half;

LOWER(half)
LOWER(float)
LOWER(double)

/* `acc = acc op x` for `n` elements of an integer type `T`, an overflow a trap. */
#define INT_COMBINE(T)                                                                                       \
    static void combine_##T(int op, char *acc, const char *x, int64_t n, const char *name, int32_t type) {   \
        for (int64_t i = 0; i < n; i++) {                                                                    \
            T a, b, r = 0;                                                                                   \
            memcpy(&a, acc + i * (int64_t) sizeof(T), sizeof a);                                             \
            memcpy(&b, x + i * (int64_t) sizeof(T), sizeof b);                                               \
            switch (op) {                                                                                    \
            case OP_ADD: if (__builtin_add_overflow(a, b, &r)) TRAP("%s: %s overflow", name, int_name(type)); break; \
            case OP_MUL: if (__builtin_mul_overflow(a, b, &r)) TRAP("%s: %s overflow", name, int_name(type)); break; \
            case OP_MIN: case OP_MINLOC: r = b < a ? b : a; break;                                           \
            default: r = b > a ? b : a; break;                                                               \
            }                                                                                                \
            memcpy(acc + i * (int64_t) sizeof(T), &r, sizeof r);                                             \
        }                                                                                                    \
    }

INT_COMBINE(int8_t)
INT_COMBINE(int16_t)
INT_COMBINE(int32_t)
INT_COMBINE(int64_t)
INT_COMBINE(uint8_t)
INT_COMBINE(uint16_t)
INT_COMBINE(uint32_t)
INT_COMBINE(uint64_t)

/* The same for a real type `T`. */
#define REAL_COMBINE(T)                                                                   \
    static void combine_##T(int op, char *acc, const char *x, int64_t n) {               \
        for (int64_t i = 0; i < n; i++) {                                                 \
            T a, b, r;                                                                    \
            memcpy(&a, acc + i * (int64_t) sizeof(T), sizeof a);                          \
            memcpy(&b, x + i * (int64_t) sizeof(T), sizeof b);                            \
            switch (op) {                                                                 \
            case OP_ADD: r = a + b; break;                                                \
            case OP_MUL: r = a * b; break;                                                \
            case OP_MIN: case OP_MINLOC: r = lower_##T(a, b); break;                      \
            default: r = upper_##T(a, b); break;                                          \
            }                                                                             \
            memcpy(acc + i * (int64_t) sizeof(T), &r, sizeof r);                          \
        }                                                                                 \
    }

REAL_COMBINE(half)
REAL_COMBINE(float)
REAL_COMBINE(double)

/* The same for a complex of `T` parts, the real part first: `+` part by part, `*` as nex writes
 * the product, (ac - bd) + (ad + bc)i, each product rounded. */
#define COMPLEX_COMBINE(T)                                                                \
    static void ccombine_##T(int op, char *acc, const char *x, int64_t n) {              \
        for (int64_t i = 0; i < n; i++) {                                                 \
            T a[2], b[2], r[2];                                                           \
            memcpy(a, acc + i * 2 * (int64_t) sizeof(T), sizeof a);                       \
            memcpy(b, x + i * 2 * (int64_t) sizeof(T), sizeof b);                         \
            if (op == OP_ADD) {                                                           \
                r[0] = a[0] + b[0];                                                       \
                r[1] = a[1] + b[1];                                                       \
            } else {                                                                      \
                T rr = a[0] * b[0];                                                       \
                T ii = a[1] * b[1];                                                       \
                T ri = a[0] * b[1];                                                       \
                T ir = a[1] * b[0];                                                       \
                r[0] = rr - ii;                                                           \
                r[1] = ri + ir;                                                           \
            }                                                                             \
            memcpy(acc + i * 2 * (int64_t) sizeof(T), r, sizeof r);                       \
        }                                                                                 \
    }

COMPLEX_COMBINE(half)
COMPLEX_COMBINE(float)
COMPLEX_COMBINE(double)

/* `acc = acc op x`, element by element, for `n` elements of nex type `type`. */
static void combine(int32_t type, int op, char *acc, const char *x, int64_t n, const char *name) {
    switch (type) {
    case NEX_INT8: combine_int8_t(op, acc, x, n, name, type); return;
    case NEX_INT16: combine_int16_t(op, acc, x, n, name, type); return;
    case NEX_INT32: combine_int32_t(op, acc, x, n, name, type); return;
    case NEX_INT64: combine_int64_t(op, acc, x, n, name, type); return;
    case NEX_UINT8: combine_uint8_t(op, acc, x, n, name, type); return;
    case NEX_UINT16: combine_uint16_t(op, acc, x, n, name, type); return;
    case NEX_UINT32: combine_uint32_t(op, acc, x, n, name, type); return;
    case NEX_UINT64: combine_uint64_t(op, acc, x, n, name, type); return;
    case NEX_REAL16: combine_half(op, acc, x, n); return;
    case NEX_REAL32: combine_float(op, acc, x, n); return;
    case NEX_REAL64: combine_double(op, acc, x, n); return;
    case NEX_COMPLEX_REAL16: ccombine_half(op, acc, x, n); return;
    case NEX_COMPLEX_REAL32: ccombine_float(op, acc, x, n); return;
    case NEX_COMPLEX_REAL64: ccombine_double(op, acc, x, n); return;
    default:
        for (int64_t i = 0; i < n; i++) acc[i] = op == OP_AND ? (acc[i] && x[i]) : (acc[i] || x[i]);
        return;
    }
}

/* Whether element `b` beats `a` for `minloc` (`low`) or `maxloc`: strictly, and a number beats a
 * `nan`; a tie keeps `a`, the lower rank's. */
static bool beats(int32_t type, bool low, const char *a, const char *b) {
#define ORDER(T)                                                         \
    {                                                                    \
        T x, y;                                                          \
        memcpy(&x, a, sizeof x);                                         \
        memcpy(&y, b, sizeof y);                                         \
        if (y != y) return false;                                        \
        if (x != x) return true;                                         \
        return low ? y < x : y > x;                                      \
    }
    switch (type) {
    case NEX_INT8: ORDER(int8_t)
    case NEX_INT16: ORDER(int16_t)
    case NEX_INT32: ORDER(int32_t)
    case NEX_INT64: ORDER(int64_t)
    case NEX_UINT8: ORDER(uint8_t)
    case NEX_UINT16: ORDER(uint16_t)
    case NEX_UINT32: ORDER(uint32_t)
    case NEX_UINT64: ORDER(uint64_t)
    case NEX_REAL16: ORDER(half)
    case NEX_REAL32: ORDER(float)
    default: ORDER(double)
    }
#undef ORDER
}

/* The pieces `parts` (piece q at `q * n * es`, `n` elements each) of `m` ranks combined in DESIGN
 * §9.2.1's pairwise tree — in rounds, 1 with 2, 3 with 4, …, an odd last one carried — into piece
 * 0; for `minloc` and `maxloc` the ranks `locs` (piece q at `q * n`) alongside. */
static void tree(int32_t type, int op, char *parts, int64_t *locs, int m, int64_t n, int64_t es, const char *name) {
    int *at = allocated((int64_t) m * (int64_t) sizeof *at);

    for (int q = 0; q < m; q++) at[q] = q;

    while (m > 1) {
        int kept = 0;

        for (int k = 0; k + 1 < m; k += 2) {
            char *a = parts + (int64_t) at[k] * n * es;
            const char *b = parts + (int64_t) at[k + 1] * n * es;

            if (op == OP_MINLOC || op == OP_MAXLOC) {
                int64_t *la = locs + (int64_t) at[k] * n;
                const int64_t *lb = locs + (int64_t) at[k + 1] * n;

                for (int64_t i = 0; i < n; i++) {
                    if (beats(type, op == OP_MINLOC, a + i * es, b + i * es)) {
                        memcpy(a + i * es, b + i * es, (size_t) es);
                        la[i] = lb[i];
                    }
                }
            } else {
                combine(type, op, a, b, n, name);
            }

            at[kept++] = at[k];
        }

        if (m % 2 == 1) at[kept++] = at[m - 1];
        m = kept;
    }

    free(at);
}

/* -- reductions ------------------------------------------------------------------------------- */

/* MPI's datatype for a nex type, where it has one. */
static MPI_Datatype datatype_of(int32_t type) {
    switch (type) {
    case NEX_INT8: return MPI_INT8_T;
    case NEX_INT16: return MPI_INT16_T;
    case NEX_INT32: return MPI_INT32_T;
    case NEX_INT64: return MPI_INT64_T;
    case NEX_UINT8: return MPI_UINT8_T;
    case NEX_UINT16: return MPI_UINT16_T;
    case NEX_UINT32: return MPI_UINT32_T;
    case NEX_UINT64: return MPI_UINT64_T;
    case NEX_REAL32: return MPI_FLOAT;
    case NEX_REAL64: return MPI_DOUBLE;
    case NEX_COMPLEX_REAL32: return MPI_C_FLOAT_COMPLEX;
    case NEX_COMPLEX_REAL64: return MPI_C_DOUBLE_COMPLEX;
    case NEX_BOOL: return MPI_C_BOOL;
    default: return MPI_DATATYPE_NULL;
    }
}

/* MPI's operator for `op` over `type`, where MPI has one: `fast = true` uses it. */
static MPI_Op mpi_op_of(int32_t type, int op) {
    bool complex = type == NEX_COMPLEX_REAL32 || type == NEX_COMPLEX_REAL64;

    if (datatype_of(type) == MPI_DATATYPE_NULL) return MPI_OP_NULL;

    if (type == NEX_BOOL) return op == OP_AND ? MPI_LAND : op == OP_OR ? MPI_LOR : MPI_OP_NULL;

    switch (op) {
    case OP_ADD: return MPI_SUM;
    case OP_MUL: return MPI_PROD;
    case OP_MIN: return complex ? MPI_OP_NULL : MPI_MIN;
    case OP_MAX: return complex ? MPI_OP_NULL : MPI_MAX;
    default: return MPI_OP_NULL;
    }
}

/* The elements one round of a reduction moves per rank: about 4 MB from all of them together. */
static int64_t chunk_of(int64_t n, int64_t es, int p) {
    int64_t c = ((int64_t) 1 << 22) / (es * p);

    if (c < 1) c = 1;
    return c < n ? c : n;
}

/* `allreduce`, `reduce_to` and `scan` (`name`) of `x` with the built-in operator `op`, in place:
 * the combination on every rank, on `root` alone, or of ranks 0 to this one. `loc` receives the rank
 * each `minloc` or `maxloc` element came from (this rank's own, where `reduce_to` leaves `x`). */
void nex_mpi_reduce(int32_t name_code, const nex_desc *x, const nex_desc *loc, int32_t op, int64_t root, bool fast, int32_t comm) {
    const char *name = NAMES[name_code];
    MPI_Comm c = comm_of(comm);
    int p = size_of(c);
    int me = rank_in(c);
    bool located = op == OP_MINLOC || op == OP_MAXLOC;
    int64_t n = nex_desc_count(x);
    int64_t es = x->elem_size;

    axes_checked(name, x);
    if (name_code == REDUCE_TO) root_checked(name, root, p);

    int64_t *shapes = all_shapes(x, c, p);

    same_shapes(name, shapes, p, 0, false, shapes);
    free(shapes);

    char *mine = packed(x);
    MPI_Op mop = fast ? mpi_op_of(x->type, op) : MPI_OP_NULL;

    if (mop != MPI_OP_NULL) {
        int count = counted(name, n);
        MPI_Datatype dt = datatype_of(x->type);

        if (name_code == ALLREDUCE) MPI_Allreduce(MPI_IN_PLACE, mine, count, dt, mop, c);
        else if (name_code == SCAN) MPI_Scan(MPI_IN_PLACE, mine, count, dt, mop, c);
        else if (me == root) MPI_Reduce(MPI_IN_PLACE, mine, count, dt, mop, (int) root, c);
        else MPI_Reduce(mine, NULL, count, dt, mop, (int) root, c);

        if (name_code != REDUCE_TO || me == root) copy_in(x, mine);
        free(mine);
        return;
    }

    int64_t chunk = chunk_of(n, es, p);
    char *all = allocated(chunk * es * p);
    int64_t *locs = located ? allocated(chunk * p * (int64_t) sizeof *locs) : NULL;
    int64_t *found = located ? allocated(n * (int64_t) sizeof *found) : NULL;
    bool keeps = name_code == REDUCE_TO && me != root;

    for (int64_t at = 0; at < n; at += chunk) {
        int64_t len = n - at < chunk ? n - at : chunk;
        int bytes = counted(name, len * es);

        if (name_code == REDUCE_TO) MPI_Gather(mine + at * es, bytes, MPI_BYTE, all, bytes, MPI_BYTE, (int) root, c);
        else MPI_Allgather(mine + at * es, bytes, MPI_BYTE, all, bytes, MPI_BYTE, c);

        if (keeps) continue;

        int m = name_code == SCAN ? me + 1 : p;

        if (located)
            for (int q = 0; q < m; q++)
                for (int64_t i = 0; i < len; i++) locs[(int64_t) q * len + i] = q;

        tree(x->type, op, all, locs, m, len, es, name);
        memcpy(mine + at * es, all, (size_t) (len * es));
        if (located) memcpy(found + at, locs, (size_t) len * sizeof *locs);
    }

    if (!keeps) copy_in(x, mine);

    if (located) {
        if (keeps)
            for (int64_t i = 0; i < n; i++) found[i] = me;

        copy_in(loc, (const char *) found);
    }

    free(mine);
    free(all);
    free(locs);
    free(found);
}

/* -- moving values ---------------------------------------------------------------------------- */

/* `bcast`: `x` as `root` holds it, on every rank, whose `x` has the root's shape. */
void nex_mpi_bcast(const nex_desc *x, int64_t root, int32_t comm) {
    MPI_Comm c = comm_of(comm);
    int p = size_of(c);

    axes_checked("bcast", x);
    root_checked("bcast", root, p);

    int64_t *shapes = all_shapes(x, c, p);

    same_shapes("bcast", shapes, p, (int) root, false, shapes);
    free(shapes);

    char *mine = packed(x);

    MPI_Bcast(mine, counted("bcast", nex_desc_count(x) * x->elem_size), MPI_BYTE, (int) root, c);
    copy_in(x, mine);
    free(mine);
}

/* Whether collective `name` leaves its result on every rank rather than on the root. */
static bool to_all(int32_t name) {
    return name == ALLREDUCE || name == SCAN || name == ALLGATHER || name == ALLGATHER_CONCAT;
}

static bool concatenates(int32_t name) { return name == GATHER_CONCAT || name == ALLGATHER_CONCAT; }

/* The last extent of `name`'s result on this rank, the ranks' shapes checked: the number of ranks
 * (`gather`, and a user operator's pieces) or the pieces' last extents added (`gather_concat`), or
 * 0 where only the root gets one and this rank is not it. */
int64_t nex_mpi_gathered(int32_t name_code, const nex_desc *x, int64_t root, int32_t comm) {
    const char *name = NAMES[name_code];
    MPI_Comm c = comm_of(comm);
    int p = size_of(c);
    bool concat = concatenates(name_code);
    int64_t out = p;

    axes_checked(name, x);
    if (!to_all(name_code)) root_checked(name, root, p);

    int64_t *shapes = all_shapes(x, c, p);

    same_shapes(name, shapes, p, 0, concat, shapes);

    if (concat) {
        out = 0;
        for (int q = 0; q < p; q++) out += shapes[(int64_t) q * SHAPE + x->rank];
    }

    free(shapes);
    return !to_all(name_code) && rank_in(c) != root ? 0 : out;
}

/* Every rank's `x`, one after another in rank order, into `into` (on the root alone, unless the
 * collective leaves its result everywhere). */
void nex_mpi_gather(int32_t name_code, const nex_desc *x, const nex_desc *into, int64_t root, int32_t comm) {
    const char *name = NAMES[name_code];
    MPI_Comm c = comm_of(comm);
    int p = size_of(c);
    int64_t es = x->elem_size;
    int64_t *shapes = all_shapes(x, c, p);
    int *counts = allocated((int64_t) p * (int64_t) sizeof *counts);
    int *displs = allocated((int64_t) p * (int64_t) sizeof *displs);
    int64_t total = 0;

    for (int q = 0; q < p; q++) {
        int64_t n = 1;

        for (int64_t a = 0; a < shapes[(int64_t) q * SHAPE]; a++) n *= shapes[(int64_t) q * SHAPE + 1 + a];

        counts[q] = counted(name, n * es);
        displs[q] = counted(name, total);
        total += n * es;
    }

    counted(name, total);
    free(shapes);

    char *mine = packed(x);
    char *all = allocated(total);
    int me = rank_in(c);

    if (to_all(name_code)) MPI_Allgatherv(mine, counts[me], MPI_BYTE, all, counts, displs, MPI_BYTE, c);
    else MPI_Gatherv(mine, counts[me], MPI_BYTE, all, counts, displs, MPI_BYTE, (int) root, c);

    if (to_all(name_code) || me == root) copy_in(into, all);

    free(mine);
    free(all);
    free(counts);
    free(displs);
}

/* Of `n` elements cut as evenly as can be among `p` ranks, the first and the count rank `r` gets:
 * the first `n mod p` ranks one more than the rest, as the module's `blocks` cuts. */
static void block_of(int64_t n, int p, int r, int64_t *first, int64_t *count) {
    int64_t q = n / p;
    int64_t extra = n % p;

    *first = r * q + (r < extra ? r : extra);
    *count = q + (r < extra ? 1 : 0);
}

/* The root's shape of `x`, on every rank, checked for `scatter` and `scatter_concat`. */
static void root_shape(int32_t name_code, const nex_desc *x, int64_t root, MPI_Comm c, int p, int64_t *s) {
    const char *name = NAMES[name_code];

    axes_checked(name, x);
    root_checked(name, root, p);
    shape_of(x, s);
    MPI_Bcast(s, SHAPE, MPI_INT64_T, (int) root, c);

    if (name_code == SCATTER && s[s[0]] != p)
        TRAP("scatter: the root's array has %lld parts along its last axis, and the communicator %d ranks", (long long) s[s[0]], p);
}

/* This rank's part's extents, of `scatter` or `scatter_concat` from `root`'s `x`, into `extents`. */
void nex_mpi_scattered(int32_t name_code, const nex_desc *x, const nex_desc *extents, int64_t root, int32_t comm) {
    MPI_Comm c = comm_of(comm);
    int p = size_of(c);
    int64_t s[SHAPE];
    int64_t out[AXES];
    int64_t first = 0;

    root_shape(name_code, x, root, c, p, s);

    for (int64_t a = 0; a + 1 < s[0]; a++) out[a] = s[1 + a];

    if (name_code == SCATTER_CONCAT) block_of(s[s[0]], p, rank_in(c), &first, &out[s[0] - 1]);

    copy_in(extents, (const char *) out);
}

/* `scatter` and `scatter_concat`: the root's `x` cut along its last axis, rank r's part into its
 * `into` — part r + 1, or the r-th of `blocks`' cuts. */
void nex_mpi_scatter(int32_t name_code, const nex_desc *x, const nex_desc *into, int64_t root, int32_t comm) {
    const char *name = NAMES[name_code];
    MPI_Comm c = comm_of(comm);
    int p = size_of(c);
    int me = rank_in(c);
    int64_t es = x->elem_size;
    int64_t s[SHAPE];
    int64_t inner = 1;

    root_shape(name_code, x, root, c, p, s);

    for (int64_t a = 0; a + 1 < s[0]; a++) inner *= s[1 + a];

    int *counts = allocated((int64_t) p * (int64_t) sizeof *counts);
    int *displs = allocated((int64_t) p * (int64_t) sizeof *displs);

    for (int q = 0; q < p; q++) {
        int64_t first = q;
        int64_t count = 1;

        if (name_code == SCATTER_CONCAT) block_of(s[s[0]], p, q, &first, &count);

        counts[q] = counted(name, inner * count * es);
        displs[q] = counted(name, inner * first * es);
    }

    char *all = me == root ? packed(x) : NULL;
    char *mine = allocated(counts[me]);

    MPI_Scatterv(all, counts, displs, MPI_BYTE, mine, counts[me], MPI_BYTE, (int) root, c);
    copy_in(into, mine);
    free(all);
    free(mine);
    free(counts);
    free(displs);
}

/* `alltoall`: part k of `x`'s last axis to rank k; part k of `into` from rank k. */
void nex_mpi_alltoall(const nex_desc *x, const nex_desc *into, int32_t comm) {
    MPI_Comm c = comm_of(comm);
    int p = size_of(c);

    axes_checked("alltoall", x);

    int64_t *shapes = all_shapes(x, c, p);

    same_shapes("alltoall", shapes, p, 0, false, shapes);

    if (shapes[x->rank] != p) {
        int64_t parts = shapes[x->rank];

        free(shapes);
        TRAP("alltoall: the array has %lld parts along its last axis, and the communicator %d ranks", (long long) parts, p);
    }

    free(shapes);

    int part = counted("alltoall", nex_desc_count(x) / p * x->elem_size);
    char *mine = packed(x);
    char *out = allocated((int64_t) part * p);

    MPI_Alltoall(mine, part, MPI_BYTE, out, part, MPI_BYTE, c);
    copy_in(into, out);
    free(mine);
    free(out);
}

/* -- point to point --------------------------------------------------------------------------- */

void nex_mpi_send(const nex_desc *x, int64_t to, int64_t tag, int32_t comm) {
    axes_checked("send", x);

    buffer b = buffer_of("send", x);

    MPI_Send(b.base, b.count, b.type, (int) to, (int) tag, comm_of(comm));
}

/* The message matched by `from` and `tag` into `x`, whose element count must be the message's;
 * `status` gets its source, tag and element count. */
static void received(const char *name, const nex_desc *x, int64_t from, int64_t tag, MPI_Comm c, const nex_desc *status) {
    int64_t out[3] = {MPI_PROC_NULL, MPI_ANY_TAG, 0};
    MPI_Status st;
    int bytes = 0;
    int64_t n = nex_desc_count(x);

    axes_checked(name, x);

    if (from == MPI_PROC_NULL) {
        copy_in(status, (const char *) out);
        return;
    }

    MPI_Probe((int) from, (int) tag, c, &st);
    MPI_Get_count(&st, MPI_BYTE, &bytes);

    if (bytes != n * x->elem_size)
        TRAP("%s: the message from rank %d holds %lld values; the array holds %lld", name, st.MPI_SOURCE, (long long) (bytes / x->elem_size), (long long) n);

    buffer b = buffer_of(name, x);

    MPI_Recv(b.base, b.count, b.type, st.MPI_SOURCE, st.MPI_TAG, c, MPI_STATUS_IGNORE);
    out[0] = st.MPI_SOURCE;
    out[1] = st.MPI_TAG;
    out[2] = n;
    copy_in(status, (const char *) out);
}

void nex_mpi_recv(const nex_desc *x, int64_t from, int64_t tag, int32_t comm, const nex_desc *status) {
    received("recv", x, from, tag, comm_of(comm), status);
}

/* `x` sent to `to` while `y` is received from `from`, so a ring of them cannot deadlock. */
void nex_mpi_sendrecv(const nex_desc *x, int64_t to, int64_t send_tag, const nex_desc *y, int64_t from, int64_t recv_tag, int32_t comm, const nex_desc *status) {
    MPI_Comm c = comm_of(comm);
    MPI_Request request;

    axes_checked("sendrecv", x);

    buffer b = buffer_of("sendrecv", x);

    MPI_Isend(b.base, b.count, b.type, (int) to, (int) send_tag, c, &request);
    received("sendrecv", y, from, recv_tag, c, status);
    MPI_Wait(&request, MPI_STATUS_IGNORE);
}

/* -- the exchange block ----------------------------------------------------------------------- */

/* The runtime's: how deep the catches around the caller are nested (0 outside every one). */
extern int32_t nex_catch_depth(void);

/* One request an `exchange` block posted: for a receive, the element count its array holds. */
typedef struct posted {
    MPI_Request request;
    MPI_Comm comm;
    bool receives;
    int64_t values;
    int64_t elem_size;
} posted;

/* An open `exchange` block: the catch depth it was opened at, and its requests. */
typedef struct block {
    int32_t depth;
    int count;
    int cap;
    posted *posts;
} block;

static block *blocks = NULL;
static int blocks_open = 0;
static int blocks_cap = 0;

void nex_mpi_exchange_begin(void) {
    if (blocks_open == blocks_cap) {
        blocks_cap = blocks_cap == 0 ? 4 : 2 * blocks_cap;
        blocks = realloc(blocks, (size_t) blocks_cap * sizeof *blocks);

        if (blocks == NULL) TRAP("mpi: out of memory for %d exchange blocks", blocks_cap);
    }

    blocks[blocks_open++] = (block){nex_catch_depth(), 0, 0, NULL};
}

/* A new request's slot in the innermost open block. */
static posted *posting(void) {
    block *k = &blocks[blocks_open - 1];

    if (k->count == k->cap) {
        k->cap = k->cap == 0 ? 8 : 2 * k->cap;
        k->posts = realloc(k->posts, (size_t) k->cap * sizeof *k->posts);

        if (k->posts == NULL) TRAP("mpi: out of memory for %d requests", k->cap);
    }

    return &k->posts[k->count++];
}

/* `send` in an `exchange` block: `MPI_Isend` of `x` where it lies, which the block's end waits for. */
void nex_mpi_isend(const nex_desc *x, int64_t to, int64_t tag, int32_t comm) {
    axes_checked("send", x);

    buffer b = buffer_of("send", x);
    posted *p = posting();

    *p = (posted){MPI_REQUEST_NULL, comm_of(comm), false, nex_desc_count(x), x->elem_size};
    MPI_Isend(b.base, b.count, b.type, (int) to, (int) tag, p->comm, &p->request);
}

/* `recv` in an `exchange` block: `MPI_Irecv` into `x` where it lies; the end checks the count. */
void nex_mpi_irecv(const nex_desc *x, int64_t from, int64_t tag, int32_t comm) {
    axes_checked("recv", x);

    buffer b = buffer_of("recv", x);
    posted *p = posting();

    *p = (posted){MPI_REQUEST_NULL, comm_of(comm), true, nex_desc_count(x), x->elem_size};
    MPI_Irecv(b.base, b.count, b.type, (int) from, (int) tag, p->comm, &p->request);
}

/* Every request of block `k` completed, each communicator's errors returned rather than fatal for
 * the wait, so a receive the message overflows traps with nex's words: `statuses` gets each one's
 * status and `codes` its error code. Each request is waited for on its own, which completes them
 * all as `MPI_Waitall` would, since all are posted, and says which failed and how. */
static void waited(block *k, MPI_Status *statuses, int *codes) {
    MPI_Errhandler *handlers = allocated((int64_t) k->count * (int64_t) sizeof *handlers);

    for (int i = 0; i < k->count; i++) {
        MPI_Comm_get_errhandler(k->posts[i].comm, &handlers[i]);
        MPI_Comm_set_errhandler(k->posts[i].comm, MPI_ERRORS_RETURN);
    }

    for (int i = 0; i < k->count; i++)
        codes[i] = MPI_Wait(&k->posts[i].request, &statuses[i]);

    for (int i = k->count - 1; i >= 0; i--) {
        MPI_Comm_set_errhandler(k->posts[i].comm, handlers[i]);
        MPI_Errhandler_free(&handlers[i]);
    }

    free(handlers);
}

/* The end of an `exchange` block: every request it posted completed, and each receive's message
 * checked against its array's element count. */
void nex_mpi_exchange_end(void) {
    block k = blocks[--blocks_open];
    MPI_Status *statuses = allocated((int64_t) k.count * (int64_t) sizeof *statuses);
    int *codes = allocated((int64_t) k.count * (int64_t) sizeof *codes);

    waited(&k, statuses, codes);

    for (int i = 0; i < k.count; i++) {
        posted p = k.posts[i];
        MPI_Status st = statuses[i];
        int code = codes[i];
        int bytes = 0;

        if (code != MPI_SUCCESS) {
            int class = 0;
            char text[MPI_MAX_ERROR_STRING];
            int len = 0;

            MPI_Error_class(code, &class);
            MPI_Error_string(code, text, &len);
            free(statuses);
            free(codes);
            free(k.posts);

            if (p.receives && class == MPI_ERR_TRUNCATE)
                TRAP("recv: the message from rank %d holds more values than the array's %lld", st.MPI_SOURCE, (long long) p.values);

            TRAP("%s: %s", p.receives ? "recv" : "send", text);
        }

        if (!p.receives || st.MPI_SOURCE == MPI_PROC_NULL) continue;

        MPI_Get_count(&st, MPI_BYTE, &bytes);

        if (bytes != p.values * p.elem_size) {
            free(statuses);
            free(codes);
            free(k.posts);
            TRAP("recv: the message from rank %d holds %lld values; the array holds %lld", st.MPI_SOURCE, (long long) (bytes / p.elem_size), (long long) p.values);
        }
    }

    free(statuses);
    free(codes);
    free(k.posts);
}

/* After the wait, the arrays the requests used: nothing to do but be called, so that the program
 * reads a received array only after the wait and frees a sent one only after it. */
void nex_mpi_landed(const nex_desc *x) { (void) x; }

void nex_mpi_held(const nex_desc *x) { (void) x; }

/* A trap leaving the catch at depth `depth`: every block opened inside it has its requests
 * cancelled and completed before the trap frees the arrays they use. */
static void unwound(int32_t depth) {
    /* A trap inside a `parallel` region is caught by its own thread, whose catches are its own. */
    if (!pthread_equal(pthread_self(), joining_thread)) return;

    while (blocks_open > 0 && blocks[blocks_open - 1].depth >= depth) {
        block k = blocks[--blocks_open];
        MPI_Status *statuses = allocated((int64_t) k.count * (int64_t) sizeof *statuses);
        int *codes = allocated((int64_t) k.count * (int64_t) sizeof *codes);

        for (int i = 0; i < k.count; i++)
            MPI_Cancel(&k.posts[i].request);

        waited(&k, statuses, codes);
        free(statuses);
        free(codes);
        free(k.posts);
    }
}

/* -- the reductions of a distributed vector --------------------------------------------------- */

/* The block of DESIGN §9.2.1: `sum`, `dot` and `norm2` reduce runs of this many elements. */
#define BLOCK 4096

/* The type each term of `name` over elements of `type` is: the element's own, or for `norm2` the
 * real of its width. */
static int32_t term_type(int32_t name, int32_t type) {
    if (name != GLOBAL_NORM2) return type;
    if (type == NEX_REAL16 || type == NEX_COMPLEX_REAL16) return NEX_REAL16;
    if (type == NEX_REAL32 || type == NEX_COMPLEX_REAL32) return NEX_REAL32;
    return NEX_REAL64;
}

static int64_t size_of_type(int32_t type) {
    switch (type) {
    case NEX_INT8: case NEX_UINT8: case NEX_BOOL: return 1;
    case NEX_INT16: case NEX_UINT16: case NEX_REAL16: return 2;
    case NEX_INT32: case NEX_UINT32: case NEX_REAL32: case NEX_COMPLEX_REAL16: return 4;
    case NEX_COMPLEX_REAL64: return 16;
    default: return 8;
    }
}

/* Term `i` of `name` into `out`: `x[i]`; `conj(x[i]) * y[i]`, or `x[i] * y[i]` of reals and
 * integers; `x[i]` squared, a complex's as `re² + im²`, each step rounded. */
static void term(int32_t name, int32_t type, const char *x, const char *y, int64_t i, char *out) {
    int64_t es = size_of_type(type);

    if (name == GLOBAL_SUM) {
        memcpy(out, x + i * es, (size_t) es);
        return;
    }

#define SQUARE(T)                                                       \
    {                                                                   \
        T v;                                                            \
        memcpy(&v, x + i * es, sizeof v);                               \
        T r = v * v;                                                    \
        memcpy(out, &r, sizeof r);                                      \
        return;                                                         \
    }
#define CSQUARE(T)                                                      \
    {                                                                   \
        T v[2];                                                         \
        memcpy(v, x + i * es, sizeof v);                                \
        T rr = v[0] * v[0];                                             \
        T ii = v[1] * v[1];                                             \
        T r = rr + ii;                                                  \
        memcpy(out, &r, sizeof r);                                      \
        return;                                                         \
    }
#define PRODUCT(T)                                                      \
    {                                                                   \
        T a, b;                                                         \
        memcpy(&a, x + i * es, sizeof a);                               \
        memcpy(&b, y + i * es, sizeof b);                               \
        T r = a * b;                                                    \
        memcpy(out, &r, sizeof r);                                      \
        return;                                                         \
    }
#define CPRODUCT(T)                                                     \
    {                                                                   \
        T a[2], b[2], r[2];                                             \
        memcpy(a, x + i * es, sizeof a);                                \
        memcpy(b, y + i * es, sizeof b);                                \
        a[1] = -a[1];                                                   \
        T rr = a[0] * b[0];                                             \
        T ii = a[1] * b[1];                                             \
        T ri = a[0] * b[1];                                             \
        T ir = a[1] * b[0];                                             \
        r[0] = rr - ii;                                                 \
        r[1] = ri + ir;                                                 \
        memcpy(out, r, sizeof r);                                       \
        return;                                                         \
    }

    if (name == GLOBAL_NORM2) {
        switch (type) {
        case NEX_REAL16: SQUARE(half)
        case NEX_REAL32: SQUARE(float)
        case NEX_REAL64: SQUARE(double)
        case NEX_COMPLEX_REAL16: CSQUARE(half)
        case NEX_COMPLEX_REAL32: CSQUARE(float)
        default: CSQUARE(double)
        }
    }

    switch (type) {
    case NEX_REAL16: PRODUCT(half)
    case NEX_REAL32: PRODUCT(float)
    case NEX_REAL64: PRODUCT(double)
    case NEX_COMPLEX_REAL16: CPRODUCT(half)
    case NEX_COMPLEX_REAL32: CPRODUCT(float)
    default: CPRODUCT(double)
    }
#undef SQUARE
#undef CSQUARE
#undef PRODUCT
#undef CPRODUCT
}

/* A run of a distributed vector as it crosses: its block, its first element's global index (from
 * 1), and how many terms follow it — or -1 where one block partial does. */
typedef struct run {
    int64_t block;
    int64_t first;
    int64_t count;
} run;

static int by_first(const void *a, const void *b) {
    int64_t x = ((const run *) a)->first;
    int64_t y = ((const run *) b)->first;

    return x < y ? -1 : x > y;
}

/* `global_sum`, `global_dot` and `global_norm2` of the distributed vector whose piece on this rank
 * is `x` (and `y`), beginning at the global index `offset`: the bits `sum`, `dot` or `norm2` of the
 * whole vector gives. Each block of §9.2.1, numbered along the whole vector, is reduced
 * sequentially — a block a rank holds whole by that rank, a block split between ranks from their
 * pieces' terms in global order — and the blocks' partials combine in the pairwise tree on every
 * rank. */
void nex_mpi_global(int32_t name_code, const nex_desc *x, const nex_desc *y, const nex_desc *into, int64_t offset, int32_t comm) {
    const char *name = NAMES[name_code];
    MPI_Comm c = comm_of(comm);
    int p = size_of(c);
    int64_t n = nex_desc_count(x);
    int32_t tt = term_type(name_code, x->type);
    int64_t ts = size_of_type(tt);

    if (name_code == GLOBAL_DOT && nex_desc_count(y) != n)
        TRAP("global_dot: x holds %lld values and y %lld", (long long) n, (long long) nex_desc_count(y));

    /* The pieces must cover 1..N once each. */
    int64_t span[2] = {offset, n};
    int64_t *spans = allocated((int64_t) p * 2 * (int64_t) sizeof *spans);

    MPI_Allgather(span, 2, MPI_INT64_T, spans, 2, MPI_INT64_T, c);

    int64_t total = 0;
    int64_t next = 1;
    bool covered = true;

    for (int q = 0; q < p; q++) total += spans[2 * q + 1];

    while (next <= total && covered) {
        covered = false;

        for (int q = 0; q < p; q++) {
            if (spans[2 * q + 1] > 0 && spans[2 * q] == next) {
                next += spans[2 * q + 1];
                covered = true;
                break;
            }
        }
    }

    if (next != total + 1) {
        free(spans);
        TRAP("%s: the ranks' pieces cover 1..%lld once each, and none begins at %lld", name, (long long) total, (long long) next);
    }

    free(spans);

    char *xs = packed(x);
    char *ys = name_code == GLOBAL_DOT ? packed(y) : NULL;

    /* This rank's runs, and their values. */
    int64_t first_block = n == 0 ? 0 : (offset - 1) / BLOCK;
    int64_t last_block = n == 0 ? -1 : (offset + n - 2) / BLOCK;
    int64_t nruns = last_block - first_block + 1;
    run *runs = allocated((nruns > 0 ? nruns : 1) * (int64_t) sizeof *runs);
    char *values = allocated((n + nruns + 1) * ts);
    int64_t used = 0;

    for (int64_t b = first_block; b <= last_block; b++) {
        int64_t lo = b * BLOCK + 1;
        int64_t hi = (b + 1) * BLOCK < total ? (b + 1) * BLOCK : total;
        int64_t from = lo > offset ? lo : offset;
        int64_t to = hi < offset + n - 1 ? hi : offset + n - 1;
        run *r = &runs[b - first_block];

        r->block = b;
        r->first = from;

        if (from == lo && to == hi) {
            char *acc = values + used * ts;
            char t[16];

            memset(acc, 0, (size_t) ts);

            for (int64_t g = from; g <= to; g++) {
                term(name_code, x->type, xs, ys, g - offset, t);
                combine(tt, OP_ADD, acc, t, 1, name);
            }

            r->count = -1;
            used += 1;
        } else {
            for (int64_t g = from; g <= to; g++) term(name_code, x->type, xs, ys, g - offset, values + (used + g - from) * ts);

            r->count = to - from + 1;
            used += r->count;
        }
    }

    free(xs);
    free(ys);

    /* Every rank's runs and values. */
    int *run_counts = allocated((int64_t) p * (int64_t) sizeof *run_counts);
    int *run_displs = allocated((int64_t) p * (int64_t) sizeof *run_displs);
    int *value_counts = allocated((int64_t) p * (int64_t) sizeof *value_counts);
    int *value_displs = allocated((int64_t) p * (int64_t) sizeof *value_displs);
    int mine[2] = {counted(name, nruns * (int64_t) sizeof(run)), counted(name, used * ts)};
    int *both = allocated((int64_t) p * 2 * (int64_t) sizeof *both);
    int64_t all_runs = 0;
    int64_t all_values = 0;

    MPI_Allgather(mine, 2, MPI_INT, both, 2, MPI_INT, c);

    for (int q = 0; q < p; q++) {
        run_counts[q] = both[2 * q];
        run_displs[q] = counted(name, all_runs);
        value_counts[q] = both[2 * q + 1];
        value_displs[q] = counted(name, all_values);
        all_runs += both[2 * q];
        all_values += both[2 * q + 1];
    }

    run *every = allocated(all_runs);
    char *every_value = allocated(all_values);

    MPI_Allgatherv(runs, mine[0], MPI_BYTE, every, run_counts, run_displs, MPI_BYTE, c);
    MPI_Allgatherv(values, mine[1], MPI_BYTE, every_value, value_counts, value_displs, MPI_BYTE, c);

    /* Where each run's values begin, before the runs are put in global order. */
    int64_t count = all_runs / (int64_t) sizeof(run);
    int64_t nblocks = (total + BLOCK - 1) / BLOCK;
    int64_t at = 0;
    int64_t *starts = allocated((count > 0 ? count : 1) * (int64_t) sizeof *starts);

    for (int64_t k = 0; k < count; k++) {
        starts[k] = at;
        at += every[k].count < 0 ? 1 : every[k].count;
    }

    /* Each run sorted by its first global index, carrying its own index in `block`. */
    run *order = allocated((count > 0 ? count : 1) * (int64_t) sizeof *order);

    for (int64_t k = 0; k < count; k++) {
        order[k] = every[k];
        order[k].block = k;
    }

    qsort(order, (size_t) count, sizeof *order, by_first);

    char *partials = allocated((nblocks > 0 ? nblocks : 1) * ts);

    memset(partials, 0, (size_t) ((nblocks > 0 ? nblocks : 1) * ts));

    for (int64_t k = 0; k < count; k++) {
        const run *r = &every[order[k].block];
        const char *v = every_value + starts[order[k].block] * ts;
        char *acc = partials + r->block * ts;

        if (r->count < 0) memcpy(acc, v, (size_t) ts);
        else
            for (int64_t i = 0; i < r->count; i++) combine(tt, OP_ADD, acc, v + i * ts, 1, name);
    }

    char result[16];

    memset(result, 0, sizeof result);

    if (nblocks > 0) {
        tree(tt, OP_ADD, partials, NULL, (int) nblocks, 1, ts, name);
        memcpy(result, partials, (size_t) ts);
    }

    if (name_code == GLOBAL_NORM2) {
        if (tt == NEX_REAL16) {
            half h;
            memcpy(&h, result, sizeof h);
            h = (half) sqrt((double) h);
            memcpy(result, &h, sizeof h);
        } else if (tt == NEX_REAL32) {
            float f;
            memcpy(&f, result, sizeof f);
            f = sqrtf(f);
            memcpy(result, &f, sizeof f);
        } else {
            double d;
            memcpy(&d, result, sizeof d);
            d = sqrt(d);
            memcpy(result, &d, sizeof d);
        }
    }

    copy_in(into, result);
    free(runs);
    free(values);
    free(run_counts);
    free(run_displs);
    free(value_counts);
    free(value_displs);
    free(both);
    free(every);
    free(every_value);
    free(starts);
    free(order);
    free(partials);
}
