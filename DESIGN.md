# nex: the language design

This is the language this implementation compiles. The reference specification
(`~/dev/nex/docs/content/spec/`, cited here as *ref §n*) still defines everything this document does
not touch: lexical structure, tuples, structs, sum types, `match`, closures, modules, interpolation,
the scalar prelude. Where a section here covers a subject, it replaces the reference's text on that
subject. The table in §13 lists every such place.

**Two markings run through it.** **PROPOSED** marks a rule this document had to invent to make a
decided feature complete; it stands until the user says otherwise. A claim about MLIR names the
experiment under `experiments/mlir/` that ran it through the toolchain (LLVM 23.1.4,
`/opt/homebrew/opt/llvm/bin`). A claim nothing ran is marked *(unverified)*.

---

## 1. Summary of the core

nex is an array-first numerical language: whole-array expressions that fuse, column-major storage,
value semantics enforced by `val`/`var` and a uniqueness rule, and a syntax in the Scala 3 / sysl
family. Scalars come in sized widths (§2). Arrays have any rank and an optional static shape (§3).
A slice is a read-only view (§6). A function mutates a caller's array through an `inout` exclusive
borrow (§8). Loops and reductions can be parallel, and the checker proves them race-free (§9). C,
BLAS and LAPACK are reachable through `extern` declarations, and `@` uses BLAS when that pays (§10).

---

## 2. Numeric types

### 2.1 The types

| Type | Meaning | MLIR |
|---|---|---|
| `integer8`, `integer16`, `integer32`, `integer64` | signed two's-complement integers | `i8` … `i64` |
| `real16`, `real32`, `real64` | IEEE 754 binary16, binary32, binary64 | `f16`, `f32`, `f64` |
| `complex16`, `complex32`, `complex64` | a pair of `real16` / `real32` / `real64` (re, im) | `complex<f16>` … `complex<f64>` |
| `integer` | alias of `integer64` | |
| `real` | alias of `real64` | |
| `complex` | alias of `complex64` | |

`bool`, `unit` and `string` are as in ref §3.1. The aliases are the same type, not a distinct one:
`[real]` and `[real64]` are one type, and a diagnostic names a type the way the source spelled it.

**Why this set.**

- **Integers 8, 16, 32, 64.** They are the widths C, BLAS/LAPACK (LP64 uses 32, ILP64 uses 64) and
  every file format exchange, so an `extern` declaration (§10) can spell any C integer parameter. A
  128-bit integer has no hardware arithmetic, no C ABI that BLAS uses and no numerical workload
  that needs it.
- **Signed only.** nex integer arithmetic traps on overflow (ref §4.4), and an unsigned type would
  bring wrap-or-trap questions at zero for no numerical gain; unsigned storage is what `[byte]`
  (ref §3.3.1) is for. Whether unsigned widths are wanted is an open question (§14).
- **Reals 16, 32, 64.** binary64 is the default and Fortran's `double precision`; binary32 is what
  single-precision BLAS, GPUs and memory-bound kernels use; binary16 is the storage width of
  half-precision data. `real16` is a storage-and-arithmetic type, and its transcendental functions
  compute in `real32` and round (**PROPOSED**); `sqrt` is native (`precision.mlir`).
- **Complex at each real width, named by the width of its parts.** `complex32` is two `real32`s, so
  promotion `real32 → complex32` keeps the number and `complex32` matches LAPACK's `c` routines. This
  is Fortran's `complex(kind=4)` convention and the opposite of NumPy's `complex64` (named by total
  size) (**PROPOSED** naming).

### 2.2 Promotion lattice

```
integer8 → integer16 → integer32 → integer64
   │            │           │           │        (any integerN → any realM or complexM)
   ▼            ▼           ▼           ▼
real16   →   real32   →   real64
   │            │           │
   ▼            ▼           ▼
complex16 →  complex32 →  complex64
```

An arrow is an **implicit widening**. A widening happens in exactly the places ref §3.2 promotes: an
operand of an arithmetic or comparison operator, an argument passed to a parameter, a value bound or
assigned to an annotated binding, field, element or return type. Every conversion that does not
follow arrows is **narrowing** and needs a conversion function (§2.4).

**The type of a binary operation** (`+ - * ^`, comparisons, element-wise array operations) on
operands of types `A` and `B`:

