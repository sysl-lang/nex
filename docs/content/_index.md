---
title: nex
splash: true
heroTitle: Fortran's model, with
heroHighlight: modern syntax and a checker that has your back
summary: An array-first numerical language for scientists and engineers who write Fortran. Compiled ahead of time to native binaries. Calls your existing Fortran, BLAS and LAPACK.
---

## What nex is for

nex is for the code Fortran is still used for: dense arrays, stencils, linear algebra, reductions, and
loops that must run fast on every core. It keeps what a Fortran programmer relies on (column-major
storage, 1-based arrays, inclusive ranges, `iso_fortran_env` type names, whole-array expressions that
fuse into one loop) and adds a modern syntax, value semantics and compile-time checks for aliasing and
data races.

Here is a Jacobi sweep on a 2-D grid, with its convergence measure:

```nex
def sweep(u: [real64; :, :], unew: inout [real64; :, :]) =
  val n = rows(u)
  val m = cols(u)
  parallel for j in 2..m-1
    unew[2..n-1, j] = 0.25 * (u[1..n-2, j] + u[3..n, j] + u[2..n-1, j-1] + u[2..n-1, j+1])

def main() =
  var u = zeros((100, 100)) * 1.0
  var unew = u
  u[1, :] = 1.0
  for k in 1..500
    sweep(u, unew)
    u[2..99, 2..99] = unew[2..99, 2..99]
  print(norm2(u))
```

`2..n-1` is Fortran's `2:n-1`. `inout` is Fortran's `intent(inout)`. Each `parallel for` iteration owns
one column, and the compiler proves it before it generates a thread.

## Compared with Fortran and Julia

- **Native binaries, no runtime to ship.** `nex build` produces an ordinary executable through MLIR and
  LLVM. There is no interpreter and no JIT warm-up; `nex run` compiles and then runs.
- **Fortran's data model.** Column-major arrays, 1-based indexing, inclusive ranges and the
  `iso_fortran_env` names (`real32`, `real64`, `int32`, `complex[real64]`), so a port from Fortran
  keeps its shapes and its numbers.
- **Safety you can rely on.** Slices are views, `val` is immutable, and an `inout` argument is an
  exclusive borrow, so the aliasing mistakes that `intent` only documents in Fortran are compile
  errors. A `parallel` loop that could race is rejected, not run.
- **Reproducible parallel reductions.** The thread count comes from `OMP_NUM_THREADS`, and a parallel
  `sum` prints the same bits at 1 thread and at 64.
- **Your existing code stays.** `extern def` declares C, BLAS, LAPACK and Fortran routines, and `A @ B`
  calls BLAS `gemm` when that pays. Link the Fortran library you already have and call it.
- **Versus Julia:** compiled ahead of time and shipped as a plain binary, no first-call latency, and the
  parallel and aliasing rules are checked by the compiler rather than left to convention.

*nex is implemented in sysl.*

## Where to go next

- [Getting started](/getting-started/): install, run a first program, build a native binary.
- [nex for Fortran programmers](/guide/): the same ideas side by side with Fortran.
- [Specification](/spec/): the language, chapter by chapter.
- [Tooling](/tooling/) and the [Playground](/playground/).
