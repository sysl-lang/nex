---
title: Arrays
summary: Array types of any rank, column-major storage, construction, 1-based indexing, end, slicing with strides, slice assignment, views and offset views, shape queries.
weight: 40
---

Arrays are the centre of nex. An array has any rank, its storage is column-major, its indices start at
1, and a range `2..5` in a subscript selects four elements, as `a(2:5)` does in Fortran. This chapter
covers the array types, how arrays are built, how they are indexed and sliced, what a slice is, and
the functions that report an array's shape. The operators that compute with whole arrays are in
[Array expressions](/spec/05-array-expressions/).

## 4.1 Array types

An array type names its element type and, after a `;`, one entry per axis. An axis is `:` when its
extent is known only at run time, or an integer literal or `const` name when it is known at compile
time.

```nex
[real; :]            // rank 1
[real; :, :]         // rank 2
[real; :, :, :]      // rank 3
[real; 3, 3]         // rank 2, static shape 3 × 3
[complex; N]         // rank 1, extent the const N
[real32; 3, :]       // rank 2: 3 rows known statically, columns at run time
```

The rank is the number of axes, and it is always known at compile time. `[T]` is shorthand for
`[T; :]`, the rank-1 array, which is the most common array in numerical code:

```nex
def norm2(x: [real]): real = sqrt(sum(x * x))
```

An array's element is a scalar: any numeric type of [Types](/spec/03-types/), or `bool`. There are no
arrays of arrays — `[[real]]` is rejected with *"an array element is a scalar; a matrix is
`[real; :, :]`"*. Raw bytes are `[uint8]`, an ordinary array.

{{< note >}}
Mixing static and run-time axes in one type (`[real32; 3, :]`), and the absence of any upper limit on
rank, are proposed rules; the details may change.
{{< /note >}}

### 4.1.1 Static shapes

A static extent is checked wherever it can be:

- Where both sides are static — the operands of an element-wise operation, the inner dimension of
  `@`, a slice assignment, an argument against its parameter — a mismatch is a **compile error**.
- A static shape converts implicitly to the run-time shape of the same rank: a `[real; 3, 3]` passes
  where `[real; :, :]` is wanted.
- A run-time shape converts implicitly to a static one at a binding, an argument or a return, with a
  check that **traps** `shape mismatch` if the extents differ.
- Two arrays of different rank never meet in an element-wise operation: that is a compile error.

```nex
def trace3(m: [real; 3, 3]): real = m[1, 1] + m[2, 2] + m[3, 3]

def report(a: [real; :, :]) =
  print(trace3(a))                // checked at the call: traps unless a is 3 × 3

trace3(fill((3, 3), 1.0))         // 3.0
trace3([[1.0, 2.0], [3.0, 4.0]])  // traps: shape mismatch
```

An array literal has run-time extents unless its binding is annotated: `val a = [1.0, 2.0]` is a
`[real; :]`, so a `var` bound to a literal may later hold a longer array.

{{< note >}}
That a literal has run-time extents unless annotated is a proposed rule; the detail may change.
{{< /note >}}

### 4.1.2 Rank-generic code

A generic parameter bounded by `Rank` stands for a rank, so one function serves every rank:

```nex
def total[T: Numeric, R: Rank](a: [T; R]): T = sum(a)

def axpy[T: Float, R: Rank](alpha: T, x: [T; R], y: inout [T; R]) =
  y = alpha * x + y
```

The rank is inferred from the arguments, and the compiler specializes the function once per element
type and rank. Inside the body, `rank(a)` is the constant `R`. Rank-generic code works through
whole-array operations, `map`, the reductions and the shape functions; it cannot write an index list
`a[i, j, …]`, whose length would be `R`. Static extents are not generic parameters: a generic
function takes run-time axes, and a caller's static shape converts to them. Generics in general are
in [Functions](/spec/06-functions/).

## 4.2 Storage

**Storage is column-major for every rank**: the first index varies fastest, as in Fortran. A dense
array of shape `(d1, d2, …, dk)` stores element `[i1, i2, …, ik]` at the zero-based offset

```
(i1 − 1) + d1·((i2 − 1) + d2·((i3 − 1) + …))
```

So a column of a matrix, `m[:, j]`, is contiguous, and a loop nest over a matrix runs fastest with the
row index innermost. An array's storage can be handed to a Fortran or C routine that expects this
layout with no copy ([Interoperability](/spec/11-interop/)).