1. Same type: that type.
2. Both in the same family (integer, real or complex): the wider of the two.
3. An integer with a real or a complex: **the real or complex operand's type**. `n * x` with
   `n: integer64` and `x: real32` is `real32`, as in Fortran: a loop index never widens a
   single-precision kernel.
4. A real with a complex: the complex type of the wider width. `real64 + complex32` is `complex64`.

`/` follows ref §4.4: two integers give `real64`; an integer with a real `realN` gives `realN`.
`div` and `%` need two integers and give the wider. `^` with an integer exponent keeps the base's
type.

**Arrays never convert implicitly as a whole.** `[real32]` does not pass where `[real64]` is
expected; `real64(a)` converts it (§2.4) and the allocation is visible. Element-wise operations mix
widths per element under rules 1–4, so `a32 + b64` is a `[real64]` computed in one fused loop with
no converted copy of `a32`.

### 2.3 Literals and prelude constants

An unsuffixed literal takes its type from its context; nex has no literal suffixes, because a suffix
such as `1.0f32` would read as juxtaposition (`1.0 * f32`, ref §4.4).

- **With an expected type** (an annotated binding, a parameter, a typed element or field): the
  literal is that type. An integer literal outside the target's range is a compile error
  (`val b: integer8 = 300`). A real literal is rounded to the nearest value of the target width;
  one that rounds to infinity is a compile error (`val h: real16 = 70000.0`). An integer literal
  may initialize a real or complex (`val x: real32 = 1`), as ref §3.2 allows.
- **As an operand of a binary operator whose other operand has a type:** an integer literal adopts
  that type if it is an integer, real or complex type; a real literal adopts it if it is a real or
  complex type, and otherwise (`n + 0.5` with `n` an integer) is `real64`. So `x32 * 2.0` is
  `real32`, and `x8 + 1` is `integer8` (and traps when `x8` is 127).
- **With no context:** an integer literal is `integer64`, a real literal `real64` (ref §2.4).

**The prelude constants `pi`, `e`, `inf`, `nan` and `i` are typed like literals** (**PROPOSED**):
each adopts the width its context asks for (`pi` is `real32` beside a `real32`, `i` is `complex32`
beside a `real32`), and with no context `pi`, `e`, `inf`, `nan` are `real64` and `i` is
`complex64`. Without this, `2pi * x32` would silently widen a `real32` kernel to `real64`.

### 2.4 Conversions

Every numeric type name is also its conversion function, on a scalar and element-wise on an array:
`real32(x)`, `integer16(n)`, `complex32(z)`, `complex32(re, im)`, `real64(a)`.

| From → to | Behaviour |
|---|---|
| integer → narrower integer | exact, or **traps** when the value is out of range |
| real → integer | truncates toward zero; **traps** on NaN, infinity or out of range |
| real → narrower real | rounds to nearest-even; overflow gives ±∞ (IEEE, no trap) |
| complex → narrower complex | each part as real → real |
| complex → real or integer | not a conversion: take `.re` (or `abs`, `arg`) first |
| any widening | the implicit widening of §2.2, also callable explicitly |

`to_real`, `to_integer` and `to_complex` (ref §10.7) remain and mean `real64`, `integer64` and
`complex64`.

### 2.5 Arithmetic, traps and printing

- Integer arithmetic traps on overflow **at every width** (ref §4.4). The emitted form is
  `llvm.intr.sadd.with.overflow` and its siblings, then a branch to the trap (`precision.mlir` runs
  `127 + 1` and `100 + 27` at `i8`).
- Real arithmetic is IEEE at its own width: `real32` operations are `f32` operations, never computed
  in `f64` and rounded (`precision.mlir`: `0.1 * 3` in `real32` prints `0.30000001192092896`).
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
| `Integral` (**PROPOSED** name) | `integer8` … `integer64` |
| `Real` | every integer and real type |
| `Float` | `real16`, `real32`, `real64` |
| `Complex` | `complex16`, `complex32`, `complex64` |
| `Ord` | every integer and real type |
| `Eq` | every numeric type, `bool`, `string` |
| `Rank` | not a type: a rank (§3.4) |

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
element is a scalar, so `[[real]]` is rejected with *"an array element is a scalar; a matrix is
`[real; :, :]`"*.

**Element types**: every numeric type of §2, and `bool`. `[byte]` stays the separate storage type of
ref §3.3.1, rank 1 only.

### 3.2 Storage

