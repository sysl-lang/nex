---
title: nex for Fortran programmers
summary: What carries over from Fortran, a line-by-line translation table, a kernel in both languages, and what nex does differently and why.
weight: 10
---

This page is for someone who writes Fortran and wants to read and write nex by the end of it. It
assumes you know Fortran 90 or later; it assumes nothing else.

nex is compiled ahead of time to a native binary, like Fortran. `nex build` produces the
executable; `nex run` compiles and runs it in one step. There is no interpreter.

## What stays the same

Most of what you rely on in Fortran is how nex works too.

- **Column-major storage.** The first index varies fastest, at every rank. A column `m[:, j]` is
  contiguous, so the loop order you already use is the fast one.
- **1-based arrays.** The first element of every axis is index 1 and the last is its extent. Axes
  are numbered from 1 too: `extent(a, 1)` is `size(a, dim=1)`.
- **Inclusive sections.** `a[2..5]` is four elements, exactly `a(2:5)`. An empty section such as
  `a[1..0]` is legal, as in Fortran.
- **Whole-array expressions.** `y = alpha * x + y` works on arrays of any rank, element by element,
  and compiles to one fused loop with no temporaries.
- **Argument intent.** A parameter is read-only unless declared `inout`, which is
  `intent(inout)`. The call site carries no marker, as in Fortran.
- **Kinds.** The type names are the `iso_fortran_env` kind names: `int32`, `int64`, `real32`,
  `real64`, `complex[real64]`. The number counts bits.
