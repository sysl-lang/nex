---
title: Types
summary: The sized numeric types, promotion and conversion, bool, string and unit, tuples, structs, sum types, function types, and array types.
weight: 30
---

## 3.1 The numeric types

| Type | Meaning |
|---|---|
| `int8`, `int16`, `int32`, `int64` | signed two's-complement integers |
| `uint8`, `uint16`, `uint32`, `uint64` | unsigned integers |
| `real16`, `real32`, `real64` | IEEE 754 binary16, binary32, binary64 |
| `complex[real16]`, `complex[real32]`, `complex[real64]` | a pair (re, im) of that real type |
| `integer` | the same type as `int64` |
| `real` | the same type as `real64` |
| `complex` | the same type as `complex[real64]` |

**The names are Fortran's `iso_fortran_env` kind names**, and the number counts **bits**: `int32`
is Fortran's `integer(int32)`, `real64` is `real(real64)`. A complex type names the kind of its
**part**, as Fortran does: `complex[real32]` is two `real32`s, Fortran's `complex(real32)`.

`integer`, `real` and `complex` are **aliases**, not distinct types: `[real]` and `[real64]` are one
type. A compiler message names a type the way the source spelled it.

There is no `byte` type. Raw bytes are `[uint8]`, an ordinary array with every array operation.
There is no `bfloat16`; the name is reserved.

## 3.2 Default precision

**The defaults are 64-bit.** `integer` is `int64`, `real` is `real64`, `complex` is
`complex[real64]`, and an unadorned literal is 64-bit (§3.7).

This is a deliberate difference from Fortran, whose default `real` is single precision. A forgotten
`d0` or `kind=` has cost generations of Fortran programs their accuracy; in nex the default is what
Fortran calls double precision, and a program that wants single precision says `real32`. Single
precision is fully supported, not an afterthought: a `real32` kernel stays `real32` (§3.6).

## 3.3 Integers

The signed types `int8` … `int64` and the unsigned types `uint8` … `uint64` cover every integer
that C, BLAS and LAPACK (32-bit for LP64, 64-bit for ILP64) and file formats exchange, so an
`extern` declaration can spell any C or Fortran integer parameter
([chapter 11](/spec/11-interop/)). Fortran has no unsigned integers; nex has them for exactly that
interchange.

**Integer arithmetic traps on overflow, at every width, signed and unsigned.** A result that does
not fit its type stops the program with `integer overflow` instead of wrapping:

```nex
val a: int8 = 127
val b = a + 1          // traps: 128 does not fit an int8

val u: uint32 = 0
val v = u - 1          // traps: an unsigned result below zero is an overflow
```

Fortran leaves overflow undefined; nex defines it as a trap.

**Signed and unsigned of the same width do not mix.** `int32 + uint32` is a compile error, because
neither type holds the other's range; convert one side explicitly (`int32(u) + n`). An unsigned type
does mix with a strictly wider signed type: `uint8 + int16` is an `int16` (§3.6).