## 4.3 Construction

### 4.3.1 Literals

A rank-1 literal is a bracketed list. A literal of rank R nests brackets R deep: the outermost list
runs along axis 1, the next along axis 2, and so on, so the element at nesting position `i, j, k` is
`a[i, j, k]`. A rank-2 literal therefore reads row by row, the way a matrix is written on paper.

```nex
val v = [1.0, 2.0, 3.0]                       // [real; :], length 3
val n = [1, 2, 3]                             // [integer; :]
val z = [1.0 + 2.0i, 3.0 - 1.0i]              // [complex; :]

val m = [[1.0, 2.0, 3.0],
         [4.0, 5.0, 6.0]]                     // [real; :, :], shape (2, 3), m[2, 1] == 4.0

val t = [[[1, 2], [3, 4]],
         [[5, 6], [7, 8]]]                    // [integer; :, :, :], shape (2, 2, 2), t[2, 1, 2] == 6

val e: [real] = []                            // an empty literal needs its type
```

The source order is the order you read; storage is column-major regardless. A Fortran programmer who
writes `reshape([1, 4, 2, 5, 3, 6], [2, 3])` writes the same matrix here as `[[1, 2, 3], [4, 5, 6]]`.

Every list at one depth must have the same length. A literal whose nesting is visibly jagged is a
compile error; an inner element that is an array expression rather than a bracket list has a run-time
length, and a mismatch there traps.

{{< note >}}
Rejecting a visibly jagged literal at compile time is a proposed rule; the detail may change.
{{< /note >}}

### 4.3.2 Constructors

`zeros`, `ones` and `fill` take an `integer` for a rank-1 array or a tuple of R integers for rank R;
`identity(n)` is the `n × n` identity matrix; `linspace(lo, hi, n)` is `n` evenly spaced reals from
`lo` to `hi` inclusive.

```nex
zeros(5)                            // [0, 0, 0, 0, 0]
zeros((2, 3, 4))                    // rank 3, shape (2, 3, 4)
fill((3, 3), 0.5)                   // [real; :, :], every element 0.5
fill(4, 7.0)                        // [7.0, 7.0, 7.0, 7.0]
identity(3)                         // 3 × 3
linspace(0.0, 1.0, 5)               // [0.0, 0.25, 0.5, 0.75, 1.0]

val z: [real32; :, :] = zeros((4, 4))   // element type from the binding
```

`zeros`, `ones` and `identity` take their element type from the type expected where they appear, and
are `integer` when nothing expects one. `fill` takes its element type from its value.

{{< note >}}
Taking the element type of `zeros`, `ones` and `identity` from the expected type is a proposed rule;
the detail may change.
{{< /note >}}

### 4.3.3 Ranges

`lo..hi` is the integers from `lo` to `hi` **inclusive**, as Fortran's `lo:hi`; `lo..<hi` stops
before `hi`. A range is a value: it can be bound, passed and iterated, and iterating it allocates
nothing.

```nex
val r = 1..n                        // 1, 2, …, n
val inner = 2..<n                   // 2, 3, …, n − 1
for k in r do total += f(k)
for k in 1..0 do never()            // empty: hi < lo
```

The same two forms select windows of an array (§4.5). There is no `range` function: a range is
written as `lo..hi` or `lo..<hi` everywhere.

### 4.3.4 Building from functions

`map(a, f)` applies `f` to every element and keeps the shape; `filter(a, p)` keeps the elements of a
rank-1 array for which `p` holds, in order; `zip`, `enumerate` and `reduce` complete the set. Each is
also written in method form, `a.map(f)`.

```nex
val x = linspace(0.0, 1.0, 101)
val y = x.map(t -> exp(-t * t))                 // [real; :], same shape as x
val evens = [3, 8, 1, 6, 4].filter(k -> k % 2 == 0)   // [8, 6, 4]
val m2 = m.map(v -> v * v)                      // rank 2 in, rank 2 out
```

{{< note >}}
How a range becomes an array when one is needed — passing a range to `map`, or binding it where an
`[integer]` is expected — is not yet settled; the detail may change.
{{< /note >}}

## 4.4 Indexing

`a[s1, s2, …]` takes one subscript per axis. **Indices start at 1**: the first element of every axis
is index 1 and the last is its extent, as in Fortran. With an integer on every axis the result is the
element.

