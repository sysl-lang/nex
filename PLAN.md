# The plan

nex is written here from scratch in sysl. The Scala 3 implementation at
[edadma/nex](https://github.com/edadma/nex) (local clone `~/dev/nex`) is a reference for behaviour
and its `docs/content/spec/` is the specification; no part of its structure is carried over. The
backend is MLIR from the first program compiled, and there is no interpreter: `nex run` compiles and
runs.

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

## Architecture

```
source ──parse──▶ AST ──elaborate──▶ typed IR ──emit──▶ MLIR text ──mlir-opt──▶ LLVM dialect
                                                                     │
       native program ◀──clang -O2 + runtime── LLVM IR ◀──mlir-translate
```

1. **The parser** (`lex`, `parse`, `ast`): the off-side rule and bracket-aware blocks through
   `sh.sysl.parsing`'s `Layout`, juxtaposition (`2pi`, `4a*c`), literate sources. `nex parse` prints
   the tree.
2. **The typed IR**: name resolution, inference, generics monomorphized away, the auto-clone pass
   (spec §8.3) made explicit as copies, and every array expression left as a whole-array operation
   rather than a loop. Every type in it is concrete. `nex elaborate` prints it.
3. **MLIR emission**: the typed IR to MLIR text, assembled in a `StrBuilder`. Scalars and control
   flow are `arith`, `math`, `scf` and `func`; an array expression is a `linalg.generic` over
   `tensor`s, one per operator, and fusing them is MLIR's job, not ours; complex numbers are the
   `complex` dialect with multiplication and division written out (below).
4. **The pipeline**: one `mlir-opt` run with a fixed pass list, `mlir-translate --mlir-to-llvmir`,
   and `clang -O2` with the runtime. The pass list is `experiments/mlir/pipeline.txt`:

   ```
   func.func(linalg-fuse-elementwise-ops), canonicalize, cse,
   one-shot-bufferize{bufferize-function-boundaries}, buffer-deallocation-pipeline,
   convert-linalg-to-loops, convert-scf-to-cf, convert-complex-to-standard,
   expand-strided-metadata, finalize-memref-to-llvm, convert-math-to-llvm, convert-complex-to-llvm,
   convert-arith-to-llvm, convert-func-to-llvm, convert-cf-to-llvm, reconcile-unrealized-casts
   ```

   The tools are driven through `sysl.process.capture`: a module goes to `mlir-opt` as a file in a
   `make_temp_dir` directory, or on its stdin through `Stdio.FromPath` or a `pipe` and
   `Stdio.FromFile`. LLVM is found at `NEX_LLVM_HOME`, else Homebrew's `opt/llvm` (LLVM 23).
5. **The runtime** (`runtime/nex_rt.c`), linked into every program: printing every value as the
   reference spells it — reals as Java's `Double.toString` (`1.0E20`, `4.9E-324`), complex numbers,
   arrays read through `llvm.emit_c_interface` memref descriptors honouring their strides — plus the
   string, handle and trap machinery below.

`tests_toolchain.sysl` holds the pipeline to account: four hand-written proofs in
`experiments/mlir/` go through it from sysl and must print their corpus output, and the library
calls the driver is built from are each pinned there. Without `mlir-opt` those tests skip.

## What MLIR gives, and what it does not

- **Elementwise fusion is free.** `313-02` (point distance) emits three `linalg.generic`s, one per
  operator; `linalg-fuse-elementwise-ops` makes them one loop, and its one allocation is freed by
  `buffer-deallocation-pipeline`. Emission never fuses by hand.
- **Complex multiplication and division are emitted over `complex.re` / `complex.im`.** The
  dialect's lowerings recover infinities (Annex G) for `mul` and use Smith's algorithm for `div`,
  which differ in the last bits from nex's textbook formulas and do not trap on a zero divisor.
  `complex.add` and `complex.sub` lower as nex means them and are used directly.
- **A tensor parameter bufferizes to a strided memref.** Converting it to an identity layout forces a
  `memref.copy`, which lowers to a call of `memrefCopy` from `libmlir_c_runner_utils`. Functions
  read their parameters at the strided layout, and the runtime defines its own `memrefCopy` for the
  copies a view genuinely needs, so no MLIR runtime library is linked.
- **There are no pointer element types.** `memref<4x!llvm.ptr>` is an invalid memref element type,
  and a `tensor` of `!llvm.ptr` cannot be bufferized. An array of strings, closures, enums with
  payloads or structs holding them is an array of `i64` handles into runtime tables; an array of
  plain-scalar structs is stored as one array per field.
- **Division traps.** Integer division by zero and real `/` by zero both trap in nex, so every
  division is emitted behind a check that calls the runtime's trap.
- **Traps are catchable.** `assert_traps` (corpus 252–254) runs a lambda and passes when it traps,
  so a trap is a `longjmp` to the innermost `setjmp` the runtime armed, and an uncaught one prints
  its message and exits. Every trap goes through one runtime entry for that reason.

## Milestones

Each is one bounded item ending in a green `sysl test .` on its branch, with the corpus programs of
its categories passing. The counts are from `index.tsv`'s category column; they sum to 425.

1. **M1 — the parser** (branch `m1-parser`). *Exit*: all 425 corpus programs parse; `nex parse`
   prints the tree; the reference's lexer and parser cases ported.
2. **M2 — the typed IR.** Elaboration, inference, generics monomorphized, auto-clone made explicit.
   *Exit*: all 425 elaborate; the reference's elaborator stage 1–3 cases ported (positive ones by
   the printed IR, negative ones by their diagnostic).
