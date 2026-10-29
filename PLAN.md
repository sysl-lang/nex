# The plan

nex is written here from scratch in sysl. The Scala 3 implementation at
[edadma/nex](https://github.com/edadma/nex) (local clone `~/dev/nex`) is a reference for behaviour,
and its `docs/content/spec/` is the specification **as amended by `DESIGN.md`**: rank-N arrays with
static shapes, slices as views, sized precision, `end`-relative indexing with no negative wrap,
`inout` borrows, parallel loops and reductions, and C/BLAS/LAPACK through `extern`. No part of the
reference's structure is carried over. The backend is MLIR from the first program compiled, and
there is no interpreter: `nex run` compiles and runs.

This implementation is also a **stressor for sysl**: a real compiler for a real numerical language,
so every gap it meets in sysl is reported to sysl first (org rule 9) rather than routed around here.

## The oracle

`testdata/corpus/` holds the reference's 425 programs, each `NNN-<name>.nex` beside
`NNN-<name>.out`, the exact bytes it must print. `index.tsv` gives each program's category, its name,
and whether the reference's own MLIR backend reaches it (348 do). That column is how far the
reference went, not a limit of MLIR: the 77 it misses — the view-slicing categories, byte buffers,
part of the prelude — are milestones here like the rest.

A program **passes** when `nex run` on it prints its `.out` byte for byte. Every milestone below is
a count of passing programs, by category, and every milestone carries the earlier ones' passes
unchanged.

### The corpus under DESIGN.md

The reference's `.out` files are the oracle only for programs whose meaning DESIGN.md leaves alone.
Counted with `grep` over `testdata/corpus/*.nex`:

| What changed | Grep | Programs | Syntax only, `.out` stands | Meaning changes, new `.out` |
|---|---|---|---|---|
| `[[T]]` types (DESIGN §3.1) | `[[` + a type name + `]]` | 2: 067, 321 | 2 | 0 |
| negative indices and bounds (§5.1) | `[A-Za-z0-9_)\]]\[ *-` and `-` after `,` or `..` inside `[…]` | 13: 109–116, 118, 120, 122, 351, 360 | 11 rewritten; 112 and 116 **untouched** (their negative index still traps with `out of bounds`) | 0 |
| `mut` parameters (§8) | `-w mut` | 10: 127, 128, 286–289, 291, 294–296 | 8 | 2: **295**, **296** |
| `a.view(…)` (§6) | `\.view(` | 35: 345–379 | 33 (29 read-only, 4 writing through the view) | 2: **353**, **362** |

The sets overlap in 351 and 360 (a view with a negative bound), so **58 distinct programs** are
touched: 2 stay byte-for-byte as the reference wrote them, **52 are rewritten with their `.out`
unchanged**, and **4 get a new `.out`**. The other **367 programs are untouched**, and their `.out`
files remain the reference's. No corpus program uses `inout`, `parallel` or `extern` as a name, binds
`end`, or puts a literal after a loop index named `i` (`2i` inside `for i`), so no other program
changes reading.

**How each is migrated** — one commit, before M1, in `testdata/corpus/` itself (git keeps the
reference's text), with a new `index.tsv` column `v2` = `same`, `syntax` or `meaning`:

- **`[[T]]`** → `[T; :, :]` (067's `[[integer]]`, 321's `[[real]]`).
- **Negative indices** → `end`-relative: `a[-1]` → `a[end]`, `a[-3..-1]` → `a[end-2..end]`,
  `a[..-1]` → `a[..end]`, `a[..=-1]` → `a[..=end]`, `m[:, -1]` → `m[:, end]`,
  `m[-2..length(m), …]` → `m[end-1.., …]`, `a.view(-3..)` → `a[end-2..]`. Each program prints what it
  printed before. 112 and 116 stay as written: they test that an out-of-range index traps, and a
  negative index now always does.
- **`mut`** → `inout`, in the parameter's mode position (`v: mut [integer]` → `v: inout [integer]`).
  127 and 128 pass `v` through a non-escaping lambda to `assert_traps`, which DESIGN §8.3 rule 4
  allows. 286–289, 291 and 294 print what they did: a scalar `mut` was already by reference, and 294
  prints nothing. **295** now prints `0` (was `10`): `zero_first(a)` borrows `a` and zeroes it, and
  nothing is moved or cloned. **296** now prints `10` then `0` (was `10`, `10`): `var b = a` is
  still a clone because `a` is used again, and `zero_first(b)` now zeroes `b` itself.
- **`a.view(…)`** → a slice: `a.view(r)` → `a[r]`, `a.view(r, k)` → `a[r by k]`, `m.view(r)` →
  `m[r, :]` (axis 1 left whole), `m.view(r, c)` → `m[r, c]`; a view of a view becomes a slice of a
  slice. The 29 read-only programs print what they did. The 4 that write through a named view —
  **347, 356, 366, 373** — write the source's window instead, `v[0] = 99` with `val v = a.view(1..4)`
  becoming `a[1..4][0] = 99` (DESIGN §5.3), and print what they did. **353** now prints `30` (was
  `99`) and **362** prints `5` (was `99`): a view keeps the value it was taken with (DESIGN §6.2 rule
  4).

The four new `.out` files are written from DESIGN.md's rules, not from any implementation's output,
and the commit that writes them quotes the rule beside each.

### The new corpus

DESIGN.md's new features have no reference programs, so each milestone below that brings one adds
its programs to `testdata/v2/`, in the corpus's own form (`NNN-<name>.nex` beside `.out`, an
`index.tsv` with a category column), each `.out` written from DESIGN.md before the code that passes
it. The five MLIR proofs added for the design (below) are each restated there as nex programs.

## Architecture

```
source ──parse──▶ AST ──elaborate──▶ typed IR ──emit──▶ MLIR text ──mlir-opt──▶ LLVM dialect
                                                                     │
       native program ◀──clang -O2 + runtime── LLVM IR ◀──mlir-translate
```

1. **The parser** (`lex`, `parse`, `ast`): the off-side rule and bracket-aware blocks through
   `sh.sysl.parsing`'s `Layout`, juxtaposition (`2pi`, `4a*c`), literate sources, array types with
   axes (`[real; :, :]`), and `end` read by bracket depth (DESIGN §5.2). `nex parse` prints the tree.
2. **The typed IR**: name resolution, inference over the precision lattice (DESIGN §2), generics and
   ranks monomorphized away, the auto-clone pass (spec §8.3) made explicit as copies — including the
   view copies of DESIGN §6.2 — the `inout` exclusivity check and the parallel-safety check, and
   every array expression left as a whole-array operation rather than a loop. Every type in it is
   concrete. `nex elaborate` prints it.
3. **MLIR emission**: the typed IR to MLIR text, assembled in a `StrBuilder`. Scalars and control
   flow are `arith`, `math`, `scf` and `func`; an array of shape `(d0, …, dk)` is a
   `tensor<dk×…×d0×T>` (axes reversed, so the default layout is column-major); an array expression
   is a `linalg.generic` per operator, and fusing them is MLIR's job, not ours; a slice is a
   `tensor.extract_slice`; complex numbers are the `complex` dialect with multiplication and
   division written out (below). Every function but `main` is `private`.
4. **The pipeline**: one `mlir-opt` run with a fixed pass list, `mlir-translate --mlir-to-llvmir`,
   and `clang -O2` with the runtime. Today's pass list is `experiments/mlir/pipeline.txt`:

   ```
   func.func(linalg-fuse-elementwise-ops), canonicalize, cse,
   one-shot-bufferize{bufferize-function-boundaries}, buffer-deallocation-pipeline,
   convert-linalg-to-loops, convert-scf-to-cf, convert-complex-to-standard,
   expand-strided-metadata, finalize-memref-to-llvm, convert-math-to-llvm, convert-complex-to-llvm,
   convert-arith-to-llvm, convert-func-to-llvm, convert-cf-to-llvm, reconcile-unrealized-casts
   ```

   It changes as the design needs (next section). The tools are driven through
   `sysl.process.capture`: a module goes to `mlir-opt` as a file in a `make_temp_dir` directory, or
   on its stdin through `Stdio.FromPath` or a `pipe` and `Stdio.FromFile`. LLVM is found at
   `NEX_LLVM_HOME`, else Homebrew's `opt/llvm` (LLVM 23).
5. **The runtime** (`runtime/nex_rt.c`), linked into every program: printing every value as the
   reference spells it — reals as Java's `Double.toString` (`1.0E20`, `4.9E-324`), complex numbers,
   arrays read through `llvm.emit_c_interface` memref descriptors honouring their strides — plus the
   string, handle and trap machinery below. `libomp` is linked when a program has a `parallel`
   construct, and a BLAS when it calls one.

`tests_toolchain.sysl` holds the pipeline to account: hand-written proofs in `experiments/mlir/` go
through it from sysl and must print their expected output, and the library calls the driver is
built from are each pinned there. Without `mlir-opt` those tests skip.

### The pipeline, revised

The design's proofs (`views.mlir`, `view-then-write.mlir`, `parallel.mlir`, `blas.mlir`,
`precision.mlir`) were each run by hand through the toolchain; `pipeline.txt` and
`tests_toolchain.sysl` take them on in the milestone that first needs them. **Sequential:**

