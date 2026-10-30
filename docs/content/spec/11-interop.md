---
title: Interoperability
summary: Calling C and existing Fortran with extern def; what crosses the boundary and how; callbacks; BLAS behind @; the LAPACK prelude.
weight: 110
---

A nex program reaches compiled code written in other languages through **`extern` declarations**:
C libraries, BLAS and LAPACK, and existing Fortran — both `bind(c)` procedures and plain objects
compiled with gfortran. Calling your own Fortran library is a first-class part of the language, not a
compatibility layer: a working Fortran code base stays where it is, and new code around it is
written in nex.

Two prelude facilities sit on top of the same machinery: the matrix product `@` uses BLAS when that
pays (§11.8), and the dense linear-algebra functions `solve`, `chol`, `eig` and the rest call LAPACK
(§11.9).

## 11.1 `extern` declarations

An `extern def` is a function declaration with no body. It names a function compiled elsewhere,
gives it nex parameter types, and says how to link it:

```nex
@link("m")
extern def cbrt(x: real): real

@link(framework = "Accelerate")
extern def cblas_ddot(n: int32, x: [real], incx: int32,
                      y: [real], incy: int32): real

@symbol("dgesv_")
extern def lapack_dgesv(n: int32, nrhs: int32, a: inout [real; :, :], lda: int32,
                        ipiv: inout [int32], b: inout [real; :, :], ldb: int32,
                        info: inout int32)
```

An `extern` function is called like any other function:

```nex
val r = cbrt(27.0)                // 3.0
```

The annotations:

| Annotation | Meaning |
|---|---|
| `@link("lib")` | link against `lib` (`-llib`) |
| `@link(framework = "Name")` | link against a macOS framework |
| `@symbol("name")` | the symbol to call, when it differs from the nex name |
| `@pure` | the function has no effects: no I/O, no global state |
| `@strided` | on an array parameter: pass any view as is (§11.5) |
| `@c` | on a `struct`: lay it out as C does (§11.4) |
| `@fortran` | apply gfortran's calling conventions (§11.7.2) |
| `@data(f)` | on a `c_ptr` parameter: it carries the environment of the callback `f` (§11.6) |

**Linking.** `nex build` links every library named by an `@link("name")` in the program, plus any
given on the command line with `-l name`, searching the directories given with `-L dir`
([Command Line](/tooling/01-cli/)). A program with a `@fortran` extern is linked against the
gfortran runtime automatically.

{{< note >}}
The spelling `@link(framework = "…")` may change before it is final.
{{< /note >}}

**`@pure` is believed, not checked.** An `extern` function is assumed to have effects unless it is
declared `@pure`; the compiler cannot look inside compiled code, so it takes the annotation on trust.
It matters in parallel code: the body of a `parallel for` may call an `extern` function only if it
is `@pure` ([Parallelism](/spec/10-parallelism/)).

```nex
@pure @link("m")
extern def cbrt(x: real): real

parallel for k in 1..n
  y[k] = cbrt(x[k])               // allowed: cbrt is @pure
```

A wrong `@pure` on a function that does write global state makes a parallel loop that calls it
racy; nothing catches it.

## 11.2 What crosses

Each nex parameter type has one C meaning:

| nex parameter | C sees |
|---|---|
| `int8` … `int64` | `int8_t` … `int64_t` |
| `uint8` … `uint64` | `uint8_t` … `uint64_t` |
| `real32`, `real64`, `real16` | `float`, `double`, `_Float16` |
| `complex[real32]`, `complex[real64]` | `float _Complex`, `double _Complex`, **by value** (§11.3) |
| `bool` | `bool` (`_Bool`) |
| an `inout` scalar | a pointer to it (`int32_t *info`) |
| `string` | `const char *`, a NUL-terminated copy valid for the call |
| `[T; …]`, read mode | `const T *` to the first element of the window |
| `[T; …]`, `inout` | `T *` to the first element; C's writes land in the caller's array |
| a `@c` struct, read mode | `const S *` |
| a `@c` struct, `inout` | `S *` |
| a function type `(A, B) -> R` | a C function pointer (§11.6) |
| `c_ptr` | `void *`, opaque; only as the `@data` partner of a callback (§11.6) |
| `[*; ..]`, read mode or `inout` | `const nex_desc *`: any array of numbers or `bool` at any rank, or a scalar (§11.10) |
| return: a scalar, a complex, or `void` | the value, or C `void` |