Storage is column-major for every rank: axis 0 varies fastest. A dense array of shape
`(d0, d1, …, dk)` stores element `[i0, i1, …, ik]` at `i0 + d0·(i1 + d1·(i2 + …))`.

**Lowering.** A nex array of shape `(d0, …, dk)` is an MLIR `tensor<dk × … × d0 × T>`: the axes are
reversed, so MLIR's identity (row-major) layout is nex's column-major one, and nex index `[i, j, k]`
is tensor index `[k, j, i]`. A dynamic axis is `?`, a static one its number. This keeps every
`linalg` op, fusion and bufferization on default layouts (`views.mlir`, rank 2 and rank 3).

### 3.3 Static shapes

- A static extent is checked at compile time wherever both sides are static: element-wise operands,
  `@`'s inner dimension, slice assignment, an argument against its parameter. A mismatch is a
  compile error, not a trap.
- A static shape converts implicitly to the dynamic shape of the same rank (`[real; 3, 3]` passes
  where `[real; :, :]` is wanted).
- A dynamic shape converts implicitly to a static one at a binding, argument or return, with a
  run-time check that **traps** `shape mismatch` (**PROPOSED**; the alternative, an explicit
  conversion, is an open question in §14).
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

Static extents as generic parameters (`def trace[N: Extent](m: [real; N, N])`) are not part of this
design; see §14.

---

## 4. Array construction and the shape functions

### 4.1 Literals

A rank-R literal is brackets nested R deep. The outermost list runs along axis 0, the next along
axis 1, and so on: the element at nesting path `i, j, k` is `a[i, j, k]`. Rank 2 is ref §4.13's
row-by-row form unchanged.

```nex
val m = [[1.0, 2.0, 3.0],
         [4.0, 5.0, 6.0]]                      // [real; :, :], shape (2, 3), m[1, 0] == 4.0

val t = [[[1, 2], [3, 4]],
         [[5, 6], [7, 8]]]                     // [integer; :, :, :], shape (2, 2, 2)
                                               // t[1, 0, 1] == 6
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
| `extent(a, k)` | the extent of axis `k` (traps if `k` is not an axis) |
| `extents(a)` | `[integer; R]`, every extent (**PROPOSED**; usable in rank-generic code) |
| `size(a)` | the number of elements, the product of the extents |
| `length(a)` | `extent(a, 0)`; for rank 2 the row count, as in the reference |
| `shape(a)` | for rank ≥ 2 the R-tuple of extents (ref §10.4's `(rows, cols)` at rank 2); for rank 1 the length |
| `rows(m)`, `cols(m)` | rank 2 only |
| `reshape(a, (d0, …, dk))` | rank k+1 from any array of the same size, column-major (ref's `reshape(a, m, n)` stays) |
| `flatten(a)` | rank 1, column-major order, from any rank |
| `transpose(m)` | rank 2 only |
| `permute(a, (p0, …, pk))` | axes reordered: result axis `n` is source axis `p_n` (**PROPOSED**) |
| `sum_axis(a, k)` | sum over axis `k`: rank R−1 (ref's rank-2 form is `k` = 0 or 1) |

`transpose`, `permute`, `reshape` of a dense array and `flatten` of a dense array return views (§6):
no data moves (**PROPOSED** as a performance guarantee; the result is a value either way, so which it
is cannot be observed; the lowering is *(unverified)*).

`for x in a` over an array of rank ≥ 2 visits every element in storage (column-major) order
(**PROPOSED**; the reference does not say).

---

## 5. Indexing and slicing

### 5.1 Index lists

`a[s0, s1, …]` takes one subscript per axis. Each subscript is one of:

| Subscript | Axis in the result |
|---|---|
| an integer expression | removed (the axis collapses) |
| `:` | kept, whole |
| `lo..hi`, `lo..=hi`, `lo..`, `..hi`, `..=hi`, `..` | kept, the window |
| any of the range forms followed by `by k` | kept, every k-th element of the window |

- Fewer subscripts than the rank leaves the trailing axes whole: on rank 3, `t[i]` is
  `t[i, :, :]` and `t[i, j]` is `t[i, j, :]` (ref §4.14's `m[i]` row form, generalized). More
  subscripts than the rank is a compile error.
- The result's rank is the number of kept axes. With every axis collapsed the result is the element
  itself, a scalar; otherwise it is a view (§6).
- **`by k` is legal on every axis** of every rank (`m[0..4 by 2, 1..]`, `t[:, :, 0..10 by 3]`), on
  read and as an assignment target. `k` may be **negative**, which walks the window downward (§5.4);
  a stride of `0` traps.
- Indexing is 0-based. **Every index and bound is checked**: an index `i` on an axis of extent `n`
  must satisfy `0 ≤ i < n`, a window `lo..hi` must satisfy `0 ≤ lo ≤ hi ≤ n`, and anything else
  **traps** `out of bounds`. **There is no negative-index wrap**: `a[-1]` traps like `a[n]`.

### 5.2 `end`: the last index of the axis

Inside a subscript, `end` is the last valid index of the axis that subscript indexes,
`extent(a, k) - 1`. It may appear anywhere in an index or a slice bound, in any expression:

```nex
a[end]               // the last element
a[end - 1]           // the one before it
a[end-2..]           // the last three
a[..end]             // all but the last
a[..=end]            // all of it
m[:, end]            // the last column
m[end, 0]            // the first element of the last row
t[:, :, end]         // the last plane of a rank-3 array
a[(end + 1) div 2]   // the middle-or-later element
```

- On an empty axis `end` is `-1`, so `a[end]` traps and `a[0..=end]` is empty: no special case.
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

A continuation line inside a subscript that starts with `end` (`a[0,` newline `end]`) is at depth > 0
and is therefore the index. No legal program changes reading under this rule, because no end marker
can sit inside brackets.

### 5.3 Element assignment and slice assignment

`a[i, j] = x` writes one element of a `var` array (or an `inout` parameter, §8). Any slice form is
also an assignment target (ref §4.15), for every rank, with `by` on any axis:

```nex
var m = zeros((4, 4)) * 1.0
m[:, 0] = [1.0, 2.0, 3.0, 4.0]          // a column
m[end, :] = fill(4, 9.0)                // the last row
m[0..4 by 2, 1..3] = [[1.0, 2.0],
                      [3.0, 4.0]]       // rows 0 and 2, columns 1 and 2