```nex
val a = [10.0, 20.0, 30.0]
a[1]                 // 10.0
a[3]                 // 30.0

val m = [[1.0, 2.0, 3.0],
         [4.0, 5.0, 6.0]]
m[2, 3]              // 6.0: row 2, column 3
```

**Every index is checked.** An index `i` on an axis of extent `n` must satisfy `1 ≤ i ≤ n`; anything
else **traps** `out of bounds`. There is no negative-index wrap: `a[0]` and `a[-1]` trap exactly as
`a[4]` does. Fortran checks bounds only under a compiler flag such as `-fcheck=bounds`; nex always
checks.

**Axes are numbered from 1 too.** `extent(a, 1)` is the first axis, Fortran's `size(a, dim=1)`, and
every function that takes an axis number counts the same way.

### 4.4.1 `end`

Inside a subscript, `end` is the last index of the axis that subscript indexes — `extent(a, k)` in
position `k`. It may appear in any expression in an index or a slice bound:

```nex
a[end]               // the last element
a[end - 1]           // the one before it
a[end-2..]           // the last three
a[..end-1]           // all but the last (also a[..<end])
m[:, end]            // the last column
m[end, 1]            // the first element of the last row
t[:, :, end]         // the last plane of a rank-3 array
a[(end + 1) div 2]   // the middle element (the earlier of two when the length is even)
```

- On an empty axis `end` is `0`, so `a[end]` traps and `a[1..end]` is empty.
- With fewer subscripts than the rank (§4.5), `end` in position `k` is still axis `k`'s.
- `end` binds to the innermost subscript list around it: in `a[b[end]]` it is `b`'s last index, and
  in `a[f(end)]` it is `a`'s.
- Outside a subscript — `val n = end`, an array literal `[end]`, a `for` header — `end` is a parse
  error: *"`end` is only an index here inside `a[...]`"*. Use `length(a)` or `extent(a, k)` there.

`end` is also the word that closes a block ([Lexical structure](/spec/02-lexical/)). The two never
collide: a block's `end` begins a line outside any bracket, and an index `end` is always inside one.

{{< note >}}
Which subscript list `end` refers to when lists nest (`a[b[end]]`, `a[f(end)]`) is a proposed rule;
the detail may change.
{{< /note >}}

## 4.5 Slicing

A subscript may select a window of its axis instead of one index. Each subscript is one of:

| Subscript | Axis in the result |
|---|---|
| an integer expression | removed: the axis collapses |
| `:` | kept, whole |
| `lo..hi`, `lo..`, `..hi`, `..` | kept: `lo` to `hi` **inclusive** (Fortran's `lo:hi`) |
| `lo..<hi`, `..<hi` | kept: `lo` to `hi − 1` |
| any range form followed by `by k` | kept: every `k`-th element of the window |

An omitted `lo` is 1 and an omitted `hi` is the axis's extent. The half-open form is for splitting at a
point: `a[..<k]` and `a[k..]` are the two halves, with no element in both.

```nex
val a = [10, 20, 30, 40, 50, 60, 70]
a[2..5]              // [20, 30, 40, 50]
a[2..<5]             // [20, 30, 40]
a[..3]               // [10, 20, 30]
a[5..]               // [50, 60, 70]
a[1..7 by 2]         // [10, 30, 50, 70]
a[.. by 3]           // [10, 40, 70]

val g: [real; :, :] = zeros((6, 6))
g[2, :]              // row 2, a rank-1 array of length 6
g[:, 2..3]           // columns 2 and 3, shape (6, 2)
g[1..5 by 2, 2..]    // rows 1, 3, 5 and columns 2 to 6, shape (3, 5)

val t: [real; :, :, :] = zeros((4, 4, 10))
t[:, :, 1..end by 3] // planes 1, 4, 7, 10
```

- The result's rank is the number of kept axes.
- **Fewer subscripts than the rank** leave the trailing axes whole: on a rank-3 `t`, `t[i]` is
  `t[i, :, :]` and `t[i, j]` is `t[i, j, :]`. More subscripts than the rank is a compile error.
- **`by k` is legal on every axis**, on read and as an assignment target. A stride of `0` **traps**.
- **Every bound is checked.** A window `lo..hi` on an axis of extent `n` must satisfy `1 ≤ lo` and
  `hi ≤ n` unless it is empty. A window with `hi = lo − 1` is empty and legal (`a[1..0]`,
  `a[n+1..n]`), as in Fortran; any other out-of-range bound traps `out of bounds`.

### 4.5.1 Negative strides

With a negative `by`, the bounds are read **in the direction of travel**: the first is where the walk
starts, the second where it stops, and `..` stays inclusive and `..<` half-open. This is Fortran's
`a(hi:lo:-1)`.

```nex
val a = [10, 20, 30, 40, 50, 60, 70]
a[5..2 by -1]        // [50, 40, 30, 20]: a[5], a[4], a[3], a[2]
a[5..<2 by -1]       // [50, 40, 30]: stops before a[2]
a[.. by -1]          // [70, 60, 50, 40, 30, 20, 10]
a[end..1 by -1]      // the same, spelled out
a[.. by -2]          // [70, 50, 30, 10]
m[:, end..1 by -1]   // the columns of m in reverse order
```

- An open start is the axis's last index and an open stop is `1`, so `a[.. by -1]` is the whole axis
  reversed.
- A window whose start is below its stop is empty: `a[1..2 by -1]` is empty, as Fortran's
  `a(1:2:-1)` is.
- A reversed slice is a view like any other (§4.7): nothing is copied.

`reverse(a)` is `a[.. by -1]`, and `reverse(a, k)` reverses axis `k` only:

```nex
reverse([1, 2, 3])                   // [3, 2, 1]
reverse(m, 2)                        // m[:, end..1 by -1]
```

## 4.6 Element and slice assignment

`a[i, j] = x` writes one element of a `var` array, or of an `inout` parameter
([Functions](/spec/06-functions/)). **Every slice form is also an assignment target**, at every rank
and with `by` on any axis:

```nex
var m: [real; :, :] = zeros((4, 4))
m[:, 1] = [1.0, 2.0, 3.0, 4.0]          // the first column
m[end, :] = fill(4, 9.0)                // the last row
m[1..3 by 2, 2..3] = [[1.0, 2.0],
                      [3.0, 4.0]]       // rows 1 and 3, columns 2 and 3
m[2..3, 2..3] = 0.0                     // a scalar fills the window
m[2..3, 2..3] += 1.0                    // compound, element by element, in place

var a = [1, 2, 3, 4, 5]
a[.. by -1] = [10, 20, 30, 40, 50]      // a is [50, 40, 30, 20, 10]
a[2..4][1] = 99                         // a slice of a place is a place: writes a[2]
```

- The right-hand side has the window's shape — checked at compile time when both are static, a trap
  otherwise — or is a scalar, which fills the window.
- The write is **in place**: the target is not copied, and the binding keeps its storage.
- The right-hand side is a value, computed before the first element is written, so an overlapping
  shift such as `a[2..] = a[..end-1]` moves every element one place right, as Fortran's array
  assignment does.

{{< note >}}
Compound assignment to a slice (`m[2..3, 2..3] += 1.0`) and assignment through a slice of a slice
(`a[2..4][1] = 99`) are proposed rules, and how an overlapping self-assignment is copied is not yet
verified; the details may change.
{{< /note >}}

## 4.7 Slices are views

A slice that keeps at least one axis evaluates to a **view**: a window onto the source's storage with
its own offset, extents and strides. Taking a view allocates nothing and copies nothing — `m[:, j]`,
`m[2, :]`, `a[1..n by 2]` and `a[.. by -1]` all cost the same.

A view has an ordinary array type: `a[1..4]` is a `[real; :]`, and every function, operator and
prelude entry that takes an array takes a view. There is no separate view type, and whether a value
is a view or an array of its own is never observable — only its cost is. **A view is a value**, fixed
when it is taken. The rules that make this so:

1. **A view is read-only.** Nothing writes through a view. To change part of an array, assign to the
   slice of the array itself (§4.6), or pass the slice to an `inout` parameter, which writes the
   source's window in place.
2. **A view bound to a `var` is copied.** `var w = a[1..4]` makes `w` an array of its own, and
   `w[1] = 0` then changes only `w`.
3. **A view that escapes is copied.** A view returned from a function, stored in a struct, tuple or
   enum, captured by a closure that outlives the block, or bound at module level is copied to a dense
   array at that point. Passing a view as an argument, or binding it to a local `val`, is not an
   escape and copies nothing.
4. **A view keeps the value it was taken with.** If the source is a `var` and is written while a view
   of it is still in use, the view still holds the old values: the compiler copies the view before
   the write. A view that is no longer used when the write happens costs nothing.
5. **A view keeps its source's storage alive** for as long as the view lives.

```nex
var a = [1.0, 2.0, 3.0, 4.0]
val head = a[1..2]          // a view: no copy
a[1] = 100.0                // head is still [1.0, 2.0]
print(sum(head))            // 3.0
```

The copies of rules 2–4 are made silently by the compiler, like every other copy that keeps values
apart ([Values and memory](/spec/08-values-and-memory/)). The common uses — passing `m[:, j]` to a
function, reducing `sum(a[2..end-1])`, assigning to a window — copy nothing at all.

A Fortran programmer may read a view as an array section passed to a dummy argument, without the
aliasing questions: a view can never be written, so nothing can change under another name.

### 4.7.1 Offset views: `origin` and `rebase`

Arrays are 1-based, always; there are no declared lower bounds. Where a computation reads better with
other bounds — a symmetric kernel indexed `-r..r`, FFT frequencies, a grid with a ghost layer at
index 0 — `origin` takes an **offset view**:

```nex
def convolve_at(x: [real], kernel: [real], i: integer): real =
  val r = (length(kernel) - 1) div 2
  val w = origin(kernel, -r)        // w[-r] .. w[r] are kernel[1] .. kernel[2r + 1]
  var acc = 0.0
  for k in -r..r do acc += w[k] * x[i - k]
  acc
```

- `origin(a, o1, o2, …)` gives the first index of each axis; axes not given keep `1`.
  `origin(grid, 0, 0)` makes `g[0, 0]` the element `grid[1, 1]`.
- Indexing, slicing and `end` on the view are relative to its origin: on `w` above, `end` is `r`, and
  an index outside `-r..r` traps.
- It is a view (§4.7): read-only, no allocation, no copy, and an access costs exactly what an access
  to the source costs.
- **An offset view is local to the function that took it.** Passing it as an argument, returning it,
  storing it, binding it at module level or capturing it in an escaping closure is a compile error:
  *"an `origin` view cannot leave this function; `rebase(w)` makes an ordinary 1-based array"*. So
  every function's array parameters start at 1, and no function has to ask what its array's bounds
  are.
- `rebase(w)` copies an offset view's elements into an ordinary 1-based array (`rebase(w)[1]` is
  `w[-r]`); that is what crosses a function boundary. A function that wants other bounds takes the
  offset as an argument and calls `origin` itself.

