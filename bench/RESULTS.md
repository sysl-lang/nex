# Perf oracle results

The baseline of PLAN.md's perf oracle (M12), taken before any compiler optimization work.
`zsh bench/run.zsh` reproduces it.

- **Machine**: Apple M5 Pro, 6 performance cores (`hw.perflevel0.physicalcpu`), so the parallel
  kernels run with `OMP_NUM_THREADS=6`.
- **LLVM**: Homebrew clang version 23.1.4 (`/opt/homebrew/opt/llvm`), which `nex` lowers through.
- **Fortran**: GNU Fortran (Homebrew GCC 16.2.0) 16.2.0, `-O2`, plus `-fopenmp` for the parallel twins.
- **Date**: 2026-10-30, 13:02 to 13:05 EDT, under `caffeinate -dimsu`.
- **Load**: the machine was never quiet. Other agents were gating in parallel, and the run waited three
  hours for a one-minute load average below 4 that never came. It started at a load of 36.0, and the
  load at each row is in the table. A kernel times one pass inside its own program and keeps the best
  of five runs, which takes out most of the noise, but treat every ratio within about 15% of the bar
  as unsettled until a quiet run confirms it.

## The table

Times are per pass (per product for gemm), best of five, in milliseconds. *ratio* is nex / twin. The
twin is `gfortran -O2`, except for BLAS gemm, where it is the same BLAS's `cblas_dgemm` called from C
(`blas-gemm.c`, Accelerate). *sums*: the two checksums agree to a relative 1e-9. *allocs*: heap
allocations of 1 MiB or more over the whole run, nex / twin, counted by `alloc-count.dylib`, which is
interposed on both binaries. Every kernel's arrays are 10⁷ elements or 1000², so a temporary the size
of one is counted. *ref/nex*: the Scala reference's AOT binary (`~/dev/nex`, `clang -O1`) as
whole-process time over nex's whole-process time, so above 1 means nex is faster. The reference has no
`extern`, so it cannot time itself.

| kernel | gfortran | nex | ratio | bar | verdict | sums | allocs nex/twin | ref/nex | load |
|---|---:|---:|---:|---:|---|---|---:|---:|---:|
| axpy | 1.76 | 3.60 | 2.04 | 1.25 | **MISSES** | yes | 103 / 2 | 1.54 | 32.1 |
| dot | 8.40 | 8.17 | 0.97 | 1.25 | meets | yes | **52 / 2** | 1.08 | 30.5 |
| nrm2 | 8.11 | 7.12 | 0.88 | 1.25 | meets | yes | **51 / 1** | 1.21 | 28.6 |
| gemv | 2.03 | 2.00 | 0.98 | 1.25 | meets | yes | 1 / 1 | 17.38 | 26.4 |
| gemm (naive) | 132.10 | 115.29 | 0.87 | 1.25 | meets | yes | 3 / 3 | 21.87 | 24.9 |
| stencil | 1.55 | 1.52 | 0.98 | 1.25 | meets | yes | 2 / 2 | 12.97 | 18.6 |
| complex axpy | 3.74 | 8.29 | 2.22 | 1.25 | **MISSES** | yes | 103 / 2 | not measured¹ | 16.0 |
| point distance | 3.99 | 10.98 | 2.75 | 1.25 | **MISSES** | yes | 256 / 5 | not measured¹ | 16.9 |
| axpy, real32 | 0.88 | 1.83 | 2.08 | 1.25 | **MISSES** | yes | 104 / 2 | not measured² | 16.2 |
| BLAS gemm | 7.07 (C) | 5.50 | 0.78 | 1.1 | meets | yes | **44 / 3** | not measured² | 16.2 |
| parallel axpy | 1.19 | 1.14 | 0.96 | 1.25 | meets | yes | 2 / 2 | not measured² | 15.7 |
| parallel dot | 1.52 | 1.16 | 0.76 | 1.25 | meets | yes | 2 / 2 | not measured² | 15.7 |

¹ The reference's AOT backend miscompiles the kernel. It emits `add { double, double }` for complex
`a*x + y`, and `add double` inside the mapped `sqrt` lambda of point distance, which clang rejects.
The reference's `sqrt` also takes only a scalar, so `bench/scala/point-distance.nex` maps it.
² The reference has no `real32`, no `parallel` and no BLAS dispatch.