`/` on two integers is real division and gives a `real64`. Integer division is `div`, which
truncates toward zero; `%` is the remainder (Fortran's `mod`). Both take two integers and give the
wider type. Integer division by zero traps.

## 3.4 Reals

`real64` is Fortran's `double precision`, and the default. `real32` is single precision, the width
of single-precision BLAS and memory-bound kernels. `real16` is IEEE half precision, chiefly a
storage width for large data sets.

**Arithmetic is IEEE 754 at the operands' own width.** A `real32` operation is a binary32 operation;
it is never computed in 64 bits and rounded afterwards. Overflow gives infinity and an invalid
operation gives NaN, as IEEE specifies; these are values, not traps. Real division by zero gives an
infinity (`1.0 / 0.0` is `inf`, `0.0 / 0.0` is `nan`); only integer division by zero traps.

`nex build --fpe-trap` turns the three IEEE exceptions that usually mean a bug — division by zero,
an invalid operation and overflow — into traps, like gfortran's `-ffpe-trap=zero,invalid,overflow`
([Command Line](/tooling/01-cli/)).

{{< note >}}
`sqrt` of a `real16` is computed natively. The other transcendental functions of a `real16` are
computed in `real32` and rounded to `real16`. This detail may change.
{{< /note >}}

## 3.5 Complex numbers

A `complex[realN]` is a pair of `realN` values, its real and imaginary parts, stored as two adjacent
`realN`s, the layout of Fortran's `complex` and of C's `_Complex`. `z.re` and `z.im` are the parts,
and `abs(z)` and `arg(z)` the modulus and argument.

`complex[real32]` is what LAPACK's `c` routines take and `complex[real64]` what its `z` routines
take. Because the type names its part, `real32` promotes to `complex[real32]` with no change of
width.

Complex values are written with the imaginary unit `i` ([§2.8](/spec/02-lexical/)): `3.0 + 4.0i`.
A complex value prints as its two parts: `3.0+4.0i`.

## 3.6 Promotion

The numeric types form a lattice. Every arrow is an **implicit widening**, which never loses a
value:

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

A widening happens where a value meets an expected type: an operand of an arithmetic or comparison
operator, an argument passed to a parameter, and a value bound or assigned to an annotated binding,
a field, an element or a return type. **Every conversion that does not follow the arrows is
narrowing**, and is never implicit (§3.8).

**The type of a binary operation** (`+`, `-`, `*`, `^`, the comparisons, and their element-wise
forms on arrays) with operands of types `A` and `B`:

1. **Same type**: that type.
2. **Both in one family** (signed integers, unsigned integers, reals, or complexes): the wider.
3. **A signed and an unsigned integer**: the signed type if it is strictly wider (`uint8 + int16` is
   `int16`); otherwise a compile error asking for a conversion.
4. **An integer and a real or complex**: **the real or complex operand's type**. With `n: int64` and
   `x: real32`, `n * x` is a `real32`. As in Fortran, a loop index never widens a single-precision
   kernel.
5. **A real and a complex**: the complex type of the wider width. `real64 + complex[real32]` is
   `complex[real64]`.

`/` on two integers gives `real64`; on an integer and a `realN` it gives `realN`. `^` with an
integer exponent keeps the base's type.

### 3.6.1 Scalars and arrays

**A typed scalar promotes an array, as in Fortran.** With `x: real64` and `a: [real32]`, `x * a` is
a `[real64]`, computed element by element at the wider width. A **literal is not a typed scalar**:
it adapts to the array (§3.7), so `2.0 * a` stays `[real32]`.

**Storing a promoted result back into a narrower array is a compile error**, not a silent rounding:

```nex
def damp(a: inout [real32], x: real64) =
  a = x * a                  // compile error: a [real64] value cannot be stored in a [real32]
  a = real32(x) * a          // round x first, then compute in real32
  a = real32(x * a)          // compute in real64, then round each element
```

Fortran would round silently on the assignment; nex makes the program say which rounding it means.
The same holds for scalars: `val y: real32 = x` with `x: real64` is a compile error.

**Whole arrays never convert implicitly.** A `[real32]` does not pass where a `[real64]` is
expected; `real64(a)` converts it, and the allocation that makes is visible in the source. Mixed
widths inside one element-wise expression are fine: `a32 + b64` is a `[real64]` computed in one
fused loop, with no converted copy of `a32`.

## 3.7 Literals and the prelude constants

A numeric literal has no type of its own until its context gives it one:

- **With an expected type** (an annotated binding, a parameter, a typed element or field), the
  literal is that type. An integer literal out of the type's range is a compile error
  (`val b: int8 = 300`, `val u: uint8 = -1`). A real literal is rounded to the nearest value of
  the target width; one that rounds to infinity is a compile error (`val h: real16 = 70000.0`). An
  integer literal may initialize a real or a complex: `val x: real32 = 1`.
- **Beside a typed operand**, an integer literal takes the operand's type when that is an integer,
  real or complex type, and a real literal takes it when that is a real or complex type. So
  `x32 * 2.0` is a `real32`, `u + 1` with `u: uint32` is a `uint32`, and `x8 + 1` with `x8: int8` is
  an `int8` (and traps when `x8` is 127). The same holds beside an array: `2.0 * a32` is a
  `[real32]`. A real literal beside an integer (`n + 0.5`) is a `real64`.
- **With no context**, an integer literal is an `integer` and a real literal a `real`, both 64-bit.

This is why nex needs no kind suffixes: `0.1` in a `real32` expression is the `real32` nearest 0.1,
not a `real64` rounded later, and there is no `0.1_real32` or `0.1d0` to forget.

**The prelude constants `pi`, `e`, `inf`, `nan` and `i` are typed like literals.** Each takes the
width its context asks for: beside a `real32`, `pi` is a `real32` and `i` a `complex[real32]`. With
no context, `pi`, `e`, `inf` and `nan` are `real64` and `i` is `complex[real64]`. So `2pi * x32`
stays a `real32` computation.

{{< note >}}
The context-dependent typing of the prelude constants may change in detail.
{{< /note >}}

## 3.8 Conversions

Every numeric type name is also its **conversion function**, on a scalar and element-wise on an
array: `real32(x)`, `int16(n)`, `uint8(k)`, `real64(a)`, `complex[real32](z)`, and
`complex[real32](re, im)` from two parts.

| From → to | Behaviour |
|---|---|
| integer → narrower integer, signed ↔ unsigned | exact, or **traps** if the value is out of range (`uint32(-1)` traps) |
| real → integer | truncates toward zero; **traps** on NaN, infinity or out of range |
| real → narrower real | rounds to nearest, ties to even; overflow gives ±infinity |
| complex → narrower complex | each part as real → real |
| complex → real or integer | not a conversion: take `z.re`, `abs(z)` or `arg(z)` first |
| any widening | the implicit widening of §3.6, also callable explicitly |

Unlike Fortran's `int()` and `real(x, kind)`, a conversion that cannot represent its value traps
instead of producing an undefined result. `to_real`, `to_integer` and `to_complex` are the
conversions to `real`, `integer` and `complex`.

## 3.9 Printing at each width

`print` and string interpolation show a real as the shortest decimal that reads back to the same
value at that real's own width: the `real32` nearest 0.3 prints as `0.3`, not as the digits of its
64-bit expansion. A whole real prints with `.0` (`9.0`), and a complex prints as its two parts
(`3.0+4.0i`).

{{< note >}}
Shortest-form printing for `real32` and `real16` may change in detail.
{{< /note >}}

## 3.10 `bool`, `string` and `unit`

| Type | Values |
|---|---|
| `bool` | `true` and `false` (Fortran's `logical`) |
| `string` | immutable UTF-8 text |
| `unit` | the single value `()`, the result of a function that returns nothing useful |

Strings compare by content. A function with no declared result whose body ends in a statement returns `unit`; it plays the
part of a Fortran `subroutine`.

## 3.11 Tuples

A tuple type is a fixed list of two or more types, written with commas: `real, real` or
`(integer, [real], complex)`. Tuples are how a function returns several values, where Fortran would
use several `intent(out)` arguments; nex has no `out` mode:

```nex
def minmax(a: [real]): (real, real) = (minval(a), maxval(a))

val (lo, hi) = minmax(samples)
val t = minmax(samples)
t.1                               // the first field, lo
t.2                               // the second, hi
```

Destructuring, `val (lo, hi) = …`, is the usual way to take a tuple apart. A field may also be read by
position with `.` and a number, counted from 1 like every index in nex.

The parentheses around a tuple type are optional except where commas already separate something
else, as in a parameter list: `def join(p: (real, real), q: (real, real))` takes two tuples.

## 3.12 Structs

A struct is a named record of fields, Fortran's derived `type`:

```nex
struct Particle
  pos: [real; 3]
  vel: [real; 3]
  mass: real
end Particle

val p = Particle([0.0, 0.0, 0.0], [1.0, 0.0, 0.0], 2.0)
val ke = 0.5 * p.mass * sum(p.vel * p.vel)
```

A struct is constructed by naming it with its fields in declaration order, and a field is read with
`.`. A struct is a value: after `var q = p`, changing `q` never changes `p`. A field of
a `var` struct may be assigned (`q.mass = 3.0`). Structs carry data only: no methods, no
inheritance, no constructors besides the field list.

A struct may take **type parameters**, inferred from the constructor's arguments:

```nex
struct Pair[A, B]
  first: A
  second: B
end Pair

val p = Pair(1, "one")                  // Pair[integer, string]
val q: Pair[real32, real32] = Pair(1.0, 2.0)
```

A type parameter may carry a bound such as `[T: Float]` (the bounds are listed in
[chapter 6](/spec/06-functions/)).

## 3.13 Sum types

A sum type, declared with `enum`, is a value that is exactly one of several **variants**. A variant
is a bare name or a constructor with named fields:

```nex
enum Outcome =
  Converged(x: real, iters: integer)
  Diverged
  MaxIters(last: real)

def report(r: Outcome): string =
  r match
    Converged(x, n) -> s"converged to $x in $n iterations"
    Diverged        -> "diverged"
    MaxIters(last)  -> s"stopped at $last"
```

A bare variant (`Diverged`) is a value; a variant with fields is called like a function
(`Converged(1.414, 6)`). `match` takes a sum-type value apart
([chapter 7](/spec/07-control-flow/)). Fortran has no direct
counterpart; it is what a status code plus several `intent(out)` arguments approximates.

A sum type may take type parameters like a struct:

```nex
enum Opt[T] =
  Some(value: T)
  None

val found = Some(42)                 // Opt[integer]
val missing: Opt[integer] = None     // a bare variant needs its type from context
```

## 3.14 Function types

A function type is written `(T1, …, Tn) -> R`; a function of one parameter may drop the parentheses:

```nex
real -> real
(real, real) -> real
([real], real -> real) -> [real]
```

A parameter mode is part of the type. A function that modifies its first argument in place has an
`inout` in its type, spelled as in its declaration:

```nex
def scale(v: inout [real], s: real) =
  v = v * s

val f: (inout [real], real) -> unit = scale
```

A function with an `inout` parameter cannot stand where a function type without it is expected, nor
the reverse. Function values are passed as arguments, returned, and stored in bindings and fields;
a function literal is written `x -> x^2` or `(x, y) -> x * y`
([chapter 6](/spec/06-functions/)).

## 3.15 Array types

An array type names its element type and, after a `;`, one entry per axis: `:` for an extent known
only at run time, or an integer (or a `const` name) for an extent known at compile time.

```nex
[real]               // rank 1, the same type as [real; :]
[real; :, :]         // rank 2, any shape
[real; :, :, :]      // rank 3
[real; 3, 3]         // rank 2, static shape 3 × 3
[complex; N]         // rank 1, extent the const N
```

The rank is the number of axes, and it is always known at compile time. Arrays are 1-based on every
axis and stored in column-major order, as in Fortran. The element type may be any type but an
array: numeric types, `bool`, and structs and tuples of scalars are stored inline, strings and other
heap values as handles. `[[real]]` is not a type, since a matrix is `[real; :, :]`. The full treatment of arrays, their
literals, indexing and views is in [chapter 4](/spec/04-arrays/).

{{< note >}}
An array type that mixes static and run-time axes, such as `[real32; 3, :]`, may change.
{{< /note >}}

## 3.16 Static and dynamic shapes

A static extent is checked at compile time wherever both sides are static: element-wise operands,
the inner dimension of `@`, slice assignment, and an argument against its parameter. A mismatch there
is a compile error.

Shapes convert in both directions between types of the **same rank**:

- **Static to dynamic is implicit and free.** A `[real; 3, 3]` passes where a `[real; :, :]` is
  expected.
- **Dynamic to static is implicit and checked at run time.** At a binding, an argument or a return,
  a `[real; :, :]` converts to a `[real; 3, 3]`, and the program **traps** with `shape mismatch` if
  the extents differ. Only a dynamic side can trap: two static shapes that differ are always a
  compile error.

```nex
def det3(m: [real; 3, 3]): real =
  m[1, 1] * (m[2, 2] * m[3, 3] - m[2, 3] * m[3, 2]) -
  m[1, 2] * (m[2, 1] * m[3, 3] - m[2, 3] * m[3, 1]) +
  m[1, 3] * (m[2, 1] * m[3, 2] - m[2, 2] * m[3, 1])

val a = reshape(linspace(1.0, 9.0, 9), (3, 3))   // [real; :, :]
val d = det3(a)                                  // checked: a is 3 × 3
val b = reshape(linspace(1.0, 4.0, 4), (2, 2))
val d2 = det3(b)                                 // traps: shape mismatch
```

Rank never converts: passing a rank-2 array where a rank-1 array is expected is a compile error, and
element-wise operations never broadcast one rank against another. A scalar combines with an array of
any rank.

An array literal has a dynamic shape unless its binding is annotated: `val v = [1.0, 2.0]` is a
`[real; :]`, so a `var` bound to it may later be assigned a longer array, while
`val w: [real; 2] = [1.0, 2.0]` is static.

{{< note >}}
That an unannotated array literal is dynamically shaped may change.
{{< /note >}}

## 3.17 Types with units

A real or complex type may carry a unit of measure, written in angle brackets directly after the
type name: `real<m>`, `real32<m/s>`, `complex<V>`, and as an array's element type,
`[real<Pa>; :, :]`. Plain `real` is dimensionless. A value of one unit converts to another unit of
the same dimension (`mm` to `in`), never to another dimension (`in` to `lbf`), and the units vanish
before code is generated. [Units of measure](/spec/13-units/) has the rules.

```nex
val g: real<m/s^2> = 9.81<m/s^2>
val heights: [real<mm>] = [12.0, 15.5, 9.25] * 1.0<mm>
```