Remember the aliases: `integer` is `int64`, `real` is `real64`, `complex` is `complex[real64]`. A
C `int` is **`int32`**, not `integer` — the LP64 BLAS and LAPACK interfaces take `int32` sizes and
leading dimensions. A literal passed to an `int32` parameter is an `int32` already; a computed
`integer` needs a conversion, which traps if the value does not fit:

```nex
val n = size(x)                       // integer
val d = cblas_ddot(int32(n), x, 1, y, 1)
```

**Units of measure do not cross.** An `extern` parameter is a plain number, so a value with a unit
is passed through `strip`, which gives the number in the value's own unit; on an array it is a view
and copies nothing. The result gets its unit back by multiplying
([Units of measure](/spec/13-units/)):

```nex
val p = [101.3, 98.6, 102.1] * 1.0<kPa>
val q = [1.0, 2.0, 1.0] * 1.0<m^3>
val work = cblas_ddot(3, strip(p), 1, strip(q), 1) * 1.0<kJ>   // kPa m^3 is kJ
```

**An `inout` scalar is how C writes back.** The argument must be a mutable place, as for any
`inout` parameter ([Functions](/spec/06-functions/)); the C function receives its address:

```nex
var A: [real; :, :] = identity(4)
var b: [real; :, :] = ones((4, 1))
var ipiv: [int32] = zeros(4)
var info: int32 = 0
lapack_dgesv(4, 1, A, 4, ipiv, b, 4, info)
if info != 0
  eprint("dgesv failed")
```

**Strings** cross as a NUL-terminated copy that lives for the duration of the call. A C function
must not keep the pointer after it returns.

**No array is returned from C.** C writes results into an `inout` array the caller allocated.

**A read-mode array is a promise.** Passing an array in read mode promises the caller that C does
not write it. The compiler cannot check C code, and a C function that writes through a `const T *`
it was given breaks the value semantics of every binding that shares that array. When a C function
writes an argument, declare the parameter `inout`.

## 11.3 Complex numbers cross by value

A `complex[real64]` passes to and returns from C exactly as a `double _Complex` does in C, and a
`complex[real32]` as a `float _Complex`. nex follows the platform C compiler's convention on each
target — on arm64 a complex is two consecutive floating-point registers; on x86-64 (System V) a
`complex[real64]` is two SSE registers and a `complex[real32]` is packed into one — so no wrapper
is needed:

```nex
@pure @link("m")
extern def cexp(z: complex): complex

@pure @link("m")
extern def csqrt(z: complex): complex

val w = cexp(i * pi)                  // -1.0+0.0i, to rounding
val s = csqrt(-4.0 + 0.0i)            // 0.0+2.0i
```

Complex **arrays** cross as pointers to interleaved (re, im) pairs, C99's and BLAS's layout.

{{< note >}}
That complex arrays match the C99 and BLAS layout has not yet been verified against a running
program; the detail may change.
{{< /note >}}

## 11.4 `@c` structs

A struct declared `@c` has C's field order, alignment and padding. It crosses **by reference**: as
`const S *` in read mode and as `S *` when the parameter is `inout`.

```c
typedef struct {
    double  tol;
    int32_t max_iter;
    int32_t iters;       /* written by the solver */
    double  residual;    /* written by the solver */
} cg_options;

int32_t cg_solve(int32_t n, const double *A, const double *b, double *x, cg_options *opt);
```