```
func.func(linalg-fuse-elementwise-ops), canonicalize, cse,
one-shot-bufferize{bufferize-function-boundaries}, drop-equivalent-buffer-results,
buffer-deallocation-pipeline, convert-bufferization-to-memref,
convert-linalg-to-loops, convert-scf-to-cf, convert-complex-to-standard,
expand-strided-metadata, lower-affine, finalize-memref-to-llvm, convert-math-to-llvm,
convert-complex-to-llvm, convert-arith-to-llvm, convert-func-to-llvm, convert-cf-to-llvm,
reconcile-unrealized-casts
```

Three passes are new, each forced by a proof that fails without it:

- `drop-equivalent-buffer-results` — a private function that writes an argument in place and returns
  it returns nothing instead, which is the `inout` calling convention; without it
  `buffer-deallocation-pipeline` clones the returned buffer, a whole-array copy per call
  (`parallel.mlir`).
- `convert-bufferization-to-memref` — lowers the `bufferization.clone`s the deallocation pipeline
  still makes (`parallel.mlir`).
- `lower-affine` — `expand-strided-metadata` leaves `affine.apply` for a subview of a dynamic-shape
  source, which `finalize-memref-to-llvm` does not lower (`views.mlir`, `parallel.mlir`).

The four existing proofs (145, 313, 316, real spelling) print the same bytes through the revised
list. **OpenMP** inserts, after `convert-bufferization-to-memref`,
`func.func(scf-forall-to-parallel), convert-linalg-to-parallel-loops, convert-scf-to-openmp`, and,
before `convert-func-to-llvm`, `convert-openmp-to-llvm`; the program links `libomp` from
`$NEX_LLVM_HOME/lib`.