t[:, :, 1] = plane                      // a plane of a rank-3 array
m[1..3, 1..3] += 1.0                    // compound, element-wise, in place (PROPOSED: compound slice targets)
a[1..4][0] = 99                         // a slice of a place is a place: writes a[1] (PROPOSED)
```

The right-hand side must have the slice's shape (statically when both are static, else a trap), or
be a scalar, which fills the window (broadcast, as ref §4.5 broadcasts scalars). The write is in
place: no copy of the target is made, and the binding keeps its identity. The right-hand side is
evaluated as a value before the first element is written, so an overlapping self-assignment
(`a[1..] = a[..end]`) shifts correctly; the compiler copies the source when the windows can overlap
*(unverified: one-shot-bufferize is expected to insert that copy)*.

---

### 5.4 Negative strides

With a negative `by k`, a range's bounds are read **in the direction of travel**: the first bound is
where the walk starts, the second where it stops, and a range stays half-open (`..`) or closed
(`..=`) exactly as it is going forward.

```nex
val a = [0, 1, 2, 3, 4, 5, 6]
a[5..2 by -1]          // [5, 4, 3]       — half-open: stops before 2
a[5..=2 by -1]         // [5, 4, 3, 2]
a[.. by -1]            // [6, 5, 4, 3, 2, 1, 0] — open bounds fill from the stride's direction
a[end..=0 by -1]       // the same, spelled out
a[.. by -2]            // [6, 4, 2, 0]
m[:, end..=0 by -1]    // the columns of m in reverse order
```

- An open start is the last index of the axis (`end`); an open stop runs past index `0`. Since no
  index is negative (§5.1), a closed `..=0` is the only spelled way to name index `0` as the stop.
- Bounds are checked as going forward: the start must be a valid index of a non-empty window, the
  stop must lie in `0..=n`, and a window whose start is below its stop is empty.
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
   copies the window, and `w[0] = 1` then changes only `w`. The copy is made by the auto-clone pass
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

Arrays are 0-based, always; there are no declared lower bounds. Where a computation reads better
with other bounds — a symmetric domain (`-n..=n` for FFT frequencies, a convolution kernel), a grid
with ghost cells — `origin` takes an **offset view**:

```nex
val w = origin(kernel, -r)          // w[-r] .. w[r] are kernel[0] .. kernel[2r]
val g = origin(grid, -1, -1)        // one origin per axis: g[-1, -1] is grid[0, 0]
for k in -r..=r do
  acc += w[k] * x[i - k]