```nex
@c
struct CgOptions
  tol: real
  max_iter: int32
  iters: int32
  residual: real
end

@link("cg")
extern def cg_solve(n: int32, A: [real; :, :], b: [real], x: inout [real],
                    opt: inout CgOptions): int32

// A: [real; :, :] is n×n, b: [real] has length n
var opt = CgOptions(1.0e-10, 500, 0, 0.0)
var x: [real] = zeros(n)
val rc = cg_solve(int32(n), A, b, x, opt)
print(opt.iters, opt.residual)
```

A struct **by value** — a C function that takes or returns `cg_options` itself rather than a
pointer to it — does not cross yet (§11.11).

## 11.5 Arrays: contiguity and the leading dimension

C receives a pointer to the first element and nothing else. What that pointer means — which
elements follow it, and how far apart — must be agreed between the two sides. nex arrays are
column-major and slices are views ([Values and memory](/spec/08-values-and-memory/)), so many views
can cross with no copy; the rest are copied silently, the same way an automatic clone is.

**Rank 1.** By default the parameter needs **unit stride**. A dense array or a contiguous slice
(`x[3..end]`) passes its pointer directly. A strided view (`x[1..n by 2]`) is copied into a dense
temporary before the call, and for an `inout` parameter copied back afterwards.

A parameter marked **`@strided`** passes any view as is, and the program passes the stride itself,
the way BLAS takes `incx`:

```nex
@link(framework = "Accelerate")
extern def cblas_ddot(n: int32, @strided x: [real], incx: int32,
                      @strided y: [real], incy: int32): real

val xs = x[1..end by 2]                   // every other element: a view
val ys = y[1..end by 2]
val d = cblas_ddot(int32(length(xs)), xs, int32(stride(xs, 1)),
                   ys, int32(stride(ys, 1)))
```

{{< note >}}
Writing `@strided` before the parameter name, as above, is a provisional spelling and may change.
{{< /note >}}

**Rank 2.** By default the parameter needs unit stride along the first axis — each column
contiguous — and accepts **any** stride between columns. That column stride is the **leading
dimension**, Fortran's and LAPACK's `lda`. A view that takes a block of rows and columns
(`m[1..3, :]`, `m[2..6, 1..4]`) crosses with no copy: its pointer is offset to its first element and
its leading dimension is the source matrix's. A view strided along the first axis
(`m[1..8 by 2, :]`) is copied first.

This is exactly how a Fortran program hands a submatrix to LAPACK. Solving with the 3×3 block of
`M` that starts at row 2, column 2, in place, with no copy:

```nex
var M: [real; :, :] = zeros((6, 6))
// … fill M …
var rhs: [real; :, :] = zeros((3, 1))
var ipiv: [int32] = zeros(3)
var info: int32 = 0

val ldm = int32(ld(M))                    // 6: the block's leading dimension is M's
lapack_dgesv(3, 1, M[2..4, 2..4], ldm, ipiv, rhs, 3, info)
```

**Rank 3 and higher.** The parameter needs a dense column-major array; any other view is copied
first.

The prelude gives the numbers C needs:

| Function | Result |
|---|---|
| `stride(a, k)` | the element stride of axis `k` (1-based axis number) |
| `ld(m)` | `stride(m, 2)` for a rank-2 array: its leading dimension |

{{< note >}}
The names `stride` and `ld` may change.
{{< /note >}}

## 11.6 Callbacks

A nex function passes where C wants a function pointer. An `extern` parameter of a function type
receives a C-callable entry point for the function named at the call:

```c
/* QUADPACK-style adaptive integrator */
double qags(double (*f)(double), double a, double b,
            double epsabs, double epsrel, double *abserr, int32_t *ier);
```

```nex
@link("quadpack")
extern def qags(f: (real) -> real, a: real, b: real,
                epsabs: real, epsrel: real,
                abserr: inout real, ier: inout int32): real

def gauss(x: real) = exp(-x * x)

var err = 0.0
var ier: int32 = 0
val area = qags(gauss, 0.0, 1.0, 1.0e-12, 1.0e-10, err, ier)   // ≈ 0.746824
val sinc = qags(x -> sin(x) / x, 1.0e-300, pi, 0.0, 1.0e-10, err, ier)
```