## What MLIR gives, and what it does not

- **Elementwise fusion is free.** `313-02` (point distance) emits three `linalg.generic`s, one per
  operator; `linalg-fuse-elementwise-ops` makes them one loop, and its one allocation is freed by
  `buffer-deallocation-pipeline`. Emission never fuses by hand. It holds at rank 3 (`views.mlir`).
- **Views are free.** A `tensor.extract_slice` bufferizes to a strided `memref.subview` of its
  source, with no allocation and no copy, for a column, a row, a window strided on both axes and a
  plane of a rank-3 array, each handed to a function as a dynamic-shape tensor (`views.mlir`). When
  the source is written while a view is live, bufferization makes the one copy value semantics
  needs, and no other (`view-then-write.mlir`).
- **Complex multiplication and division are emitted over `complex.re` / `complex.im`.** The
  dialect's lowerings recover infinities (Annex G) for `mul` and use Smith's algorithm for `div`,
  which differ in the last bits from nex's textbook formulas and do not trap on a zero divisor.
  `complex.add` and `complex.sub` lower as nex means them and are used directly. The same holds at
  `complex<f32>` (`precision.mlir`).
- **Every width lowers.** `f16` arithmetic and `sqrt`, `f32` `sin`, `i8` overflow detection with
  `llvm.intr.sadd.with.overflow`, and width conversions all go through the existing list
  (`precision.mlir`). An `f16` transcendental other than `sqrt` was not run.