- **Your libraries.** BLAS, LAPACK and your own compiled Fortran are called directly
  ([Calling your existing Fortran](#calling-your-existing-fortran)).

## Translation table

Comments in nex start with `//`. Blocks are marked by indentation; an `end` line
(`end for`, `end if`, `end def`) may close a block but is never required.

### Declarations and kinds

| Fortran | nex |
|---|---|
| `integer(int32) :: n` | `var n: int32 = 0` |
| `integer :: n` (usually 32-bit) | `var n: int32 = 0`, or `integer` for 64-bit |
| `integer(int64) :: n` | `var n: integer = 0` (`integer` **is** `int64`) |
| `real(real32) :: x` | `var x: real32 = 0.0` |
| `real(real64) :: x` | `var x = 0.0` (`real` **is** `real64`, and an unannotated real literal is `real64`) |
| `complex(real64) :: z` | `var z: complex = 0` (`complex` **is** `complex[real64]`) |
| `complex(real32) :: z` | `var z: complex[real32] = 0` |
| `logical :: ok` | `var ok = true` (type `bool`) |
| `integer, parameter :: n = 100` | `const n = 100` |
| `real(real64), parameter :: tol = 1.0e-10_real64` | `const tol = 1.0e-10` |
| `1.0_real64`, `1.0d0` | `1.0` (a literal takes its type from where it is used) |
| `2.5_real32 * x` | `2.5 * x` (with `x: real32`, the product is `real32`) |
| `real(x, real32)`, `dble(x)`, `int(x)` | `real32(x)`, `real64(x)`, `int64(x)`: every type name is its conversion |
| `cmplx(a, b, real64)` | `complex(a, b)`, or `a + b*i` |
| `real(z)`, `aimag(z)`, `conjg(z)` | `z.re`, `z.im`, `conj(z)` |

A `val` is a binding that never changes; a `var` may be reassigned. Write `val` unless you mean to
change it. Both always have a value: there is no uninitialized variable.

### Arrays and shapes

| Fortran | nex |
|---|---|
| `real(real64), allocatable :: a(:)` then `allocate(a(n)); a = 0` | `var a = fill(n, 0.0)` (type `[real]`) |
| `real(real64), allocatable :: m(:,:)` then `allocate(m(r, c))` | `var m = fill((r, c), 0.0)` (type `[real; :, :]`) |
| `real(real64) :: m(3,3)` (fixed shape) | `var m: [real; 3, 3] = fill((3, 3), 0.0)` |
| `real(real32), allocatable :: t(:,:,:)` | a `[real32; :, :, :]` |
| `a = [1.0, 2.0, 3.0]` | `val a = [1.0, 2.0, 3.0]` |
| `reshape([1,2,3,4,5,6], [2,3])` | `reshape([1, 2, 3, 4, 5, 6], (2, 3))` (column-major, as Fortran) |
| `size(a)` | `size(a)` |
| `size(a, dim=k)` | `extent(a, k)` |
| `shape(m)` | `shape(m)`, a tuple `(rows, cols)` at rank 2 |
| `size(m, 1)`, `size(m, 2)` | `rows(m)`, `cols(m)` |
| `deallocate(a)` | nothing: storage is freed when the last use is gone |

A matrix literal is written row by row, as you read it; storage is column-major regardless:

```nex
val m = [[1.0, 2.0, 3.0],
         [4.0, 5.0, 6.0]]          // shape (2, 3); m[2, 1] == 4.0
```

### Sections

| Fortran | nex |
|---|---|
| `a(i)`, `m(i, j)` | `a[i]`, `m[i, j]` |
| `a(lo:hi)` | `a[lo..hi]` |
| `a(lo:)`, `a(:hi)`, `a(:)` | `a[lo..]`, `a[..hi]`, `a[:]` |
| `a(lo:hi:step)` | `a[lo..hi by step]` |
| `a(n:1:-1)` | `a[n..1 by -1]`, or `a[.. by -1]` |
| `m(:, j)` (a column) | `m[:, j]` |
| `m(i, :)` (a row) | `m[i, :]` |
| `a(size(a))` | `a[end]` |
| `a(size(a)-2:)` | `a[end-2..]` |
| `m(:, size(m, 2))` | `m[:, end]` |
| `a(2:5) = b` | `a[2..5] = b` |
| `m(1:3:2, 2:3) = 0` | `m[1..3 by 2, 2..3] = 0.0` |

Inside a subscript, `end` means the last index of that axis. nex also has a half-open form,
`a[lo..<hi]`, which stops before `hi`; it is useful for splitting an array at a point
(`a[..<k]` and `a[k..]`). Every index is bounds-checked, always. See
[Arrays](/spec/04-arrays/).

### Array operations and intrinsics

| Fortran | nex |
|---|---|
| `c = a + b`, `y = alpha * x + y` | the same, without the declarations |
| `sqrt(a)` on an array (elemental) | `a.map(t -> sqrt(t))` |
| `matmul(a, b)` | `a @ b` |
| `matmul(a, x)` | `a @ x` (matrix–vector) |
| `dot_product(x, y)` (real) | `x @ y` or `dot(x, y)` |
| `transpose(m)` | `transpose(m)` |
| `sum(a)`, `product(a)` | `sum(a)`, `product(a)` |
| `sum(m, dim=1)`, `sum(m, dim=2)` | `sum_axis(m, 1)`, `sum_axis(m, 2)` |
| `maxval(a)`, `minval(a)` | `max(a)`, `min(a)` |
| `norm2(a)` | `norm(a)` |
| `x**2`, `x**n` | `x^2`, `x^n` |
| `mod(a, b)` | `a % b` |
| `a / b` on two integers | `a div b` (`a / b` on two integers gives a `real`) |
| `a /= b`, `.and.`, `.or.`, `.not.` | `a != b`, `and`, `or`, `not` |

`@` is matrix multiplication on ranks 1 and 2 and calls BLAS when the product is large enough to
pay for it ([Array expressions](/spec/05-array-expressions/)). Note that `@` on two complex
vectors does **not** conjugate, where Fortran's `dot_product` conjugates its first argument; write
`x.map(t -> conj(t)) @ y` for the Hermitian product.

### Control flow

| Fortran | nex |
|---|---|
| `do i = 1, n` … `end do` | `for i in 1..n` (indented body) |
| `do i = 1, n-1` | `for i in 1..n-1`, or `for i in 1..<n` |
| `do while (err > tol)` | `while err > tol` |
| `if (x > 0) then` … `else if` … `else` … `end if` | `if x > 0` … `else if` … `else` (indented bodies) |
| `y = merge(a, b, x > 0)` | `val y = if x > 0 then a else b` (`if` is an expression) |
| `select case` | `match` ([Control flow](/spec/07-control-flow/)) |
| `do concurrent (i = 1:n)` | `parallel for i in 1..n` |
| `!$omp parallel do` | `parallel for i in 1..n` |
| `!$omp parallel do reduction(+:s)` | `parallel for i in 1..n reduce s: +` |
| `reduction(max:m)` | `reduce m: max` |

A one-line body follows `do`: `for i in 1..n do y[i] = 2.0 * x[i]`. nex has no `exit` or `cycle`;
put the stopping test in a `while` condition, or `return` from a function.

### Parallel loops and reductions

```fortran
s = 0.0_real64
!$omp parallel do reduction(+:s)
do i = 1, n
   s = s + x(i) * y(i)
end do
```

```nex
var s = 0.0
parallel for i in 1..n reduce s: +
  s += x[i] * y[i]
```

There is no pragma to forget and no compiler flag to enable: a program that contains `parallel`
links the OpenMP runtime, and the thread count comes from `OMP_NUM_THREADS`, as your batch scripts
already set it. The compiler **proves** the loop is race-free — every iteration writes only
elements indexed by its own loop variable, and nothing reads what another iteration writes — and
rejects it with an error naming the offending line otherwise. Nothing runs in parallel unless you
wrote `parallel`, so an MPI code with one rank per core is never oversubscribed. See
[Parallelism](/spec/10-parallelism/).

`maxloc` and `minloc` are reduction operators, with Fortran's tie rule (the lowest index wins):

```fortran
loc = maxloc(abs(r), dim=1)
```

```nex
var worst = (0.0, 0)
parallel for k in 1..n reduce worst: maxloc
  worst = maxloc(worst, abs(r[k]), k)
val (largest, loc) = worst
```

### Procedures

| Fortran | nex |
|---|---|
| `function f(x) result(y)` with `real(real64), intent(in) :: x` | `def f(x: real): real = …` |
| `subroutine s(a, b)` | `def s(a: …, b: …) = …` |
| `intent(in)` | the default: no keyword |
| `intent(inout)` | `inout` |
| `intent(out)` | `inout`, or better, return the value (a tuple returns several) |
| `call s(a, b)` | `s(a, b)` |
| `pure function` | an ordinary `def` |
| `elemental function f(x)` | a scalar `def f`, applied with `map(a, f)` or `a.map(f)` |
| `optional` argument | a default value: `def f(x: real, tol: real = 1.0e-8)` |
| `f(x, tol=1.0e-6)` (keyword argument) | `f(x, tol = 1.0e-6)` |

```fortran
subroutine scale(v, s)
   real(real64), intent(inout) :: v(:)
   real(real64), intent(in)    :: s
   v = v * s
end subroutine scale

call scale(x, 2.0_real64)
```

```nex
def scale(v: inout [real], s: real) =
  v = v * s

scale(x, 2.0)
```

A function's value is its last expression; `return` exits early. nex has no `pure` attribute
because it does not need one: inside a `parallel for` the compiler checks every function called for
the effects that would make it unsafe. See [Functions](/spec/06-functions/).

### Modules and I/O

| Fortran | nex |
|---|---|
| `module linalg` … `contains` … `end module` | a directory `linalg/`: every `.nex` file in it is the module |
| `use linalg, only: solve, lu` | `import linalg.{solve, lu}` |
| `use linalg` (everything) | not allowed: list the names you import |
| `private :: helper` | `private def helper(…) = …` |
| `.mod` files and build order | none: the compiler reads the sources and orders them itself |
| `print *, x` | `print(x)` |
| `print *, 'n =', n, ' err =', err` | `print(s"n = $n err = $err")` |
| `write(*, '(F10.3)') x` | `print(f"$x%10.3f")` |

See [Modules](/spec/09-modules/) and [The prelude](/spec/12-prelude/).

## One kernel in both languages

Jacobi iteration for the 1-D Poisson problem −u″ = f on n interior points, with u = 0 at both ends.

```fortran
program jacobi
   use iso_fortran_env, only: real64
   implicit none
   integer, parameter :: n = 100
   real(real64), parameter :: tol = 1.0e-10_real64
   real(real64) :: u(0:n+1), unew(n), f(n), h, diff
   integer :: iter

   h = 1.0_real64 / (n + 1)
   f = 1.0_real64
   u = 0.0_real64
   diff = huge(diff)
   iter = 0
   do while (diff >= tol .and. iter < 100000)
      unew = 0.5_real64 * (u(0:n-1) + u(2:n+1) + h*h*f)
      diff = maxval(abs(unew - u(1:n)))
      u(1:n) = unew
      iter = iter + 1
   end do
   print *, 'iterations:', iter, '  u(mid) =', u((n + 1) / 2)
end program jacobi
```

```nex
const n = 100
const tol = 1.0e-10

def main() =
  val h = 1.0 / (n + 1)
  val f = fill(n, 1.0)
  var u = fill(n + 2, 0.0)            // u[1] and u[end] are the boundary values
  var diff = inf
  var iter = 0

  while diff >= tol and iter < 100000
    val unew = 0.5 * (u[1..end-2] + u[3..end] + h * h * f)
    diff = max(map(unew - u[2..end-1], t -> abs(t)))
    u[2..end-1] = unew
    iter += 1

  print(s"iterations: $iter  u(mid) = ${u[(n + 3) div 2]}")
```

A program starts at `def main()`, like Fortran's `program` unit. The nex version has no declarations to keep in step with the code, no `_real64` suffixes, and no
`implicit none` because there is no implicit typing. `1.0 / (n + 1)` is a `real` because `/` on
an integer always gives a real. The Fortran array runs `0:n+1`; nex arrays start at 1, so the
interior is `u[2..end-1]` and the middle point `u((n+1)/2)` is `u[(n + 3) div 2]`.

The update is a loop you can run in parallel. To keep Fortran's `0:n+1` indexing in the loop
body, take an `origin` view, which renumbers an array without copying it. The loop in `main`
becomes:

```nex
  var unew = fill(n, 0.0)

  while diff >= tol and iter < 100000
    val g = origin(u, 0)              // g[0] .. g[n+1] are u[1] .. u[n+2]
    parallel for k in 1..n do unew[k] = 0.5 * (g[k - 1] + g[k + 1] + h * h * f[k])
    diff = max(map(unew - u[2..end-1], t -> abs(t)))
    u[2..end-1] = unew
    iter += 1
```

Each iteration writes only `unew[k]` and only reads `u`, which the loop does not write, so the
compiler accepts it. Change the body to read `unew[k - 1]` and it is a compile error, not a race.

## What is different, and why

### `end` inside a subscript

`a[end]` is the last element. In Fortran you write `a(size(a))` or `a(ubound(a, 1))`; in nex
`end` is the last index of whichever axis it appears in (`m[end, 1]`, `m[:, end-1]`). Outside a
subscript, `end` is the optional block terminator.

### Values, not aliases — Fortran's aliasing rule, checked

Fortran forbids passing the same array twice to a procedure when one of the dummies is modified,
but no compiler checks it, and a violation silently gives wrong answers at `-O2`. nex makes the rule
a compile error:

```nex
def axpy(alpha: real, x: [real], y: inout [real]) =
  y = alpha * x + y

axpy(2.0, a, a)          // error: `a` is borrowed inout and read in the same call
```

Two sections of one array may both be passed `inout` to one call only when the compiler can see
from the source that they do not overlap: different constant windows (`a[1..4]` and `a[5..8]`), or
a split at one point (`a[1..k]` and `a[k+1..]`). Everything else is rejected with a message
suggesting the split form.

Assignment copies the value, as in Fortran: after `var b = a`, changing `b` does not change `a`.
The compiler avoids the copy whenever `a` is not used again.

### Sections are views

`a[2..5]`, `m[:, j]` and `a[.. by -1]` copy nothing: they are windows onto the original storage,
passed to functions and to BLAS without a temporary (Fortran's copy-in/copy-out of a
non-contiguous section does not happen for a column or a leading-dimension block). A view is
read-only; you write a section through slice assignment (`a[2..5] = b`) or by passing it `inout`.
A view keeps the values it had when it was taken even if the array is written afterwards, so you
never see a half-updated window.

### `origin` instead of arbitrary lower bounds

Every nex array starts at 1. Fortran's declared bounds — `u(0:n+1)`, `w(-r:r)` — are replaced by
an **offset view**:

```nex
val w = origin(kernel, -r)            // w[-r] .. w[r] are kernel[1] .. kernel[2r + 1]
for k in -r..r
  acc += w[k] * x[i - k]
```

An offset view lives only in the function that took it; passing it to another function is a
compile error that tells you to call `rebase(w)` for an ordinary 1-based copy. The reason is a
Fortran bug you have probably met: an array declared `u(0:n+1)` arrives in an assumed-shape dummy
`v(:)` as `v(1:n+2)`, and the off-by-one is silent. In nex every parameter starts at 1, always, and
no function has to ask what its argument's bounds are.

### `real` is 64-bit

`real` is `real64`, and an unannotated literal such as `0.1` is `real64`. This removes the
forgotten-`d0` bug: in nex there is no way to compute in single precision by accident. When you do
want single precision, say `real32` on the arrays and the literals follow them: with `x: [real32]`,
`2.0 * x` is computed in `real32`.

Arrays never change kind silently. Assigning a `real64` result into a `real32` array is a compile
error until you write which rounding you mean (`a = real32(x * a)`).

When translating, a Fortran `real` (default kind) is `real32` in nex, and `double precision` is
`real` — but check whether the program meant single precision or only forgot to ask for double.

### Integer overflow traps

Integer arithmetic stops the program with an error on overflow, at every width, signed and
unsigned. Fortran leaves overflow undefined, and gfortran wraps. A loop counter that overflows an
`int32` is reported at the line that did it.

### Errors where Fortran has undefined behaviour

| Fortran (undefined, or silently wrong) | nex |
|---|---|
| index out of bounds without `-fcheck=bounds` | every index is checked; out of bounds stops the program with the location |
| reading an uninitialized variable | impossible: every `val` and `var` is initialized |
| aliasing a modified dummy argument | compile error |
| integer overflow | stops the program |
| conformance mismatch in `a = b + c` | compile error when the shapes are known, otherwise a run-time error |
| a data race in `do concurrent` or an OpenMP loop | compile error |
| `real` → integer conversion of NaN or an out-of-range value | stops the program |

Floating-point arithmetic is ordinary IEEE: dividing by zero gives an infinity or a NaN and does not
stop the program.

### Reproducible reductions

`sum`, `product`, `dot`, `norm` and every `parallel for … reduce` give **the same bits for every
thread count**: `OMP_NUM_THREADS=1` and `OMP_NUM_THREADS=64` agree exactly, and adding or removing
`parallel` never changes a result. They get this by summing in fixed blocks combined in a fixed
pairwise tree. The price is that `sum(x)` differs in its last bits from a Fortran `DO` loop that
adds one element at a time; the gain, besides reproducibility, is accuracy, since pairwise
summation's rounding error grows as O(log n) rather than O(n). A loop you write element by element
(`for k in 1..n do s += x[k]`) without `reduce` adds in the order you wrote.

A product dispatched to BLAS follows the BLAS library's own order, so a large `@` may differ in the
last bits from a small one.

### `i` is the imaginary unit — until you name a loop index `i`

`3 + 2i` is a complex number, since a number written directly before a name multiplies it. Inside
`for i in 1..n`, `i` is the loop index, so `2i` is `2 * i`, an integer. Name the index `k` or `j`
in complex code, or write the unit as `complex(0.0, 1.0)`.

## Calling your existing Fortran

Your compiled Fortran stays where it is. A procedure written with `bind(c)` is declared like any C
function; an ordinary Fortran 77/90 procedure compiled by gfortran is declared `@fortran`, which
applies gfortran's name mangling and passes every argument by reference, as Fortran does:

```nex
@fortran @link("mylib")
extern def dgtsv(n: int32, nrhs: int32, dl: inout [real], d: inout [real], du: inout [real],
                 b: inout [real; :, :], ldb: int32, info: inout int32)
```

{{< note >}}
The `@fortran` and `@link` spellings may change before they are final.
{{< /note >}}

Arrays cross with no copy, since both languages are column-major and 1-based; a column block such
as `m[2..6, 1..4]` crosses with the original leading dimension. Assumed-shape dummies (`a(:)`),
derived types and `optional` arguments need a small `bind(c)` wrapper on the Fortran side. LAPACK
itself is already in the prelude as `solve`, `lu`, `chol`, `qr`, `eig`, `svd` and friends. See
[Interoperability](/spec/11-interop/).
