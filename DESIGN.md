# nex: the language design

This is the language this implementation compiles. The reference specification
(`~/dev/nex/docs/content/spec/`, cited here as *ref §n*) still defines everything this document does
not touch: lexical structure, tuples, structs, sum types, `match`, closures, modules, interpolation,
the scalar prelude. Where a section here covers a subject, it replaces the reference's text on that
subject. The table in §14 lists every such place.

**Two markings run through it.** **PROPOSED** marks a rule this document had to invent to make a
decided feature complete; it stands until the user says otherwise. A claim about MLIR names the
experiment under `experiments/mlir/` that ran it through the toolchain (LLVM 23.1.4,
`/opt/homebrew/opt/llvm/bin`). A claim nothing ran is marked *(unverified)*.

---

## 1. Summary of the core

nex is an array-first numerical language for the scientists and engineers who write Fortran:
**Fortran's model, modern syntax, compiler-enforced safety, ahead-of-time native binaries.** It
keeps what a Fortran programmer relies on — column-major storage, 1-based arrays, inclusive ranges
(`a[2..5]` is `a(2:5)`), the `iso_fortran_env` type names, whole-array expressions that fuse — and
adds value semantics enforced by `val`/`var` and a uniqueness rule, in a syntax of the Scala 3 /
sysl family. Scalars come in sized widths (§2). Arrays have any rank and an optional static shape
(§3). A slice is a read-only view (§6). A function mutates a caller's array through an `inout`
exclusive borrow (§8). Loops and reductions can be parallel, the checker proves them race-free, and
their results are the same for every thread count (§9). C, BLAS, LAPACK and existing Fortran are
reachable through `extern` declarations, and `@` uses BLAS when that pays (§10). A real can carry a
unit of measure (`9.81<m/s^2>`, `real<mm>`), checked at compile time and free at run time (§13).

nex is compiled: `nex run` compiles the program to a native binary and runs it, and the compiler
is the source of truth for what a program means. An interpreter sharing the compiler's front end
and runtime is a later, measured option (PLAN.md), checked against the compiler test by test. The playground does the same on a server, running the native binary inside
nsjail on its own VM.

---

## 2. Numeric types

### 2.1 The types

| Type | Meaning | MLIR |
|---|---|---|
| `int8`, `int16`, `int32`, `int64` | signed two's-complement integers | `i8` … `i64` |
| `uint8`, `uint16`, `uint32`, `uint64` | unsigned integers | `i8` … `i64` (unsigned operations) |
| `real16`, `real32`, `real64` | IEEE 754 binary16, binary32, binary64 | `f16`, `f32`, `f64` |
| `complex[real16]`, `complex[real32]`, `complex[real64]` | a pair of that real type (re, im) | `complex<f16>` … `complex<f64>` |
| `integer` | alias of `int64` | |
| `real` | alias of `real64` | |
| `complex` | alias of `complex[real64]` | |

`bool`, `unit` and `string` are as in ref §3.1. The aliases are the same type, not a distinct one:
`[real]` and `[real64]` are one type, and a diagnostic names a type the way the source spelled it.

**The names are Fortran's `iso_fortran_env` kind names**, so a Fortran programmer reads
`real64`, `int32` and `complex[real64]` (Fortran's `complex(real64)`) without a glossary. The
number counts **bits**. A complex type names the kind of its **part**, as Fortran does: `complex[real32]`
is two `real32`s, matches LAPACK's `c` routines, and promotes from `real32` without changing the
number.

**The defaults are 64-bit.** `integer` is `int64`, `real` is `real64` and `complex` is
`complex[real64]`. This deliberately fixes Fortran's single-precision default `real`, which has cost
generations of programs their accuracy through a forgotten `d0` or `kind=`; a program that wants
single precision says `real32`.

**There is no `byte` type.** Raw bytes are `[uint8]`, an ordinary array with every array operation.

**Why this set.**

- **Integers 8, 16, 32, 64.** They are the widths C, BLAS/LAPACK (LP64 uses 32, ILP64 uses 64) and
  every file format exchange, so an `extern` declaration (§10) can spell any C or Fortran integer
  parameter. A 128-bit integer has no hardware arithmetic, no C ABI that BLAS uses and no numerical
  workload that needs it.
- **Unsigned widths exist, and trap like signed ones.** Unsigned arithmetic traps on overflow and
  on going below zero (`uint8(0) - 1` traps), exactly as signed arithmetic traps on overflow
  (ref §4.4). Mixing a signed and an unsigned operand of the same width is a compile error that
  asks for an explicit conversion (§2.2), because neither type holds the other's range.
- **Reals 16, 32, 64.** binary64 is the default and Fortran's `double precision`; binary32 is what
  single-precision BLAS, GPUs and memory-bound kernels use; binary16 is the storage width of
  half-precision data. `real16` is a storage-and-arithmetic type, and its transcendental functions
  compute in `real32` and round (**PROPOSED**); `sqrt` is native (`precision.mlir`). `real128` comes
  later (§15).
- **No `bfloat16`.** The name is reserved; MLIR's `bf16` makes it cheap to add when a workload asks.

### 2.2 Promotion lattice

```
uint8 ──→ uint16 ──→ uint32 ──→ uint64
   ╲          ╲          ╲                       (uintN → int(2N): every value fits)
int8  ──→  int16  ──→  int32  ──→  int64
   │          │          │          │            (any integer → any real or complex)
   ▼          ▼          ▼          ▼
real16    →    real32    →    real64
   │             │              │
   ▼             ▼              ▼
complex[real16] → complex[real32] → complex[real64]
```

An arrow is an **implicit widening**. A widening happens in exactly the places ref §3.2 promotes: an
operand of an arithmetic or comparison operator, an argument passed to a parameter, a value bound or
assigned to an annotated binding, field, element or return type. Every conversion that does not
follow arrows is **narrowing** and needs a conversion function (§2.4).

**The type of a binary operation** (`+ - * ^`, comparisons, element-wise array operations) on
operands of types `A` and `B`:

1. Same type: that type.
2. Both in the same family (signed integer, unsigned integer, real or complex): the wider of the two.
3. A signed and an unsigned integer: the signed type when it is strictly wider (`uint8 + int16` is
   `int16`); otherwise a **compile error** naming both types and asking for a conversion
   (`int32(u) + n`).
4. An integer with a real or a complex: **the real or complex operand's type**. `n * x` with
   `n: int64` and `x: real32` is `real32`, as in Fortran: a loop index never widens a
   single-precision kernel.
5. A real with a complex: the complex type of the wider width. `real64 + complex[real32]` is
   `complex[real64]`.

`/` follows ref §4.4: two integers give `real64`; an integer with a real `realN` gives `realN`.
`div` and `%` need two integers and give the wider. `^` with an integer exponent keeps the base's
type.

**Arrays never convert implicitly as a whole.** `[real32]` does not pass where `[real64]` is
expected; `real64(a)` converts it (§2.4) and the allocation is visible. Element-wise operations mix
widths per element under rules 1–5, so `a32 + b64` is a `[real64]` computed in one fused loop with
no converted copy of `a32`.

**A typed scalar promotes an array, as in Fortran and Julia.** `x * a` with `x: real64` and
`a: [real32]` is a `[real64]`: the result is computed at the wider width, element by element. A
*literal* is not a typed scalar: it adapts to the array (§2.3), so `2.0 * a` stays `[real32]`.
Storing a promoted result back into the narrower array is a **compile error**, not a silent
rounding: `a = x * a` with `a: [real32]` is refused, and `a = real32(x) * a` or
`a = real32(x * a)` says which rounding is meant.

### 2.3 Literals and prelude constants

An unsuffixed literal takes its type from its context; nex has no literal suffixes, because a suffix
such as `1.0f32` would read as juxtaposition (`1.0 * f32`, ref §4.4).

- **With an expected type** (an annotated binding, a parameter, a typed element or field): the
  literal is that type. An integer literal outside the target's range is a compile error
  (`val b: int8 = 300`, `val u: uint8 = -1`). A real literal is rounded to the nearest value of the target width;
  one that rounds to infinity is a compile error (`val h: real16 = 70000.0`). An integer literal
  may initialize a real or complex (`val x: real32 = 1`), as ref §3.2 allows.
- **As an operand of a binary operator whose other operand has a type:** an integer literal adopts
  that type if it is an integer, real or complex type; a real literal adopts it if it is a real or
  complex type, and otherwise (`n + 0.5` with `n` an integer) is `real64`. So `x32 * 2.0` is
  `real32`, `x8 + 1` is `int8` (and traps when `x8` is 127), and `u + 1` with `u: uint32` is
  `uint32`. The same holds when the other operand is an array: `2.0 * a32` is `[real32]`.
- **With no context:** an integer literal is `int64`, a real literal `real64` (ref §2.4).

**The prelude constants `pi`, `e`, `inf`, `nan` and `i` are typed like literals** (**PROPOSED**):
each adopts the width its context asks for (`pi` is `real32` beside a `real32`, `i` is `complex[real32]`
beside a `real32`), and with no context `pi`, `e`, `inf`, `nan` are `real64` and `i` is
`complex[real64]`. Without this, `2pi * x32` would silently widen a `real32` kernel to `real64`.

### 2.4 Conversions

Every numeric type name is also its conversion function, on a scalar and element-wise on an array:
`real32(x)`, `int16(n)`, `uint8(k)`, `complex[real32](z)`, `complex[real32](re, im)`,
`real64(a)`.

| From → to | Behaviour |
|---|---|
| integer → narrower integer, signed ↔ unsigned | exact, or **traps** when the value is out of range (`uint32(-1)` traps) |
| real → integer | truncates toward zero; **traps** on NaN, infinity or out of range |
| real → narrower real | rounds to nearest-even; overflow gives ±∞ (IEEE, no trap) |
| complex → narrower complex | each part as real → real |
| complex → real or integer | not a conversion: take `.re` (or `abs`, `arg`) first |
| any widening | the implicit widening of §2.2, also callable explicitly |

`to_real`, `to_integer` and `to_complex` (ref §10.7) remain and mean `real64`, `int64` and
`complex[real64]`.

### 2.5 Arithmetic, traps and printing

- Integer arithmetic traps on overflow **at every width, signed and unsigned** (ref §4.4); an
  unsigned result below zero is an overflow. The emitted form is
  `llvm.intr.sadd.with.overflow` and its siblings, then a branch to the trap (`precision.mlir` runs
  `127 + 1` and `100 + 27` at `i8`).
- Real arithmetic is IEEE at its own width: `real32` operations are `f32` operations, never computed
  in `f64` and rounded (`precision.mlir`: `0.1 * 3` in `real32` prints `0.30000001192092896`).
- **Real arithmetic does not trap by default.** `1.0 / 0.0` is `inf`, `0.0 / 0.0` is `nan`, and an
  overflow is `±inf`, as IEEE specifies. `nex build --fpe-trap` (and `nex run --fpe-trap`) traps on
  real division by zero, invalid operations and overflow instead, like gfortran's
  `-ffpe-trap=zero,invalid,overflow`. Integer division by zero and integer overflow trap always.
- Printing (ref §10.6) prints a `real32` or `real16` as the shortest decimal that reads back to the
  same value **at that width**, in the reference's spelling (`0.3` for the `real32` nearest 0.3, not
  `0.30000001192092896`) (**PROPOSED**; needs runtime entries per width). A complex prints as its two
  parts do.