3. **M3 — scalars and the pipeline: 151.** Emission for scalars, control flow, functions, strings and
   printing; the driver and the runtime's printing and trapping division. *Exit*: top-level bindings
   (4), scalar arithmetic (13), comparison + logical (12), chained comparison (7), control flow (27),
   blocks + scoping (4), top-level initialization (3), compound assignment (8), functions (43),
   string interpolation (19), const fn calls (5), mut by-ref (6) — 151 pass.
4. **M4 — aggregates and closures: 38 more, 189.** Structs, tuples, enums, escaping closures, the
   handle tables. *Exit*: structs (8), tuple destructuring (6), paren-less tuple construction (8),
   sum types (13), closure escape (3) pass.
5. **M5 — generics: 36 more, 225.** *Exit*: user generics (17), user generic enums (10), user generic
   structs (9) pass.
6. **M6 — arrays: 115 more, 340.** `tensor` and `linalg.generic` emission, fusion through the
   pipeline, bufferization, auto-clone copies, rank-2. *Exit*: arrays (96), auto-clone (14), byte
   buffers (5) pass, and 313-02's emitted loop count is one.
7. **M7 — views: 35 more, 375.** Slices as strided memrefs, the runtime's `memrefCopy`, bounds and
   stride traps. *Exit*: view-style slicing (9), rank-1 strided (8), rank-2 (9), rank-2
   sub-rectangle (9) pass.
8. **M8 — the prelude and catchable traps: 50 more, 425.** The array and matrix prelude, `assert_approx`,
   `assert_traps` over `setjmp`/`longjmp`. *Exit*: prelude (38) and docs/examples (12) pass: **the
   whole corpus, 425 of 425**; `examples/fft` compiles and runs.
9. **M9 — modules and `nex test`.** The module loader, the source prelude found by `--prelude-path`
   / `NEX_HOME`, `@test` discovery. *Exit*: the reference's module loader, sysroot, prelude
   integration and test runner cases ported.
10. **M10 — performance.** *Exit*: the perf oracle below, met on every kernel.

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

*Exit*: every kernel within 1.25× of `gfortran -O2` and no slower than the Scala reference's AOT
output, and no kernel allocates a temporary its Fortran twin does not. The timings, the machine and
the LLVM version are recorded in `bench/RESULTS.md` beside the kernels.
