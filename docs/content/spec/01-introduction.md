---
title: Introduction
summary: What nex is, what it is for, how this specification is written, and a first complete program.
weight: 10
---

## 1.1 What nex is

nex is an array-first numerical language for scientists and engineers who write Fortran. Its
summary is **Fortran's model, modern syntax, compiler-enforced safety, ahead-of-time native
binaries.**

It keeps what a Fortran programmer relies on:

- **column-major storage** and **1-based arrays** of any rank;
- **inclusive ranges**: `a[2..5]` is Fortran's `a(2:5)`, four elements;
- the **`iso_fortran_env` type names**: `int32`, `real64`, `complex[real64]` (Fortran's
  `complex(real64)`);
- **whole-array expressions** that compile to fused loops, with no temporary arrays.

It adds what Fortran leaves to discipline:

- **value semantics**, enforced by `val` and `var` bindings and a uniqueness rule: two names never
  silently share a mutable array;
- **`inout` parameters**, an exclusive borrow the compiler checks, so a procedure that modifies its
  argument cannot alias another argument;
- **slices that are views**, read-only, with no copy;
- **explicit parallelism** (`parallel for`, `parallel map`) that the compiler proves race-free, and
  **reductions whose result is the same for every thread count**;
- **trapping integer overflow and bounds checks** rather than undefined behaviour;
- a syntax in the indentation-based style of Scala 3, with type inference.

C libraries, BLAS, LAPACK and existing Fortran code are reachable through `extern def`
declarations, and the matrix product `@` calls BLAS when that pays
([chapter 11](/spec/11-interop/)).

**nex is always compiled.** The compiler translates a program through MLIR to a native binary. There
is no interpreter: `nex run` compiles the program and then runs the binary.

## 1.2 Design goals

- **A Fortran reader is at home.** Indexing, storage order, ranges and type names mean what they
  mean in Fortran. Where nex differs from Fortran, this specification says so in place.
- **Mathematics reads as mathematics.** `2pi * x`, `3 + 4i`, `a @ b`, `y = alpha * x + y`.
- **Precision is never lost silently.** The default real is 64-bit; a narrowing assignment is a
  compile error, not a rounding ([§3.6](/spec/03-types/)).
- **Performance is predictable.** Array expressions fuse; slices do not copy; an allocation is
  visible in the source.
- **Errors are found early and stop loudly.** What the compiler can prove it checks at compile time.
  What depends on run-time values (an index out of bounds, an integer overflow, a shape mismatch)
  *traps*: the program stops with a message naming the failure.
- **Results are reproducible.** A parallel reduction gives the same bits on one thread as on
  sixty-four.

nex is not a general-purpose systems or application language. It has no classes, no inheritance and
no dynamic dispatch.

## 1.3 Notation

**Code** is set in a fixed-width font. A comment in an example often states the result:

```nex
val m = [[1.0, 2.0],
         [3.0, 4.0]]       // [real; :, :], shape (2, 2)
print(m[2, 1])             // 3.0
```

**Grammar** is written in a light EBNF: `::=` defines a rule, `|` separates alternatives, `( … )*`
means zero or more repetitions, `?` marks an optional part, and quoted text is literal.

```
array-type ::= '[' element-type ']'
             | '[' element-type ';' axes ']'
```

**Three kinds of failure** are distinguished throughout:

- a **compile error** is reported by the compiler, and no binary is produced;
- a **trap** stops the running program with a message (`out of bounds`, `integer overflow`,
  `shape mismatch`);
- IEEE floating-point results such as infinity and NaN are **values**, not failures.

**Section references** take the form §3.6 for section 6 of chapter 3.

{{< note >}}
A few rules in this specification are marked as **subject to change**. They are complete and
implemented as described, but the exact detail may still change. Every such rule carries a note like
this one.
{{< /note >}}

## 1.4 A first program

This program solves the heat equation `u_t = u_xx` on the interval `[0, 1]`, with `u = 0` at both
ends and `u(x, 0) = sin(πx)`, by explicit time stepping, and compares the result with the exact
solution `exp(−π²t) sin(πx)`:

```nex
// One explicit step of the heat equation on the interior points.
def step(u: inout [real], r: real) =
  u[2..end-1] = u[2..end-1] + r * (u[1..end-2] - 2.0 * u[2..end-1] + u[3..end])

def main() =
  val n = 101
  val x = linspace(0.0, 1.0, n)
  val dx = 1.0 / (n - 1)
  val dt = 0.4 * dx^2                 // r = dt / dx^2 = 0.4; the scheme is stable for r <= 1/2
  val steps = 500

  var u = sin(pi * x)
  for k in 1..steps do step(u, dt / dx^2)

  val exact = exp(-steps * dt * pi^2) * sin(pi * x)
  val err = maxval(abs(u - exact))
  print(s"max error after $steps steps: $err")
```

Points to notice, each explained in its own chapter:

- `main` is the program's entry point.
- `[real]` is a rank-1 array of `real`, which is a 64-bit real (Fortran's `real(real64)`).
- `u: inout [real]` lets `step` modify the caller's array in place. The call `step(u, …)` carries no
  marker, as in Fortran; the compiler checks that `u` is a `var` and that nothing else aliases it
  ([chapter 6](/spec/06-functions/)).
- `u[2..end-1]` is the interior, Fortran's `u(2:n-1)`. `end` inside a subscript is the last index of
  that axis ([chapter 4](/spec/04-arrays/)).
- The update is one whole-array expression: it compiles to a single loop with no temporaries
  ([chapter 5](/spec/05-array-expressions/)).
- `1.0 / (n - 1)` divides a real by an integer and gives a real; `dx^2` raises to an integer power.
- `sin`, `exp` and `abs` are elemental: applied to an array they apply to every element, and fuse
  into the surrounding expression ([chapter 12](/spec/12-prelude/)); `pi` is a prelude constant.
- `maxval` is the largest element, Fortran's `MAXVAL`.
- `s"…"` is an interpolated string.

`nex run heat.nex` compiles this file and runs the result.

## 1.5 The prelude

Every program and module sees the **prelude** without importing it: the constants `pi`, `e`,
`inf`, `nan` and `i`; the numeric type names and their conversion functions (`real32(x)`,
`int64(n)`); the mathematical functions (`sqrt`, `exp`, `sin`, …); the array constructors and shape
functions (`zeros`, `linspace`, `extent`, `reshape`, …); the reductions (`sum`, `maxval`, …); and
`print`. [Chapter 12](/spec/12-prelude/) lists it.

Prelude names are ordinary names, not keywords. A local binding with the same name shadows the
prelude's within its scope; the usual case is a loop index named `i`, which hides the imaginary unit
([§2.8](/spec/02-lexical/)).