Exit-bar status: **4 of 12 kernels miss on time** (axpy, complex axpy, point distance, axpy real32).
**4 more allocate a temporary their twin does not** (dot, nrm2, BLAS gemm, and axpy, which also misses
on time). Every kernel the reference compiles runs at least as fast in nex.

## With element-wise fusion

The emitter fuses a quiet element-wise expression into one `linalg.generic`, writes an assignment
to a local the expression reads in place, and computes a reduction's quiet operand as it reduces
(DESIGN §7.1). The affected kernels, 2026-10-30 13:48 EDT, at a load of 70 to 74 the whole run, so
both columns are slower than on a quiet machine and every ratio is unsettled until a quiet run:

| kernel | gfortran | nex | ratio | bar | verdict | sums | allocs nex/twin | ref/nex | load |
|---|---:|---:|---:|---:|---|---|---:|---:|---:|
| axpy | 2.45 | 2.48 | 1.01 | 1.25 | meets | yes | 2 / 2 | 3.47 | 73.4 |
| dot | 13.02 | 8.52 | 0.65 | 1.25 | meets | yes | 2 / 2 | 1.79 | 73.9 |
| nrm2 | 13.44 | 8.41 | 0.63 | 1.25 | meets | yes | 1 / 1 | 1.67 | 70.6 |
| stencil | 2.22 | 2.25 | 1.02 | 1.25 | meets | yes | 2 / 2 | 16.37 | 72.9 |
| complex axpy | 6.18 | 8.03 | 1.30 | 1.25 | **MISSES** | yes | 2 / 2 | not measured¹ | 72.3 |
| point distance | 5.92 | 10.33 | 1.75 | 1.25 | **MISSES** | yes | **106 / 5** | not measured¹ | 71.3 |
| axpy, real32 | 1.36 | 1.21 | 0.88 | 1.25 | meets | yes | 2 / 2 | not measured² | 72.9 |

What is left of the misses:

1. **point distance, 1.75×**: one loop now, with no temporary per operator; what remains is two
   80 MB buffers per pass. `d` is not read by its expression and has a dynamic shape that the
   assignment may change, so the result goes to a new buffer, and the `for` loop, an `scf.while`,
   copies a carried array whose new value is not its old buffer into a fresh one every pass:
   one-shot bufferization copies an `scf.while` iteration argument whenever the body's yield is not
   equivalent to it, where an `scf.for` does not. A counted loop emitted as `scf.for`, writing `d`
   over where its shape is unchanged, is the fix.
2. **complex axpy, 1.30×**: no temporary left (2 / 2); within the noise of this load of the bar,
   and the complex multiply's lowering is the next thing to read.

## The misses of the baseline, ranked by ratio

The diagnoses come from `nex emit` (MLIR) and `zsh bench/run.zsh --ir <kernel>` (the LLVM IR as
`clang -O2` optimizes it), with allocations counted as above.

1. **point distance, 2.75×**: no fusion. Each of the five operators is its own `linalg.generic` into a
   fresh `tensor.empty`, so each pass allocates and writes 5 temporaries of 80 MB (256 / 5).
2. **complex axpy, 2.22×**: the axpy pattern below over complex. `a*x` is materialized, then `+ y`
   goes into a new tensor: 2 temporaries per pass.
3. **axpy real32, 2.08×**: the axpy pattern below. The time per byte is the same as real64
   (1.83 ms against 3.60), so the cost is in the extra traffic, not in the element type.
4. **axpy, 2.04×**: temporary allocated. `y = a*x + y` lowers to two `linalg.generic`s, and the
   shape-mismatch trap the emitter puts between them (an `scf.if` around the second generic) keeps
   `linalg-fuse-elementwise-ops` from fusing them. `a*x` becomes a full temporary, and the sum lands
   in a new buffer instead of `y`'s: 2 × 80 MB per pass.
5. **Allocations only (on time today)**: dot and nrm2 materialize `x * y` (or `x * x`) before `sum`,
   one temporary per pass, unfused for the same reason. They meet the bar because gfortran's `sum`
   is a strict serial reduction while nex's is reordered. BLAS gemm allocates 2 buffers per
   `c = a @ b` where the C caller reuses one.

Inside the bar but worth watching: in naive gemm and gemv the inner loop vectorizes (`<2 x double>`)
behind a runtime alias check (`vector.memcheck`), and the bounds checks are hoisted to the outer
loop. The multiplies and adds stay separate `fmul`/`fadd` with no FMA contraction, while gfortran
contracts them.
