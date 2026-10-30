# The plan

nex is written here from scratch in sysl. The Scala 3 implementation at
[edadma/nex](https://github.com/edadma/nex) (local clone `~/dev/nex`) is a reference for behaviour,
and its `docs/content/spec/` is the specification **as amended by `DESIGN.md`**: rank-N arrays with
static shapes, 1-based indexing and inclusive `..` ranges as in Fortran, the `iso_fortran_env` type
names, slices as views, `end`-relative indexing with no negative wrap, `inout` borrows,
reproducible parallel loops and reductions, and C/BLAS/LAPACK/Fortran through `extern`. No part of the
reference's structure is carried over. The backend is MLIR from the first program compiled, and
`nex run` compiles and runs. The compiler is the source of truth; an interpreter is a later, gated
item that executes the compiler's own typed form (below).

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

The sets overlap in 351 and 360 (a view with a negative bound), so 58 distinct programs are touched
by these four changes; 2 of them (112, 116) keep their text.

**On top of these, the whole corpus is rewritten to v3 syntax**: 1-based indexing, inclusive `..`
(`..<` for half-open), and the `iso_fortran_env` type names. Counted with `grep` over
`testdata/corpus/*.nex`, **162 programs** index an array or write a range (`[A-Za-z0-9_)]\[` or
`\.\.`), and the 5 byte-buffer programs (421–425, `bytes(n)`) become `[uint8]` programs; no corpus
program spells a sized type name (`integerN`, `complexN`). Each is
rewritten so it computes **the same thing**: an index `a[k]` becomes `a[k + 1]` (or the loop that
produced `k` shifts its range), the reference's half-open `lo..hi` over indices becomes
`lo+1..hi`, its inclusive `..=` becomes `..`, and a byte buffer becomes `[uint8]`. A range that
is not an index range (`for k in 0..3` counting, printing `k`) is restated to keep its values
(`for k in 0..2`). A program whose output
**prints an index or a loop counter** (a `print(i)`, an "at index" message, an `argmax`, an
out-of-bounds trap message naming the index) gets a new `.out` with the 1-based value, written from
DESIGN.md. The exact `syntax` / `meaning` split is counted by the migration commit itself, which
records it in `index.tsv`; the programs that touch neither an index, a range nor a sized type
(about 260) stay byte-for-byte the reference's. No corpus program uses `inout`, `parallel`,
`extern`, `origin` or `rebase` as a name, binds `end`, or puts a literal after a loop index named
`i` (`2i` inside `for i`), so no other program changes reading.

**How each is migrated** — one commit, before M1, in `testdata/corpus/` itself (git keeps the
reference's text), with a new `index.tsv` column `v3` = `same`, `syntax` or `meaning`:

- **`[[T]]`** → `[T; :, :]` (067's `[[integer]]`, 321's `[[real]]`).
- **1-based, inclusive ranges** → every index shifted by one and every range restated: the
  reference's `for k in 0..n` (half-open) is `for k in 1..n`, `a[0]` is `a[1]`, `a[i..j]` (half-open)
  is `a[i+1..j]`, `a[i..=j]` is `a[i+1..j+1]`.
- **Byte buffers** → `[uint8]` (DESIGN §2.1, §3.1): `val b = bytes(4)` → `val b: [uint8] =
  zeros(4)`, and the byte prelude (`to_bytes`, `read_bytes`, `write_bytes`) takes and gives
  `[uint8]`. A program that prints a whole buffer (422's hex dump) is `meaning` if `[uint8]` prints
  differently from the reference's byte buffer, and its `.out` is rewritten from DESIGN.md.
- **Negative indices** → `end`-relative: `a[-1]` → `a[end]`, `a[-3..-1]` → `a[end-2..end]`,
  `a[..-1]` (half-open) → `a[..end-1]`, `a[..=-1]` → `a[..end]`, `m[:, -1]` → `m[:, end]`,
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
  `m[r, :]` (the second axis left whole), `m.view(r, c)` → `m[r, c]`, each range then restated
  1-based and inclusive; a view of a view becomes a slice of a
  slice. The 29 read-only programs print what they did. The 4 that write through a named view —
  **347, 356, 366, 373** — write the source's window instead, `v[0] = 99` with `val v = a.view(1..4)`
  becoming `a[2..4][1] = 99` (DESIGN §5.3; the same elements, 1-based and inclusive), and print what
  they did. **353** now prints `30` (was
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
   flow are `arith`, `math`, `scf` and `func`; an array of shape `(d1, …, dk)` is a
   `tensor<dk×…×d1×T>` (axes reversed, so the default layout is column-major, and each 1-based nex
   index is lowered by subtracting 1, which folds into loop bounds); an array expression
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
5. **The runtime** (`runtime/`, a sysl archive from `sysl build-c`), linked into every program: printing every value as the
   reference spells it — reals as Java's `Double.toString` (`1.0E20`, `4.9E-324`), complex numbers,
   arrays read through `llvm.emit_c_interface` memref descriptors honouring their strides — plus the
   string, handle and trap machinery below. `libomp` is linked when, and only when, a program has a
   `parallel` construct (no flag), and a BLAS when it calls one; a program calling Fortran links
   `libgfortran`.

   **The counted heap** (`runtime/heap.sysl`) holds every string built at run time, every cell a
   lambda captures and every lambda's environment: an object is a two-word header (a count and the
   function that releases what its payload holds) before its payload, and **a handle is the payload's
   address**, so a string is still a `char *` every C function reads as it is. A literal is a constant
   with the same header and a negative count, never freed. The emitter keeps the counts
   (`emit_own.sysl`): every place — a local's slot, a cell, a module-level binding, a field — owns
   one count on its value; a store retains the new value and releases the old; a value an expression
   makes (a call, a concatenation, an interpolation, a lambda) is its statement's temporary, released
   where the statement ends; a parameter is borrowed for the call and a result owned by the caller.
   A struct, tuple or enum is an LLVM struct value, never a heap object (no type contains itself), so
   counting one counts its parts. The tables of handles an array of strings, closures or enums with
   payloads stores (below) are arrays of these addresses as `i64`; a runtime table indexed by number
   would buy nothing but a load per use. Counts are atomic (DESIGN §9.5): a `parallel` body may copy
   and drop an outer string on several threads at once. The leak check (`tests_run_aggregate.sysl`) runs the
   `testdata/leaks/` programs under `leaks --atExit` and under Guard Malloc.

`tests_toolchain.sysl` holds the pipeline to account: hand-written proofs in `experiments/mlir/` go
through it from sysl and must print their expected output, and the library calls the driver is
built from are each pinned there. Without `mlir-opt` those tests skip.

### The pipeline, revised

The design's proofs (`views.mlir`, `view-then-write.mlir`, `parallel.mlir`, `blas.mlir`,
`precision.mlir`) were each run by hand through the toolchain; `pipeline.txt` and
`tests_toolchain.sysl` take them on in the milestone that first needs them. **Sequential:**

```
canonicalize, cse, func.func(linalg-fuse-elementwise-ops), canonicalize, cse,
one-shot-bufferize{bufferize-function-boundaries allow-return-allocs-from-loops},
canonicalize, drop-equivalent-buffer-results, canonicalize, cse, canonicalize,
buffer-deallocation-pipeline, convert-bufferization-to-memref,
convert-linalg-to-loops, convert-scf-to-cf, convert-complex-to-standard,
expand-strided-metadata, lower-affine, finalize-memref-to-llvm, convert-math-to-llvm,
convert-complex-to-llvm, convert-arith-to-llvm, convert-func-to-llvm, convert-cf-to-llvm,
reconcile-unrealized-casts
```

Each pass and setting below is new, forced by a program that fails or copies without it:

- `canonicalize, cse` before fusion — the emitter checks the shapes of element-wise operands and
  sizes each result from an operand's extents, and those `tensor.dim` uses of an intermediate
  result stop `linalg-fuse-elementwise-ops`, which fuses only a producer with one use. Folded
  first, they go, and 313-02's three operators are one loop (`tests_run_array.sysl`).
- `allow-return-allocs-from-loops` — a loop that rebinds an array local to a new value
  (`a = a * 2` in a `for`, a growing `flatMap` result) carries a fresh buffer round the loop.

- `drop-equivalent-buffer-results` — a private function that writes an argument in place and returns
  it returns nothing instead, which is the `inout` calling convention; without it
  `buffer-deallocation-pipeline` clones the returned buffer, a whole-array copy per call
  (`parallel.mlir`).
- `canonicalize` around it, then `cse, canonicalize` — a callee whose `inout` array is carried
  round a loop returns the loop's result, which is its argument only once the bufferized loop is
  folded away, so the canonicalize before `drop-equivalent-buffer-results` lets it drop the result.
  The caller's `insert_slice` of an `inout` window then copies the window onto itself; `cse` makes
  the two subviews one value and the last `canonicalize` erases the self-copy
  (`tests_run_view.sysl`).
- `convert-bufferization-to-memref` — lowers the `bufferization.clone`s the deallocation pipeline
  still makes (`parallel.mlir`).
- `lower-affine` — `expand-strided-metadata` leaves `affine.apply` for a subview of a dynamic-shape
  source, which `finalize-memref-to-llvm` does not lower (`views.mlir`, `parallel.mlir`).

The four existing proofs (145, 313, 316, real spelling) print the same bytes through the revised
list. **OpenMP**: a program with a `parallel` construct emits its own `omp.parallel` regions
(DESIGN §9.5), so the list gains only `convert-openmp-to-llvm`, before `convert-func-to-llvm`, and
the program links `libomp` from `$NEX_LLVM_HOME/lib` (`driver.sysl`'s `pipeline_for`).

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
  `omp.declare_reduction` for the reduction) and run on several threads (`parallel.mlir`). nex
  emits none of them: a region's order of combination would follow the thread count, and its body
  could not hold the emitter's locals in memory. It outlines each region's code itself and opens an
  `omp.parallel` around a runtime call (DESIGN §9.5).
- **BLAS takes a view as it is.** A column-major matrix or a view with unit stride along its first axis is a
  pointer (`extract_aligned_pointer_as_index` plus the metadata offset) and a leading dimension (the
  memref's axis-0 stride), handed to `cblas_dgemm` with no copy (`blas.mlir`, Accelerate).
- **There are no pointer element types.** `memref<4x!llvm.ptr>` is an invalid memref element type,
  and a `tensor` of `!llvm.ptr` cannot be bufferized. An array of strings, closures, enums with
  payloads or structs holding them is an array of `i64` handles, the addresses of objects of the
  counted heap (above), each element owning a count. An array of
  structs or tuples of scalars is stored inline (DESIGN §3.1), as a memref of a packed element type
  or as a byte buffer with computed field offsets, so `p[k].x` is one load.
- **Integer division traps.** Integer division by zero traps in nex, so every integer division is
  emitted behind a check that calls the runtime's trap. Real division is IEEE (`1.0 / 0.0` is `inf`)
  and needs no check; `--fpe-trap` enables the floating-point exception traps for division by zero,
  invalid and overflow in the generated code instead.
- **Traps are catchable.** `assert_traps` (corpus 252–254) runs a lambda and passes when it traps,
  so a trap is a `longjmp` to the innermost `setjmp` the runtime armed, and an uncaught one prints
  its message and exits. Every trap goes through one runtime entry for that reason. A `longjmp` may
  not leave an OpenMP worker, so every thread of a region runs its share under a catch of its own,
  and the region's end raises the first trap in the thread that started it (DESIGN §9.4).

## Milestones

Each is one bounded item ending in a green `sysl test .` on its branch, with the corpus programs of
its categories passing. Corpus counts are from `index.tsv`'s category column (they sum to 425, all
of the corpus as migrated above); `v2` counts are the programs the milestone adds to `testdata/v2/`.

0. **M0 — the corpus migration to v3 syntax** (branch `corpus-v3`). The whole corpus is rewritten
   to DESIGN.md's syntax: **1-based indexing, inclusive `..` (`..<` half-open), the
   `iso_fortran_env` type names and `[uint8]` for bytes**, plus the four rewrites of "The corpus
   under DESIGN.md". *Exit*: every program of that section committed; `index.tsv`'s `v3` column
   accounts for all 425 as `same`, `syntax` or `meaning`, every `meaning` program's new `.out`
   quoting the DESIGN rule that changed it (at least 295, 296, 353, 362, and each program that
   prints an index); `grep -lw mut`, `grep -l '\.view('`, `grep -l '\.\.='`, `grep -lw bytes` and
   the negative-index grep return only 112 and 116; and a reviewer's pass over the 162 index/range
   programs finds no 0-based index left.
1. **M1 — the parser.** The reference's syntax is on dev (`fa31517`, lexer, parser, corpus and
   literate tests); what remains is DESIGN.md's syntax, as its own item after M0. *Exit*: all 425
   corpus programs, as migrated, parse; `nex parse` prints the tree; the reference's lexer and
   parser cases ported; parser cases for array types
   with axes and static extents, `complex[real32]`, rank-3 literals, `..` and `..<` with and
   without bounds and `by`, every subscript form with `end` (including `end`
   on a continuation line inside brackets, and `end for` after a line ending in `]`), `inout`,
   `parallel for … reduce`, `parallel` expressions and `extern def` with its attributes.
2. **M2 — the typed IR.** Elaboration, inference over the precision lattice, generics and `Rank`
   parameters monomorphized, auto-clone and view copies made explicit, the `inout` exclusivity check,
   the parallel-safety check and the module-`var` effect summary both use. **Units of measure**
   (DESIGN §13): `unit` declarations reduced to base exponents and an exact rational factor, unit
   inference through every operator, prelude function, generic `U: Unit` parameter and the linear
   algebra of §13.6, same-dimension conversions made explicit as one multiplication by a folded
   constant, and the units erased from the typed IR handed to emission. *Exit*: all 425
   elaborate; the reference's elaborator stage 1–3 cases ported (positive ones by the printed IR,
   negative ones by their diagnostic); a negative case for each rule of DESIGN §8.3 and §9.4 and for
   each narrowing that §2.2 refuses (same-width signed/unsigned mixing, a promoted `[real64]` stored
   into a `[real32]`); §8.3 rule 1's disjoint borrows accepted in each listed form (constant
   windows, a split at one `e`, distinct constant indices) and rejected otherwise with the
   split-form suggestion, and the same three forms accepted for an `inout` window beside a read-mode
   window of one array under rule 2 (`axpy(2.0, a[1..4], a[5..8])`); a negative case for an
   unmarked scalar function applied to an array, for a `main` of any other signature, for a
   top-level statement, and for `exit` and a nested `parallel` in a parallel body. For units: the
   typed IR of `10.0<mm> + 1.0<in>` shows the folded factor 25.4 on the right operand and that of
   `1.0<m> + 2.0<m>` shows none; `sqr[U: Unit]` infers `real<m^2>`; `N` and `kg m / s^2` unify, and
   so do `ft` and `12 in`; and a negative case, by its diagnostic, for each refusal of §13 —
   adding different dimensions (the message names both units and both dimensions), a bare literal
   beside a unit (`x + 1.0`, with the suggestion `1.0<m>`), a dimensioned argument to `exp`, a
   non-constant exponent on a dimensioned base, `to` across dimensions, a unit-carrying argument to
   an `extern` (suggesting `strip`), a circular `unit` declaration, and an unknown unit name.