This is the one place nex departs from Fortran's model on purpose: Fortran lets a dummy argument
declare its own lower bound, so one routine can see the same array as `a(0:n)` and another as
`a(1:n+1)`. In nex an array means the same index everywhere it is passed.

## 4.8 Shape queries

| Function | Result |
|---|---|
| `rank(a)` | the rank, a compile-time constant |
| `extent(a, k)` | the extent of axis `k`, `1 ≤ k ≤ rank(a)` (traps if `k` is not an axis); Fortran's `size(a, dim=k)` |
| `extents(a)` | every extent, an `[integer]` of length `rank(a)` |
| `size(a)` | the number of elements, the product of the extents |
| `length(a)` | `extent(a, 1)`: a vector's length, a matrix's row count |
| `shape(a)` | rank 1: the length; rank ≥ 2: the tuple of extents, `(rows, cols)` at rank 2 |
| `rows(m)`, `cols(m)` | rank 2 only |

```nex
val t = zeros((2, 3, 4))
rank(t)              // 3
extent(t, 2)         // 3
size(t)              // 24
shape(t)             // (2, 3, 4)
length(t)            // 2
val (r, c) = shape(m)
```

The functions that reorganize an array without changing its elements:

| Function | Result |
|---|---|
| `reshape(a, (d1, …, dk))` | rank `k`, from any array of the same size, in column-major order (Fortran's `reshape`) |
| `flatten(a)` | rank 1, in column-major order, from any rank |
| `transpose(m)` | rank 2 only: `transpose(m)[i, j] == m[j, i]` |
| `permute(a, (p1, …, pk))` | axes reordered: axis `n` of the result is axis `p_n` of `a` |
| `reverse(a)`, `reverse(a, k)` | §4.5.1 |

`for x in a` over an array of rank 2 or more visits every element in storage order, column by column.

{{< note >}}
`extents` and `permute` are proposed, as are the storage order of `for x in a` at rank ≥ 2 and the
guarantee that `transpose`, `permute`, `reshape` and `flatten` of a dense array move no data. The
result is the same value either way; the details may change.
{{< /note >}}
