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

1. **point distance, 1.75×**: one loop, with no temporary per operator, but two 80 MB buffers per
   pass, which the next section removes.
2. **complex axpy, 1.30×**: no temporary left (2 / 2); within the noise of this load of the bar,
   and the complex multiply's lowering is the next thing to read.

## With counted loops as `scf.for`

A `for` whose passes are counted on entry and that no pass can leave early is an `scf.for`, which
carries its arrays without a copy per pass; `d = <expression>` on a dynamic-shape `d` it does not
read writes `d`'s buffer where the extents agree at run time, and `c = a @ b` hands BLAS `c`'s own
buffer where it fits and lies dense (DESIGN §7.1, §10.4, §11.1). The five kernels the change touches,
2026-10-30 14:41 to 14:45 EDT, each side built from its own checkout and run back to back under one
build slot (`nice -n 15`); *before* is the fusion commit above (`86a3aac`). Load at each row:

| kernel | gfortran | nex before | nex after | ratio before | ratio after | allocs before | allocs after (nex/twin) | load before / after |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| point distance | 5.05 / 4.29 | 6.51 | 4.27 | 1.29 | **1.00** | 106 | **5 / 5** | 14.7 / 24.5 |
| BLAS gemm | 8.59 / 9.49 (C) | 6.39 | 6.14 | 0.74 | 0.65 | 44 | **3 / 3** | 14.1 / 23.1 |
| stencil | 1.66 / 1.55 | 1.63 | 1.56 | 0.98 | 1.01 | 2 | 2 / 2 | 14.1 / 23.1 |
| gemm (naive) | 186.73 / 135.23 | 167.30 | 119.09 | 0.90 | 0.88 | 3 | 3 / 3 | 14.8 / 19.6 |
| gemv | 2.65 / 2.59 | 2.62 | 2.55 | 0.99 | 0.98 | 1 | 1 / 1 | 29.2 / 16.9 |

The twin column is the twin's time in each run (before / after), since the load moved between them;
the ratio is against the twin of the same run. Point distance now meets the bar and allocates what
its twin does: the two 80 MB buffers per pass are gone, and BLAS gemm's two per product with them.
Stencil, naive gemm and gemv carry no array whose buffer changes, and stay where they were.

## With the complex product in two lanes

Complex axpy was the last kernel over the bar, and the load was not the reason: interleaved runs of
the twin and nex held 1.46× at a load of 22, and user CPU agreed (0.26 s against 0.18 s). The
multiply was never the Annex G kind — nex already wrote `(ac - bd) + (ad + bc)i` and no recovery
branches — and the loop was one fused `linalg.generic` with no temporary. The cost was the shape
LLVM's loop vectorizer gave it: two complexes per pass, split by `ld2` into a vector of real parts
and one of imaginary parts and joined again by `st2`, with eight vector operations per pass.
gfortran keeps one complex per 128-bit register (`ldr q`, two `fcmla`, `fadd`, `str q`). Its `fcmla`
is a fused multiply-add, which DESIGN §2.5 rules out for nex, but the fusion is not where its speed
comes from: C kernels over the same data, best of 15 with the arrays in cache (2000 complexes, ns per
pass, load 65), give

| loop | ns per pass |
|---|---:|
| gfortran (`fcmla`, fused) | 547 |
| nex (`ld2` / `st2`) | 1123 |
| C, unfused textbook, vectorized as nex is | 1008 |
| C, fused | 838 |
| C, unfused, one complex per register: `[ar, ar] * x + [-ai, ai] * swap(x)` | 732 |
| nex's MLIR with that product written into the generic by hand | 706 |

and at 10⁷, where the loop is near memory speed, the last form ran as fast as the twin. Its values
are the scalar form's bit for bit: `(-ai) * xi` is exactly `-(ai * xi)`, and `x + -y` is `x - y`.
The emitter now writes a complex product in an element-wise `linalg.generic` that way (DESIGN
§2.5), and LLVM keeps it: `fmul <2 x double>`, a lane swap and `fadd`, with no `<4 x double>`
interleaving. A scalar product keeps the scalar form, which MLIR folds where its operands are
constants, as it always has.

2026-10-30 16:08 EDT, best of nine runs of each, interleaved, at a load of 30 to 37. *Before* is dev
at `efd44c1`:

