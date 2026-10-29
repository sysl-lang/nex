---
title: Later
summary: Directions that are decided but not in the first language, and the things nex deliberately leaves out.
weight: 900
---

## Decided, not yet in the language

Each of these is a settled direction, kept here so it is not lost. None of them is available today.

- **Structs by value across C and Fortran calls.** `@c` structs cross by reference (see
  [Interop](/spec/11-interop/)); passing and returning them by value needs the per-platform
  aggregate rules a C compiler applies, and waits until a library needs it.
- **`real128`** and **`complex[real128]`**, the `iso_fortran_env` quad-precision kind, for the
  computations that need more than 64-bit accuracy; it comes after the 16-, 32- and 64-bit kinds are
  complete.
- **`bfloat16`.** The name is reserved now so no program can take it; the type is cheap to add and
  arrives when a workload asks for it.
- **Batched BLAS** behind an explicit batched routine, if the idiom
  `parallel for k in 1..n do C[:, :, k] = A[:, :, k] @ B[:, :, k]` measures slower than a vendor's
  batched `gemm`.
- **Banded and tridiagonal LAPACK solvers**, which follow the first set of dense routines
  (see [The Prelude](/spec/12-prelude/)).
- **Generalized eigenproblems** (`A x = λ B x`), after `eig` and `eigh`.
- **`rcond` and `cond`**, condition-number estimates, with the rest of the second LAPACK set.

## Not planned

These are left out on purpose, not postponed.

- **Implicit parallelism** (an `--auto-parallel` mode). Threads start only at a `parallel` the
  program wrote: scientific codes typically run one MPI rank per core, and a compiler that threaded
  each rank unasked would oversubscribe every core (see [Parallelism](/spec/10-parallelism/)).
- **Static extents as generic parameters** (`def trace[N: Extent](m: [real; N, N])`). A generic
  function takes dynamic axes, and a caller's static shape converts to them.
- **Batched `@` on rank 3 or more.** `@` takes ranks 1 and 2, as Fortran's `MATMUL` does; a batch of
  products is an explicit `parallel for` over the trailing axis.
- **A call-site marker for `inout`.** The parameter's declaration says it; the call does not repeat
  it (see [Functions](/spec/06-functions/)).