The callback's parameters follow the extern's convention: by value for a C extern, by reference
when the extern is declared `@fortran` (§11.7.2).

**A callback must not capture.** A named `def` or a lambda that refers only to its own parameters
and to module-level constants passes directly, as both calls above do. A lambda that **captures** a
local binding has no C function pointer to stand for it, because a C function pointer carries no
environment.

**Callbacks with user data: `c_ptr` and `@data`.** Many C libraries — QUADPACK wrappers, GSL, most
C ODE solvers — pass an opaque `void *` beside the function pointer and hand it back to every call of
the callback:

```c
double integrate(double (*f)(double x, void *data), void *data,
                 double a, double b, double epsabs, double epsrel);
```

nex spells that pointer **`c_ptr`**, the name Fortran's `iso_c_binding` gives it. `c_ptr` is an
opaque type: it is legal only in `extern` declarations, and it has no arithmetic and cannot be
dereferenced. The extern pairs the data parameter with its callback by writing `@data(f)` before
the type:

```nex
@link("quad")
extern def integrate(f: (real, c_ptr) -> real, data: @data(f) c_ptr,
                     a: real, b: real, epsabs: real, epsrel: real): real
```

A call passes an ordinary closure for `f` and **leaves `data` out**:

```nex
def main() =
  val k = 3.0
  val area = integrate(x -> sin(k * x), 0.0, pi, 0.0, 1.0e-10)   // captures k
  print(area)
```