| kernel | gfortran | nex before | nex after | ratio before | ratio after | allocs (nex/twin) |
|---|---:|---:|---:|---:|---:|---:|
| complex axpy | 4.53 | 5.83 | 4.54 | 1.29 | **1.00** | 2 / 2 |

`zsh bench/run.zsh complex-axpy axpy point-distance` from this checkout, at a load of 33 to 37,
gives 1.10, 1.06 and 0.95: every kernel of the oracle now meets its bar. The same change makes
`y = x * a + y` 1.16× faster (6.26 to 5.40 ms) and leaves `y = x * y` as it was (5.36 and 5.39 ms).

## On a quiet machine

The whole oracle at dev `7378a37`, `zsh bench/run.zsh`, 2026-10-30 16:18 EDT, at a load of 4.3 to
6.0 — the run the earlier sections waited for. Every kernel meets its bar, with no allocation its
twin does not make, and every checksum agrees.

| kernel | twin | nex | ratio | allocs (nex/twin) | ref/nex |
|---|---:|---:|---:|---:|---:|
| axpy | 1.61 | 1.61 | 1.00 | 2 / 2 | 2.83 |
| dot | 8.18 | 5.02 | 0.61 | 2 / 2 | 1.68 |
| nrm2 | 7.96 | 4.94 | 0.62 | 1 / 1 | 1.70 |
| gemv | 2.02 | 1.94 | 0.96 | 1 / 1 | 18.06 |
| gemm (naive) | 131.88 | 115.60 | 0.88 | 3 / 3 | 21.20 |
| stencil | 1.47 | 1.46 | 0.99 | 2 / 2 | 13.91 |
| complex axpy | 3.42 | 3.61 | 1.06 | 2 / 2 | n/m |
| point distance | 3.68 | 3.58 | 0.97 | 5 / 5 | n/m |
| axpy, real32 | 0.82 | 0.80 | 0.98 | 2 / 2 | n/m |
| BLAS gemm (vs `cblas_dgemm`) | 6.23 | 3.82 | 0.61 | 3 / 3 | n/m |
| parallel axpy | 1.19 | 1.17 | 0.99 | 2 / 2 | n/m |
| parallel dot | 1.43 | 0.98 | 0.69 | 2 / 2 | n/m |

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

## Against three Fortran compilers

dev `a3d4151` plus the kernels of this section, 2026-11-11, at a load of 2.3 to 3.2 (point
distance, gemm, gemv and axpy real32 re-run at 5 to 9 after the guard below). Every twin is built
three ways: `gfortran -O2` (GCC 16.2.0, the twin the exit bar is measured against), `gfortran -O3
-mcpu=native`, and LLVM `flang -O3 -mcpu=native` (Homebrew flang 23.1.5), which lowers through MLIR
and LLVM as nex does. *nex/best* is nex over the fastest of the three. Every checksum agrees.

| kernel | gfortran -O2 | gfortran -O3 | flang -O3 | nex | ratio (bar) | nex/best |
|---|---:|---:|---:|---:|---:|---:|
| axpy | 1.69 | 1.36 | 3.34 | 1.62 | 0.96 | **1.19** |
| dot | 8.16 | 8.16 | 5.13 | 5.00 | 0.61 | 0.97 |
| nrm2 | 7.99 | 7.98 | 5.15 | 4.93 | 0.62 | 0.96 |
| gemv | 2.04 | 2.04 | 1.89 | 1.92 | 0.94 | 1.02 |
| gemm (naive) | 128.27 | 83.87 | 113.02 | 113.07 | 0.88 | **1.35** |
| stencil | 1.42 | 1.42 | 1.43 | 1.42 | 1.00 | 1.00 |
| complex axpy | 3.22 | 1.64 | 6.91 | 3.35 | 1.04 | **2.05** |
| point distance | 3.44 | 3.43 | 3.51 | 3.39 | 0.99 | 0.99 |
| axpy, real32 | 0.81 | 1.36 | 1.62 | 0.80 | 0.99 | 0.99 |
| BLAS gemm (vs `cblas_dgemm`) | 5.98 (C) | – | – | 3.98 | 0.67 | 0.67 |
| parallel axpy (6 threads) | 1.22 | 1.16 | 1.22 | 1.20 | 0.98 | 1.04 |
| parallel dot (6 threads) | 1.42 | 1.43 | 1.06 | 0.98 | 0.69 | 0.92 |
| parallel mandel (6 threads) | 43.76 | 40.91 | 40.75 | 45.42 | 1.04 | 1.11 |

