---
title: The Prelude
summary: Every name available without an import — constants, elementary and complex math, array construction, shape queries, reductions, linear algebra, higher-order functions, views, conversions, I/O and testing — with its Fortran equivalent.
weight: 120
---

The prelude is imported implicitly into every module. Every name in this chapter is in scope
without an `import`, and any of them can be shadowed by a binding of the same name in the usual way
(see [Modules](/spec/09-modules/)).

The tables give a signature, what the function returns, and the nearest Fortran intrinsic or idiom.
In signatures, `T` is an element type, `R` is a rank (see [Types](/spec/03-types/)), `[T]` is a
rank-1 array, `[T; :, :]` a rank-2 array and `[T; R]` an array of any rank. Every index and every
axis number is **1-based**.

Any prelude function whose first argument is an array may also be called with method syntax:
`a.sum()` is `sum(a)`, and `xs.map(x -> x * x).sum()` is `sum(map(xs, x -> x * x))`. The two forms
compile to the same thing; the method form reads better in a chain.

There is no `range` function. A range is written `lo..hi` (inclusive, Fortran's `lo:hi`) or
`lo..<hi` (half-open), and a range is a value: it can be bound, passed and iterated (see
[Array expressions](/spec/05-array-expressions/)).

## 12.1 Constants

| Name | Value | Fortran |
|---|---|---|
| `pi` | π = 3.14159265358979… | `4 * atan(1.0_real64)` |
| `e` | Euler's number, 2.71828182845904… | `exp(1.0_real64)` |
| `inf` | positive infinity | `ieee_value(x, ieee_positive_inf)` |
| `nan` | a quiet NaN | `ieee_value(x, ieee_quiet_nan)` |
| `i` | the imaginary unit, 0 + 1i | `(0.0_real64, 1.0_real64)` |

Negative infinity is `-inf`. `true` and `false` are keywords, not prelude names.

The constants are typed like literals: each takes the width its context asks for. Beside a
`real32`, `pi` is a `real32` and `i` is a `complex[real32]`, so `2pi * x` keeps a single-precision
kernel single-precision. With no context, `pi`, `e`, `inf` and `nan` are `real64` and `i` is
`complex[real64]`.

{{< note >}}
Context typing of the prelude constants is a proposed rule and may change in detail.
{{< /note >}}

`i` is an ordinary name. A loop index called `i` shadows it, and inside that loop `2i` means
"2 times the index":

```nex
val z = 3 + 2i            // 3.0+2.0i
for i in 1..3
  print(2i)               // 2, 4, 6
print(2i)                 // 0.0+2.0i
```

Inside a scope that binds `i`, write the unit as `complex(0.0, 1.0)`, or name the index `j`, `k`,
`m` or `n`.

## 12.2 Elementary functions

Each function is defined for every integer and real type it makes sense for, and returns the type
of its argument (an integer argument to a transcendental function gives `real64`). `sqrt`, `exp`,
`log`, `log2`, `log10`, `sin`, `cos` and `tan` are also defined on complex values.

| Signature | Meaning | Fortran |
|---|---|---|
| `sqrt(x)` | square root | `SQRT` |
| `cbrt(x)` | cube root | `x ** (1.0/3)` (for `x ≥ 0`) |
| `abs(x)` | absolute value; for a complex, the modulus (a real) | `ABS` |
| `sign(x)` | signum: −1, 0 or +1 | — (`SIGN(A, B)` copies a sign; it is not signum) |
| `exp(x)`, `log(x)` | exponential, natural logarithm | `EXP`, `LOG` |
| `log2(x)`, `log10(x)` | base-2 and base-10 logarithms | `LOG(x)/LOG(2.0)`, `LOG10` |
| `sin`, `cos`, `tan` | trigonometric functions, radians | `SIN`, `COS`, `TAN` |
| `asin`, `acos`, `atan` | inverse trigonometric functions; the result is an angle, a `real<rad>` | `ASIN`, `ACOS`, `ATAN` |
| `atan2(y, x)` | angle of the point (x, y), in (−π, π], a `real<rad>` | `ATAN2(Y, X)` |
| `sinh`, `cosh`, `tanh` | hyperbolic functions | `SINH`, `COSH`, `TANH` |
| `asinh`, `acosh`, `atanh` | inverse hyperbolic functions | `ASINH`, `ACOSH`, `ATANH` |
| `hypot(x, y)` | √(x² + y²) without intermediate overflow | `HYPOT` |
| `fma(a, b, c)` | `a * b + c` rounded once, elemental over reals; `a * b` and `c` share a dimension, and the result has it; integers and complex numbers are refused | `IEEE_FMA` |
| `floor(x)`, `ceil(x)` | round down, round up | `FLOOR`, `CEILING` |
| `round(x)` | round to nearest, halves away from zero | `ANINT` |
| `trunc(x)` | round toward zero | `AINT` |
| `min(x, y, …)`, `max(x, y, …)` | the smallest, the largest of the arguments, element by element | `MIN`, `MAX` |

A `real32` argument is computed in `real32` arithmetic, never widened to `real64` and rounded back.
For a `real16` argument, `sqrt` is computed natively and the transcendental functions compute in
`real32` and round to `real16`.

{{< note >}}
The `real16` evaluation rule for transcendental functions is proposed and may change.
{{< /note >}}

**On arrays.** Every function in this section and in §12.3 is **elemental**, as Fortran's
intrinsics are: given an array of any rank it applies to every element and returns an array of the
same shape. Inside a whole-array expression the call fuses into the same loop as the surrounding
arithmetic, so no temporary is made for it:

```nex
val y = exp(-x * x)
val r = sqrt(x) + 1.0
val c = max(a, 0.0)          // clamps every element at zero
```

`min` and `max` are elemental over their arguments: a scalar argument is broadcast, and arrays must
agree in shape. They are not reductions — `max(a)` of one array is a compile error. The extremes of
an array are `minval` and `maxval` (§12.6).

A user function is elemental when it is marked `@elemental` (see
[Functions](/spec/06-functions/)). Applying an unmarked scalar function to an array is a compile
error that suggests `@elemental` or `map`.

## 12.3 Complex numbers

A complex value is written with `i` and arithmetic, or with a constructor:

```nex
val z = 3 + 4i                       // complex (complex[real64])
val w = complex[real32](1.5, -2.0)   // two real32 parts
exp(pi * i)                          // ≈ -1.0+0.0i
```

| Signature | Meaning | Fortran |
|---|---|---|
| `z.re` | real part | `REAL(z)` |
| `z.im` | imaginary part | `AIMAG(z)` |
| `complex(re, im)` | the complex `re + im·i` (`complex[real64]`) | `CMPLX(re, im, real64)` |
| `complex[realN](re, im)` | the same at width N | `CMPLX(re, im, realN)` |
| `conj(z)` | complex conjugate; on an array, of every element | `CONJG` |
| `abs(z)` | modulus \|z\|, a real of the part's width | `ABS` |
| `arg(z)` | argument (angle) in radians, in (−π, π] | `ATAN2(AIMAG(z), REAL(z))` |

The parts of a `complex[real32]` are `real32`; a complex type is named by the kind of its part, as
Fortran's `complex(real32)` is. A complex value does not convert to a real: take `.re`, `abs` or
`arg` explicitly.

## 12.4 Array construction

| Signature | Meaning | Fortran |
|---|---|---|
| `zeros(n)`, `zeros((d1, …, dR))` | an array of zeros, rank 1 or rank R | `allocate(a(n)); a = 0` |
| `ones(n)`, `ones((d1, …, dR))` | an array of ones | `allocate(a(n)); a = 1` |
| `fill(n, x)`, `fill((d1, …, dR), x)` | an array every element of which is `x`; element type is `x`'s | `allocate(a(n)); a = x` |
| `identity(n)` | the n × n identity matrix | — |
| `diag(d)` | the n × n matrix with the length-n vector `d` on its diagonal, zero elsewhere | — |
| `linspace(lo, hi, n)` | `n` reals evenly spaced from `lo` to `hi`, both ends included | — |

`zeros`, `ones` and `identity` take their element type from the expected type, and are `integer`
when there is none:

```nex
val z: [real32; :, :] = zeros((4, 4))   // real32 zeros
val k = zeros(5)                        // [integer], [0, 0, 0, 0, 0]
val h = fill((3, 3), 0.5)               // [real; :, :]
val buf: [uint8] = zeros(1024)          // a zeroed byte buffer
val x = linspace(0.0, 1.0, 5)           // [0.0, 0.25, 0.5, 0.75, 1.0]
```

{{< note >}}
Taking the element type of `zeros`, `ones` and `identity` from context is a proposed rule and may
change in detail.
{{< /note >}}

Array literals and the rules for nesting them are in [Arrays](/spec/04-arrays/).

## 12.5 Shape queries and reshaping

| Signature | Meaning | Fortran |
|---|---|---|
| `rank(a)` | the rank, a compile-time constant | `RANK(a)` |
| `extent(a, k)` | the extent of axis `k`, `1 ≤ k ≤ rank(a)`; traps if `k` is not an axis | `SIZE(a, DIM=k)` |
| `extents(a)` | every extent, as a rank-1 `[integer]` of length `rank(a)` | `SHAPE(a)` |
| `size(a)` | the number of elements, the product of the extents | `SIZE(a)` |
| `length(a)` | `extent(a, 1)`: the length of a vector, the row count of a matrix | `SIZE(a, 1)` |
| `shape(a)` | rank 1: the length; rank ≥ 2: the tuple of extents, `(rows, cols)` at rank 2 | `SHAPE(a)` |
| `rows(m)`, `cols(m)` | rank 2 only: `extent(m, 1)`, `extent(m, 2)` | `SIZE(m, 1)`, `SIZE(m, 2)` |
| `stride(a, k)` | the element stride of axis `k` in memory | — |
| `ld(m)` | rank 2: the leading dimension, `stride(m, 2)` | the `LDA` argument |
| `reshape(a, (d1, …, dk))` | the same elements as rank k, column-major order; sizes must match | `RESHAPE(a, [d1, …, dk])` |
| `reshape(a, m, n)` | rank 2, the same as `reshape(a, (m, n))` | `RESHAPE(a, [m, n])` |
| `flatten(a)` | rank 1, every element in column-major order | `RESHAPE(a, [SIZE(a)])` |

`stride` and `ld` exist for passing arrays and views to C and Fortran libraries; see
[Interop](/spec/11-interop/).

```nex
val m = [[1.0, 2.0, 3.0],
         [4.0, 5.0, 6.0]]
extent(m, 1)          // 2
extent(m, 2)          // 3
shape(m)              // (2, 3)
size(m)               // 6
flatten(m)            // [1.0, 4.0, 2.0, 5.0, 3.0, 6.0] — column-major
```

{{< note >}}
`extents` and the names `stride` and `ld` are proposed and may change.
{{< /note >}}

## 12.6 Reductions

| Signature | Meaning | Fortran |
|---|---|---|
| `sum(a: [T; R]): T` | the sum of every element | `SUM(a)` |
| `product(a: [T; R]): T` | the product of every element | `PRODUCT(a)` |
| `minval(a: [T; R]): T` | the smallest element (ordered types); a `nan` is passed over, and the result is `nan` only where every element is one | `MINVAL(a)` |
| `maxval(a: [T; R]): T` | the largest element (ordered types); a `nan` is passed over, and the result is `nan` only where every element is one | `MAXVAL(a)` |
| `minloc(a)`, `maxloc(a)` | the index of the smallest, the largest element; a tuple of indices for rank ≥ 2; ties go to the first in storage order; a `nan` is passed over, and where every element is one the location is the first | `MINLOC(a)`, `MAXLOC(a)` |
| `any(a: [bool; R])`, `all(a: [bool; R])` | whether any, every element is `true` | `ANY(a)`, `ALL(a)` |
| `count(a: [bool; R]): integer` | the number of `true` elements | `COUNT(a)` |
| `norm2(a)` | the Euclidean norm √(Σ \|aₖ\|²); the Frobenius norm of a matrix | `NORM2(a)` |
| `dot(x: [T], y: [T]): T` | Σ conj(xₖ) yₖ — `x` is conjugated when complex; lengths must match, else trap | `DOT_PRODUCT(x, y)` |
| `minloc(acc, x, k)`, `maxloc(acc, x, k)` | combine a running `(value, index)` pair with the candidate `x` at index `k`; ties go to the lower index | — |

**Every reduction takes a named `dim =` argument** and then reduces along that axis only, giving an
array of rank R − 1, as Fortran's `DIM=` does. For a matrix, `sum(m, dim = 1)` sums down each column
(a vector of length `cols(m)`) and `sum(m, dim = 2)` sums along each row (length `rows(m)`);
`maxloc(m, dim = 1)` is the row index of the largest element of each column.

```nex
val m = [[1, 2, 3],
         [4, 5, 6]]
sum(m)                 // 21
sum(m, dim = 1)        // [5, 7, 9]
sum(m, dim = 2)        // [6, 15]
maxval(m, dim = 2)     // [3, 6]
maxloc([3, 9, 4])      // 2
maxloc(m)              // (2, 3)
count(m > 2)           // 4
```

`dot` conjugates its first argument when it is complex, as Fortran's `DOT_PRODUCT` and BLAS's
`zdotc` do, so `dot(z, z)` is the squared norm of `z`. `@` never conjugates: `x @ y` of two complex
vectors is Σ xₖ yₖ.

`min` and `max` are not reductions: they are elemental over their arguments (§12.2). The extremes of
an array are `minval` and `maxval`.

The three-argument `minloc` and `maxloc` combine a running `(value, index)` pair with one candidate.
They are the operator form used by `parallel for … reduce` (see
[Parallelism](/spec/10-parallelism/)); sequentially they fold the same way:

```nex
var worst = (0.0, 0)
for k in 1..length(r)
  worst = maxloc(worst, abs(r[k]), k)
val (largest, where) = worst
```

**Order of summation.** `sum`, `product`, `dot` and `norm2`, with or without `dim =`, combine their elements in a
fixed blocked pairwise tree, not left to right. The result is identical with or without
`parallel` and for every thread count, and the rounding error grows as O(log n) rather than O(n). A
floating-point `sum` can therefore differ in its last bits from a Fortran `DO` loop that accumulates
one element at a time; a loop written that way in nex accumulates in source order, as written.
Integer reductions are exact and trap on overflow. The `minval` and `maxval` of an empty integer
array are the type's largest and smallest values, and of an empty real array `+inf` and `-inf`, as
in Fortran. `minval` and `maxval` pass over a `nan`, as Fortran's do, along a `dim =` lane by lane and
under `parallel` for every thread count; the elemental `min` and `max`, which are not reductions,
carry a `nan` through.

## 12.7 Linear algebra

| Signature | Meaning | Fortran |
|---|---|---|
| `A @ B` | matrix product: `(m, k) @ (k, n)` is `(m, n)`; `(m, k) @ k` is `m`; `k @ (k, n)` is `n`; `k @ k` is the dot product | `MATMUL(A, B)`, `DOT_PRODUCT` |
| `transpose(m)` | rank 2: rows and columns exchanged | `TRANSPOSE(m)` |
| `conj(a)` | the conjugate of every element | `CONJG(a)` |
| `solve(A, b)` | `x` with `A @ x == b`; `b` a vector or a matrix of right-hand sides | `?GESV` |
| `lstsq(A, b)` | the least-squares solution | `?GELSD` |
| `inv(A)` | the inverse | `?GETRF` + `?GETRI` |
| `det(A)` | the determinant; `0.0` for a singular matrix | `?GETRF` |
| `lu(A)` | `(L, U, p)`, the pivoted LU factors | `?GETRF` |
| `chol(A)` | the lower Cholesky factor `L` of a symmetric or Hermitian positive-definite `A`: `A == L @ conj(transpose(L))` | `?POTRF` |
| `chol(A, upper = true)` | the upper factor `U`: `A == conj(transpose(U)) @ U` | `?POTRF` |
| `qr(A)` | `(Q, R)` | `?GEQRF` + `?ORGQR` |
| `eigvals(A)` | the eigenvalues of a general matrix, always complex | `?GEEV` |
| `eig(A)` | `(values, vectors)` of a general matrix, always complex; the vectors are the columns | `?GEEV` |
| `eigh(A)` | `(values, vectors)` of a symmetric or Hermitian matrix; the values are real, in ascending order | `?SYEVD` / `?HEEVD` |
| `svd(A)` | `(U, s, V)` with `A == U @ diag(s) @ conj(transpose(V))` | `?GESDD` |
| `svdvals(A)` | the singular values `s`, in descending order | `?GESDD` |

`@` takes operands of rank 1 and 2 only; an operand of rank 3 or more is a compile error. The inner
extents must agree: a compile error when both are static, a trap otherwise. Large products of
`real32`, `real64` and complex operands are computed by BLAS.

The LAPACK functions take and return values: they copy their inputs, because LAPACK overwrites
them, and they **trap** when LAPACK reports failure, with a message in the problem's terms and
1-based indices — *"solve: matrix is singular (U[3,3] = 0)"*. Only the solvers (`solve`, `inv`)
trap on a singular matrix; `det` of one is `0.0`. In-place forms that return LAPACK's
`info` instead of trapping (`lu_inplace`, `chol_inplace`, `qr_inplace`, …), BLAS dispatch and the
leading-dimension rules are in [Interop](/spec/11-interop/).

```nex
val A = [[4.0, 1.0],
         [1.0, 3.0]]
val b = [1.0, 2.0]
val x = solve(A, b)
assert_approx(A @ x, b, 1e-12)
```

## 12.8 Higher-order functions

| Signature | Meaning | Fortran |
|---|---|---|
| `map(a: [T; R], f: T -> U): [U; R]` | `f` applied to every element; shape kept | an `ELEMENTAL` function applied to an array |
| `filter(a: [T], p: T -> bool): [T]` | the elements for which `p` holds, in order | `PACK(a, mask)` |
| `flatMap(a: [T], f: T -> [U]): [U]` | `f` applied to every element, the results concatenated | — |
| `reduce(a: [T], init: U, f: (U, T) -> U): U` | left fold: `f(… f(f(init, a[1]), a[2]) …, a[n])` | `REDUCE` (Fortran 2018) |
| `enumerate(a: [T])` | each element paired with its index, starting at **1** | — |
| `zip(a: [T], b: [U])` | the elements of `a` and `b` paired, truncated to the shorter | — |

```nex
val xs = [1, 2, 3, 4, 5]
xs.map(x -> x * x).filter(y -> y > 10).sum()     // 16 + 25 = 41
reduce(xs, 0, (acc, x) -> acc + x)               // 15, folded left to right

for k, x in enumerate(xs)
  print(k, x)                                    // 1 1, 2 2, … 5 5
```

`map`, `sum`, `product`, `minval`, `maxval` and `dot` have parallel forms, written with the `parallel`
prefix (`parallel map(x, t -> exp(-t * t))`); `reduce` has none. See
[Parallelism](/spec/10-parallelism/).

`enumerate` and `zip` give arrays of tuples — `enumerate(xs)` is an `[(integer, T)]` — which may be
iterated, as above, or stored like any other array (see [Types](/spec/03-types/)).

## 12.9 Views

A view shows an existing array's elements without copying them. Every slice is a view; these
functions make the views that a slice cannot spell. Views are read-only (see
[Values and memory](/spec/08-values-and-memory/)).

| Signature | Meaning | Fortran |
|---|---|---|
| `reverse(a)` | `a[.. by -1]`: the elements back to front | `a(n:1:-1)` |
| `reverse(a, k)` | axis `k` reversed, the others unchanged | `a(:, n:1:-1)` for `k = 2` |
| `transpose(m)` | rank 2, axes exchanged | `TRANSPOSE(m)` |
| `permute(a, (p1, …, pk))` | axes reordered: result axis `n` is source axis `pₙ` | `RESHAPE(a, …, ORDER=…)` |
| `origin(a, o1, o2, …)` | an offset view whose first index on each axis is `o1`, `o2`, … (missing ones stay 1) | a pointer with lower bounds, `p(-r:) => a` |
| `rebase(w)` | an ordinary 1-based copy of an offset view | `a(lbound(a,1):)` copied |

`origin` is for a computation that reads better with other bounds, such as a symmetric kernel or a
grid with ghost cells. On the view, indexing, slicing and `end` are relative to the new origin, and
an access costs exactly what an access to the source costs:

```nex
val w = origin(kernel, -r)          // w[-r] .. w[r] are kernel[1] .. kernel[2r + 1]
for k in -r..r do acc += w[k] * x[i - k]
```

An offset view is **local**: it cannot be passed, returned, stored or captured by an escaping
closure, and trying is a compile error that names `origin`. `rebase(w)` makes the ordinary 1-based
array that may cross a function boundary, so every function parameter starts at index 1.

`transpose`, `permute`, and `reshape` and `flatten` of a dense array move no data.

{{< note >}}
`permute` is proposed, and the guarantee that `transpose`, `permute`, `reshape` and `flatten`
return views rather than copies is a proposed performance guarantee; the result is the same value
either way.
{{< /note >}}

## 12.10 Conversions

Every numeric type name is also its conversion function, on a scalar and, element by element, on an
array:

| Signature | Meaning | Fortran |
|---|---|---|
| `int8(x)` … `int64(x)`, `uint8(x)` … `uint64(x)` | to that integer type | `INT(x, int32)` etc. |
| `real16(x)`, `real32(x)`, `real64(x)` | to that real type | `REAL(x, real32)` etc. |
| `complex[realN](z)`, `complex[realN](re, im)` | to that complex type | `CMPLX(z, KIND=realN)` |
| `to_real(x)`, `to_integer(x)`, `to_complex(x)` | the same as `real64`, `int64`, `complex[real64]` | `REAL`, `INT`, `CMPLX` with the 64-bit kind |

| From → to | Behaviour |
|---|---|
| integer → narrower integer, signed ↔ unsigned | exact, or **traps** when out of range (`uint32(-1)` traps) |
| real → integer | truncates toward zero; **traps** on NaN, infinity or out of range |
| real → narrower real | rounds to nearest-even; overflow gives ±∞ |
| complex → narrower complex | each part as real → real |
| complex → real or integer | not a conversion: take `.re`, `abs` or `arg` |
| any widening | happens implicitly; the function may also be called explicitly |

Arrays never convert implicitly as a whole: a `[real32]` does not pass where a `[real64]` is
expected, and `real64(a)` makes the converted copy visibly. The full promotion rules are in
[Types](/spec/03-types/).

```nex
val a32 = real32(linspace(0.0, 1.0, 11))   // [real32]
val n = int32(3.9)                         // 3
val bytes = uint8([72, 105])               // [uint8]
val codes = int64(bytes)                   // [integer]
```

**Units.** Two more functions convert between units of measure, on a scalar and element by element
on an array:

| Signature | Meaning |
|---|---|
| `to<u>(x)` | `x` converted to unit `u` of the same dimension: `to<mm>(1.0<in>)` is `25.4<mm>` |
| `strip(x)` | the number in `x`'s own unit, without the unit; on an array a view, with no copy |

The prelude declares these units, each exactly:

| Units | Definitions |
|---|---|
| SI base | `m` `kg` `s` `A` `K` `mol` `cd` |
| SI derived | `N = kg m / s^2`, `J = N m`, `W = J / s`, `Pa = N / m^2`, `Hz = 1 / s`, `C = A s`, `V = W / A`, `ohm = V / A` |
| Angle | `rad` (a base unit), `sr = rad^2`, `deg = π/180 rad`, `turn = 2π rad`, `arcmin = deg / 60`, `arcsec = arcmin / 60` |
| SI scaled | `mm = 0.001 m`, `cm = 0.01 m`, `km = 1000 m`, `g = 0.001 kg`, `ms = 0.001 s`, `us = 0.000001 s`, `ns = 0.000000001 s`, `kPa = 1000 Pa`, `MPa = 1000000 Pa`, `GPa = 1000000000 Pa`, `kN = 1000 N`, `kJ = 1000 J`, `kW = 1000 W` |
| Imperial and US customary | `in = 0.0254 m`, `ft = 12 in`, `yd = 3 ft`, `mi = 5280 ft`, `lb = 0.45359237 kg`, `oz = 0.0625 lb`, `lbf = 4.4482216152605 N`, `slug = lbf s^2 / ft`, `psi = lbf / in^2`, `ksi = 1000 psi`, `BTU = 1055.05585262 J`, `hp = 550 ft lbf / s`, `usgal = 231 in^3`, `ukgal = 0.00454609 m^3` |

There is no `gal`: write `usgal` or `ukgal`. How units pass through the other prelude functions is
in [Units of measure](/spec/13-units/).

## 12.11 Input and output

| Signature | Meaning | Fortran |
|---|---|---|
| `print(x, …)` | prints its arguments on one line to standard output, then a newline | `PRINT *, x, …` |
| `print()` | prints an empty line | `PRINT *` |
| `eprint(x, …)` | as `print`, to standard error | `WRITE(ERROR_UNIT, *) x, …` |
| `read_bytes(path: string): [uint8]` | the whole file's contents | `OPEN(…, ACCESS='stream')` + `READ` |
| `write_bytes(path: string, data: [uint8])` | writes `data` as the file's contents | `OPEN(…, ACCESS='stream')` + `WRITE` |

A real prints as the shortest decimal that reads back to the same value at its own width, so the
`real32` nearest 0.3 prints as `0.3`. A complex prints as its two parts do. Text is formatted with
interpolated strings: `s"…"` substitutes values, `f"…"` adds printf-style specs such as
`$x%10.3f` (see [Lexical structure](/spec/02-lexical/)).

```nex
val n = 42
print(s"n = $n")              // n = 42
print(f"pi = $pi%.3f")        // pi = 3.142

val data = read_bytes("input.bin")
write_bytes("copy.bin", data)
```

Raw bytes are `[uint8]`, an ordinary array with every array operation; there is no separate byte
type.

{{< note >}}
Width-exact printing of `real32` and `real16` values is proposed and may change in detail.
{{< /note >}}

## 12.12 Testing

For test functions and test modules (see [Functions](/spec/06-functions/) and
[Modules](/spec/09-modules/)):

| Signature | Meaning |
|---|---|
| `assert(cond)`, `assert(cond, msg)` | traps unless `cond` is `true` |
| `assert_eq(actual, expected)` | traps unless the two are equal |
| `assert_approx(actual, expected, tol)` | traps unless \|actual − expected\| ≤ `tol`; on arrays, element by element, and a shape mismatch traps |
| `assert_traps(thunk)` | passes if calling the zero-argument closure traps, fails if it returns |
| `assert_traps(thunk, text)` | as above, and the trap message must contain `text` |

Every failed assertion traps with a message naming the assertion and any `msg`; the test runner
(`nex test`, see [Command Line](/tooling/01-cli/)) reports it as that test's failure and carries on
with the rest of the suite. For `real` and `complex` values prefer
`assert_approx`: exact floating-point equality is almost never what a test means. For a complex the
distance is the modulus of the difference.

```nex
@test
def overflow_traps() =
  val big: int8 = 127
  assert_traps(() -> big + 1)       // int8 arithmetic traps at 128
```