- **A tensor parameter bufferizes to a strided memref.** Converting it to an identity layout forces a
  `memref.copy`, which lowers to a call of `memrefCopy` from `libmlir_c_runner_utils`. Functions
  read their parameters at the strided layout, and the runtime defines its own `memrefCopy` for the
  copies a view genuinely needs, so no MLIR runtime library is linked.
- **Parallel loops lower to OpenMP.** `scf.forall` with `shared_outs`, `scf.parallel` with
  `scf.reduce`, and a parallel `linalg.generic` all reach `omp.wsloop` (with an
  `omp.declare_reduction` for the reduction) and run on several threads (`parallel.mlir`). An element
  write inside one must be a `linalg.fill` of a one-element slice: `tensor.from_elements` costs an
  allocation and a `memrefCopy` per iteration.
- **BLAS takes a view as it is.** A column-major matrix or a view with unit stride along axis 0 is a
  pointer (`extract_aligned_pointer_as_index` plus the metadata offset) and a leading dimension (the
  memref's axis-0 stride), handed to `cblas_dgemm` with no copy (`blas.mlir`, Accelerate).
- **There are no pointer element types.** `memref<4x!llvm.ptr>` is an invalid memref element type,
  and a `tensor` of `!llvm.ptr` cannot be bufferized. An array of strings, closures, enums with
  payloads or structs holding them is an array of `i64` handles into runtime tables; an array of
  plain-scalar structs is stored as one array per field.
- **Division traps.** Integer division by zero and real `/` by zero both trap in nex, so every
  division is emitted behind a check that calls the runtime's trap.
- **Traps are catchable.** `assert_traps` (corpus 252–254) runs a lambda and passes when it traps,
  so a trap is a `longjmp` to the innermost `setjmp` the runtime armed, and an uncaught one prints
  its message and exits. Every trap goes through one runtime entry for that reason. A `longjmp` may
  not leave an OpenMP worker, so inside a parallel region the entry records the trap and the region's
  end raises it (DESIGN §9.4; not yet run).

## Milestones

Each is one bounded item ending in a green `sysl test .` on its branch, with the corpus programs of
its categories passing. Corpus counts are from `index.tsv`'s category column (they sum to 425, all
of the corpus as migrated above); `v2` counts are the programs the milestone adds to `testdata/v2/`.

0. **M0 — the corpus migration** (branch `corpus-v2`). *Exit*: the 52 rewrites and 4 new `.out`
   files of "The corpus under DESIGN.md" committed; `index.tsv`'s `v2` column reads 367 `same` +
   2 untouched-trap `same` (369), 52 `syntax`, 4 `meaning`; `grep -lw mut`, `grep -l '\.view('`
   and the negative-index grep return only 112 and 116.