- **Against `gfortran -O2` every kernel still meets its bar.** Against `gfortran -O3 -mcpu=native`
  three do not: complex axpy (2.05×), naive gemm (1.35×) and axpy (1.19×). These are the gaps that
  stand between nex and PLAN.md's "Versions" bar.
- **flang is nowhere faster than nex**, and is 2× slower on axpy and complex axpy, so the three gaps
  are what GCC's optimizer does, not something LLVM offers that nex fails to reach. flang and nex
  both beat gfortran on dot and nrm2 by vectorizing the sum.
- `gfortran -O3 -mcpu=native` is slower than `-O2` on axpy real32 (1.36 against 0.81), in two runs.
- **Point distance, gemm and gemv now feed each pass into the next** (`x1[1] += d[n] * 1e-30` and the
  like). Before, each pass recomputed the same result from unchanged inputs, and `gfortran -O3` ran
  point distance's fifty passes as one (0.16 ms a pass).

### The three gaps to `gfortran -O3`, diagnosed

Two of the three were the benchmark, not nex. In `gfortran -O3 -mcpu=native -S` of the axpy, complex
axpy and axpy real32 twins, the timed loop is turned inside out. The element loop is outside. Inside
it, `a * x(i)` is computed once and added to a register 50 times (`mov w0, 25` around two `fadd`s),
and `y(i)` is stored once. The fifty passes over 160 to 480 MB become one, and nothing else
explains the speed. The same twins under `-ffp-contract=off` run as fast (complex axpy 1.71 ms
against 1.69, axpy 1.37 against 1.37), so `fcmla` and contraction play no part. This
inside-out loop also explains why `-O3` was slower than `-O2` on axpy real32: fifty dependent
`real32` adds per element cost more than the memory traffic they save. The three kernels now feed
each pass into the next (`x[1] += y[n] * 1e-30`), as point distance, gemm and gemv already did, and
their checksums are unchanged.

Naive gemm is a real gap. gfortran unrolls and jams the `k` loop by two:
`c(i,j) = (c(i,j) + a(i,k) b(k,j)) + a(i,k+1) b(k+1,j)`, two-wide. That loads and stores `c(:,j)`
once per two `k`, and its additions are in the serial order, so the bits are unchanged (`-ffp-contract=off`
gives 85.1 ms against 83.9). nex's inner loop is already as good as LLVM makes it: four `<2 x double>`
per iteration, bounds checks hoisted. A C twin with `restrict`, built by `clang -O2`, runs at 114 ms,
as nex does. The same C with `k` jammed by two by hand runs at 85 ms, as gfortran does. LLVM has an
unroll-and-jam pass, but it is off by default, and `-mllvm -enable-unroll-and-jam` (count 2 or 4) does
not fire even on the C with `restrict`. Closing the gap therefore needs nex to unroll and jam the loop
itself: legality from its own dependence facts, and the remainder when `n` is odd. That is a design
item, not a flag.

Nothing is recovered by flags alone. nex's own `.ll`, rebuilt by `clang` with `-O3`, `-mcpu=native`,
`-ffp-contract=fast`, or all three, gives the same time as `-O2` within 1 % on all three kernels, and
the same checksums. `-ffp-contract=fast` changes nothing because contraction of IR needs the
`contract` flag on the instructions, which nex never writes (DESIGN §2.5). There is also the runtime alias check
(`vector.memcheck`) in gemm. It is there because `memref.alloc`'s 64-byte alignment rounds the
allocated pointer through `ptrtoint`/`inttoptr`, which loses its provenance. With the allocator
declared `noalias` and the aligned pointer derived by a `getelementptr` instead, the check goes away,
but the time does not change (113.1 ms against 113.0).

`zsh bench/run.zsh complex-axpy gemm axpy axpy-real32` from this branch, 2026-11-11, at a load of 7.8
to 11:

| kernel | gfortran -O2 | gfortran -O3 | flang -O3 | nex | ratio (bar) | nex/best |
|---|---:|---:|---:|---:|---:|---:|
| complex axpy | 3.28 | 3.27 | 7.51 | 3.37 | 1.03 | 1.03 (was 2.05) |
| gemm (naive) | 140.21 | 91.36 | 119.68 | 120.72 | 0.86 | **1.32** |
| axpy | 1.66 | 1.63 | 3.32 | 1.75 | 1.06 | 1.07 (was 1.19) |
| axpy, real32 | 0.83 | 0.83 | 1.64 | 0.81 | 0.97 | 0.97 |

## Scaling across the 18 cores

`zsh bench/run.zsh --scale`, the same run: each parallel kernel at `OMP_NUM_THREADS` 1 to 18 and
unset. The machine has 6 performance and 12 efficiency cores. Times in ms; *speedup* is over the same
program at one thread; *best* is the fastest of the three Fortran builds.

| kernel | threads | gfortran -O2 | gfortran -O3 | flang -O3 | nex | nex/best | best speedup | nex speedup |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| parallel axpy | 1 | 2.41 | 1.62 | 1.63 | 1.63 | 1.01 | 1.00 | 1.00 |
| | 2 | 1.43 | 1.39 | 1.39 | 1.27 | 0.92 | 1.17 | 1.29 |
| | 4 | 1.38 | 1.36 | 1.37 | 1.16 | 0.86 | 1.19 | 1.41 |
| | 6 | 1.22 | 1.20 | 1.22 | 1.18 | 0.99 | 1.35 | 1.38 |
| | 8 | 1.03 | 1.02 | 1.02 | 0.98 | 0.97 | 1.59 | 1.66 |
| | 12 | 0.98 | 0.98 | 1.00 | 0.97 | 0.99 | 1.65 | 1.69 |
| | 18 | 0.91 | 0.93 | 0.96 | 0.90 | 0.99 | 1.77 | 1.81 |
| | unset | 0.94 | 0.94 | 0.97 | 0.92 | 0.99 | 1.73 | 1.77 |
| parallel dot | 1 | 8.17 | 8.16 | 5.03 | 4.99 | 0.99 | 1.00 | 1.00 |
| | 2 | 4.11 | 4.11 | 2.55 | 2.52 | 0.99 | 1.97 | 1.98 |
| | 4 | 2.10 | 2.10 | 1.36 | 1.31 | 0.97 | 3.71 | 3.81 |
| | 6 | 1.42 | 1.42 | 1.05 | 0.98 | 0.93 | 4.77 | 5.11 |
| | 8 | 1.09 | 1.08 | 0.84 | 0.78 | 0.93 | 6.01 | 6.43 |
| | 12 | 0.83 | 0.85 | 0.91 | 0.77 | 0.93 | 6.03 | 6.45 |
| | 18 | 0.85 | 0.96 | 0.94 | 0.77 | 0.91 | 5.91 | 6.46 |
| | unset | 0.96 | 0.97 | 0.92 | 0.77 | 0.84 | 5.48 | 6.46 |
| parallel mandel | 1 | 120.49 | 112.95 | 112.31 | 124.83 | 1.11 | 1.00 | 1.00 |
| | 2 | 60.81 | 57.02 | 56.62 | 63.34 | 1.12 | 1.98 | 1.97 |
| | 4 | 56.47 | 52.93 | 52.65 | 58.72 | 1.12 | 2.13 | 2.13 |
| | 6 | 43.69 | 40.91 | 40.70 | 45.41 | 1.12 | 2.76 | 2.75 |
| | 8 | 35.81 | 33.44 | 32.97 | 37.02 | 1.12 | 3.41 | 3.37 |
| | 12 | 25.79 | 23.98 | 24.32 | 27.36 | 1.14 | 4.68 | 4.56 |
| | 18 | 18.10 | 16.89 | 16.77 | 19.03 | 1.13 | 6.70 | 6.56 |
| | unset | 18.12 | 16.91 | 16.81 | 19.03 | 1.13 | 6.68 | 6.56 |

**The schedule decides the compute-bound case.** `parallel-mandel` is a 1024 × 1024 Mandelbrot
grid: little memory, very uneven work, the costly points together in the middle of the grid. nex
gives each thread one equal contiguous share of the iterations (`compiler/emit_parallel.sysl`), which
is OpenMP's `static` schedule, and the three Fortran builds use `static` by default too. The same
gfortran twin with `schedule(runtime)`, at a load of about 3.7:

| threads | static | dynamic,1 | guided |
|---:|---:|---:|---:|
| 1 | 120.59 (1.00×) | 120.71 (1.00×) | 120.59 (1.00×) |
| 4 | 56.52 (2.13×) | 30.84 (3.91×) | 43.11 (2.80×) |
| 6 | 43.75 (2.76×) | 20.93 (5.77×) | 30.00 (4.02×) |
| 8 | 35.74 (3.37×) | 16.02 (7.54×) | 22.19 (5.43×) |
| 12 | 25.63 (4.70×) | 11.09 (10.88×) | 15.51 (7.78×) |
| 18 | 18.07 (6.67×) | 7.96 (15.16×) | 10.50 (11.49×) |

- With work handed out as threads free up, 18 threads run 15.2× faster than one; with equal shares,
  6.7×. Every one of the 18 cores does useful work; the efficiency cores were not the limit, the
  imbalance was.
- **The memory-bound kernels are near their ceiling**: parallel axpy levels off at about 1.8× and
  parallel dot at about 6.5×, where bandwidth runs out. A schedule cannot help them.
- **Left unset, the OpenMP runtimes use all 18 cores**, as fast as the best fixed count in every
  row, so nex does not need to pick a thread count. The `OMP_NUM_THREADS=6` the oracle uses for its
  main table understates the machine.

### With dynamic blocks

The threads now claim their work from a counter as they free up (DESIGN §9.5): runs of 1/16 of a
thread's share, at least one iteration and at most 16 blocks of 4096, a reduction's runs of whole
blocks, so every result keeps its bits. `zsh bench/run.zsh --scale` on branch `par-dynamic`,
2026-11-11, at a load of 4.6 to 9.4 (mandel's rows the busiest). nex columns only; *before* is the
table above.

| kernel | threads | nex ms | nex speedup | before |
|---|---:|---:|---:|---:|
| parallel axpy | 1 | 1.63 | 1.00 | 1.00 |
| | 2 | 1.15 | 1.42 | 1.29 |
| | 4 | 1.33 | 1.22 | 1.41 |
| | 6 | 0.99 | 1.66 | 1.38 |
| | 8 | 0.99 | 1.65 | 1.66 |
| | 12 | 0.94 | 1.74 | 1.69 |
| | 18 | 0.91 | 1.79 | 1.81 |
| | unset | 0.92 | 1.78 | 1.77 |
| parallel dot | 1 | 4.99 | 1.00 | 1.00 |
| | 2 | 2.53 | 1.97 | 1.98 |
| | 4 | 1.39 | 3.58 | 3.81 |
| | 6 | 0.97 | 5.14 | 5.11 |
| | 8 | 0.86 | 5.77 | 6.43 |
| | 12 | 0.70 | 7.10 | 6.45 |
| | 18 | 0.73 | 6.83 | 6.46 |
| | unset | 0.73 | 6.84 | 6.46 |
| parallel mandel | 1 | 125.58 | 1.00 | 1.00 |
| | 2 | 65.41 | 1.92 | 1.97 |
| | 4 | 34.06 | 3.69 | 2.13 |
| | 6 | 23.63 | 5.31 | 2.75 |
| | 8 | 17.74 | 7.08 | 3.37 |
| | 12 | 11.89 | 10.56 | 4.56 |
| | 18 | 8.76 | 14.34 | 6.56 |
| | unset | 8.71 | 14.42 | 6.56 |

- **Mandel scales as the Fortran twin does under `schedule(dynamic,1)`**: 14.3× at 18 threads
  against its 15.2×, and 8.76 ms against the static Fortran builds' 16.6 to 18.1 ms.
- **The memory-bound kernels lose nothing.** Axpy is within the run-to-run spread of the table above
  at every count. Dot is as fast or faster from 6 threads up (0.70 ms at 12, where static gave 0.77).
- **Claims of a single block were measured first and rejected**: parallel dot fell to 0.89 to 0.92 ms
  at 8 to 18 threads, about 15% behind static, the threads queueing on the counter. Runs of up to 16
  blocks bring a 10-million-element pass down to a few hundred claims.