### 2.6 Generic constraints

The closed constraint set of ref §6.10 widens to the sized types:

| Constraint | Admitted types |
|---|---|
| `Any` | every type |
| `Numeric` | every integer, real and complex type |
| `Integral` (**PROPOSED** name) | `int8` … `int64`, `uint8` … `uint64` |
| `Real` | every integer and real type |
| `Float` | `real16`, `real32`, `real64` |
| `Complex` | `complex[real16]`, `complex[real32]`, `complex[real64]` |
| `Ord` | every integer and real type |
| `Eq` | every numeric type, `bool`, `string` |
| `Rank` | not a type: a rank (§3.4) |
| `Unit` | not a type: a unit of measure (§13.5) |

Unifying one type parameter against several numeric actuals widens along §2.2, as ref §6.10 widens
through the old tower.

---

## 3. Array types

### 3.1 Syntax

```
array-type ::= '[' element-type ']'                      rank 1, extent dynamic
             | '[' element-type ';' axes ']'
             | '[' element-type ';' rank-param ']'       rank-generic (§3.4)
axes       ::= axis (',' axis)*
axis       ::= ':'                                       extent known at run time
             | extent                                    extent known at compile time
extent     ::= integer-literal | const-name
```

```nex
[real; :]            // rank 1
[real; :, :]         // rank 2
[real; :, :, :]      // rank 3
[real; 3, 3]         // rank 2, static shape 3 × 3
[real32; 3, :]       // rank 2, 3 rows known statically, columns at run time   (PROPOSED: mixed axes)
[complex; N]         // rank 1, extent the const N
```

The rank is the number of axes. There is no upper limit below MLIR's (**PROPOSED**: the compiler
accepts any rank; the prelude is written for any rank through `R: Rank`).

**`[T]` stays, as sugar for `[T; :]`.** Rank 1 is the most common array in numerical code, the
reference's 425 programs and every example spell it that way, and the form cannot be confused with
anything else: without a `;` there is no shape to read. **`[[T]]` is not a type.** An array's
element is never an array (a nested literal is one array of higher rank), so `[[real]]` is rejected
with *"an array element is not an array; a matrix is `[real; :, :]`"*.

**Element types: any type but an array.** Numeric types of §2 and `bool` are stored densely. A
struct or tuple whose fields are all scalars is stored **inline**, field after field in each
element, as a Fortran array of a derived type is: `p[k].x` is one load at a computed offset. A
string or another heap value (a struct holding an array, an enum with a payload, a closure) is
stored as a handle. Element-wise arithmetic and fusion (§7) apply only to numeric
elements; indexing, slicing, views, `map` and `parallel for` work on every element type. Bytes are
`[uint8]`, an ordinary array; there is no separate byte storage type.

**Tuples** are indexed from 1, like arrays: `t.1` and `t.2` are the first two fields. Destructuring,
`val (q, r) = t`, is the preferred way to take a tuple apart.

### 3.2 Storage and indexing base

**Arrays are 1-based**, as in Fortran: the first element of every axis is index 1 and the last is
its extent. Axes are numbered from 1 too (`extent(a, 1)` is the first axis, Fortran's
`size(a, dim=1)`).

Storage is column-major for every rank: the first axis varies fastest. A dense array of shape
`(d1, d2, …, dk)` stores element `[i1, i2, …, ik]` at zero-based offset
`(i1−1) + d1·((i2−1) + d2·((i3−1) + …))`.

**Lowering.** A nex array of shape `(d1, …, dk)` is an MLIR `tensor<dk × … × d1 × T>`: the axes are
reversed, so MLIR's identity (row-major) layout is nex's column-major one, and nex index `[i, j, k]`
is tensor index `[k−1, j−1, i−1]`. The front end subtracts the base once per index; MLIR folds it
into the loop bounds, so a 1-based loop costs nothing over a 0-based one. A dynamic axis is `?`,
a static one its number. This keeps every `linalg` op, fusion and bufferization on default layouts (`views.mlir`, rank 2 and rank 3).

### 3.3 Static shapes

- A static extent is checked at compile time wherever both sides are static: element-wise operands,
  `@`'s inner dimension, slice assignment, an argument against its parameter. A mismatch is a
  compile error, not a trap.
- A static shape converts implicitly to the dynamic shape of the same rank (`[real; 3, 3]` passes
  where `[real; :, :]` is wanted).
- A dynamic shape converts implicitly to a static one at a binding, argument or return, with a
  run-time check that **traps** `shape mismatch`. Only a dynamic side can trap: two static shapes
  that differ are always the compile error of the first rule.
- **A literal is dynamically shaped** unless its binding is annotated: `val a = [1.0, 2.0]` is
  `[real; :]`, so `var a = [1.0, 2.0]` may later be assigned a longer array (ref §5.2)
  (**PROPOSED**).
- Rank is always static. Two operands of different rank in an element-wise operation are a compile
  error; there is no rank broadcasting.

### 3.4 Rank-generic and element-generic code

A generic parameter bounded by `Rank` stands for a rank, and an array type whose shape is that
parameter has that rank with every axis dynamic:

```nex
def total[T: Numeric, R: Rank](a: [T; R]): T = sum(a)

def axpy[T: Float, R: Rank](alpha: T, x: [T; R], y: inout [T; R]) =
  y = alpha * x + y
```

The rank is inferred from the arguments like a type parameter, and specialization is per (type,
rank), as ref §6.10 specializes per type. The parser does not tell `[T; R]` from `[T; N]` (an
extent const); name resolution does, from the generic list. Inside the body, `rank(a)` is the
constant `R`. Rank-generic code works through whole-array operations, `map`, the reductions,
`extent`, `size` and `flatten`; it cannot write an index list, whose length would be `R`.

Static extents as generic parameters (`def trace[N: Extent](m: [real; N, N])`) are not part of the
language; a generic function takes dynamic axes and the caller's static shape converts to them.

---

## 4. Array construction and the shape functions

### 4.1 Literals

A rank-R literal is brackets nested R deep. The outermost list runs along axis 1, the next along
axis 2, and so on: the element at nesting position `i, j, k` (counting from 1) is `a[i, j, k]`.
Rank 2 is ref §4.13's row-by-row form unchanged.

```nex
val m = [[1.0, 2.0, 3.0],
         [4.0, 5.0, 6.0]]                      // [real; :, :], shape (2, 3), m[2, 1] == 4.0

val t = [[[1, 2], [3, 4]],
         [[5, 6], [7, 8]]]                     // [integer; :, :, :], shape (2, 2, 2)
                                               // t[2, 1, 2] == 6
```

Every list at one depth must have the same length. A literal whose nesting is visibly jagged is a
**compile error** (**PROPOSED**; the reference traps at run time); an inner element that is an array
expression rather than a bracket list has a run-time length, and a mismatch there traps as in the
reference. The source order is row-major, as you read it; storage is column-major regardless.

### 4.2 Constructors

`zeros`, `ones` and `fill` take an `integer` (rank 1) or an R-tuple of integers (rank R):

```nex
zeros(5)                      // [integer; :]
zeros((2, 3, 4))              // [integer; :, :, :]
fill((3, 3), 0.5)             // [real; :, :]
identity(3)                   // [integer; :, :]
```