```

- `origin(a, o0, o1, …)` takes one first-index per axis (fewer leaves the rest at `0`). Indexing,
  slicing and `end` on the view are relative to it: on `w`, `end` is `r`, and an index outside
  `-r..=r` traps.
- It is a view (§6.2): read-only, no allocation, no copy — the offset is folded into the view's base
  address, so an access costs exactly what an access to `kernel` costs.
- **PROPOSED: the origin belongs to the binding, not to the array.** When an offset view is passed
  to a function, returned, or stored, it arrives **0-based**: a function parameter's first index is
  always `0`, so no function ever has to ask what its array's bounds are. (Fortran resets an
  assumed-shape dummy to `1` the same way; here the rule is stated rather than discovered.) A
  function that wants the offset takes it as an ordinary argument and calls `origin` itself.

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
| `[T; :] @ [T; :]` | `k @ k` | `T` (the dot product, no conjugation) |

An operand of rank 3 or more is a compile error (**PROPOSED**; batching over leading axes is an open
question, §14). The inner extent is checked at compile time when both are static and traps
otherwise. Static extents carry into the result's type: `[real; 3, 4] @ [real; 4, :]` is
`[real; 3, :]`. Mixed element types promote per §2.2.

**Lowering.** Below the BLAS threshold, or for an element type BLAS has no routine for, `A @ B` is a
`linalg.matmul` (`matvec`, `vecmat`, `dot`). With the axes reversed (§3.2), nex's `C = A @ B` is
storage's `Cᵀ = Bᵀ Aᵀ`, so the operands are emitted swapped (`blas.mlir` runs it). Above the
threshold it is a BLAS call (§10.4).

---

## 8. `inout` parameters

### 8.1 The mode

A parameter is **read mode** (the default, ref §6.4: the callee reads it and may not mutate it) or
**`inout`**:

```nex
def scale(v: inout [real], s: real) =
  v = v * s                        // or element by element: for k in 0..length(v) do v[k] *= s

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

The call site writes no marker (**PROPOSED**; Swift writes `&x`, see §14).

### 8.2 What may be passed

The argument to an `inout` parameter is a **place** rooted in something mutable: a `var` binding,
an `inout` parameter, a field of one (`p.pos`), an element (`a[i]`), or a slice (`m[:, j]`,
`a[0..n by 2]`), which borrows exactly that window and writes it in place. Passing a `val`, a
literal, a function result or any other temporary is a compile error: *"an inout argument must be a
`var`"*. (No auto-clone fires here: a clone's writes could not reach anything.)

### 8.3 Exclusivity

For the duration of the call, the callee has the only access to the borrowed place. At every call
the checker rejects:

1. **The same root in two `inout` arguments**: `swap(a, a)`, `swap(a[0], a[1])`,
   `f(m[:, 0], m[:, 1])`. The exception is two **different fields** of a local struct `var`
   (`swap(p.x, p.y)`), which never overlap. Whether provably disjoint windows of one array may be
   borrowed together is an open question (§14); this design rejects them.
2. **An `inout` argument plus any other argument that reads the same root while the call runs**:
   `f(a, a)` with the first parameter `inout`, or `f(a, a[1..3])`, since a read-mode array argument
   is borrowed, not copied (ref §8.4). An argument that is fully evaluated to a scalar before the call
   starts does not conflict: `scale(a, a[0])` and `resize(a, length(a))` are legal. Arguments are
   evaluated left to right, and the exclusive access begins after the last one.
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
parallel for i in 0..n do y[i] = a * x[i] + y[i]

parallel for j in 0..cols(m)
  m[:, j] = m[:, j] / norm(m[:, j])        // each iteration owns column j

parallel for i in 0..rows(c), j in 0..cols(c)          // a 2-D iteration space (PROPOSED)
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
parallel for i in 0..n reduce total: +, peak: max
  total += x[i] * y[i]
  peak = max(peak, abs(x[i]))