The compiler generates the C entry point (a trampoline of the callback's C type), passes the
closure's environment as `data`, and the trampoline unpacks it and calls the closure. So a callback
that captures a model parameter needs no module-level variable. The closure is **borrowed for the
call**: it may be used only while the extern runs, and the extern must not keep it for later — a C
library that stores the pointer and calls it after returning is outside what nex supports.

Without `@data`, a callback must not capture, as Fortran requires of a procedure argument: passing
a capturing closure for a callback parameter that has no `@data` partner is a compile error.

**A trap inside a callback** — an out-of-bounds index, an integer overflow — unwinds to the nex
frame that made the extern call; the C frames between are abandoned.

{{< note >}}
Unwinding a trap through the C frames of a callback has not yet been verified; the detail may
change.
{{< /note >}}

## 11.7 Calling Fortran

nex shares Fortran's model — column-major arrays, 1-based indexing, inclusive ranges — so a Fortran
array argument needs no translation: a dense array or a leading-dimension view crosses with no copy,
and index `k` in nex is index `k` in Fortran. Two kinds of Fortran procedure can be called.

### 11.7.1 `bind(c)` procedures

A procedure with Fortran 2003's `bind(c)` attribute is a C function, and is declared as in §11.1.
`@symbol` gives the `bind(c, name=…)` name when it differs from the nex name:

```fortran
subroutine smooth(n, x, w) bind(c, name="nx_smooth")
  use iso_c_binding
  integer(c_int),  value         :: n
  real(c_double),  intent(inout) :: x(n)
  real(c_double),  value         :: w
  ! ...
end subroutine
```

```nex
@symbol("nx_smooth") @link("filters")
extern def smooth(n: int32, x: inout [real], w: real)

smooth(int32(length(signal)), signal, 0.25)
```

Give scalar dummy arguments the `value` attribute so they cross by value. A scalar dummy without
`value` is a pointer in C terms; declare it `inout` on the nex side, and pass a `var`.

### 11.7.2 Plain gfortran objects: `@fortran`

Most existing Fortran is not `bind(c)`: a `.o`, `.a` or `.so` compiled from ordinary Fortran 77 or
90. Declare such a procedure `@fortran`, and nex applies gfortran's conventions, so the declaration
reads like the Fortran interface:

```nex
@fortran @link("mylib")
extern def dgtsv(n: int32, nrhs: int32, dl: inout [real], d: inout [real], du: inout [real],
                 b: inout [real; :, :], ldb: int32, info: inout int32)

@fortran
extern def read_mesh(filename: string, nodes: inout [real; :, :], n: inout int32)
```

{{< note >}}
The `@fortran` spelling may change.
{{< /note >}}

What `@fortran` does:

1. **Name mangling.** The symbol is the lowercase name with a trailing underscore: `dgtsv` calls
   `dgtsv_`. `@symbol` overrides it, as for a module procedure, whose gfortran symbol is
   `__modname_MOD_procname`.
2. **Every argument by reference**, as Fortran passes it. A read-mode scalar passes the address of a
   temporary copy, so the caller's value cannot change; an `inout` scalar passes the address of the
   caller's place.
3. **Hidden string lengths.** Each `string` argument passes its pointer in place and its length as
   an extra trailing argument (`size_t`, gfortran 8 and later), in order after all the declared
   arguments. Fortran strings are not NUL-terminated, and nex adds no terminator. So `read_mesh`
   above is called, in C terms, as
   `read_mesh_(const char *filename, double *nodes, int32_t *n, size_t filename_len)`.
4. **Arrays** pass as for C (§11.5): column-major is native, so a dense array or a leading-dimension
   view crosses with no copy.
5. **Complex** is by reference like every other argument.

{{< note >}}
The convention for a Fortran `COMPLEX` *function result* follows gfortran's for the target and has
not yet been verified; the detail may change.
{{< /note >}}

Match the Fortran kinds exactly. A default `INTEGER` is 4 bytes: `int32`, not `integer`. `DOUBLE
PRECISION` and `REAL(8)` are `real`; a default `REAL` is `real32`; `COMPLEX(8)` is `complex`.

### 11.7.3 A worked example

An existing Fortran routine solves a tridiagonal system with the Thomas algorithm, overwriting
`d` and `b`:

```fortran
! tridiag.f90
subroutine trisolve(n, dl, d, du, b)
  integer,          intent(in)    :: n
  double precision, intent(in)    :: dl(n-1), du(n-1)
  double precision, intent(inout) :: d(n), b(n)
  integer :: k
  double precision :: m
  do k = 2, n
    m    = dl(k-1) / d(k-1)
    d(k) = d(k) - m * du(k-1)
    b(k) = b(k) - m * b(k-1)
  end do
  b(n) = b(n) / d(n)
  do k = n-1, 1, -1
    b(k) = (b(k) - du(k) * b(k+1)) / d(k)
  end do
end subroutine trisolve
```

Compile it into a library with gfortran, as it always has been:

```
gfortran -c -O2 tridiag.f90
ar rcs libtridiag.a tridiag.o
```

The nex side declares the interface and calls it. This solves `-u'' = 1` on (0, 1) with
`u(0) = u(1) = 0` by finite differences:

```nex
@fortran @link("tridiag")
extern def trisolve(n: int32, dl: [real], d: inout [real], du: [real], b: inout [real])

def main() =
  val n = 99
  val h = 1.0 / (n + 1)
  val off = fill(n - 1, -1.0)
  var diag = fill(n, 2.0)
  var u = fill(n, h * h)

  trisolve(int32(n), off, diag, off, u)    // u now holds the solution
  print(u[50])                             // 0.125: u(x) = x(1 - x)/2 at x = 0.5
```

`dl` and `du` are read-mode, so the same array `off` is passed for both; `diag` and `u` are `inout`,
so they must be `var` bindings, and two distinct ones. `trisolve` overwrites `diag` with its
elimination, exactly as the Fortran caller would expect.

Build it with the library's directory on the search path: `nex build -L . solve.nex`. Because the
program has a `@fortran` extern, `nex build` links the gfortran runtime itself, so Fortran code that
does its own I/O needs nothing more ([Command Line](/tooling/01-cli/)).

### 11.7.4 What does not cross

- **Assumed-shape dummies** (`a(:)`) of a procedure that is not `bind(c)`: they need gfortran's
  array descriptor.
- **Derived types.**
- **`optional` arguments.**

Each of these is reached through a small `bind(c)` wrapper written in Fortran, which takes explicit
extents and calls the original procedure.

BLAS and LAPACK are themselves Fortran libraries, and nex calls them through exactly these rules.

## 11.8 BLAS: what `@` dispatches

The matrix product `A @ B` ([Array expressions](/spec/05-array-expressions/)) normally compiles to
a fused loop nest. It becomes a BLAS call instead when **all** of these hold:

1. **The element type** is `real32`, `real64`, `complex[real32]` or `complex[real64]` (BLAS's `s`,
   `d`, `c`, `z`). Integer, `bool` and `real16` products never dispatch.
2. **Either** the product is large:

   | Product | Dispatches when |
   |---|---|
   | matrix–matrix, `m×k` times `k×n` | `m·k·n ≥ 64³` |
   | matrix–vector or vector–matrix | `m·k ≥ 128²` |
   | dot product of two length-`k` vectors | `k ≥ 4096` |

   **or** the operand shape is one the fused path cannot handle without materializing an operand:
   an operand that is `transpose(X)` or `conj(transpose(X))`, or a rank-2 view whose unit stride is
   along the second axis (a transposed layout). These become BLAS's `T` and `C` flags, so the
   transpose is never formed.
3. **A BLAS library is linked**: Accelerate on macOS, OpenBLAS elsewhere, through the LP64
   (`int32`) interface.

{{< note >}}
The size thresholds are provisional and will be set by measurement. Linking OpenBLAS on platforms
other than macOS has not yet been verified.
{{< /note >}}

The routine follows the shape: `gemm` for matrix–matrix, `gemv` for matrix–vector (with the `T`
flag for vector–matrix), and `dot` for two vectors — `dotu` for complex, because `@` does not
conjugate. The prelude's `dot(x, y)`, which conjugates `x`, uses `dotc`. With static extents the decision is made at compile time; with dynamic extents the
compiler emits both paths and a run-time test. Operands that break §11.5's stride rules are copied
first.

```nex
val G = transpose(A) @ A                  // gemm with the T flag; transpose(A) is never formed
val y = A @ x                             // gemv when large enough
val Hz = conj(transpose(Z)) @ z           // complex: the C flag
```

An update of the form `C = alpha * (A @ B) + beta * C`, assigned back to the same `C`, is one
`gemm` call using BLAS's `beta`.

{{< note >}}
Fusing `C = alpha * (A @ B) + beta * C` into a single `gemm` is provisional and may change.
{{< /note >}}

**A BLAS result may differ from the fused path in the last bits**, because BLAS sums in a different
order. To get the fused path everywhere — for a bit-for-bit comparison with an earlier run, say —
build with `--no-blas`:

```
nex build --no-blas model.nex
```

{{< note >}}
The flag's name `--no-blas` may change.
{{< /note >}}

To call a BLAS routine `@` does not cover, declare it with `extern def` as in §11.1 and §11.5.

## 11.9 LAPACK

The prelude reaches LAPACK for the dense linear-algebra kernels. Each function picks the routine for
its element type (`s`, `d`, `c`, `z`):

| Function | LAPACK | Result |
|---|---|---|
| `solve(A, b)` | `?gesv` | `x` with `A @ x == b`; `b` a vector or a matrix of right-hand sides |
| `lstsq(A, b)` | `?gelsd` | the least-squares solution `x` |
| `inv(A)` | `?getrf` + `?getri` | the inverse |
| `det(A)` | `?getrf` | the determinant; `0.0` for a singular matrix |
| `lu(A)` | `?getrf` | `(L, U, p)`, the pivoted factors |
| `chol(A)` | `?potrf` | the lower factor `L` of a symmetric (Hermitian) positive-definite `A`: `A == L @ conj(transpose(L))` |
| `chol(A, upper = true)` | `?potrf` | the upper factor `U`: `A == conj(transpose(U)) @ U` |
| `qr(A)` | `?geqrf` + `?orgqr` | `(Q, R)` |
| `eigvals(A)` | `?geev` | the eigenvalues of a general matrix, **always complex** |
| `eig(A)` | `?geev` | `(values, vectors)` of a general matrix, **always complex**; the vectors are the columns |
| `eigh(A)` | `?syevd` / `?heevd` | `(values, vectors)` of a symmetric (Hermitian) matrix; the values real, in ascending order |
| `svd(A)` | `?gesdd` | `(U, s, V)` with `A == U @ diag(s) @ conj(transpose(V))` |
| `svdvals(A)` | `?gesdd` | the singular values `s`, in descending order |

Pivot indices, as `lu_inplace` takes them, are `[int32]`, LAPACK's own integer type.

Column-major storage means LAPACK receives the arrays as they are, with no transposes, and views
follow §11.5's leading-dimension rules.

### 11.9.1 Value forms trap

The functions above take values and return values. Because LAPACK overwrites its inputs, they copy
them first, so the caller's arrays are untouched. When LAPACK's `info` reports a failure, a value
form **traps** with a message naming the function and the cause in mathematical terms:

```
solve: matrix is singular (U[3,3] = 0)
chol: matrix is not positive definite (leading minor 4)
svd: did not converge
```

The indices in a message are 1-based, as LAPACK's `info` already is, and as nex's arrays are.

```nex
val A = [[4.0, 1.0, 0.0],
         [1.0, 4.0, 1.0],
         [0.0, 1.0, 4.0]]
val b = [1.0, 2.0, 3.0]

val x = solve(A, b)
val (Q, R) = qr(A)
val (U, s, V) = svd(A)
val L = chol(A)                     // A == L @ transpose(L)
val (lambda, X) = eigh(A)           // lambda ascending; A @ X[:, k] == lambda[k] * X[:, k]
```

`eig` and `eigvals` return complex eigenvalues even for a real matrix, since a general real matrix
may have complex ones; for a symmetric matrix such as this `A`, `eigh` is the right call and its
eigenvalues are real.

Only the solvers trap on a singular matrix. `det` of a singular matrix is `0.0`, since zero is the
right answer and not a failure.

### 11.9.2 `inout` forms return `info`

The `inout` forms factor in place, with no copy — `lu_inplace(A, ipiv)`, `chol_inplace(A)`,
`qr_inplace(A, tau)`, and so on — and **do not trap**. They return LAPACK's `info` as an `integer`:
zero on success, positive for a numerical failure, for the code that wants to handle a singular or
indefinite matrix itself.

The standard test for positive definiteness is to attempt a Cholesky factorization. A trap would be
the wrong answer here, since "no" is an expected result:

```nex
def is_positive_definite(A: [real; :, :]): bool =
  var work = A                            // a copy: chol_inplace overwrites it
  chol_inplace(work) == 0

val K = [[ 2.0, -1.0,  0.0],
         [-1.0,  2.0, -1.0],
         [ 0.0, -1.0,  2.0]]
print(is_positive_definite(K))            // true
print(is_positive_definite(-K))           // false
```

When the factor itself is wanted, keep it and read `info`:

```nex
var L = K
val info = chol_inplace(L)
if info > 0
  eprint("not positive definite: leading minor", info)
```

## 11.10 Any type, any rank: `[*; ..]`

A C library with one entry point for every element type — MPI's `send`, HDF5's `write`, a PETSc
vector — is declared once with a **`[*; ..]`** parameter: any array of numbers or `bool`, at any
rank, or a single such value. It is Fortran 2018's `type(*), dimension(..)`: `*` for the element
type, `..` for the axes. C receives a **descriptor** of the argument, as a `bind(c)` Fortran
procedure receives a `CFI_cdesc_t`:

```nex
@link("mylib")
extern def lib_write(x: [*; ..], tag: int32)
@link("mylib")
extern def lib_read(x: inout [*; ..], tag: int32)

def write[T: Numeric, R: Rank](x: [T; R], tag: integer = 0) = lib_write(x, int32(tag))

def main() =
  write([1.0, 2.0, 3.0])                       // real64, rank 1
  write(reshape([1, 2, 3, 4], 2, 2)[:, 2])     // int64, a column
  lib_write(2.5i, 7)                           // complex[real64], rank 0
  var m: [real32; :, :] = zeros((4, 4))
  lib_read(m[2..3, 4..1 by -1], 1)             // C writes where the view lies
```

```c
#include "nex_desc.h"

void lib_write(const nex_desc *x, int32_t tag) {
    /* x->type is NEX_REAL64, NEX_INT64, … ; x->rank axes in x->dim[], nex's first axis first */
    int64_t n = nex_desc_count(x);
    ...
}
```

**The descriptor** is `nex_desc`, from the header `nex_desc.h` that nex ships (`include/` in its
source tree):

| field | meaning |
|---|---|
| `void *base` | the first element of the argument as it lies (index 1 along every axis) |
| `int64_t elem_size` | bytes of one element |
| `int32_t type` | the element type: `NEX_INT8` … `NEX_UINT64`, `NEX_REAL16`, `NEX_REAL32`, `NEX_REAL64`, `NEX_COMPLEX_REAL16`, `NEX_COMPLEX_REAL32`, `NEX_COMPLEX_REAL64`, `NEX_BOOL` |
| `int32_t rank` | the number of axes; 0 for a scalar |
| `int32_t contiguous` | 1 where the elements are one dense column-major block |
| `int32_t writable` | 1 where the parameter is `inout` |
| `nex_dim dim[rank]` | per axis, `extent` (elements) and `stride` (**bytes**, negative for a reversed view) |

Element (i₀, i₁, …), counting from 0, is at `(char *)base + i₀ * dim[0].stride + i₁ * dim[1].stride
+ …`; the header's `nex_desc_at` computes the address and `nex_desc_count` the number of elements.
The fields follow `CFI_cdesc_t` where the two agree — `base_addr`, `elem_len`, `extent`, `sm` in bytes,
the first axis first — so C written against Fortran's descriptor reads nex's with little change.

- **Every view crosses where it lies, with no copy**: a window of a matrix, a row, a strided view, a
  reversed one. The strides say how to walk it; a C routine that needs a flat buffer checks
  `contiguous` and copies only when it is 0. `@strided` (§11.5) has nothing to add and is refused here.
- **A scalar is rank 0**, `base` pointing at it. An `inout` scalar may be a `var` or a field of one.
- **A measured value crosses as its numbers**, no `strip` needed: the descriptor carries no unit.
- **A generic body passes its `[T; R]` or `T`** where `T`'s constraint admits only numbers (`Numeric`,
  `Float`, `Integral`, `Real`, `Complex`); each instance describes its own element type and rank.
- **`inout` makes the argument writable**, borrowed for the call like any `inout` argument; C writes
  through `base` into exactly the elements the view names.
- **The descriptor and its memory are valid for the call only.** A C function must not keep either
  after it returns.

A `[*; ..]` parameter refuses a `string`, a struct (a `@c` one too), a tuple, an enum, a function,
or an array of any of these. Only a C `extern`'s parameter may be `[*; ..]` — not a `def`'s, whose
generic form is `[T; R]`; not a result, a variable or a callback's parameter; not a `@fortran`
extern's, since a plain Fortran procedure takes no descriptor; not a `@host` function's. `[*]` and
`[real; ..]` are not types: the two wildcards go together. Like every `extern`, it runs compiled only.

## 11.11 Not yet

These are decided directions that the first language does not include:

- **Structs by value** across the FFI, in either direction. `@c` structs cross by reference only
  (§11.4).
- **Banded and tridiagonal LAPACK solvers** (`?gbsv`, `?gtsv` and their kin) in the prelude. They
  can be called directly through `extern def` or `@fortran` today.
- **Generalized eigenproblems** (`A x = λ B x`).
- **`rcond` / `cond`**, condition-number estimates.

The full list is in the [Later](/spec/appendix-later/) appendix.