3. **M3 — scalars and the pipeline: 151.** Emission for scalars of every width, control flow,
   functions, strings and printing; the driver and the runtime's printing per width and trapping
   integer division and overflow at every width, IEEE real division and `--fpe-trap`; `exit`,
   `cycle`, named loops, stepped `for` headers and `stop n`; `main(args)` and `eprint`; `inout` scalars. `precision.mlir` joins the toolchain tests.
   *Exit*: top-level bindings (4), scalar arithmetic (13), comparison + logical (12), chained
   comparison (7), control flow (27), blocks + scoping (4), top-level initialization (3), compound
   assignment (8), functions (43), string interpolation (19), const fn calls (5), `inout` by-ref (6)
   — 151 pass; and `v2` **precision** programs (every type of DESIGN §2.1 printed, each promotion
   rule, each conversion's trap, unsigned overflow and underflow traps, literal adoption, a `real64`
   scalar promoting a `real32` array, `real32` printing) pass; and `v2` **units** programs (every
   prelude unit of DESIGN §13.9 converted to its SI base and printed, `print` showing the unit, mixed
   `mm` and `in` arithmetic and comparison, `to` and `strip`, a projectile in `real<m>` and
   `real<m/s>`) pass, each with a twin written without units whose emitted MLIR differs only in the
   unit strings it prints.
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
   indexing, element-wise, `sum(a, dim = 2)`, `reshape`/`flatten` round trips at rank 3, static
   shape compile errors) pass, as do arrays of `real<Pa>` printed with their unit and `to<mm>` over
   a rank-2 array fused into its expression; and an `inout` array call emits no `memref.copy`.
