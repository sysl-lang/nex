---
title: Array Expressions
summary: Element-wise operators, scalar broadcasting, promotion, fusion, the @ operator and BLAS, transpose and conjugate, whole-array and axis reductions, reproducible summation, minloc and maxloc.
weight: 50
---

nex computes with whole arrays the way Fortran 90 does: `c = a + 2*b` is one statement for every
element, and it compiles to one loop with no temporary arrays. This chapter covers the element-wise
operators, the matrix product `@`, and the reductions. The array types, indexing and slicing they
work on are in [Arrays](/spec/04-arrays/).

## 5.1 Element-wise operators

An arithmetic operator with an array operand applies to every element. `A op B` needs:

- **equal rank** — a compile error otherwise;
- **equal shape** — a compile error when both shapes are static, a trap `shape mismatch` otherwise.

The result has the operands' shape.

```nex
val a = [1.0, 2.0, 3.0]
val b = [4.0, 5.0, 6.0]
val c = a + b                       // [5.0, 7.0, 9.0]
val d = a * b                       // [4.0, 10.0, 18.0]: element by element, not a product of matrices
val e = 2a + b                      // [6.0, 9.0, 12.0]
val p = a ^ 2                       // [1.0, 4.0, 9.0]

val M = [[1.0, 2.0], [3.0, 4.0]]
val N = [[10.0, 20.0], [30.0, 40.0]]
val P = M + N                       // [[11.0, 22.0], [33.0, 44.0]]
val Q = 2M                          // [[2.0, 4.0], [6.0, 8.0]]
```

As in Fortran, `*` on two arrays is the element-wise product; the matrix product is `@` (§5.5).
`2a` is juxtaposition, `2 * a` ([Lexical structure](/spec/02-lexical/)).

The comparison operators are element-wise too and give a `bool` array of the same shape, and `and`,
`or` and `not` apply element by element to `bool` arrays:

```nex
val big = a > 1.5                   // [false, true, true]
val mid = (a > 1.5) and (a < 2.5)   // [false, true, false]
```

`and` and `or` short-circuit only on scalar `bool`s; on arrays both sides are computed.

The prelude's math functions are **elemental**: applied to an array they apply to every element, and
the call fuses into the expression's loop like any operator ([Prelude §12.2](/spec/12-prelude/)). A
user function marked `@elemental` behaves the same way ([Functions](/spec/06-functions/)); any other
function reaches every element through `map` ([Arrays §4.3.4](/spec/04-arrays/)):

```nex
val g = exp(-x * x)
val clipped = max(a, 0.0)                 // elemental over both arguments
val h = x.map(t -> if t < 0.0 then 0.0 else t)
```

## 5.2 Broadcasting is scalar-only

A scalar combines with an array of any rank: `A op s` and `s op A` apply the scalar to every element.

```nex
val shifted = a + 1.0               // [2.0, 3.0, 4.0]
val scaled = 0.5 * M                // every element of M halved
```

That is the only broadcasting. Two arrays of different rank never combine — there is no
NumPy-style stretching of a vector across a matrix. A row or a column is combined with a matrix by
slicing to the same shape, or by a loop over the other axis:

```nex
var A: [real; :, :] = zeros((n, n))
for j in 1..n do A[:, j] = A[:, j] + col     // add col to every column
```

This is Fortran's rule: an array expression combines conformable arrays and scalars, nothing else.

## 5.3 Element types

Operands of different element types combine element by element under the promotion rules of
[Types](/spec/03-types/): two reals give the wider, an integer with a real gives the real's type,
a real with a complex gives the complex type of the wider width.

```nex
val a32: [real32] = [1.0, 2.0]
val b64: [real64] = [0.5, 0.5]
a32 + b64                           // [real64; :]: one fused loop, no converted copy of a32
2.0 * a32                           // [real32; :]: a literal adapts to the array
```

- **A literal adapts** to the array's element type, so `2.0 * a32` stays single precision.
- **A typed scalar promotes the array**, as in Fortran: `x * a32` with `x: real64` is a `[real64]`.
- **An array never converts as a whole by itself.** A `[real32]` does not pass where a `[real64]` is
  expected; `real64(a32)` converts it, and that allocation is visible in the source.
- **Storing a widened result into a narrower array is a compile error**, not a silent rounding:
  `a32 = x * a32` is refused, and `a32 = real32(x) * a32` or `a32 = real32(x * a32)` says which
  rounding is meant.

## 5.4 Fusion