print(total, peak)
```

The operators are `+`, `*`, `min`, `max`, `and`, `or`. The reduction variable is an outer `var` of
a type the operator applies to. Each iteration contributes through exactly one of `v op= e`,
`v = v op e`, `v = op(v, e)` (for `min`, `max`), `v = v and e`, `v = v or e`, where `e` does not
mention `v`; `v` is not read anywhere else in the body. The `var`'s value before the loop is the
starting value, and after the loop it holds the combination of the start and every contribution.
`reduce` is a contextual word here, not a keyword: the prelude function `reduce` keeps its name.

**A parallel floating-point reduction does not promise the sequential order.** `+` over reals is
combined in an order that depends on the thread count, so the last bits may differ between runs
with different thread counts (but not between runs with the same count and schedule); see §14.

### 9.3 Parallel map and reduction expressions

`parallel` also prefixes an expression whose value is computed element by element:

```nex
val y = parallel map(x, t -> exp(-t * t))       // or parallel x.map(t -> exp(-t * t))
val d = parallel sum(x * y)
val r = parallel 2a + b                          // a whole-array expression (PROPOSED)
```

The forms are `map`, the reductions `sum`, `product`, `min`, `max`, `dot`, and any whole-array
element-wise expression. The general `reduce(a, init, f)` has no parallel form, because `f`'s
associativity cannot be checked; a custom combination is a `parallel for … reduce` over one of the
six operators. A whole-array expression without `parallel` is sequential (**PROPOSED**: it is always
safe to run in parallel, so whether the compiler may do so unasked is an open question, §14).

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
   `var` (the transitive summary of §8.3). I/O (`print`, `write_bytes`, …) and `extern` functions not
   marked `@pure` (§10) are rejected in a parallel body (**PROPOSED**: stdout is shared state).
4. **The reductions are well formed** (§9.2).

A body the checker cannot prove is a compile error naming the offending write or read, never a
silent fallback to a sequential loop.

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
(complex `+`, `min`/`max` on integers, `and`/`or`) is *(unverified)*; only real `+` was run. Which
pipeline a program gets, and how the thread count is chosen, is §14. The runtime honours
`OMP_NUM_THREADS` (**PROPOSED**).

---

## 10. C FFI, BLAS and LAPACK

### 10.1 `extern` declarations

```nex
@link("m")
extern def cbrt(x: real): real

@link(framework = "Accelerate")                    // macOS; @link("openblas") elsewhere
extern def cblas_ddot(n: integer32, x: [real], incx: integer32,
                      y: [real], incy: integer32): real

@symbol("dgesv_")
extern def lapack_dgesv(n: integer32, nrhs: integer32, a: inout [real; :, :], lda: integer32,
                        ipiv: inout [integer32], b: inout [real; :, :], ldb: integer32,
                        info: inout integer32)