7. **M7 — views: 35 more, 375.** Every slice a `tensor.extract_slice`, the runtime's `memrefCopy`,
   `end`, bounds and stride traps, `by` on every axis, slice assignment in place, the escape and
   source-written copies of DESIGN §6.2. `views.mlir` and `view-then-write.mlir` join the toolchain
   tests. *Exit*: view-style slicing (9), rank-1 strided (8), rank-2 (9), rank-2 sub-rectangle (9)
   pass; `v2` view programs (rule 4, a returned view, a view stored in a struct, a strided rank-3
   plane) pass; and **passing a slice to a function allocates nothing**: the bufferized IR of each
   view program in the four categories has no `memref.alloc` or `memref.copy` the program's own
   arrays do not account for. `v2` **base and range** programs, all in 1-based inclusive syntax:
   `a[1]` and `a[end]` read the ends, `a[0]` and `a[n+1]` trap `out of bounds`, `a[2..5]` has four
   elements and `a[2..<5]` three, `a[1..0]` and `a[n+1..n]` are empty without trapping, `m[2..3, :]`
   and `m[:, ..<end]` agree with their element-by-element loops `for i in 2..3`. Also DESIGN §5.4
   and §6.4: `v2` programs for negative strides (every row of §5.4's example, `a[end..1 by -1]`, a
   reversed column `m[:, end..1 by -1]`, reversed slice assignment, `reverse(a, k)`) and for
   `origin` (a symmetric kernel `for k in -r..r`, a ghost-cell grid, `end` on an offset view, an
   out-of-range index trapping, `rebase(w)` passed to a callee and arriving 1-based) pass with no
   copy; passing, returning, storing or capturing an `origin` view are four negative cases whose
   diagnostic names `origin`; the negative-stride `memref` question of §5.4 is settled by a probe in
   `experiments/mlir/`.