**A whole-array expression compiles to one loop nest, with no temporary arrays.** `y = alpha * x + y`
reads `x` and `y` once and writes `y` once, exactly the loop a Fortran programmer would write by hand,
at every rank:

```nex
def axpy(alpha: real, x: [real], y: inout [real]) =
  y = alpha * x + y

val r = 2u - v + 0.5 * w            // one loop over the elements, one result array
```

Slices take part on the same terms: `a[2..end] - a[1..end-1]` is one loop over views of `a`, with no
copy of either window ([Arrays §4.7](/spec/04-arrays/)). So write whole-array expressions freely;
splitting one into named steps for readability costs the intermediate arrays the split creates.

A whole-array expression runs on one thread. `parallel` before a `map` or a reduction —
`parallel sum(x * y)` — runs it on several ([Parallelism](/spec/10-parallelism/)); nex never threads
a computation you did not mark.

## 5.5 Matrix product: `@`

`@` is the matrix product. It is defined on ranks 1 and 2, as Fortran's `matmul` is:

| Operands | Shapes | Result |
|---|---|---|
| `[T; :, :] @ [T; :, :]` | `(m, k) @ (k, n)` | `(m, n)` |
| `[T; :, :] @ [T; :]` | `(m, k) @ k` | `m` |
| `[T; :] @ [T; :, :]` | `k @ (k, n)` | `n` |
| `[T; :] @ [T; :]` | `k @ k` | `T`, the dot product |

```nex
val A = [[1.0, 2.0], [3.0, 4.0]]
val v = [5.0, 6.0]
A @ v                               // [17.0, 39.0]
A @ A                               // [[7.0, 10.0], [15.0, 22.0]]
v @ v                               // 61.0
```

- The inner extents must agree: a compile error when both are static, a trap otherwise.
- **Static extents carry into the result**: `[real; 3, 4] @ [real; 4, :]` is a `[real; 3, :]`.
- Mixed element types promote as in §5.3.
- The rank-1 product does **not** conjugate, for complex operands as for real: `u @ v` is
  `Σ u[k] * v[k]`. The Hermitian inner product is `dot(u, v)`, which conjugates `u` as Fortran's
  `dot_product` does (§5.7), or `conj(u) @ v`.
- **Units multiply**: a `[real<N/m>; :, :]` times a `[real<m>]` is a `[real<N>]`. Element-wise
  `+` and `-` need operands of one dimension and convert the right operand's scale to the left's,
  exactly as for scalars ([Units of measure](/spec/13-units/)).

### 5.5.1 BLAS

For a large product of `real32`, `real64`, `complex[real32]` or `complex[real64]`, `@` calls the
linked BLAS — Accelerate on macOS, OpenBLAS elsewhere — choosing `gemm`, `gemv` or `dot` from the
shapes. A product of a transposed or conjugate-transposed operand (`transpose(A) @ B`,
`conj(transpose(A)) @ B`) passes BLAS's transpose flag instead of forming the transpose. Smaller
products, integer products and `real16` products are compiled inline. When the extents are known
only at run time, the compiler emits both paths and chooses when the product runs.

A BLAS result can differ from the inline one in its last bits, because it adds in a different order,
and a BLAS library may use threads of its own under its own settings (`OPENBLAS_NUM_THREADS`,
`VECLIB_MAXIMUM_THREADS`). Calling BLAS and LAPACK routines directly is covered in
[Interoperability](/spec/11-interop/).

{{< note >}}
The size thresholds at which `@` switches to BLAS, the option to turn the switch off when building,
and the folding of `C = alpha * (A @ B) + beta * C` into one `gemm` are proposed; OpenBLAS support
off macOS is not yet verified. The details may change.
{{< /note >}}

### 5.5.2 Batches of products

An operand of rank 3 or more is a **compile error**: `@` does not multiply stacks of matrices. A batch
is a loop over the trailing axis, and marking it `parallel` runs the products at once — the compiler
proves each iteration writes only its own plane:

```nex
var C: [real; :, :, :] = zeros((m, n, nb))
parallel for k in 1..nb do C[:, :, k] = A[:, :, k] @ B[:, :, k]
```

## 5.6 Transpose and conjugate

`transpose(m)` is the rank-2 transpose, `transpose(m)[i, j] == m[j, i]`. `conj(z)` is the complex
conjugate, element by element on a complex array; the conjugate transpose is `conj(transpose(m))`.

```nex
val H = conj(transpose(Z))          // Zᴴ
val gram = transpose(X) @ X         // XᵀX
```