```

`extern def` is a bodyless declaration of a C function, the second sanctioned bodyless form beside
`@intrinsic` (ref §6.11). `@symbol("…")` names the C symbol when it differs from the nex name;
`@link("lib")` and `@link(framework = "…")` add a link input (**PROPOSED** spellings). An `extern`
function is assumed to have effects (I/O, global state) unless declared `@pure`, which the checker
believes without proof.

### 10.2 What crosses

| nex parameter | C sees |
|---|---|
| `integer8` … `integer64` | `int8_t` … `int64_t` |
| `real32`, `real64`, `real16` | `float`, `double`, `_Float16` |
| `bool` | `bool` (`_Bool`) |
| `inout` scalar | a pointer to it (`int32_t *info`) |
| `string` | `const char *`, a NUL-terminated copy valid for the call |
| `[T; …]` read mode | `const T *` to the first element of the window |
| `[T; …]` `inout` | `T *` to the first element; C's writes land in the caller's array |
| return: a scalar or `unit` | the value, or `void` |

A complex scalar does not cross by value (the C ABI for `double _Complex` differs by target)
(**PROPOSED**); complex **arrays** cross as pointers, whose interleaved (re, im) layout is C99's and
BLAS's *(unverified for complex)*. No array is returned from C, and structs and callbacks do not
cross (§14). A read-mode array argument is a promise that C does not write it; the compiler cannot
check that, and a C function that breaks it breaks value semantics.

### 10.3 Strides and the leading dimension

C receives a pointer and nothing else, so what the pointer means must be agreed:

- **Rank 1.** By default the parameter needs unit stride: a strided view (`x[0..n by 2]`) is copied
  to a dense array before the call (and, for `inout`, copied back after). A parameter marked
  `@strided` passes any view as is, and the program passes the stride itself, as BLAS's `incx`.
- **Rank 2.** By default the parameter needs unit stride along axis 0 (each column contiguous) and
  any stride between columns: that column stride is the **leading dimension**. A view such as
  `m[1..3, :]` or `m[2..6, 1..4]` crosses with no copy, its pointer offset to its first element and
  its leading dimension the source's. A view strided along axis 0 (`m[0..8 by 2, :]`) is copied
  first.
- **Rank ≥ 3.** The parameter needs a dense column-major array; anything else is copied first.

The prelude gives the numbers C needs: `stride(a, k)`, the element stride of axis `k`, and
`ld(m) = stride(m, 1)` for rank 2 (**PROPOSED** names). Every copy here is silent, like an
auto-clone.

**Lowering.** The pointer is `memref.extract_aligned_pointer_as_index` plus the offset from
`memref.extract_strided_metadata`; the leading dimension is the stride of the memref's axis 0, which
is nex's axis 1 (§3.2). `blas.mlir` calls `cblas_dgemm` from Accelerate on a whole matrix and on the
view `Big[1..3, :]` (offset 1, leading dimension 4) and gets the same product both times, no copy.

### 10.4 `@` dispatches to BLAS

`A @ B` is a BLAS call instead of a `linalg` op when all of these hold:

1. The element type is `real32`, `real64`, `complex32` or `complex64` (`s`, `d`, `c`, `z`). Integer,
   `bool` and `real16` products never dispatch.
2. **Either** the product is large: `m·k·n ≥ 64³` for matrix-matrix, `m·k ≥ 128²` for
   matrix-vector and vector-matrix, `k ≥ 4096` for a dot (**PROPOSED** thresholds, to be set by the
   perf oracle); **or** the shape is one the fused path cannot do without materializing an operand:
   an operand that is `transpose(X)`, `conj(transpose(X))` (BLAS's `T` and `C` flags), or a rank-2
   view whose unit stride is along axis 1 rather than axis 0 (a transposed layout).
3. A BLAS library is linked: Accelerate on macOS (the run in `blas.mlir`), OpenBLAS elsewhere
   *(unverified)*, through the LP64 (`integer32`) interface.

The routine follows the shape: `gemm`, `gemv` (`T` flag for vector-matrix), `dot` (`dotu` for
complex: nex's `@` does not conjugate). With static extents the decision is made at compile time;
with dynamic ones the compiler emits both paths and a run-time test. Operands that fail §10.3's
stride rules are copied first. `C = alpha * (A @ B) + beta * C` assigned to the same `C` is one
`gemm` with `beta` (**PROPOSED**).

**A BLAS result may differ in the last bits from the `linalg` path**, since it sums in a different
order. Every corpus matrix is far below the threshold. A build flag disables dispatch
(**PROPOSED**: `nex build --no-blas`).

### 10.5 LAPACK

The prelude reaches LAPACK for the dense linear-algebra kernels, each taking and returning values,
copying its inputs because LAPACK overwrites them (**PROPOSED** set and names): `solve(A, b)`,
`lstsq(A, b)`, `inv(A)`, `det(A)`, `chol(A)`, `qr(A)`, `eig(A)`, `eigh(A)`, `svd(A)`. Each has an
`inout` form that factors in place without the copy (`lu_inplace(A, ipiv)`). A LAPACK `info` that
reports failure (a singular matrix, no convergence) traps. Column-major storage means no transposes,
and the leading-dimension rules are §10.3's.

---

## 11. Lexical changes

**Keywords** (ref §2.3) gain `inout`, `parallel` and `extern`. `mut` stays reserved and means
nothing. `by` (slices) and `reduce` (the `parallel for` clause) are contextual, so `reduce` remains a
prelude name. The type names of §2.1 are prelude type names, not keywords.

**`end`** is both the block terminator of ref §2.7 and the index expression of §5.2, told apart by
bracket depth and line position as §5.2 specifies.

---

## 12. The imaginary unit `i`

`i` is a prelude constant, the imaginary unit (0, 1), and any binding named `i` shadows it within
that binding's scope, exactly as ref §2.4 and §10.1 say. Juxtaposition (ref §4.4) multiplies a
numeric literal by whatever `i` names at that point. So a loop index named `i` turns `2i` into
"2 times the index". This is intended: `i` is an ordinary name, and the most common loop index in
numerical code is not worth a reserved word.

```nex
val z = 3 + 2i            // 3.0+2.0i: i is the imaginary unit
for i in 0..3
  print(2i)               // 0, 2, 4: i is the loop index, so 2i is 2 * i, an integer