1. **M1 — the parser.** The reference's syntax is on dev (`fa31517`, lexer, parser, corpus and
   literate tests); what remains is DESIGN.md's syntax, as its own item after M0. *Exit*: all 425
   corpus programs, as migrated, parse; `nex parse` prints the tree; the reference's lexer and
   parser cases ported; parser cases for array types
   with axes and static extents, rank-3 literals, every subscript form with `end` (including `end`
   on a continuation line inside brackets, and `end for` after a line ending in `]`), `inout`,
   `parallel for … reduce`, `parallel` expressions and `extern def` with its attributes.
2. **M2 — the typed IR.** Elaboration, inference over the precision lattice, generics and `Rank`
   parameters monomorphized, auto-clone and view copies made explicit, the `inout` exclusivity check,
   the parallel-safety check and the module-`var` effect summary both use. *Exit*: all 425
   elaborate; the reference's elaborator stage 1–3 cases ported (positive ones by the printed IR,
   negative ones by their diagnostic); a negative case for each rule of DESIGN §8.3 and §9.4 and for
   each narrowing that §2.2 refuses.
3. **M3 — scalars and the pipeline: 151.** Emission for scalars of every width, control flow,
   functions, strings and printing; the driver and the runtime's printing per width and trapping
   division and overflow at every width; `inout` scalars. `precision.mlir` joins the toolchain tests.
   *Exit*: top-level bindings (4), scalar arithmetic (13), comparison + logical (12), chained
   comparison (7), control flow (27), blocks + scoping (4), top-level initialization (3), compound
   assignment (8), functions (43), string interpolation (19), const fn calls (5), `inout` by-ref (6)
   — 151 pass; and `v2` **precision** programs (every type of DESIGN §2.1 printed, each promotion
   rule, each conversion's trap, literal adoption, `real32` printing) pass.
4. **M4 — aggregates and closures: 38 more, 189.** Structs, tuples, enums, escaping closures, the
   handle tables. *Exit*: structs (8), tuple destructuring (6), paren-less tuple construction (8),
   sum types (13), closure escape (3) pass.
5. **M5 — generics: 36 more, 225.** *Exit*: user generics (17), user generic enums (10), user generic
   structs (9) pass; `v2` rank-generic programs (`R: Rank`, one function called at ranks 1, 2 and 3)
   pass.
6. **M6 — arrays of any rank: 115 more, 340.** `tensor` and `linalg.generic` emission with reversed
   axes, static shapes as static tensor dimensions, fusion, bufferization, auto-clone copies,
   `inout` arrays through `drop-equivalent-buffer-results`, the shape functions of DESIGN §4.3.
   `pipeline.txt` becomes the revised sequential list. *Exit*: arrays (96), auto-clone (14), byte
   buffers (5) pass; 313-02's emitted loop count is one; `v2` **rank-N** programs (rank-3 literals,
   indexing, element-wise, `sum_axis` on axis 2, `reshape`/`flatten` round trips at rank 3, static
   shape compile errors) pass; and an `inout` array call emits no `memref.copy`.
7. **M7 — views: 35 more, 375.** Every slice a `tensor.extract_slice`, the runtime's `memrefCopy`,
   `end`, bounds and stride traps, `by` on every axis, slice assignment in place, the escape and
   source-written copies of DESIGN §6.2. `views.mlir` and `view-then-write.mlir` join the toolchain
   tests. *Exit*: view-style slicing (9), rank-1 strided (8), rank-2 (9), rank-2 sub-rectangle (9)
   pass; `v2` view programs (rule 4, a returned view, a view stored in a struct, a strided rank-3
   plane) pass; and **passing a slice to a function allocates nothing**: the bufferized IR of each
   view program in the four categories has no `memref.alloc` or `memref.copy` the program's own
   arrays do not account for.
8. **M8 — the prelude and catchable traps: 50 more, 425.** The array and matrix prelude at every
   rank, `assert_approx`, `assert_traps` over `setjmp`/`longjmp`. *Exit*: prelude (38) and
   docs/examples (12) pass: **the whole corpus, 425 of 425**; `examples/fft` compiles and runs.