`zeros`, `ones`, `identity` take their element type from the expected type when there is one, and
are `integer` otherwise (**PROPOSED**; ref §10.5 says they return `integer` "until overload by return
type lands"): `val z: [real32; :, :] = zeros((4, 4))`.

### 4.3 Shape functions

| Function | Result |
|---|---|
| `rank(a)` | the rank, a compile-time constant |
| `extent(a, k)` | the extent of axis `k`, `1 ≤ k ≤ rank(a)` (traps if `k` is not an axis) |
| `extents(a)` | `[integer; R]`, every extent (**PROPOSED**; usable in rank-generic code) |
| `size(a)` | the number of elements, the product of the extents |
| `length(a)` | `extent(a, 1)`; for rank 2 the row count, as in the reference |
| `shape(a)` | for rank ≥ 2 the R-tuple of extents (ref §10.4's `(rows, cols)` at rank 2); for rank 1 the length |
| `rows(m)`, `cols(m)` | rank 2 only |
| `reshape(a, (d1, …, dk))` | rank k from any array of the same size, column-major (ref's `reshape(a, m, n)` stays) |
| `flatten(a)` | rank 1, column-major order, from any rank |
| `transpose(m)` | rank 2 only |
| `permute(a, (p1, …, pk))` | axes reordered: result axis `n` is source axis `p_n` (**PROPOSED**) |
| `sum(a, dim = k)` | sum over axis `k`: rank R−1 (at rank 2, `k` is 1 or 2); every reduction takes `dim =` (§7.4) |

`transpose`, `permute`, `reshape` of a dense array and `flatten` of a dense array return views (§6):
no data moves (**PROPOSED** as a performance guarantee; the result is a value either way, so which it
is cannot be observed; the lowering is *(unverified)*).

`for x in a` over an array of rank ≥ 2 visits every element in storage (column-major) order
(**PROPOSED**; the reference does not say).

---

## 5. Indexing and slicing

### 5.1 Index lists

`a[s1, s2, …]` takes one subscript per axis. Each subscript is one of:

| Subscript | Axis in the result |
|---|---|
| an integer expression | removed (the axis collapses) |
| `:` | kept, whole |
| `lo..hi`, `lo..`, `..hi`, `..` | kept, the window `lo` to `hi` **inclusive** (Fortran's `lo:hi`) |
| `lo..<hi`, `..<hi` | kept, the half-open window `lo` to `hi − 1` |
| any of the range forms followed by `by k` | kept, every k-th element of the window |

**`..` is inclusive because that is what a Fortran programmer reads**: `a[2..5]` is four elements,
`a(2:5)`. `..<` is the half-open form for the code that wants it, chiefly splitting at a point
(`a[..<k]`, `a[k..]`). An omitted `lo` is 1 and an omitted `hi` is the axis's extent (`end`).

- Fewer subscripts than the rank leaves the trailing axes whole: on rank 3, `t[i]` is
  `t[i, :, :]` and `t[i, j]` is `t[i, j, :]` (ref §4.14's `m[i]` row form, generalized). More
  subscripts than the rank is a compile error.
- The result's rank is the number of kept axes. With every axis collapsed the result is the element
  itself, a scalar; otherwise it is a view (§6).
- **`by k` is legal on every axis** of every rank (`m[1..5 by 2, 2..]`, `t[:, :, 1..10 by 3]`), on
  read and as an assignment target. `k` may be **negative**, which walks the window downward (§5.4);
  a stride of `0` traps.
- Indexing is 1-based (§3.2). **Every index and bound is checked**: an index `i` on an axis of
  extent `n` must satisfy `1 ≤ i ≤ n`, and a window `lo..hi` must satisfy `1 ≤ lo` and `hi ≤ n`
  unless it is empty. A window with `hi = lo − 1` is empty and legal (`a[1..0]`, `a[n+1..n]`), as in
  Fortran; anything else **traps** `out of bounds`. **There is no negative-index wrap**: `a[0]` and
  `a[-1]` trap like `a[n + 1]`.

### 5.2 `end`: the last index of the axis

Inside a subscript, `end` is the last valid index of the axis that subscript indexes,
`extent(a, k)`. It may appear anywhere in an index or a slice bound, in any expression:

```nex
a[end]               // the last element
a[end - 1]           // the one before it
a[end-2..]           // the last three
a[..end-1]           // all but the last (also a[..<end])
a[1..end]            // all of it
m[:, end]            // the last column
m[end, 1]            // the first element of the last row
t[:, :, end]         // the last plane of a rank-3 array
a[(end + 1) div 2]   // the middle element (the earlier of two when the length is even)
```

- On an empty axis `end` is `0`, so `a[end]` traps and `a[1..end]` is empty: no special case.
- `end` binds to the **innermost** enclosing subscript list: in `a[b[end]]` it is `b`'s last index,
  and in `a[f(end)]` it is `a`'s (**PROPOSED** for the nested cases).
- With a partial index list (§5.1), `end` in position `k` is axis `k`'s.
- `end` anywhere else — `val n = end`, an array literal `[end]`, a range in a `for` header — is a
  parse error: *"`end` is only an index here inside `a[...]`"*.

**How the parser tells `end` the index from `end` the block terminator** (ref §2.7). The lexer emits
one `end` token. An end marker is only ever the first token of a logical line, and the layout pass
(`sh.sysl.parsing`'s `Layout`, which already suppresses the off-side rule inside brackets) knows
whether that line is inside an open `[`. So:

- `end` at the start of a logical line at **bracket depth zero** is a block terminator, optionally
  followed by the construct's keyword (`end for`, `end if`, `end def`).
- `end` at **bracket depth > 0**, or not at the start of a line, is an expression. The parser then
  checks the innermost bracket is a subscript list, not an array literal; otherwise the parse error
  above.

A continuation line inside a subscript that starts with `end` (`a[1,` newline `end]`) is at depth > 0
and is therefore the index. No legal program changes reading under this rule, because no end marker
can sit inside brackets.

### 5.3 Element assignment and slice assignment

`a[i, j] = x` writes one element of a `var` array (or an `inout` parameter, §8). Any slice form is
also an assignment target (ref §4.15), for every rank, with `by` on any axis:

```nex
var m = zeros((4, 4)) * 1.0
m[:, 1] = [1.0, 2.0, 3.0, 4.0]          // the first column
m[end, :] = fill(4, 9.0)                // the last row
m[1..3 by 2, 2..3] = [[1.0, 2.0],
                      [3.0, 4.0]]       // rows 1 and 3, columns 2 and 3
t[:, :, 2] = plane                      // a plane of a rank-3 array
m[2..3, 2..3] += 1.0                    // compound, element-wise, in place (PROPOSED: compound slice targets)
a[2..4][1] = 99                         // a slice of a place is a place: writes a[2] (PROPOSED)
```

The right-hand side must have the slice's shape (statically when both are static, else a trap), or
be a scalar, which fills the window (broadcast, as ref §4.5 broadcasts scalars). The write is in
place: no copy of the target is made, and the binding keeps its identity. The right-hand side is
evaluated as a value before the first element is written, so an overlapping self-assignment
(`a[2..] = a[..end-1]`) shifts correctly; the compiler copies the source when the windows can overlap
*(unverified: one-shot-bufferize is expected to insert that copy)*.

---

### 5.4 Negative strides

With a negative `by k`, a range's bounds are read **in the direction of travel**: the first bound is
where the walk starts, the second where it stops, and a range stays inclusive (`..`) or half-open
(`..<`) exactly as it is going forward. This is Fortran's `a(hi:lo:-1)`.

```nex
val a = [10, 20, 30, 40, 50, 60, 70]
a[5..2 by -1]          // [50, 40, 30, 20] — inclusive: a[5], a[4], a[3], a[2]
a[5..<2 by -1]         // [50, 40, 30]     — half-open: stops before a[2]
a[.. by -1]            // [70, 60, 50, 40, 30, 20, 10] — open bounds fill from the stride's direction
a[end..1 by -1]        // the same, spelled out
a[.. by -2]            // [70, 50, 30, 10]
m[:, end..1 by -1]     // the columns of m in reverse order
```

- An open start is the last index of the axis (`end`); an open stop is index `1`.
- Bounds are checked as going forward: the start must be a valid index of a non-empty window, the
  stop must lie in `1..n` (or be `0` / `n + 1` for an empty window), and a window whose start is
  below its stop is empty (`a[1..2 by -1]` is empty, as Fortran's `a(1:2:-1)`).
- A reversed slice is a view like any other (§6): **nothing is copied**. It is valid as an
  assignment target (`a[.. by -1] = b` writes `b` into `a` back to front).
- The prelude's `reverse(a)` is `a[.. by -1]`, and `reverse(a, k)` reverses axis `k` only.

**Lowering, unverified:** a negative stride in a `memref` strided layout must be probed. If the
layout refuses it, a reversed axis lowers as an offset at the far end plus index arithmetic in the
loop, and a reversed view crossing the FFI to BLAS (`incx < 0`) passes the pointer to the
lowest-addressed element, since BLAS starts a negative-increment vector from that end.

## 6. Views

### 6.1 What a view is

Every slice expression with at least one kept axis — a range, `:`, `by`, or a partial index list —
evaluates to a **view**: a read-only window onto the source's storage, carrying its own offset,
extents and strides. Taking a view allocates nothing and copies nothing.

A view has an ordinary array type (`a[1..4]` is `[real; :]`); there is no separate view type. Every
function, operator and prelude entry that takes an array takes a view. Whether a value is a view or
an owned array is never observable, only its cost: **a view is a value**, fixed when it is taken.

### 6.2 The rules

1. **Read-only.** Nothing writes through a view. A view bound with `val` is immutable like any
   `val`. Writing *the source's* window is slice assignment on the source (§5.3), never through a
   named view.
2. **Copies when mutated.** A view bound to a `var` becomes an owned array: `var w = a[1..4]`
   copies the window, and `w[1] = 1` then changes only `w`. The copy is made by the auto-clone pass
   (ref §8.3) and is silent, like every other clone. (A slice *expression* of a `var` passed to an
   `inout` parameter is not a view but a place, written in place: §8.2.)
3. **Copies when it escapes.** A view that would outlive the expression or block that took it, by
   being **returned** from the function, **stored** in a struct, tuple or enum payload, **captured**
   by an escaping closure, or bound at **module level**, is copied to a dense owned array at that
   point. Passing a view as an argument is not an escape (the callee borrows it, ref §8.4), and
   neither is binding it to a local `val`.
4. **The source does not change under it.** If the source is a `var` and is written while a view of
   it is still live, the view keeps the values it had when it was taken: the compiler copies the view
   before the write. A view whose last use comes before the write costs nothing
   (`view-then-write.mlir`: the live view is copied once, the dead one not at all).
5. **A view keeps its source's storage alive** while the view lives (it holds a reference count on
   the buffer, ref §8.5).

These rules make views fit the two regimes of ref §8.1 without a new one: a view of a `val` array
shares freely, as the `val` does; a view of a `var` array shares only while the `var` is not
written, so the `var` stays the only writer of its buffer.

### 6.3 Lowering

A slice is a `tensor.extract_slice` with one offset, size and stride per axis (axes reversed,
§3.2); a collapsed axis is a size-1 dimension dropped by the rank-reducing form. One-shot
bufferization turns it into a `memref.subview` of the source with a strided layout, and allocates
nothing. `views.mlir` runs a column (`strided<[1], offset: 6>`), a row (`strided<[3], offset: 1>`),
a window strided on both axes (`strided<[3, 2], offset: 3>`) and a rank-2 plane of a rank-3 array
(`strided<[4, 1], offset: 12>`), each passed to a function taking a dynamic-shape tensor: two
allocations for the two source arrays and **no copy**, and the three element-wise operations on the
rank-3 array fuse to one loop nest. Rule 4 needs nothing from nex: `tensor.extract_slice` is a value,
and bufferization copies only when a later write would be visible (`view-then-write.mlir`).

Element access through a dynamic strided view needs `lower-affine` after `expand-strided-metadata`,
which the pipeline gains (PLAN.md).

### 6.4 Offset views: `origin`

Arrays are 1-based, always; there are no declared lower bounds. Where a computation reads better
with other bounds — a symmetric domain (`-n..n` for FFT frequencies, a convolution kernel), a grid
with ghost cells — `origin` takes an **offset view**:

```nex
val w = origin(kernel, -r)          // w[-r] .. w[r] are kernel[1] .. kernel[2r + 1]
val g = origin(grid, 0, 0)          // one origin per axis: g[0, 0] is grid[1, 1]
for k in -r..r do acc += w[k] * x[i - k]
```

- `origin(a, o1, o2, …)` takes one first-index per axis (fewer leaves the rest at `1`). Indexing,
  slicing and `end` on the view are relative to it: on `w`, `end` is `r`, and an index outside
  `-r..r` traps.
- It is a view (§6.2): read-only, no allocation, no copy — the offset is folded into the view's base
  address, so an access costs exactly what an access to `kernel` costs.
- **An offset view is local.** It lives only in the function that took it. Passing it as an
  argument, returning it, storing it in a struct, tuple or enum payload, binding it at module level,
  or capturing it in an escaping closure is a **compile error that names `origin`**: *"an `origin`
  view cannot leave this function; `rebase(w)` makes an ordinary 1-based array"*. So every function
  parameter starts at 1 and no function ever asks what its array's bounds are.
- `rebase(w)` is an ordinary 1-based copy of an offset view's elements (`rebase(w)[1]` is `w[-r]`),
  and is what crosses a function boundary. A function that wants the offset takes it as an ordinary
  argument and calls `origin` itself.

---

## 7. Element-wise operations and `@`

### 7.1 Element-wise

ref §4.5 holds for every rank: `A op B` needs equal rank (a compile error otherwise) and equal
shape (a compile error when both are static, else a trap), and is element-wise, with element types
mixed per §2.2. **Broadcasting is scalar-only**: `A op s` and `s op A` for a scalar `s`, any rank.
Element-wise expressions fuse to one loop nest per expression for every rank (`views.mlir`, rank 3).

### 7.2 `@`

`@` is defined on ranks 1 and 2, as ref §4.5 defines it:

| Operands | Shapes | Result |
|---|---|---|
| `[T; :, :] @ [T; :, :]` | `(m, k) @ (k, n)` | `(m, n)` |
| `[T; :, :] @ [T; :]` | `(m, k) @ k` | `m` |
| `[T; :] @ [T; :, :]` | `k @ (k, n)` | `n` |
| `[T; :] @ [T; :]` | `k @ k` | `T` (the dot product, no conjugation; `dot` conjugates, §7.4) |

An operand of rank 3 or more is a **compile error**, as Fortran's `matmul` takes ranks 1 and 2 only.
A batch of products is an explicit loop over the trailing axis, which the checker proves race-free
(§9):

```nex
parallel for k in 1..n
  C[:, :, k] = A[:, :, k] @ B[:, :, k]
```

The inner extent is checked at compile time when both are static and traps
otherwise. Static extents carry into the result's type: `[real; 3, 4] @ [real; 4, :]` is
`[real; 3, :]`. Mixed element types promote per §2.2.

**Lowering.** Below the BLAS threshold, or for an element type BLAS has no routine for, `A @ B` is a
`linalg.matmul` (`matvec`, `vecmat`, `dot`). With the axes reversed (§3.2), nex's `C = A @ B` is
storage's `Cᵀ = Bᵀ Aᵀ`, so the operands are emitted swapped (`blas.mlir` runs it). Above the
threshold it is a BLAS call (§10.4).

### 7.3 Elemental functions

**Every prelude scalar math function is elemental** — `sqrt`, `exp`, `log`, `sin`, `cos`, `tan` and
the rest of the elementary functions, `abs`, `conj`, `floor`, `ceil`, `round`, `trunc`, `sign`,
`hypot`, `atan2`, `min`, `max`: applied to an array of any rank it applies element by element and
returns an array of the same shape, and it fuses into the surrounding expression's loop nest like an
operator. `sqrt(a) + 1.0` is one loop. Arguments of a several-argument elemental function broadcast
as operators do (scalar-only, equal shapes otherwise): `max(a, 0.0)` clamps every element.

**A user function opts in with `@elemental`**: `@elemental def f(x: real) = …`. Its body obeys the
parallel-body rules of §9.4 — no `inout` parameters, no writes to module variables, no I/O except
`print` — so the compiler may evaluate it in any order and fuse it. An unmarked scalar function
applied to an array is a compile error that suggests `@elemental` or `map`.

### 7.4 Reductions

The prelude's whole-array reductions take Fortran's names: `sum`, `product`, `minval`, `maxval`,
`minloc`, `maxloc`, `any`, `all`, `count`, `norm2`, `dot`.

- `minloc(a)` and `maxloc(a)` return the index of the extreme element, a tuple of indices for rank
  ≥ 2; ties go to the first in storage order.
- **Every reduction takes a named `dim =` argument**, reducing along that axis to rank R − 1:
  `sum(m, dim = 2)`, `maxval(a, dim = 1)`, `maxloc(a, dim = 1)`.
- `min` and `max` are elemental (§7.3), never reductions: `max(a, 0.0)` clamps, and the extremes of
  one array are `minval` / `maxval`.
- `norm2` is the Euclidean norm, the Frobenius norm of a matrix. There is no `norm`.
- `dot(x, y)` conjugates `x` when complex, as Fortran's `dot_product` and BLAS's `zdotc` do. `@`
  never conjugates.
- The `minval` / `maxval` of an empty integer array are the type's largest / smallest values (the
  identities of §9.2), and `+inf` / `-inf` for reals.

---

## 8. `inout` parameters

### 8.1 The mode

A parameter is **read mode** (the default, ref §6.4: the callee reads it and may not mutate it) or
**`inout`**:

```nex
def scale(v: inout [real], s: real) =
  v = v * s                        // or element by element: for k in 1..length(v) do v[k] *= s

def swap(a: inout integer, b: inout integer) =
  val t = a
  a = b
  b = t

var x = [1.0, 2.0, 3.0]
scale(x, 2.0)                      // x is now [2.0, 4.0, 6.0]; nothing was returned
var p = 1
var q = 2
swap(p, q)                         // p == 2, q == 1
```

An `inout` parameter is an **exclusive borrow** of the caller's place, Swift's model: the callee
reads and writes the caller's storage directly; the caller keeps the variable, nothing is moved, and
the function does not return it. When the call returns, the caller sees every write. The mode
applies to scalars, arrays and structs alike; a scalar `inout` is by reference, as the reference's
`mut integer` was. A function type spells it the same way: `(inout [real], real) -> unit`.

The call site writes no marker, as in Fortran: `scale(x, 2.0)` reads the same whether `v` is
`inout` or not. A marker would add nothing the checker does not already enforce, since every misuse
of an `inout` argument (§8.2, §8.3) is a compile error at the call.

### 8.2 What may be passed

The argument to an `inout` parameter is a **place** rooted in something mutable: a `var` binding,
an `inout` parameter, a field of one (`p.pos`), an element (`a[i]`), or a slice (`m[:, j]`,
`a[1..n by 2]`), which borrows exactly that window and writes it in place. Passing a `val`, a
literal, a function result or any other temporary is a compile error: *"an inout argument must be a
`var`"*. (No auto-clone fires here: a clone's writes could not reach anything.)

### 8.3 Exclusivity

For the duration of the call, the callee has the only access to the borrowed place. At every call
the checker rejects:

1. **The same root in two `inout` arguments, unless the two places are syntactically disjoint**:
   `swap(a, a)`, `swap(a[i], a[j])` and `f(a[1..k], a[j..n])` are rejected. Two places of one root
   are accepted together only when the checker can see from the source alone that they cannot
   overlap:
   - two **different fields** of a local struct `var` (`swap(p.x, p.y)`);
   - on one axis, **non-overlapping constant windows or indices**: `f(a[1..4], a[5..8])`,
     `swap(a[1], a[2])`, `f(m[:, 1], m[:, 2])`;
   - on one axis, **a split at one expression `e`**, the same expression on both sides:
     `f(a[1..e], a[e+1..n])`, `f(a[..<e], a[e..])`, `f(m[:, ..e], m[:, e+1..])`.

   Every other pair of places on one root is a compile error, and the message suggests the split
   form: *"`a[1..k]` and `a[j..n]` may overlap; borrow `a[1..e]` and `a[e+1..]` at one split point
   `e`"*. No run-time disjointness check is made.
2. **An `inout` argument plus any other argument that reads an overlapping place of the same root
   while the call runs**: `f(a, a)` with the first parameter `inout`, or `f(a, a[1..3])`, since a
   read-mode array argument is borrowed, not copied (ref §8.4). An `inout` window and a read-mode
   window of the same array **are** accepted together when they are provably disjoint by the same
   three forms as two `inout` windows in rule 1 — non-overlapping constant windows or indices, a
   split at one expression `e` (`a[1..e]` / `a[e+1..n]`, also `..<e` / `e..`), distinct constant
   indices on one axis (`m[:, 1]`, `m[:, 2]`): `axpy(2.0, a[1..4], a[5..8])` with `y` the `inout`
   parameter is legal. Any other pair is a compile error. An argument that is fully evaluated to a
   scalar before the call starts does not conflict: `scale(a, a[1])` and `resize(a, length(a))` are
   legal. Arguments are evaluated left to right, and the exclusive access begins after the last one.
3. **Access by another route inside the callee.** Passing a module-level `var` as `inout` to a
   function that reads or writes that `var` by name, directly or through anything it calls, is
   rejected. The checker computes for each function the module-level `var`s it reads and writes,
   transitively; the same summary serves §9 (**PROPOSED** mechanism).
4. **Escaping captures.** An `inout` parameter may be captured by a non-escaping lambda (one passed
   straight as an argument, such as `assert_traps(() -> f(v), "…")`) but never by an escaping one.

### 8.4 Traps and the uniqueness rule

A trap inside the callee leaves the writes it made before the trap in place; nothing is rolled back.
The uniqueness rule (ref §8.2) loses its `mut` case: a `var` array is moved only by `return` and by
assignment to another `var` (and the auto-clone pass makes the latter a copy when the source is used
again, ref §8.3). An `inout` call is not a move and needs no clone.

**Lowering.** An `inout` array is a tensor argument whose updated value is returned and bound back
to the caller's variable. Every nex function except `main` is emitted `private`; with
`drop-equivalent-buffer-results` before `buffer-deallocation-pipeline`, a result that is its own
argument's buffer disappears, the function returns nothing and writes the caller's buffer in place
(`parallel.mlir`, `axpy`). Kept public, the same function returns its argument and the deallocation
pipeline clones it: a whole-array copy per call. A scalar `inout` is a pointer argument
*(unverified)*. An `inout` slice argument (§8.2) is the subview of §6.3 written in place
*(unverified)*.

---

## 9. Parallelism

### 9.1 `parallel for`

```nex
parallel for i in 1..n do y[i] = a * x[i] + y[i]

parallel for j in 1..cols(m)
  m[:, j] = m[:, j] / norm2(m[:, j])       // each iteration owns column j

parallel for i in 1..rows(c), j in 1..cols(c)          // a 2-D iteration space
  c[i, j] = dot(a[i, :], b[:, j])
```

The header is `parallel for` *index* `in` *range* (`,` *index* `in` *range*)*, over integer ranges
only (not over an array's elements). The iterations may run in any order and at the same time; the
loop ends when all of them have.

### 9.2 Reductions

A reduction is declared in the header with its operator, after the ranges:

```nex
var total = 0.0
var peak = 0.0
parallel for i in 1..n reduce total: +, peak: max
  total += x[i] * y[i]
  peak = max(peak, abs(x[i]))
print(total, peak)
```

**The operators** are the built-in `+`, `*`, `min`, `max`, `and`, `or`, `minloc`, `maxloc`, and any
**user-defined function** of type `(T, T) -> T`. The reduction variable is an outer `var` of a type
the operator applies to. Each iteration contributes through exactly one of `v op= e`, `v = v op e`,
`v = op(v, e)` (for `min`, `max` and a user function), `v = v and e`, `v = v or e`, or the location
forms below, where `e` does not mention `v`; `v` is not read anywhere else in the body. The `var`'s
value before the loop is the starting value, and after the loop it holds the combination of the
start and every contribution. `reduce` is a contextual word here, not a keyword: the prelude
function `reduce` keeps its name.

- **A user-defined operator** is named in the header and called in the contribution:

  ```nex
  def kahan_add(a: (real, real), b: (real, real)): (real, real) = …

  var s = (0.0, 0.0)
  parallel for i in 1..n reduce s: kahan_add
    s = kahan_add(s, (x[i], 0.0))
  ```

  The variable's value before the loop is taken as the operator's **identity**: every block of
  §9.2.1 starts from it, so it must satisfy `f(id, x) == x` (here `(0.0, 0.0)`, a zero sum with
  zero compensation). The function is called inside the
  parallel body and obeys every rule of §9.4. The compiler assumes it is associative; it cannot
  check that, and the fixed combination order of §9.2.1 makes the result reproducible whether or
  not it is.
- **`minloc` and `maxloc`** reduce a (value, index) pair, as Fortran's `MINLOC`/`MAXLOC` and
  OpenMP's `MINLOC`/`MAXLOC` reductions do. The variable holds both, and the contribution names the
  candidate and its index:

  ```nex
  var worst = (0.0, 0)
  parallel for i in 1..n reduce worst: maxloc
    worst = maxloc(worst, abs(r[i]), i)
  val (largest, where) = worst
  ```

  Ties go to the lowest index, as in Fortran, whatever the thread count.

#### 9.2.1 Reproducible reductions

**A reduction's result does not depend on the thread count.** The index range is cut into
fixed-size blocks (4096 iterations; the size is a compile-time constant, not a tuning knob), each
block is reduced sequentially from the operator's identity (`0` for `+`, `1` for `*`, `+inf` for
a real `min` and the type's largest value for an integer `min`, `-inf` / the type's smallest value
for `max`, …; for a user operator, the variable's starting value), the block partials are combined in
a **fixed pairwise tree** over the block numbers, and the tree's result is combined once with the
variable's starting value. Threads only decide who computes
which block, never the order of combination, so `OMP_NUM_THREADS=1` and `OMP_NUM_THREADS=64` give
identical bits.

**The sequential whole-array reductions use the same tree.** `sum(x)`, `product`, `dot`, `norm2`
and their `dim =` forms block and combine exactly as `parallel sum(x)` does, so adding or removing
`parallel` never changes a result's bits.

**The order is not left to right.** A floating-point `sum` therefore differs in its last bits from
a naive Fortran `DO` loop that accumulates one element at a time. Pairwise summation is also more
accurate: its rounding error grows as O(log n) rather than O(n). A loop written element by element
without `reduce` (`for i in 1..n do s += x[i]`) is an ordinary sequential loop and accumulates in
source order, as written. Integer reductions are exact, so their order is unobservable except that
an overflow traps.

### 9.3 Parallel map and reduction expressions

`parallel` also prefixes an expression whose value is computed element by element:

```nex
val y = parallel exp(-x * x)                    // elemental calls fuse into one parallel loop
val w = parallel map(x, t -> if t > 0.0 then t else 0.0)   // or parallel x.map(…)
val d = parallel sum(x * y)
val r = parallel 2a + b                          // a whole-array expression (PROPOSED)
```

The forms are `map`, the reductions `sum`, `product`, `minval`, `maxval`, `dot` (with or without
`dim =`), and any whole-array element-wise expression, elemental calls included. The general `reduce(a, init, f)` has no parallel form; a custom
combination is a `parallel for … reduce s: f` with a user operator (§9.2), where the identity and
the contribution are spelled out.

**There is no implicit parallelism.** A whole-array expression or reduction without `parallel` runs
on one thread, even though it would always be safe to run in parallel. The reason is MPI: the
typical scientific code runs one MPI rank per core, and a compiler that threaded each rank unasked
would oversubscribe every core. Threads are only ever started by a `parallel` the programmer wrote.
The one exception is outside nex's control: an `@` dispatched to BLAS (§10.4) may thread inside the
library, under that library's own controls (`OPENBLAS_NUM_THREADS`, `VECLIB_MAXIMUM_THREADS`).

### 9.4 What the checker proves

Inside the body of a `parallel for`, or the function passed to `parallel map`:

1. **No write to shared state.** Assignment is allowed only to (a) bindings declared inside the
   body, (b) declared reduction variables, in the forms of §9.2, and (c) elements or slices of an
   outer `var` array (or `inout` parameter) **owned by the iteration**: in every such write, some
   axis's subscript is exactly one of the loop's index variables, distinct loop variables on
   distinct axes, so two iterations can never write the same element (`y[i]`, `m[:, j]`,
   `c[i, j]`, `t[i, :, k]`). `y[i + 1]`, `y[2 * i]` and `y[idx[i]]` are rejected (**PROPOSED**: the
   rule recognizes only the plain index variable).
2. **No read of what another iteration writes.** An array written under rule 1(c) may be read in the
   body only at the iteration's own subscript (`y[i]` when writing `y[i]`); `y[i - 1]` is rejected.
   Every other outer binding is read-only for the duration of the loop, and reading it is free:
   value semantics means no other code can change it meanwhile.
3. **No effects through calls.** A function called in the body may receive `inout` only places that
   rule 1 allows the body to write (`normalize(m[:, j])`), and may not itself write a module-level
   `var` (the transitive summary of §8.3). `extern` functions not marked `@pure` (§10) are rejected
   in a parallel body.
   **I/O:** `print` and writing to stderr are allowed, and each call is **atomic** — its whole line
   is written under a lock, so lines never interleave mid-line — but the **order of lines across
   iterations is unspecified**. This is the one deliberately non-reproducible thing in a parallel
   loop. Every other I/O (`read_bytes`, `write_bytes`, opening or writing a file, reading input) is a
   compile error in a parallel body.
4. **The reductions are well formed** (§9.2).
5. **No nested `parallel`.** A `parallel for` or `parallel` expression inside a parallel body is a
   compile error, and the message suggests the two-axis header
   `parallel for j in 1..n, i in 1..m`.
6. **`cycle` is allowed, `exit` is not.** `cycle` ends the current iteration; `exit` (and an
   `exit`/`cycle` naming a loop outside the body) is a compile error, since the iterations have no
   order to leave.

A body the checker cannot prove is a compile error naming the offending write or read, never a
silent fallback to a sequential loop. The wording of the checker's messages is the
implementation's; the documentation's are illustrative.

The body of an `@elemental` function (§7.3) obeys rules 1–3 and 5 as if it were a parallel body.

**A trap inside a parallel body** ends the loop: every iteration already running finishes, no new
one starts, and the trap is raised in the thread that started the loop, as if by its first
statement after the loop (**PROPOSED**). Which iteration's trap is reported when several trap is
unspecified. (The runtime's `longjmp` must not cross an OpenMP thread, so a worker records the trap
and the region's end raises it *(unverified)*.)

### 9.5 Lowering

| nex | MLIR at the tensor level | after bufferization |
|---|---|---|
| `parallel for` writing owned elements | `scf.forall` with `shared_outs`, one `tensor.parallel_insert_slice` per written array | `scf.forall` → `scf.parallel` (`scf-forall-to-parallel`) |
| a reduction (`reduce` clause, `parallel sum`) | `scf.parallel` with an `scf.reduce` region over the operand's `bufferization.to_buffer` | itself |
| `parallel map`, `parallel` element-wise | `linalg.generic`, all iterators `parallel` | `convert-linalg-to-parallel-loops` |

then `convert-scf-to-openmp` (an `omp.parallel` / `omp.wsloop`, and an `omp.declare_reduction` per
reduction) and `convert-openmp-to-llvm`, linking `libomp`. `parallel.mlir` runs all three shapes
through both the sequential pipeline (where `convert-scf-to-cf` makes every parallel op a plain
loop) and the OpenMP one, with the same sum both ways, and records the highest OpenMP thread id that
ran an iteration: 0 sequentially, 3 under `OMP_NUM_THREADS=4`. An element write in the body is a
`linalg.fill` of a one-element `tensor.extract_slice`; `tensor.from_elements` instead bufferizes to
an allocation and a `memrefCopy` call per iteration (both run).

The OpenMP lowering of a reduction over an operator the conversion does not pattern-match
(complex `+`, `min`/`max` on integers, `and`/`or`, `minloc`/`maxloc`, a user operator) is
*(unverified)*; only real `+` was run. The fixed block-and-tree order of §9.2.1 is emitted by nex
around the per-block loop, not left to `omp.declare_reduction`, whose combination order follows the
thread count.

**Which pipeline a program gets is decided by the program, not by a flag.** A program that contains
a `parallel` construct anywhere is lowered through OpenMP and links the OpenMP runtime; a program
with none is lowered sequentially and links no OpenMP runtime at all. There is no `-fopenmp`
equivalent to forget.

**The thread count comes from `OMP_NUM_THREADS` only**, the variable every HPC batch script already
sets; nex adds no variable of its own. `OMP_PROC_BIND` and `OMP_PLACES` are honoured as the OpenMP
runtime reads them. `OMP_NUM_THREADS=1` runs the program sequentially and, by §9.2.1, produces
identical bits.

---

## 10. C FFI, BLAS and LAPACK

### 10.1 `extern` declarations

```nex
@link("m")
extern def cbrt(x: real): real

@link(framework = "Accelerate")                    // macOS; @link("openblas") elsewhere
extern def cblas_ddot(n: int32, x: [real], incx: int32,
                      y: [real], incy: int32): real

@symbol("dgesv_")
extern def lapack_dgesv(n: int32, nrhs: int32, a: inout [real; :, :], lda: int32,
                        ipiv: inout [int32], b: inout [real; :, :], ldb: int32,
                        info: inout int32)
```

`extern def` is a bodyless declaration of a C function, the second sanctioned bodyless form beside
`@intrinsic` (ref §6.11). `@symbol("…")` names the C symbol when it differs from the nex name;
`@link("lib")` adds a link input, as does `-l lib` on the command line, with `-L dir` adding a
search directory; `@link(framework = "…")` is a **PROPOSED** spelling. A program with a `@fortran`
extern links the gfortran runtime automatically. An `extern` function is assumed to have effects (I/O, global state) unless declared `@pure`, which the checker
believes without proof.

### 10.2 What crosses

| nex parameter | C sees |
|---|---|
| `int8` … `int64` | `int8_t` … `int64_t` |
| `uint8` … `uint64` | `uint8_t` … `uint64_t` |
| `real32`, `real64`, `real16` | `float`, `double`, `_Float16` |
| `complex[real32]`, `complex[real64]` | `float _Complex`, `double _Complex`, **by value** |
| `bool` | `bool` (`_Bool`) |
| `inout` scalar | a pointer to it (`int32_t *info`) |
| `string` | `const char *`, a NUL-terminated copy valid for the call |
| `[T; …]` read mode | `const T *` to the first element of the window |
| `[T; …]` `inout` | `T *` to the first element; C's writes land in the caller's array |
| a `@c` struct, read mode or `inout` | `const S *` / `S *` to the struct, laid out as C lays it out |
| a function type `(A, B) -> R` | a C function pointer (§10.2.1) |
| `c_ptr` | `void *`, opaque, only as a callback's `@data` partner (§10.2.1) |
| return: a scalar, a complex or `unit` | the value, or `void` |

**Complex scalars cross by value.** nex mirrors clang's ABI for `_Complex` on each target, so
`double _Complex` arguments and results agree with C: on arm64 a complex is a homogeneous
floating-point aggregate in two consecutive FP registers; on x86-64 System V it is two SSE values
(a `complex[real64]` in two SSE registers, a `complex[real32]` packed in one). Complex **arrays**
cross as pointers, whose interleaved (re, im) layout is C99's and BLAS's *(unverified for complex)*.

**`@c` structs cross by reference.** A struct declared `@c` has C's field order, alignment and
padding, and passes as a pointer (`const S *` in read mode, `S *` as `inout`). A struct **by value**
does not cross yet (§15).

No array is returned from C. A read-mode array argument is a promise that C does not write it; the
compiler cannot check that, and a C function that breaks it breaks value semantics.

#### 10.2.1 Callbacks

A nex `def` passes where C wants a function pointer: an `extern` parameter of a function type
(`f: (real) -> real`) receives a C-callable trampoline for the named function. The callback's
parameters follow the extern's convention — by value for a C extern, by reference when the extern
is declared Fortran (§10.6). Without a data pointer a callback must not capture (Fortran's rule):
a **non-capturing** `def` or lambda passes directly.

**Callbacks with user data.** The opaque type **`c_ptr`** (`iso_c_binding`'s name) is C's `void *`.
It is legal only in `extern` declarations, has no arithmetic and cannot be dereferenced. An extern
pairs it with a callback parameter by `@data(f)`:

```nex
extern def gsl_integration_qags(f: (real, c_ptr) -> real, data: @data(f) c_ptr,
                                a: real, b: real, …)
```

A call passes an ordinary closure for `f` and **omits** `data`:
`gsl_integration_qags(x -> sin(k * x), 0.0, pi, …)`. The compiler generates the C trampoline of
`f`'s C type, passes the closure's environment as `data`, and the trampoline unpacks it and calls
the closure. The closure is **borrowed for the call** and may not escape it: a library that keeps
the pointer past its return is outside the model. A capturing closure for a callback parameter with
no `@data` partner is a compile error. A trap inside a callback unwinds to the nex frame that made
the extern call *(unverified)*.

### 10.3 Strides and the leading dimension

C receives a pointer and nothing else, so what the pointer means must be agreed:

- **Rank 1.** By default the parameter needs unit stride: a strided view (`x[1..n by 2]`) is copied
  to a dense array before the call (and, for `inout`, copied back after). A parameter marked
  `@strided` passes any view as is, and the program passes the stride itself, as BLAS's `incx`.
- **Rank 2.** By default the parameter needs unit stride along the first axis (each column contiguous) and
  any stride between columns: that column stride is the **leading dimension**. A view such as
  `m[1..3, :]` or `m[2..6, 1..4]` crosses with no copy, its pointer offset to its first element and
  its leading dimension the source's. A view strided along the first axis (`m[1..8 by 2, :]`) is
  copied first.
- **Rank ≥ 3.** The parameter needs a dense column-major array; anything else is copied first.

The prelude gives the numbers C needs: `stride(a, k)`, the element stride of axis `k`, and
`ld(m) = stride(m, 2)` for rank 2 (**PROPOSED** names). Every copy here is silent, like an
auto-clone.

**Lowering.** The pointer is `memref.extract_aligned_pointer_as_index` plus the offset from
`memref.extract_strided_metadata`; the leading dimension is the stride of the memref's first
dimension, which is nex's second axis (§3.2). `blas.mlir` calls `cblas_dgemm` from Accelerate on a
whole matrix and on the view `Big[2..3, :]` (offset 1, leading dimension 4) and gets the same
product both times, no copy.

### 10.4 `@` dispatches to BLAS

`A @ B` is a BLAS call instead of a `linalg` op when all of these hold:

1. The element type is `real32`, `real64`, `complex[real32]` or `complex[real64]` (`s`, `d`, `c`,
   `z`). Integer,
   `bool` and `real16` products never dispatch.
2. **Either** the product is large: `m·k·n ≥ 64³` for matrix-matrix, `m·k ≥ 128²` for
   matrix-vector and vector-matrix, `k ≥ 4096` for a dot (**PROPOSED** thresholds, to be set by the
   perf oracle); **or** the shape is one the fused path cannot do without materializing an operand:
   an operand that is `transpose(X)`, `conj(transpose(X))` (BLAS's `T` and `C` flags), or a rank-2
   view whose unit stride is along the second axis rather than the first (a transposed layout).
3. A BLAS library is linked: Accelerate on macOS (the run in `blas.mlir`), OpenBLAS elsewhere
   *(unverified)*, through the LP64 (`int32`) interface.

The routine follows the shape: `gemm`, `gemv` (`T` flag for vector-matrix), `dot` (`dotu` for
complex: nex's `@` does not conjugate). With static extents the decision is made at compile time;
with dynamic ones the compiler emits both paths and a run-time test. Operands that fail §10.3's
stride rules are copied first. `C = alpha * (A @ B) + beta * C` assigned to the same `C` is one
`gemm` with `beta` (**PROPOSED**).

**A BLAS result may differ in the last bits from the `linalg` path**, since it sums in a different
order. Every corpus matrix is far below the threshold. A build flag disables dispatch
(**PROPOSED**: `nex build --no-blas`).

### 10.5 LAPACK

The prelude reaches LAPACK for the dense linear-algebra kernels. **The first set** is:

| Function | LAPACK | Result |
|---|---|---|
| `solve(A, b)` | `?gesv` | `x` with `A @ x == b` (`b` a vector or a matrix of right-hand sides) |
| `lstsq(A, b)` | `?gelsd` | the least-squares `x` |
| `inv(A)` | `?getrf` + `?getri` | the inverse |
| `det(A)` | `?getrf` | the determinant; `0.0` for a singular matrix (no trap) |
| `lu(A)` | `?getrf` | `(L, U, p)`, the pivoted factors |
| `chol(A)` | `?potrf` | lower `L` with `A == L @ conj(transpose(L))`, `A` symmetric/Hermitian positive-definite |
| `chol(A, upper = true)` | `?potrf` | upper `U` with `A == conj(transpose(U)) @ U` |
| `qr(A)` | `?geqrf` + `?orgqr` | `(Q, R)` |
| `eigvals(A)` | `?geev` | eigenvalues of a general matrix, **always complex** |
| `eig(A)` | `?geev` | `(values, vectors)`, **always complex**; vectors are columns |
| `eigh(A)` | `?syevd` / `?heevd` | `(values, vectors)` of a symmetric/Hermitian matrix; values real, ascending |
| `svd(A)` | `?gesdd` | `(U, s, V)` with `A == U @ diag(s) @ conj(transpose(V))` |
| `svdvals(A)` | `?gesdd` | the singular values, descending |

Pivot indices (`ipiv`) are `[int32]`, LAPACK's integer.

**Later** (§15): banded and tridiagonal solvers, generalized eigenproblems, `rcond` / `cond`.

**The value forms** take and return values, copying their inputs because LAPACK overwrites them,
and **trap** when LAPACK's `info` reports failure, with a message naming the routine and the cause
in the user's terms: *"solve: matrix is singular (U[3,3] = 0)"*, *"chol: matrix is not positive
definite (leading minor 4)"*, *"svd: did not converge"*. The indices in a message are 1-based, as
LAPACK's `info` already is. Only the solvers (`solve`, `inv`, …) trap on a singular matrix.

**The `inout` forms** factor in place without the copy — `lu_inplace(A, ipiv)`,
`chol_inplace(A)`, `qr_inplace(A, tau)`, … — and do **not** trap: they return LAPACK's `info` as an
`integer`, for the code that wants to handle a singular matrix itself.

Column-major storage means no transposes, and the leading-dimension rules are §10.3's.

### 10.6 Calling Fortran

**nex calls existing Fortran directly**, and this is first-class, not an afterthought: the product
case against Julia is *Fortran's model, modern syntax, compiler-enforced safety, ahead-of-time native
binaries* — and a scientist's existing Fortran library is part of Fortran's model. Two kinds of
Fortran procedure are reachable:

- **`bind(c)` procedures** (Fortran 2003 interoperability) are C functions to nex and are declared
  as in §10.1, with `@symbol` giving the `bind(c, name=…)` name.
- **Plain gfortran objects** — a `.o`, `.a` or `.so` compiled from ordinary Fortran 77/90 — are
  declared `@fortran` (**PROPOSED** spelling):

  ```nex
  @fortran @link("mylib")
  extern def dgtsv(n: int32, nrhs: int32, dl: inout [real], d: inout [real], du: inout [real],
                   b: inout [real; :, :], ldb: int32, info: inout int32)

  @fortran
  extern def read_mesh(filename: string, nodes: inout [real; :, :], n: inout int32)
  ```

  `@fortran` applies gfortran's conventions so the declaration reads like the Fortran interface:
  1. **Name mangling**: the symbol is the lowercase name with a trailing underscore (`dgtsv_`);
     `@symbol` overrides it (a module procedure's `__mod_MOD_name`).
  2. **Every argument by reference**, as Fortran passes it: a read-mode scalar passes the address of
     a temporary copy, an `inout` scalar the address of the caller's place.
  3. **Hidden string lengths**: each `string` argument passes its pointer in place and its length
     as an extra trailing argument (`size_t` in gfortran 8 and later), in order after all the
     declared arguments. Fortran strings are not NUL-terminated and nex adds no terminator.
  4. **Arrays** pass as for C (§10.2, §10.3): column-major is native, so a dense array or a
     leading-dimension view crosses with no copy, and Fortran's 1-based indexing matches nex's.
  5. **Complex** is by reference like every other argument; a Fortran `COMPLEX` function result
     follows gfortran's convention for the target *(unverified)*.

What does not cross: Fortran assumed-shape (`a(:)`) dummies of a non-`bind(c)` procedure, which
need gfortran's array descriptor; derived types; `optional` arguments. Each is reached through a
`bind(c)` wrapper written in Fortran. LAPACK and BLAS (§10.4, §10.5) are themselves Fortran and are
called through these rules.

**Linking.** `nex build` links the gfortran runtime automatically when the program has a
`@fortran` extern. The Fortran library itself comes from `@link("name")` or `-l name`, found on the
default search path or a `-L dir` given on the command line.

---

## 11. Lexical changes

**Keywords** (ref §2.3) gain `inout`, `parallel`, `extern`, `enum`, and the loop and program
controls `exit`, `cycle` and `stop` (§11.1). `mut` stays reserved and means nothing. `by` (the step
of a range) and `reduce` (the `parallel for` clause) are contextual, so `reduce` remains a prelude
name. `unit` is contextual too: followed by a name at the start of a top-level declaration it
declares a unit of measure (§13.1), and everywhere else it is the type `unit`. The type names of
§2.1 are prelude type names, not keywords.

**Units**: a `<` written directly after a numeric literal, a name or a `]`, with no space, opens a
unit of measure only if the text after it, up to a `>` on the same line, is valid unit syntax
(`9.81<m/s^2>`, `real32<m/s>`, §13.2); otherwise it is the comparison, so `1<x` and
`0<x and x>1` compare. Inside the brackets, names are unit names in their own namespace, so `in`
is a unit there. A `<` after anything else, or after a space, is the comparison.

**Operator precedence**: `^` binds tighter than unary minus, so `-x^2` is `-(x^2)` as in Fortran and
mathematics, and `^` is right-associative (`2^3^2` is `2^(3^2)`). `^` is the only power operator;
there is no `**`.

**Ranges**: `..` is the inclusive range operator and `..<` the half-open one (§5.1); there is no
`..=`. Both serve slices and `for` headers alike: `for k in 1..n` runs `n` times. There is no `range()` function: `lo..hi` and `lo..<hi` are the only
range spellings, and each is an integer array wherever an expression may stand (`sum(0..<n)`). A
range binds looser than `+` and tighter than a comparison, so `2 * (0..<n)` and `(0..<n)[3..6]`
need their parentheses and `0..<n < 3` does not.

**`end`** is both the block terminator of ref §2.7 and the index expression of §5.2, told apart by
bracket depth and line position as §5.2 specifies.

**`do`** introduces only a one-line body (`for k in 1..n do s += k`). A body on the following,
indented lines takes no `do`, in a `for`, a `while` and a `parallel for` alike.

### 11.1 Loop and program control

- **`exit`** leaves the innermost loop; **`cycle`** goes to its next iteration (Fortran's names).
- **A loop may be named**: `outer: for j in 1..n`, and `exit outer` / `cycle outer` act on that
  loop, as Fortran's named `DO` constructs do.
- **`stop`** ends the program with exit status 0; **`stop n`** with status `n`.
- **A `for` header takes a step**: `for k in n..1 by -1`, `for k in 1..n by 2`, read in the direction
  of travel exactly as a subscript's `by` (§5.4). A stepped range is a value (`val odd = 1..n by 2`).
- In a `parallel for` body, `cycle` ends that iteration and is allowed; `exit` is a compile error
  (§9.4).

### 11.2 The program

- **The entry point** is `def main()` or `def main(args: [string])`; any other signature of `main`
  is a compile error. `args` holds only the user's arguments, without the program name, 1-based:
  `args[1]` is the first. The exit status is 0 when `main` returns, `n` after `stop n`, and non-zero
  after an uncaught trap.
- **The top level of a file holds only declarations** (`import`, `const`, module-level `val` and
  `var`, `def`, `struct`, `enum`, `extern`); there are no top-level statements.
- **`print`** writes to standard output, **`eprint`** to standard error.
- **No `intent(out)`.** A function returns its results; several are returned as a tuple and taken
  apart with `val (q, r) = f(…)`.
- **`nex test`** runs every `@test def` in the project, in any module, prints one line per failure
  and then a summary, and exits non-zero on any failure. `nex test <substring>` runs only the tests
  whose names contain it. A trap fails its own test; the others still run.

---

## 12. The imaginary unit `i`

`i` is a prelude constant, the imaginary unit (0, 1), and any binding named `i` shadows it within
that binding's scope, exactly as ref §2.4 and §10.1 say. Juxtaposition (ref §4.4) multiplies a
numeric literal by whatever `i` names at that point. So a loop index named `i` turns `2i` into
"2 times the index". This is intended: `i` is an ordinary name, and the most common loop index in
numerical code is not worth a reserved word.

```nex
val z = 3 + 2i            // 3.0+2.0i: i is the imaginary unit
for i in 1..3
  print(2i)               // 2, 4, 6: i is the loop index, so 2i is 2 * i, an integer
print(2i)                 // 0.0+2.0i: the loop's i is out of scope again
```

Inside a scope that binds `i`, write the unit some other way (`complex(0.0, 1.0)`, or a binding
`val im = i` taken outside), or name the index `j`, `k`, `m` or `n`.

---

## 13. Units of measure

A real or complex value may carry a **unit of measure**, which the type checker follows through
every expression and erases before code generation. A program that adds a length to a force, or
stores a pressure where a length belongs, does not compile. The notation is F#'s: a unit is written
in angle brackets after a literal or a type name.

### 13.1 Declaring units

```nex
unit m                          // a base unit: a dimension of its own
unit N = kg m / s^2             // a derived unit
unit in = 0.0254 m              // a scaled unit: an exact factor times a unit
unit ft = 12 in
unit lbf = 4.4482216152605 N
unit psi = lbf / in^2
```

- **A `unit` declaration is a top-level declaration.** `unit` is a contextual word (§11): followed
  by a name at the start of a top-level declaration it declares a unit, and everywhere else it is
  the type `unit` of ref §3.1, which keeps its meaning.
- **A unit expression** is built from unit names and `1`: juxtaposition multiplies, `/` divides and
  `^n` raises to a constant power — an integer, optionally negative (`s^-1`), or a parenthesized
  rational (`m^(1/2)`). `^` binds tightest, juxtaposition next, `/` loosest and left-associative,
  and parentheses group: `kg m / s^2` is (kg·m)/s², and `J / kg K` is J/(kg·K).
- **A derived unit** (`N = kg m / s^2`) is another name for its expression. **A scaled unit**
  (`in = 0.0254 m`) is a positive numeric literal times a unit expression. The factor is **exact**:
  a decimal literal is read as the rational it spells, and factors compose exactly, so `ft` is
  exactly 0.3048 m and `psi` exactly 6894.757293168361… Pa as a rational. A definition may not
  refer to itself, directly or through another unit.
- **Two units are the same unit** when they reduce to the same exponents of the same base units and
  the same factor. `N` and `kg m / s^2` are one unit, `Hz` and `1/s` are one, and so are `J` and
  `N m` (as in SI, torque and energy are not told apart). `mm` and `m` have the same **dimension**
  and different factors: two units, convertible (§13.3).
- **Unit names live in their own namespace** and appear only inside `<…>` and in `unit`
  declarations, so a variable named `m`, `s` or `g` does not clash with the unit, and the keyword
  `in` is an ordinary unit name there (`2.0<in>`). A module's own `unit` declaration of a prelude
  unit's name shadows it in that module, as any prelude name may be shadowed. `ms` is the
  millisecond; the metre-second is `m s`.

### 13.2 Spelling a unit

| Form | Example |
|---|---|
| a literal | `9.81<m/s^2>`, `2.0<in>`, `1.0e5<Pa>` |
| a real type | `real<m>`, `real32<m/s>`, `real16<Pa>` |
| a complex type | `complex<V>`, `complex[real32]<ohm>` |
| an array type | `[real<m>; :, :]`, `[real32<Pa>; 3, 3]`, `[complex<V>]` |
| dimensionless | `<1>`: `real<1>` is `real` |

- **`<` opens a unit only directly after a numeric literal, a name or a `]`, with no space, and
  only when unit syntax up to a `>` on the same line follows.** `x<y`, `1<x` and `2 < x` are
  comparisons; `2<x>` is the literal 2 with unit `x`.
- **Plain `real` is dimensionless**, and so is an unannotated literal: `1.0` is `real<1>`.
- **Units attach to real and complex types only** (**PROPOSED**); integers count things. An integer
  literal with a unit is a real literal of that value: `12<in>` is `12.0<in>`.
- A literal with a unit takes its width from context exactly as §2.3 says: `9.81<m/s^2>` beside a
  `real32<m>` is a `real32<m/s^2>`.

### 13.3 Arithmetic and conversion

- **`+`, `-` and the comparisons need operands of the same dimension.** Of the same unit, the
  operation is the plain one. Of the same dimension and different scales, the right operand is
  converted to the **left operand's unit**, with the ratio of the two factors folded at compile
  time: `10.0<mm> + 1.0<in>` is `35.4<mm>`, and `1.0<ft> > 300.0<mm>` compares in feet. Of
  different dimensions they are a compile error: `1.0<in> + 1.0<lbf>` is *"cannot add in and lbf:
  length and force are different dimensions"*.
- **`*` and `/` combine units**: `3.0<m> / 2.0<s>` is a `real<m/s>`, and `2.0 * x` keeps `x`'s
  unit. A product keeps the names it was made from (`1.0<mm> * 1.0<in>` is `real<mm in>`, an area
  whose factor is 0.001 × 0.0254).
- **`^` takes a constant exponent** when its base carries a unit: `x^2` is `real<m^2>` for
  `x: real<m>`, and a rational exponent is allowed (`<m^(1/2)>`). `x^n` with `n` not a compile-time
  constant needs a dimensionless `x`.
- **A bare literal is dimensionless.** With `x: real<m>`, `x + 1.0` and `x > 0.0` are compile errors;
  write `x + 1.0<m>` and `x > 0.0<m>`.
- **An expected type converts** (**PROPOSED**): a binding, an argument, a returned value or an
  assignment of the same dimension and another scale is converted to the target's unit, as `+`
  converts its right operand. `val d: real<mm> = 1.0<in>` holds `25.4<mm>`. A different dimension
  is a compile error.
- **`to<u>(x)`** converts explicitly, on a scalar and element-wise on an array: `to<mm>(1.0<in>)` is
  `25.4<mm>`. A target of another dimension is a compile error.
- **`strip(x)`** removes the unit and gives the number in `x`'s own unit, dimensionless:
  `strip(25.4<mm>)` is `25.4`, and `strip(to<m>(d))` is the length in metres. On an array it is a
  view of the same storage, with no copy. **A unit is attached by multiplying**: `y * 1.0<m>`.

### 13.4 Prelude functions

- `sqrt` halves every exponent: `sqrt(a)` for `a: real<m^2>` is `real<m>`.
- `abs`, `conj`, `floor`, `ceil`, `round`, `trunc`, `min`, `max`, `minval`, `maxval`, `sum` and
  `norm2` keep the unit; `min`, `max` and `hypot` convert their second argument as `+` does.
  `atan2(y, x)` takes two values of one dimension and returns a dimensionless angle.
- `exp`, `log`, `sin`, `cos`, `tan` and the other elementary functions need a dimensionless argument
  and return a dimensionless result. **`rad` is dimensionless** (`unit rad = 1`), so
  `sin(0.5<rad>)` is accepted.
- `product(a)` has unit `U^n`; for an `a` that carries a unit, `n` must be a static extent
  (**PROPOSED**), and otherwise it is a compile error that suggests `strip`.
- `print` and string interpolation show the unit after the value, separated by a space: with
  `val g = 9.81<m/s^2>`, `print(g)` prints `9.81 m/s^2`. The unit is spelled as the type carries it,
  in a form that reads back as the same unit (`8.314 J/(mol K)`). An array prints its elements and
  then its unit once (**PROPOSED**). A dimensionless value prints as it always has.

### 13.5 Generic units

A generic parameter bounded by `Unit` (§2.6) stands for a unit, in the generic-parameter form of
§3.4:

```nex
def sqr[U: Unit](x: real<U>) = x * x                   // real<U^2>

def mean[U: Unit](a: [real<U>]) = sum(a) / length(a)   // real<U>
```

`U` is inferred from the arguments. Units are erased, so a unit parameter adds no
specialization: `sqr` called on `real<m>` and on `real<s>` is one function.

### 13.6 Linear algebra

Every element of an array carries the array's one unit; a matrix whose columns have different units
is held stripped. The products and solvers carry units through:

| Operation | Unit |
|---|---|
| `A @ x`, `A @ B` | the product of the operands' units |
| `dot(x, y)` | the product of the operands' units |
| `sum(a)`, `norm2(a)` | `a`'s unit |
| `solve(A, b)`, `lstsq(A, b)` | `b`'s unit divided by `A`'s |
| `inv(A)` | the reciprocal of `A`'s unit (**PROPOSED**) |
| `det(A)` | `A`'s unit to the power n; `A` carrying a unit needs a static extent n (**PROPOSED**) |
| `eigvals`, `eigh`, `svdvals`; the `R` of `qr`, the `U` of `lu`, the `s` of `svd` | `A`'s unit; the other factors are dimensionless (**PROPOSED**) |
| `chol(A)` | the square root of `A`'s unit (**PROPOSED**) |

### 13.7 C and Fortran

**An `extern` parameter never carries a unit.** Passing a unit-carrying value to one is a compile
error that names `strip`: `cbrt(strip(v))`. An array strips as a view, with no copy, so
`cblas_ddot(n, strip(x), 1, strip(y), 1)` copies nothing. A result is given its unit by
multiplying: `cbrt(strip(v)) * 1.0<m>`. A nex function passed as a callback (§10.2.1) has
unit-free parameters and result for the same reason.

### 13.8 Cost

Units exist only in the type checker and are erased before MLIR is emitted, so a program with units
compiles to the same code as the same program without them. **Mixing scales costs one
multiplication by a constant**: the ratio of two exact factors, rounded once to the operand's width
at compile time — the same single rounding a hand conversion makes. Where no scales are mixed, no
conversion is emitted.

### 13.9 The prelude units

| Units | Definitions |
|---|---|
| SI base | `m` `kg` `s` `A` `K` `mol` `cd` |
| SI derived | `N = kg m / s^2`, `J = N m`, `W = J / s`, `Pa = N / m^2`, `Hz = 1 / s`, `C = A s`, `V = W / A`, `ohm = V / A`, `rad = 1` |
| SI scaled | `mm = 0.001 m`, `cm = 0.01 m`, `km = 1000 m`, `g = 0.001 kg`, `ms = 0.001 s`, `us = 0.000001 s`, `ns = 0.000000001 s`, `kPa = 1000 Pa`, `MPa = 1000000 Pa`, `GPa = 1000000000 Pa`, `kN = 1000 N`, `kJ = 1000 J`, `kW = 1000 W` |
| Imperial and US customary | `in = 0.0254 m`, `ft = 12 in`, `yd = 3 ft`, `mi = 5280 ft`, `lb = 0.45359237 kg`, `oz = 0.0625 lb`, `lbf = 4.4482216152605 N`, `slug = lbf s^2 / ft`, `psi = lbf / in^2`, `ksi = 1000 psi`, `BTU = 1055.05585262 J`, `hp = 550 ft lbf / s`, `usgal = 231 in^3`, `ukgal = 0.00454609 m^3` |

`in`, `lb` and `lbf` are the international definitions (1959), `lbf` is `lb` times standard
gravity 9.80665 m/s², `BTU` is the International Table BTU and `hp` the mechanical horsepower.
**There is no `gal`**: the US and UK gallons differ by a fifth, so a program says which. Temperature
is in `K` until the affine units of §15 arrive.

---

## 14. Where this differs from the reference specification

| Subject | Reference | Here | Change |
|---|---|---|---|
| Sized numeric types and their aliases | §3.1, §11.2 | §2.1 | `iso_fortran_env` names: `int8…64`, `uint8…64`, `real16…64`, `complex[real16…64]`; `integer`, `real`, `complex` become aliases of the 64-bit kinds |
| Unsigned integers | — | §2.1, §2.2 | `uint8…64`, trapping; same-width signed/unsigned mixing needs a conversion |
| `byte` and `[byte]` | §3.3.1 | §3.1 | gone: bytes are `[uint8]`, an ordinary array (`read_bytes`/`write_bytes` take and give `[uint8]`) |
| Promotion | §3.2, §4.4 | §2.2 | a lattice across widths; integer meets real gives the real's width; a typed scalar promotes an array |
| Index base | §4.14 (0-based) | §3.2, §5.1 | **1-based**, as Fortran; axis numbers (`extent(a, k)`, `dim =`) are 1-based too |
| Range syntax | §4.14 (`..` half-open, `..=` inclusive) | §5.1 | `a..b` is **inclusive** (Fortran `a:b`); `a..<b` is half-open; `..=` is gone |
| `range(lo, hi)` | §10 (prelude) | §5.1, §11 | gone: a range is written `lo..hi` or `lo..<hi`, and is an array value anywhere an expression may stand |
| Literal typing | §2.4 | §2.3 | literals and `pi`/`e`/`inf`/`nan`/`i` take their context's width |
| Conversions | §10.7 | §2.4 | a conversion function per type name |
| Generic constraints | §6.10 | §2.6 | widened to sized types; `Integral`, `Rank` added |
| Array types | §3.3, §3.10, §11.2 | §3 | `[T; axes]`, any rank, static extents; `[T]` is sugar; `[[T]]` is gone |
| Rank-generic code | §6.10 | §3.4 | `R: Rank` parameters |
| Literals of rank ≥ 3; jagged literals | §4.13 | §4.1 | nesting to any depth; a visibly jagged literal is a compile error |
| Constructors and shape functions | §10.4, §10.5 | §4.2, §4.3 | any rank; `rank`, `extent`, `extents`, `size`, `permute`; element type from context |
| Negative indices | §4.14 | §5.1 | removed: a negative index traps |
| End-relative indexing | — | §5.2 | `end` in subscripts |
| Strided slices on every axis; strided assignment | §4.14, §4.15 | §5.1, §5.3 | `by` on any axis, read and write |
| Negative strides | §4.14 (deferred) | §5.4 | `by -k` reverses; `reverse(a)`; a view, no copy |
| Offset views | — | §6.4 | `origin(a, o1, …)`: a local-only view with other first indices; `rebase` copies to 1-based; arrays stay 1-based |
| Slices | §4.14 ("freshly owned") | §6 | a slice is a read-only view |
| `a.view(…)` | §10.5 (view-style slicing) | §6 | gone; a slice is the view, and writing goes through slice assignment or `inout` |
| Writes to a source visible through an earlier view | §10.5 | §6.2 rule 4 | a view keeps the value it was taken with |
| `@` | §4.5 | §7.2 | ranks 1 and 2 only, static extents, BLAS dispatch |
| Parameter modes | §6.4, §3.9, §8.1–§8.4 | §8 | `inout` exclusive borrow replaces move-in `mut`; syntactically disjoint windows may be borrowed together |
| Parallel loops and reductions | §11.2 | §9 | `parallel for … reduce` with built-in, `minloc`/`maxloc` and user operators; reproducible across thread counts; `parallel map`/reductions; no implicit parallelism |
| Whole-array reduction order | — | §9.2.1 | blocked pairwise tree, the same with or without `parallel` |
| FFI, BLAS, LAPACK | §6.11, §11.2 | §10 | `extern def`, `@link`, `@symbol`, `@strided`, `@pure`, `@c` structs, callbacks, complex by value; LAPACK value forms trap, `inout` forms return `info` |
| Calling Fortran | — | §10.6 | `bind(c)` and plain gfortran procedures through `@fortran` |
| Keywords | §2.3 | §11 | `inout`, `parallel`, `extern`, `enum`, `exit`, `cycle`, `stop`; contextual `unit` |
| `^` and unary minus | — | §11 | `^` binds tighter than unary minus (`-x^2` is `-(x^2)`) and is right-associative |
| Loop control | — | §11.1 | `exit`, `cycle`, named loops, `stop n`, `by` in a `for` header |
| Program entry | — | §11.2 | `main()` or `main(args: [string])`, 1-based `args`; declarations only at the top level; `eprint` |
| Real division by zero | — | §2.5 | IEEE (`inf`, `nan`); traps only under `--fpe-trap` |
| Elemental functions | — | §7.3 | every prelude scalar math function is elemental; `@elemental` for user functions |
| Reductions | §10 | §7.4 | Fortran names: `minval`, `maxval`, `minloc`, `maxloc`, `any`, `all`, `count`, `norm2`; `dim =` in place of the reference's `sum_axis`; `dot` conjugates |
| Array elements | §3.3 | §3.1 | any element type but an array; structs and tuples of scalars stored inline |
| Tuple fields | — | §3.1 | 1-based: `t.1`, `t.2` |
| Units of measure | — | §13 | `unit` declarations (base, derived, scaled by an exact factor); `9.81<m/s^2>`, `real<m>`, `[real<Pa>; :, :]`; same-dimension scales convert to the left operand's unit, other dimensions are a compile error; `to<u>`, `strip`; erased before code generation |
| Unit generics | §6.10 | §2.6, §13.5 | `U: Unit` parameters (`real<U^2>`) |
| Prelude units | — | §13.9 | SI base, derived and scaled, imperial and US customary; `usgal` / `ukgal`, no `gal` |
| `unit` | §3.1 | §11, §13.1 | still the type; also a contextual word that declares a unit at the top level |

Unchanged, and restated only to fix their meaning beside the new rules: `i` and its shadowing
(§12), silent auto-clone insertion (ref §8.3), scalar-only broadcasting (ref §4.5).

---

## 15. Later

Decided directions that are not in the first language. Each is kept here so it is not lost, and
each has an item in PLAN.md's later list.

- **Structs by value across the FFI.** `@c` structs cross by reference today (§10.2); passing and
  returning them by value needs the per-target aggregate classification clang does (arm64 HFA and
  indirect rules, x86-64 SysV eightbyte classes), and is deferred until a library asks for it.
- **`real128`** (and `complex[real128]`), the `iso_fortran_env` quad kind.
- **`bfloat16`.** The name is reserved (§2.1).
- **Batched BLAS** behind an explicit batched routine, should the `parallel for` idiom of §7.2
  prove slower than a vendor's batched `gemm`.
- **More LAPACK** (§10.5): banded and tridiagonal solvers, generalized eigenproblems,
  `rcond` / `cond`.
- **Affine temperature units** `degC` and `degF` (§13). Until they arrive, temperatures are in `K`.
  They are not scaled units: 20 °C is 293.15 K, an offset and not a multiplication, so converting a
  temperature is `x + 273.15` where converting a length is `x * 0.001`. And a temperature
  **difference** converts without the offset — a rise of 20 °C is a rise of 20 K — so an affine unit
  needs two types, a point and a difference, with point − point giving a difference and point + point
  refused. That is a rule of its own, not a factor in the table of §13.9.
- **Unit-polymorphic externs**: an `extern` declaration whose parameters carry units (§13.7), so a C
  routine can be given its units once in its declaration instead of `strip` at every call.

Not in the language, and not planned: implicit parallelism (§9.3), static extents as generic
parameters (§3.4), batched `@` on rank ≥ 3 (§7.2), a call-site marker for `inout` (§8.1).