print(2i)                 // 0.0+2.0i: the loop's i is out of scope again
```

Inside a scope that binds `i`, write the unit some other way (`complex(0.0, 1.0)`, or a binding
`val im = i` taken outside), or name the index `j`, `k`, `m` or `n`.

---

## 13. Where this differs from the reference specification

| Subject | Reference | Here | Change |
|---|---|---|---|
| Sized numeric types and their aliases | §3.1, §11.2 | §2.1 | `integer8…64`, `real16…64`, `complex16…64`; `integer`, `real`, `complex` become aliases |
| Promotion | §3.2, §4.4 | §2.2 | a lattice across widths; integer meets real gives the real's width |
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
| Offset views | — | §6.4 | `origin(a, o0, …)`: a view with other first indices; arrays stay 0-based |
| Slices | §4.14 ("freshly owned") | §6 | a slice is a read-only view |
| `a.view(…)` | §10.5 (view-style slicing) | §6 | gone; a slice is the view, and writing goes through slice assignment or `inout` |
| Writes to a source visible through an earlier view | §10.5 | §6.2 rule 4 | a view keeps the value it was taken with |
| `@` | §4.5 | §7.2 | ranks 1 and 2, static extents, BLAS dispatch |
| Parameter modes | §6.4, §3.9, §8.1–§8.4 | §8 | `inout` exclusive borrow replaces move-in `mut` |
| Parallel loops and reductions | §11.2 | §9 | `parallel for … reduce`, `parallel map`/reductions |
| FFI, BLAS, LAPACK | §6.11, §11.2 | §10 | `extern def`, `@link`, `@symbol`, `@strided`, `@pure` |
| Keywords | §2.3 | §11 | `inout`, `parallel`, `extern` |

Unchanged, and restated only to fix their meaning beside the new rules: `i` and its shadowing
(§12), silent auto-clone insertion (ref §8.3), scalar-only broadcasting (ref §4.5).

---

## 14. Open questions

These are the user's to answer. The document above takes the stated default until then.

1. **Unsigned integers.** Should `uinteger8…64` exist (for bit manipulation, image data, FFI to
   unsigned C parameters), and should `[byte]` then become `[uinteger8]`? Default: no unsigned
   types; `[byte]` stays.
2. **`bfloat16`.** Wanted beside `real16` (ML data)? Default: no.
3. **A real64 scalar meeting a real32 array.** §2.2 promotes `a32 * x64` to a `[real64]` (NumPy's
   current rule). Should an array's width win over a non-literal scalar's instead? Default: promote.
4. **Dynamic to static shape.** Implicit with a run-time check (default), or only through an
   explicit conversion?
5. **Static extents as generic parameters** (`def trace[N: Extent](m: [real; N, N])`). Wanted?
   Default: not in the language.
6. **Batched `@`** over leading axes for rank ≥ 3 (NumPy's `matmul`). Default: a compile error.
7. **A call-site marker for `inout`** (`scale(&x, 2.0)` or `scale(inout x, 2.0)`), as Swift
   requires. Default: no marker.
8. **Disjoint borrows of one array.** Should `f(a[0..k], a[k..])` with both parameters `inout` be
   allowed when the checker can prove the windows disjoint (divide and conquer)? Default: rejected.
9. **Reproducible parallel reductions.** Should a floating-point reduction give the same bits for
   every thread count (a fixed reduction tree, at some cost)? Default: same bits only for the same
   thread count.
10. **Implicit parallelism.** May the compiler run whole-array expressions in parallel without a
    `parallel` prefix, above a size threshold? Default: only when asked.
11. **Which pipeline by default, and the thread count.** Is OpenMP lowering on for every build, or
    behind a flag (`nex build --parallel`), and is `NEX_THREADS` wanted beside `OMP_NUM_THREADS`?
    Default: on whenever a program has a `parallel` construct.
12. **I/O in a parallel body.** Rejected (default), or allowed with unspecified interleaving?
13. **User-defined reduction operators** for `parallel for … reduce`. Default: the six built-in ones.
14. **FFI breadth.** Complex scalars by value, structs, and C callbacks (for an ODE solver or a
    quadrature routine taking an integrand). Default: none of the three.
15. **The first LAPACK set** (§10.5), and whether failure traps or returns a result value.