9. **M9 — parallel.** `parallel for` with `shared_outs`, `reduce` clauses as `scf.parallel` +
   `scf.reduce`, `parallel map` and parallel element-wise expressions, the OpenMP pipeline, the trap
   relay out of a parallel region. `parallel.mlir` joins the toolchain tests (skipped without
   `libomp`). *Exit*: `v2` **parallel** programs pass under both the sequential and the OpenMP
   pipeline with identical output (integer reductions, and real ones whose order cannot matter); each
   rejected body of DESIGN §9.4 is a negative elaborator case; a trapping iteration is caught by
   `assert_traps`; a reduction over every operator of §9.2 runs (the OpenMP lowering of `min`, `max`,
   `and`, `or` and complex `+` is proved here or reported); and on this machine at
   `OMP_NUM_THREADS=4` the perf oracle's axpy, dot and point-distance kernels written with `parallel`
   run at least 2.5× faster than their sequential builds.
10. **M10 — FFI, BLAS and LAPACK.** `extern def`, `@link`, `@symbol`, `@strided`, `@pure`; arrays and
    views crossing per DESIGN §10.3 (with the copies it requires); `@` dispatching to `gemm`, `gemv`
    and `dot` by threshold and by shape; the LAPACK prelude. `blas.mlir` joins the toolchain tests
    (skipped without a BLAS). *Exit*: `v2` **FFI** programs pass — a libm function, `cblas_ddot` on a
    strided view with `incx = 2`, `dgemm` on a sub-block view with its leading dimension, an `inout`
    LAPACK `dgesv` solve, `transpose(A) @ B` dispatched with the `T` flag and no transposed copy;
    `A @ B` above the threshold emits a call and below it a `linalg.matmul`, checked in the emitted
    MLIR; and the BLAS gemm kernel below meets its bar.
11. **M11 — modules and `nex test`.** The module loader, the source prelude found by
    `--prelude-path` / `NEX_HOME`, `@test` discovery. *Exit*: the reference's module loader,
    sysroot, prelude integration and test runner cases ported.
12. **M12 — performance.** *Exit*: the perf oracle below, met on every kernel.

## The perf oracle

nex claims Fortran's performance, so it is measured against Fortran. Each kernel is written three
times — in nex for this compiler, in nex for the Scala reference's AOT backend, and in Fortran for
`gfortran -O2` — and timed on one machine, best of five, at sizes that leave the cache:

| kernel | shape |
|---|---|
| axpy | `y = a*x + y`, n = 10⁷ |
| dot | `sum(x * y)`, n = 10⁷ |
| nrm2 | `sqrt(sum(x * x))`, n = 10⁷ |
| gemv | `y = A x`, 4000 × 4000 |
| gemm | `C = A B`, 1000 × 1000, naive triple loop in every language |
| stencil | 3-point Jacobi sweep, n = 10⁷, 100 sweeps |
| complex axpy | `y = a*x + y` over complex, n = 10⁷ |
| point distance | `sqrt((x2-x1)^2 + (y2-y1)^2)` elementwise, n = 10⁷ — a fusion check |
| axpy, real32 | as axpy, over `real32` — the same time per byte as `real64` |
| BLAS gemm | `C = A @ B`, 1000 × 1000, through the BLAS dispatch |
| parallel axpy, dot | the `parallel` forms, `OMP_NUM_THREADS` = the performance-core count |

*Exit*: every sequential kernel within 1.25× of `gfortran -O2` and no slower than the Scala
reference's AOT output, and no kernel allocates a temporary its Fortran twin does not; BLAS gemm
within 1.1× of the same BLAS's `cblas_dgemm` called from C; the parallel kernels within 1.25× of
`gfortran -O2 -fopenmp` with `!$omp parallel do`. The timings, the machine and the LLVM version are
recorded in `bench/RESULTS.md` beside the kernels.