When a transpose or conjugate transpose is an operand of a product that goes to BLAS, it is not
formed: it becomes BLAS's transpose flag (§5.5.1). `permute` reorders the axes of any rank
([Arrays §4.8](/spec/04-arrays/)).

## 5.7 Reductions

### 5.7.1 Whole-array reductions

| Function | Result |
|---|---|
| `sum(a)` | the sum of every element |
| `product(a)` | the product of every element |
| `minval(a)`, `maxval(a)` | the smallest and largest element |
| `minloc(a)`, `maxloc(a)` | the index of the smallest and largest element; a tuple of indices for rank ≥ 2 |
| `any(a)`, `all(a)`, `count(a)` | on a `bool` array: whether any, whether all, how many are `true` |
| `dot(x, y)` | `Σ conj(x[k]) * y[k]` (`x` conjugated when complex); the lengths must agree, or it traps |
| `norm2(a)` | the Euclidean (2-) norm; for a matrix, the Frobenius norm |
| `reduce(a, init, f)` | a left fold with your own function: `f(…f(f(init, a[1]), a[2])…, a[n])` |

The names and meanings are Fortran's. Each takes an array of any rank, or a view, and gives a scalar
(an index tuple for `minloc` and `maxloc` at rank ≥ 2):

```nex
val m = [[1.0, 2.0, 3.0],
         [4.0, 5.0, 6.0]]
sum(m)                              // 21.0
maxval(m)                           // 6.0
maxloc(m)                           // (2, 3)
sum(m[:, 2..])                      // 16.0: a window, no copy
count(m > 2.5)                      // 4
dot([1.0, 2.0], [3.0, 4.0])         // 11.0
[1, 2, 3, 4].reduce(0, (s, k) -> s + k * k)   // 30
```

`min` and `max` are not reductions. They are elemental functions of two or more arguments —
`max(a, 0.0)` clamps every element of `a` at zero — and `max(a)` of one array is a compile error
that suggests `maxval`.

### 5.7.2 Axis reductions: `dim =`

Every reduction takes a named `dim =` argument, and then reduces along that axis only and returns an
array of rank one less, as Fortran's `DIM=` does. Axes are numbered from 1:

```nex
sum(m, dim = 1)                     // [5.0, 7.0, 9.0]: down each column
sum(m, dim = 2)                     // [6.0, 15.0]: along each row
maxval(m, dim = 1)                  // [4.0, 5.0, 6.0]
maxloc(m, dim = 2)                  // [3, 3]: the column of each row's largest
```

### 5.7.3 Summation order

**A reduction's result does not depend on how many threads ran it, and is the same with or without
`parallel`.** `sum`, `product`, `dot`, `norm2` and their `dim =` forms all add in one fixed order: the
elements are cut into fixed-size blocks, each block is reduced in sequence, and the block results are
combined in a fixed pairwise tree. `parallel sum(x)` uses the same blocks and the same tree, so adding
or removing `parallel`, or changing `OMP_NUM_THREADS`, never changes a bit of the answer
([Parallelism](/spec/10-parallelism/)).

The order is not left to right. A floating-point `sum(x)` therefore differs in its last bits from a
Fortran `DO` loop that adds one element at a time — and is more accurate: pairwise summation's
rounding error grows as O(log n) rather than O(n). A loop you write element by element,
`for k in 1..n do s += x[k]`, adds in the order written. Integer reductions are exact, so their order
cannot be seen, except that an overflow traps.

{{< tip >}}
To compare a result with a Fortran program bit for bit, write the Fortran program's loop in nex. To
get the more accurate answer, call `sum`.
{{< /tip >}}

### 5.7.4 `minloc` and `maxloc` in a loop

`minloc(a)` and `maxloc(a)` find the index of the extreme element of an array. Inside a loop, their
three-argument forms find the value and the index of the smallest or largest **candidate**, as
OpenMP's `minloc` and `maxloc` reductions do. They reduce a (value, index) pair: the accumulator holds
both, and each step offers a candidate and its index.

```nex
val r = residual(x)
var worst = (0.0, 0)
parallel for k in 1..length(r) reduce worst: maxloc
  worst = maxloc(worst, abs(r[k]), k)
val (largest, where) = worst
```

**Ties go to the lowest index**, as in Fortran, whatever the thread count. The candidate need not be
an element: here it is the absolute value, and `where` equals `maxloc(abs(r))`. The loop and its
`reduce` clause are described in [Parallelism](/spec/10-parallelism/).