8. **M8 — the prelude and catchable traps: 50 more, 425.** The array and matrix prelude at every
   rank, `assert_approx`, `assert_traps` over `setjmp`/`longjmp`. *Exit*: prelude (38) and
   docs/examples (12) pass: **the whole corpus, 425 of 425**; `examples/fft` compiles and runs.
9. **M9 — parallel.** `parallel for` with `shared_outs`, `reduce` clauses as `scf.parallel` +
   `scf.reduce`, `parallel map` and parallel element-wise expressions, the OpenMP pipeline, the trap
   relay out of a parallel region. `parallel.mlir` joins the toolchain tests (skipped without
   `libomp`). **Reductions are reproducible** (DESIGN §9.2.1): fixed 4096-iteration blocks, each
   reduced sequentially, partials combined in a fixed pairwise tree that nex emits itself, and the
   sequential whole-array reductions (`sum`, `product`, `dot`, `norm2`, `dim =` forms) lowered through
   the same tree. The operators are `+ * min max and or`, the location reductions `minloc` /
   `maxloc`, and user-defined `(T, T) -> T` functions. The OpenMP pipeline is chosen by the presence
   of a `parallel` construct, with no flag, and a program without one links no OpenMP runtime.
   `print` and stderr in a parallel body are atomic per call. *Exit*: `v2` **parallel** programs
   print **identical bits** sequentially and under `OMP_NUM_THREADS` = 1, 2, 4 and 7, real
   reductions included; `sum(x)` and `parallel sum(x)` agree bit for bit on n = 10⁶; a pairwise
   `sum` beats a naive loop's error on an ill-conditioned series; `minloc`/`maxloc` return the lowest
   index on ties at every thread count; a Kahan `reduce s: kahan_add` runs; every rejected body of
   DESIGN §9.4 (file I/O, input, a non-`@pure` extern, a shared write) is a negative elaborator case,
   and `print` in a body is accepted; a trapping iteration is caught by `assert_traps`; a program
   with no `parallel` has no `omp` symbol in its binary; a reduction over every operator of §9.2 runs
   (the OpenMP lowering of each is proved here or reported); and on this machine at
   `OMP_NUM_THREADS=4` the perf oracle's axpy, dot and point-distance kernels written with `parallel`
   run at least 2.5× faster than their sequential builds.

   *Measured* (Apple M5 Pro, 6 performance cores; 100 sweeps of n = 10⁷; wall time of the whole
   program, median of 9 runs, min–max beside it, on a shared machine at load 7–12):

   | kernel | sequential | `parallel`, 1 thread | 4 threads | 6 threads |
   |---|---|---|---|---|
   | axpy, `parallel for` | 186 (178–196) | 183 (180–193) | 156 (154–164) | 130 (128–150) |
   | axpy, `gfortran -O2 [-fopenmp]` | 182 (181–191) | 262 (261–272) | 167 (162–182) | 141 (132–163) |
   | dot, `parallel dot` | 725 (713–748) | 790 (782–809) | 329 (324–366) | 250 (245–285) |

   Before the region's traps were declared never to return and its literal steps made constants,
   one thread of the axpy ran 499 ms against a sequential 335 (neither vectorized). axpy at
   n = 10⁷ is bound by memory bandwidth: gfortran's own `!$omp parallel do` gains 1.1× at 4 threads,
   so the 2.5× bar is out of reach for axpy at this size on this machine, and nex's parallel axpy
   is at gfortran's. dot keeps each 4096-element block in order (§9.2.1), so its additions do not
   vectorize and it scales with threads instead: 2.2× at 4.

   *Count cost* (`nex_retain`/`nex_release`; a loop of 3·10⁷ passes that copies and drops two
   strings, a closure and a struct holding both, no allocation; median of 5, four rounds): atomic
   counts 2438–2822 ms, plain 2066–2179, plain-unless-a-region-runs (what the runtime does) 2215–2276.
   Atomic costs 13–18%, the region check 4–7%. A loop that builds its strings (3·10⁶ passes) shows
   no difference: 813 / 819 ms, the allocation dominates.
