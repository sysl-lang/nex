/* nex_desc.h: the descriptor a C function receives for a nex `extern` parameter declared `[*; ..]`
 * (nex DESIGN §10.7), nex's counterpart of ISO_Fortran_binding.h's CFI_cdesc_t.
 *
 *     extern def send(x: [*; ..], to: int32)          // void send(const nex_desc *x, int32_t to);
 *     extern def recv(x: inout [*; ..], from: int32)  // void recv(const nex_desc *x, int32_t from);
 *
 * The descriptor describes the argument as it lies: an array of any rank, a window of one, a strided
 * or reversed view, or a scalar as rank 0. Nothing is copied. Element (i0, i1, …), each counted from
 * 0, is at `(char *)d->base + i0 * d->dim[0].stride + i1 * d->dim[1].stride + …`.
 *
 * The descriptor and the memory it describes are valid only for the call: a function that keeps
 * either past its return reads freed or reused memory.
 */

#ifndef NEX_DESC_H
#define NEX_DESC_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* The element type: nex's name, then C's. */
typedef enum nex_type {
    NEX_INT8 = 1,            /* int8               int8_t */
    NEX_INT16 = 2,           /* int16              int16_t */
    NEX_INT32 = 3,           /* int32              int32_t */
    NEX_INT64 = 4,           /* int64, integer     int64_t */
    NEX_UINT8 = 5,           /* uint8              uint8_t */
    NEX_UINT16 = 6,          /* uint16             uint16_t */
    NEX_UINT32 = 7,          /* uint32             uint32_t */
    NEX_UINT64 = 8,          /* uint64             uint64_t */
    NEX_REAL16 = 9,          /* real16             _Float16 */
    NEX_REAL32 = 10,         /* real32             float */
    NEX_REAL64 = 11,         /* real64, real       double */
    NEX_COMPLEX_REAL16 = 12, /* complex[real16]    two _Float16, real part first */
    NEX_COMPLEX_REAL32 = 13, /* complex[real32]    float _Complex */
    NEX_COMPLEX_REAL64 = 14, /* complex[real64]    double _Complex */
    NEX_BOOL = 15            /* bool               bool, one byte, 0 or 1 */
} nex_type;

/* One axis: how many elements it holds, and the bytes from one to the next along it (CFI's `sm`). */
typedef struct nex_dim {
    int64_t extent;
    int64_t stride;
} nex_dim;

typedef struct nex_desc {
    void *base;          /* the first element: index 1 along every nex axis */
    int64_t elem_size;   /* bytes of one element */
    int32_t type;        /* a nex_type */
    int32_t rank;        /* 0 for a scalar */
    int32_t contiguous;  /* 1 where the elements are one dense column-major block */
    int32_t writable;    /* 1 where the parameter is `inout`: C may write through `base` */
    nex_dim dim[];       /* `rank` axes, nex's first axis first */
} nex_desc;

/* The number of elements described: 1 for a scalar, 0 where an axis is empty. */
static inline int64_t nex_desc_count(const nex_desc *d) {
    int64_t n = 1;
    for (int32_t k = 0; k < d->rank; k++) n *= d->dim[k].extent;
    return n;
}

/* The address of the element at `index` (`rank` indices, each counted from 0). */
static inline void *nex_desc_at(const nex_desc *d, const int64_t *index) {
    char *p = (char *)d->base;
    for (int32_t k = 0; k < d->rank; k++) p += index[k] * d->dim[k].stride;
    return p;
}

#ifdef __cplusplus
}
#endif

#endif