10. **M10 — FFI, Fortran interop, BLAS and LAPACK.** `extern def`, `@link`, `@symbol`, `@strided`,
    `@pure`; arrays and views crossing per DESIGN §10.3 (with the copies it requires); **complex
    scalars by value** mirroring clang's ABI per target (arm64 HFA in two FP registers, x86-64 SysV
    SSE); **`@c` structs by reference**; **C callbacks** (a nex `def` as a function pointer, a
    capturing closure through a `@data(f) c_ptr` parameter, with the trampoline generated, by-reference callback arguments for a Fortran
    extern); **calling Fortran** (DESIGN §10.6) — `bind(c)` procedures and plain gfortran objects
    through `@fortran`: `name_` mangling, every argument by reference, hidden trailing string
    lengths, column-major arrays crossing with no copy, the gfortran runtime linked automatically
    when a `@fortran` extern is present; `@link("name")` and `-L` / `-l` on the command line. This is the product case against Julia, and
    it is first-class here, not a later extra. `@` dispatches to `gemm`, `gemv` and `dot` by
    threshold and by shape; the LAPACK prelude's first set (`solve lstsq inv det lu chol qr eigvals eig
    eigh svd svdvals`, DESIGN §10.5), whose value forms trap with a message naming the routine and cause and whose `inout`
    forms return `info`. `blas.mlir` joins the toolchain tests (skipped without a BLAS). *Exit*: `v2`
    **FFI** programs pass — a libm function, `cblas_ddot` on a strided view with `incx = 2`, `dgemm`
    on a sub-block view with its leading dimension, an `inout` LAPACK `dgesv` solve,
    `transpose(A) @ B` dispatched with the `T` flag and no transposed copy, `cexp` called and
    returning a `complex[real64]` by value, a struct read and written through a `@c` pointer, a C
    quadrature routine integrating a nex `def` and a capturing closure through `user_data`; `v2`
    **Fortran** programs pass against a gfortran-compiled fixture library — a `bind(c)` function, a
    plain `subroutine` taking scalars, arrays and an `info` by reference, one taking a
    `character(*)` argument, and a Fortran routine calling a nex callback; each LAPACK value form's
    failure traps with its message (`solve` on a singular matrix, `chol` on an indefinite one) and
    its `inout` form returns the same `info`; `eig` of a rotation matrix returns complex
    eigenvalues; `A @ B` above the threshold emits a call and below it a `linalg.matmul`, checked in
    the emitted MLIR; `solve` on a stiffness matrix in `real<N/m>` and loads in `real<N>` returns
    `real<m>`, and `strip` of an array passed to `cblas_ddot` emits no copy; and the BLAS gemm kernel
    below meets its bar.
11. **M11 — modules and `nex test`.** The module loader, the source prelude found by
    `--prelude-path` / `NEX_HOME`, `@test` discovery; `nex test` prints a line per failure and a
    summary, filters by a name substring, and keeps running after a test traps. *Exit*: the reference's module loader,
    sysroot, prelude integration and test runner cases ported.
12. **M12 — performance.** *Exit*: the perf oracle below, met on every kernel.

**Later** (DESIGN §15), each its own item once M12 is done, none dropped:

- **Structs by value across the FFI** — `@c` structs passed and returned by value, with clang's
  per-target aggregate classification. Kept on the list at the user's request.
- **`bfloat16`** — the name is reserved; MLIR's `bf16` makes it cheap.
- **`real128`** and `complex[real128]`.
- **Batched BLAS** — a vendor batched `gemm` behind an explicit routine, if the
  `parallel for k … C[:, :, k] = A[:, :, k] @ B[:, :, k]` idiom measures slower.
- **Banded and tridiagonal LAPACK solvers**, generalized eigenproblems, `rcond` / `cond`.
- **Affine temperature units** `degC` / `degF`, with a point type and a difference type.
- **Unit-polymorphic externs** — units in an `extern` declaration's parameters.
- **The interpreter.** The compiler stays the source of truth: the interpreter executes the same
  typed intermediate form the compiler lowers, so there is one front end, and it calls the same
  runtime (the sysl runtime below) directly. `nex test --interp` runs the tests through it, and
  `nex test --both` runs every test and every corpus program both ways and byte-diffs the output,
  plus a fuzzer generating programs for the same diff. For the diff to hold, the compiler does not
  contract floating point (`-ffp-contract=off`) unless nex itself says so, and the reproducible
  reduction tree (DESIGN §9.2.1) lets a single-threaded interpreter match parallel runs bit for bit.
  **Gate**: it is built only if the measured compile + load latency of a typical script exceeds
  about 0.5 s; otherwise compiling is the interpreter. *Exit*: `nex test --both` is clean over the
  corpus, the `v2` programs and a fuzzer run of a fixed seed and size.
- **nex as a 3D modeller's scripting language.** Requirements: fast edit-and-rerun — compile a
  script to a shared library and `dlopen` it, or run it through MLIR's ORC JIT, with a module cache,
  against a stated latency target; small static-shape arrays (`[real; 3]`, `[real; 4, 4]`) held in
  registers or on the stack, never on the heap; an embedding API, in which the host exposes its
  geometry kernel through the C FFI and callbacks and calls into compiled scripts; and a sandbox mode
  (no `extern`, no file I/O, no `stop`) for models from untrusted sources. Units (`mm` and `in` in
  one model, DESIGN §13) are the CAD selling point. *Exit*: a sample host loads a script, calls it
  with a transform and a point array, re-runs an edited script within the latency target, and
  refuses a sandboxed script with an `extern`.

**The runtime in sysl.** The runtime is written in sysl: `runtime/`, a project of its own (its own
`sysl.hocon`, so the compiler's tree stops there), built by `sysl build-c runtime` into
`libnex_rt.a` and its header. The three MLIR proofs — 316, 313 and 145 — and `real-spelling` link
that archive and nothing else, and each prints its `.out` byte for byte. `tests_toolchain.sysl`
holds it to account: **one `main` and one allocator** — the archive defines neither, so `main` is the
one MLIR generated and the runtime's heap is the libc `malloc` and `free` that lowered memrefs call;
**memref descriptors by pointer** — `@export` functions named `_mlir_ciface_*` take a struct laid out
as MLIR's rank-1 descriptor, and `trap-catch.mlir` prints a stride-2 view from offset 1 through one;
and **catchable traps** — `nex_catch_trap` takes a body's address and runs it under `setjmp`, a
`nex_trap_*` called two MLIR frames down `longjmp`s back to it (an `@abandons` extern), the catch
answers true and the program goes on, twice; with nothing catching, the trap writes its message to
standard error and aborts with what was printed kept. The interpreter later calls this same runtime
directly.

**The playground** (its own item, any time after M3). A page in `docs/` with an editor; **Run**
sends the source to a small service that compiles it with the ordinary pipeline and **runs the
native binary on the server**, returning its output, stdout and the trap message alike. One
compiler, one target: the playground cannot disagree with `nex compile`. The service runs on its
own small VM, never beside another deploy, and every run is sandboxed: a fresh `nsjail` per run,
no network, a read-only filesystem but a private tmpfs, and limits on CPU time (2 s), wall time
(5 s), memory (256 MB), processes and output size (64 KB), plus a per-client rate limit. *Exit*: the
docs' examples run from the page and print what `nex compile` prints; an infinite loop, a fork bomb,
a memory hog, a 1 GB print, a network connect and (after M10) an `extern def system` call are each
stopped or refused, one test apiece against the deployed sandbox; a probe page is checked in
headless Chrome.

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
