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

`bool`, `void` and `string` are as in ref §3.1, `void` being the type the reference calls `unit`. The aliases are the same type, not a distinct one:
`[real]` and `[real64]` are one type, and a diagnostic names a type the way the source spelled it.
A type the source never wrote, that of an inferred binding or of an intermediate result, is named
by its full name: `int64`, `real64`, `complex[real64]`.

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
such as `1.0f32` would read as juxtaposition (`1.0 * f32`, ref §4.4). The one name a literal is
written against that is not a multiplication is a unit's: `10mm` is `10<mm>` (§13.2).

- **With an expected type** (an annotated binding, a parameter, a typed element or field): the
  literal is that type. An integer literal outside the target's range is a compile error
  (`val b: int8 = 300`, `val u: uint8 = -1`). An integer literal's value is its magnitude in every
  base, never a bit pattern: `0xFF` is 255, so `val y: int8 = 0xFF` is refused, and
  `0xFFFF_FFFF_FFFF_FFFF` initializes a `uint64` and no signed type. A literal is at most 64 bits. A real literal is rounded to the nearest value of the target width;
  one that rounds to infinity is a compile error (`val h: real16 = 70000.0`). An integer literal
  may initialize a real or complex (`val x: real32 = 1`), as ref §3.2 allows.
- **As an operand of a binary operator whose other operand has a type:** an integer literal adopts
  that type if it is an integer, real or complex type; a real literal adopts it if it is a real or
  complex type, and otherwise (`n + 0.5` with `n` an integer) is `real64`. So `x32 * 2.0` is
  `real32`, `x8 + 1` is `int8` (and traps when `x8` is 127), and `u + 1` with `u: uint32` is
  `uint32`. The same holds when the other operand is an array: `2.0 * a32` is `[real32]`.
- **With no context:** an integer literal is `int64`, a real literal `real64` (ref §2.4).

**A literal is any expression made only of literals and prelude constants** — `2`, `-0.5`, `2pi`,
`3 + 4i` — and it adopts as a whole, so `2pi * x32` is `real32` throughout. The same adoption reaches
every place two values meet in one type: the branches of an `if` used as a value (`if c then x32 else
1` is `real32`; the branches meet in their common type, as the operands of `+` do), the arguments
of `min`, `max`, `atan2` and `hypot`, and a chained comparison, whose literal operands take the
common type of its other operands (`0 < n32 < x64` compares `0` as a `real64`). A minus written
on a literal is part of it, so `val b: int8 = -128` holds.

**The prelude constants `pi`, `e`, `inf`, `nan` and `i` are typed like literals** (**PROPOSED**):
each adopts the width its context asks for (`pi` is `real32` beside a `real32`, `i` is `complex[real32]`
beside a `real32`), and with no context `pi`, `e`, `inf`, `nan` are `real64` and `i` is
`complex[real64]`. Without this, `2pi * x32` would silently widen a `real32` kernel to `real64`.

### 2.4 Conversions

Every numeric type name is also its conversion function, on a scalar and element-wise on an array:
`real32(x)`, `int16(n)`, `uint8(k)`, `complex[real32](z)`, `complex[real32](re, im)`,
`real64(a)`. In the two-argument form each part converts as `real32(re)` would, and either part may
be an array, the other then an array of the same shape or a scalar that broadcasts.

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
- `div` and `%` truncate toward zero, as Fortran's integer `/` and `MOD` do: `-7 div 2` is `-3` and
  `-7 % 2` is `-1`. A zero divisor traps, and so does the one quotient out of range, the signed
  minimum `div -1`; the minimum `% -1` is `0`.
- **An integer power keeps the base's type and traps on overflow**, at every width. A negative
  exponent divides, as Fortran's `**` does: `2 ^ -1` is `0`, `1 ^ -n` is `1`, `(-1) ^ -n` is `1` or
  `-1` by the parity of `n`, and `0 ^ -n` traps as a division by zero.
- **A trap's message names what failed**: `int8 overflow` (the type whose range was left, `uint8
  overflow` for going below zero too), `integer division by zero`, `` `%` by zero ``, `complex division by
  zero`, `int64 value out of range for uint32` and `real64 value out of range for int32` (a
  conversion, NaN and infinities included), `` a `for` step of 0 ``, `assertion failed` or `assertion
  failed: <message>`. A trap nothing catches writes `trap: <message>` to standard error after
  everything printed before it, and the program ends abnormally (a non-zero status).
- Real arithmetic is IEEE at its own width: `real32` operations are `f32` operations, never computed
  in `f64` and rounded (`precision.mlir`: `0.1 * 3` in `real32`, widened to `real64` to print, is
  `0.30000001192092896`).
- **Real arithmetic does not trap by default.** `1.0 / 0.0` is `inf`, `0.0 / 0.0` is `nan`, and an
  overflow is `±inf`, as IEEE specifies. `nex build --fpe-trap` (and `nex run --fpe-trap`) traps on
  real division by zero, invalid operations and overflow instead, like gfortran's
  `-ffpe-trap=zero,invalid,overflow`. Integer division by zero and integer overflow trap always.
  Under the flag a real `/` by zero traps `floating-point division by zero`; a NaN computed from
  operands that are not NaN traps `floating-point invalid operation` (`sqrt(-1.0)`, `0.0 / 0.0`); and
  an infinity computed from finite operands traps `floating-point overflow`, a narrowing
  `real32(1.0e300)` included. These are checks in the generated code, so they behave the same on
  every machine, whether or not its floating-point unit can trap.
- Printing (ref §10.6) prints a `real32` or `real16` as the shortest decimal that reads back to the
  same value **at that width**, in the reference's spelling (`0.3` for the `real32` nearest 0.3, not
  `0.30000001192092896`) (**PROPOSED**). The spelling is the one the `real64` nearest that decimal
  gets, so a whole number is shortened too: the `real16` 65504 prints `65500.0` and the `real32`
  nearest 1e15 prints `1.0E15`. A complex prints as its two parts do.
- `round` rounds half away from zero, as Fortran's `ANINT` does: `round(2.5)` is `3.0` and
  `round(-2.5)` is `-3.0`.
- **The prelude's real functions** (`sqrt`, `exp`, `sin`, `floor`, …, ref §10.2) compute at the
  width of a real argument, and widen an integer argument to `real64` first (`sqrt(n32)` is a
  `real64`). `sqrt`, `exp`, `log`, `sin`, `cos` and `tan` also take a complex and give one. `abs` and
  `sign` keep an integer's or a real's type, and `abs` of a `complex[realN]` is a `realN`.
- **An `f"..."` specifier is checked against its value's type at compile time**: `d x X o b` format
  an integer, `f e g` a real, `s` anything. `f"$n%.2f"` with `n` an integer is a compile error, not
  the reference's run-time trap, since the type is known where the literal is written.

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
| `Eq` | every numeric type, `bool`, `string`, and every struct, tuple and enum that holds no function value (§11.4) |
| `Rank` | not a type: a rank (§3.4) |
| `Unit` | not a type: a unit of measure (§13.5) |

Unifying one type parameter against several numeric actuals widens along §2.2, as ref §6.10 widens
through the old tower.

Generic functions, structs and enums (ref §3.6, §3.8, §6.10) stand, with these rules (**PROPOSED**).

- **A generic function's body is checked once, against its constraints, at its definition**,
  whether or not anything uses it. In the body a type parameter is a type of which nothing is known
  but what its constraint admits, so an operation is allowed only where it is allowed on every type
  the constraint admits: `def bad[T](x: T) = x + 1` is a compile error at the `+`, reported once,
  naming `T` and no instance, even if `bad` is never called. A generic refused there is refused at
  every use without a second diagnostic.
- **A use checks only that its arguments satisfy the constraints**: `min2("a", "b")` with
  `T: Ord` is a compile error at the call, naming the constraint. A type parameter satisfies a
  constraint that admits everything its own does: `T: Float` passes to `T: Ord`, `T: Numeric` does
  not. The one thing an argument decides in a body already checked is whether a literal fits it:
  `x + 300` with `T: Integral` is a compile error at the `int8` instance, naming it, `f[int8]`.
- **What a constraint allows in a body**: arithmetic and `-` under Numeric and every constraint
  inside it; `<`, `<=`, `>`, `>=`, `min`, `max` under Ord, Real, Integral and Float, never under
  Numeric (it admits complex numbers); `==` and `!=` under Eq and every constraint inside it, not
  under Any; `div` and `%` under Integral; the real functions (`sqrt`, `exp`, …) under Float, and
  under Integral giving `real64`. `/` is allowed where the quotient has one type: under Float and
  Complex it is `T`, under Integral `real64`, and under Numeric, Real and Ord, which admit integers
  and reals both, it is a compile error (bound the parameter by Float, or convert). `abs` and `arg`
  of a `T: Complex` give its real part's type, which no parameter names, and are a compile error.
- **A value of a type parameter meets only its own type and the literals that can take it**: a
  literal adopts `T` where every type its constraint admits can hold that literal kind (an integer
  literal under any numeric constraint, a real literal under Float and Complex), and `T` widens to
  nothing: with `T: Real`, `x * 2.5` and returning `x` as a `real` are compile errors, since the
  common type would differ from one instance to the next.
- **The type arguments are inferred, never written at a call.** The arguments that are not literals
  fix them first; a literal fixes a parameter only where nothing else does and otherwise adopts it
  (`add(x32, 2)` is `add[real32]`); a lambda argument comes last, its parameter types filled in from
  what is known, and its result fixes the parameters there (`apply1(5, x -> x * 2.5)` is
  `apply1[int64, real64]`). A parameter nothing fixes is a compile error.
- **An expected type gives a generic struct's or enum's arguments**, before its fields are looked
  at, and an argument that disagrees with them is converted or refused against its field:
  `val n: Opt[integer] = None`, `val r: Result[integer, string] = Ok(7)`. A type names all of a
  generic's arguments (`Pair[integer, string]`); `Pair` alone or `Pair[integer]` is a compile error.
- **A type argument holds a value**: `void` and `never` are not type arguments.
- **A name holds at most one generic `def` and one concrete `def`.** The concrete one is called
  wherever it takes the arguments, each as it is or widened, a literal adopting its parameter's
  type; the generic one otherwise. The arguments to such a name are passed by position.
- **A generic function as a value** takes its instance from the function type its position
  expects: `call(id)` with `call(f: (integer) -> integer)` passes `id[int64]`. With no function type
  expected it is a compile error.
- **A `Rank` parameter is the whole shape of an array**, `[T; R]`, never one axis among others, and
  only a function takes one; a struct's or an enum's parameters are types.
- **An instance that needs a larger instance of the same generic is a compile error**: `f[T]`
  calling `f[Box[T]]`, or `struct Grow[T]` with a field of `[Grow[Box[T]]]`, would never finish.
  A function's is found when its body is checked and reported there, `f[Box[T]] inside f[T]`.
- **An instance is named by its generic and its arguments**: `id[int64]`, `Pair[int64, string]`,
  `total[real64, 2]` (a rank argument is its number). The typed IR holds only instances, each a
  separate declaration made for each set of arguments a use needs, and two instances of one generic
  are unrelated types.

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
- A slice's kept axes are dynamic, except an axis taken whole with `:`, which keeps its static
  extent: `m[:, 1]` of a `[real; 3, :]` is `[real; 3]`, `a[1..2]` is `[real; :]`.
- Two arrays that stand for one value, as the branches of an `if` do, meet in one type: the same
  rank, the common element type of §2.2, and a static extent only on an axis where both have the
  same one.

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

The body is checked once at no particular rank (§2.6), so what depends on the rank is a compile
error there: an index list; a reduction with `dim`, whose result has rank `R` − 1; `minloc`,
`maxloc`, `extents` and the other prelude functions whose result's type or arguments count the
axes; and meeting an array of any other shape, `[T; R]` with `[T]` in an operator or where one is
required. An axis given to `extent` is checked at each instance.

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

The element type is the one the position expects (`val a: [real32] = [1, 2]`), or else the common
type (§2.2) of the elements, a literal element adopting the others' type as an operand does:
`[x32, 1]` is `[real32]`, `[n, 2.5]` is `[real64]`. Elements of non-numeric types must all be one
type. An empty literal `[]` takes its type from its position, and with none is a compile error, as
is an empty row inside a matrix literal.

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
| `diag(v)`, `diag(m)` | the square matrix with the vector `v` on its diagonal; the diagonal of the matrix `m` |
| `linspace(lo, hi, n)` | `n` reals evenly from `lo` to `hi` inclusive, `[real; :]` |
| `to_integers(b)`, `to_bytes(a)` | `int64(b)` and `uint8(a)`, element by element (§2.4); `to_bytes` traps outside `0..255` |

An axis number written as a literal (`extent(m, 3)`, `dim = 0`) that is not an axis of the array is
a compile error; a computed one traps `not an axis of the array`. A computed `permute` order that
names an axis twice or one the array lacks traps `not a permutation of the axes`.

**The higher-order functions** take the function last and give its parameters the element type, so
a lambda need not write them (`map(xs, x -> x * 2)`). They walk the elements in storage order:

| Function | Result |
|---|---|
| `map(a, f)` | the shape of `a`, each element `f` of the source's; `f` returns a scalar |
| `filter(a, p)` | `[T; :]` of the elements for which `p` is true |
| `flatMap(a, f)` | `[U; :]`, the vectors `f` returns, concatenated |
| `reduce(a, init, f)` | `f(…f(f(init, a₁), a₂)…)`; a literal `init` adopts the element type |
| `enumerate(a)`, `zip(a, b)` | `[(integer, T); :]`, `[(T, U); :]` |

`enumerate` pairs each element with its position from 1, `for i, x in enumerate(xs)` giving `xs[i]`
as `x`; `zip` stops at the shorter array, as the reference's does. An array of rank ≥ 2 is taken in
storage order, its position counted along it.

**`assert_approx(a, b, tol)`** passes where `|a − b| ≤ tol`: for two numbers, or for two arrays of
one shape element by element (an integer widened to `real64`, a complex's distance its modulus). A
`nan` is never within any tolerance. Otherwise it traps, saying where and by how much: `assert_approx:
element (2, 2): |4.0 - 4.5| = 0.5 > 1.0E-6`, or `assert_approx: the shapes differ, (2, 1) and (1, 2)`
(`the lengths differ, 2 and 3` at rank 1).

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
  stop must lie in `1..n` (or be `0` / `n + 1` for an empty window), and a window whose stop is one
  past its start is empty (`a[1..2 by -1]` and `a[3..<3 by -1]` are empty, as Fortran's
  `a(1:2:-1)`). A stop further past the start traps `out of bounds`, as `a[5..2]` does going
  forward: `a[2..5 by -1]` is an error, not an empty window.
- A reversed slice is a view like any other (§6): **nothing is copied**. It is valid as an
  assignment target (`a[.. by -1] = b` writes `b` into `a` back to front).
- The prelude's `reverse(a)` is `a[.. by -1]`, and `reverse(a, k)` reverses axis `k` only.

**Lowering:** a reversed axis is a `tensor.extract_slice` whose offset is the far end and whose
stride is negative; bufferization makes it a `memref.subview` with that offset and stride, and
`expand-strided-metadata` keeps both, so it is read and written in place like any other view
(`experiments/mlir/negative-stride.mlir`). A reversed view crossing the FFI to BLAS (`incx < 0`)
passes the pointer to the lowest-addressed element, since BLAS starts a negative-increment vector
from that end.

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
   neither is binding it to a local `val`. The copy is made where the value is known to be a view
   (a slice, `reverse`, a local `val` bound to one, a branch giving one); a parameter is not known
   to be one, so a function that returns its parameter copies nothing.
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

**An array whose elements are not numbers** — strings, functions, tuples, structs, enums — is not a
tensor but a counted object holding its elements, and the same windows (offset, extent and stride per
axis, `by` and `origin` included) are taken of it with the same checks. Read as a value, a slice of
one is a new array holding a count on each element of the window: one allocation, the elements
shared rather than copied, which only the cost tells apart from a view. Slice assignment, a write
through a slice of a place, and an `inout` slice write the source's own elements in place, so a
callee that traps leaves its earlier writes in the caller's array (§8.4).

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
  argument and calls `origin` itself. `rebase` of an ordinary array is a dense copy of it.
- **Only a `val` holds an offset view, and only indexing reads its offsets.** Binding one to a `var`,
  assigning it, or giving it as the value of an `if`, a `match` or a block is a compile error naming
  `origin`, as escaping is. Read as a value — by an operator, `sum`, `print`, `for x in w` — it is
  its elements, and the result is 1-based like every other value. A slice of an offset view
  (`w[-1..1]`) is an ordinary 1-based view, as a Fortran section is. `origin(w, …)` of an offset
  view replaces its first indices.

---

## 7. Element-wise operations and `@`

### 7.1 Element-wise

ref §4.5 holds for every rank: `A op B` needs equal rank (a compile error otherwise) and equal
shape (a compile error when both are static, else a trap), and is element-wise, with element types
mixed per §2.2. **Broadcasting is scalar-only**: `A op s` and `s op A` for a scalar `s`, any rank.
Element-wise expressions fuse to one loop nest per expression for every rank (`views.mlir`, rank 3),
reading the arrays at the expression's leaves and building no array in between, so
`sqrt((x2 - x1)^2 + (y2 - y1)^2)` reads four arrays and writes one. **What fuses is a quiet
expression**: real and complex arithmetic, comparisons, widenings, unit conversions and the prelude's
elemental functions, which can neither trap nor print once the operands' shapes agree. Integer
arithmetic (which traps on overflow and on a zero divisor), complex division, a conversion that
checks its range, a call of an `@elemental` function (which may print or trap) and everything under
`--fpe-trap` are computed one operation at a time, each whole before the next, so their traps and
prints come in the order of the operations. Either way the shapes are checked, and a mismatch traps,
in the order the operations one by one check them: after both operands of each are evaluated. **An
assignment writes its target in place** where the target is a local array the expression reads at
the element it computes (`y = a*x + y`), or a local of static shape: each element is read before it
is written. Where the old value is still read — by another holder (`val keep = y`), or by an operand
that is a view of the target read at other elements (`v = v[n..1 by -1] + v`) — bufferization copies
it first. **A reduction's quiet operand is fused into it**: `sum(x * y)`, `dot(x, y)` and
`sqrt(sum(x * x))` compute each product as the reduction reads it, in the same blocks and tree.

Comparisons are element-wise too: `a == b` and `a < 5` are `[bool]`, and whether two arrays are equal
is `all(a == b)`. `not`, `and` and `or` apply element by element to `[bool]` operands (a `bool`
broadcasts), evaluating both sides. A chained comparison (`0 < a < 1`) compares scalars only; on
arrays it is `0 < a and a < 1`.

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
operator (§7.1). `sqrt(a) + 1.0` is one loop. Arguments of a several-argument elemental function broadcast
as operators do (scalar-only, equal shapes otherwise): `max(a, 0.0)` clamps every element.

**A user function opts in with `@elemental`**: `@elemental def f(x: real) = …`. Its body obeys the
parallel-body rules of §9.4 — no `inout` parameters, no writes to module variables, no I/O except
`print` and `eprint`, no `parallel`, directly or through anything it calls — so `parallel` may
evaluate it in any order and fuse it (§9.5). Without `parallel` its call is computed whole, every
element's call before the operation that uses it, since it may print or trap (§7.1). Its parameters are scalars and
it returns a value. Called with an array for any parameter, it applies element by element, its
other arguments broadcasting as an operator's do. An unmarked scalar function applied to an array is
a compile error that suggests `@elemental` or `map`.

### 7.4 Reductions

The prelude's whole-array reductions take Fortran's names: `sum`, `product`, `minval`, `maxval`,
`minloc`, `maxloc`, `any`, `all`, `count`, `norm2`, `dot`.

- `minloc(a)` and `maxloc(a)` return the index of the extreme element, a tuple of indices for rank
  ≥ 2; ties go to the first in storage order. A `nan` is never the extreme unless every element is
  one, when the location is the first; an empty array's location is `0`.
- `minval(a)` and `maxval(a)` pass over a `nan` as `minloc` and `maxloc` do, and as Fortran's
  `MINVAL` and `MAXVAL` do: a `nan` is never the extreme unless every element is one, when the
  result is `nan`; along a `dim =` the rule holds lane by lane, and under `parallel` it holds across
  blocks, whatever the thread count (a block of only `nan` is a `nan` partial, which every number
  beats). The elemental `min` and `max` (§7.3), and a `min` or `max` operator of a `parallel for`
  `reduce` clause (§9.2), are not reductions of an array and carry a `nan` through.
- **Every reduction takes a named `dim =` argument**, reducing along that axis to rank R − 1:
  `sum(m, dim = 2)`, `maxval(a, dim = 1)`, `maxloc(a, dim = 1)`.
- `min` and `max` are elemental (§7.3), never reductions: `max(a, 0.0)` clamps, and the extremes of
  one array are `minval` / `maxval`.
- `norm2` is the Euclidean norm, the Frobenius norm of a matrix, and is real: an integer array is
  widened to `real64`, a complex one gives its part type. There is no `norm`.
- `any`, `all` and `count` take `[bool]`; `count` is an `integer`. `dot` takes two vectors and no
  `dim =`.
- `dot(x, y)` conjugates `x` when complex, as Fortran's `dot_product` and BLAS's `zdotc` do. `@`
  never conjugates.
- The `minval` / `maxval` of an empty integer array are the type's largest / smallest values (the
  identities of §9.2), and `+inf` / `-inf` for reals: an empty array has no `nan` to give.

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
`mut integer` was. A function type spells it the same way: `(inout [real], real) -> void`.

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
   `e`"*, on the first axis where the two places differ — two windows `..e` and `e+1..` there, every
   other axis whole, or, where both are elements, `m[e, 1]` and `m[e+1, 1]` with the other subscripts
   kept. No run-time disjointness check is made.

   The three forms are one rule: on one axis, two subscripts are disjoint when the last index one
   reaches and the first the other reaches are **the same base plus two constants, the first
   constant the smaller** — no base for constant windows (`a[1..4]`, `a[5..end]`), `e` for a split
   (`..e` / `e+1..`, `..<e` / `e..`, also `a[e]` / `a[e+1]` and `a[..e-1]` / `a[e..]`). An index is a
   window of one element; an open start is 1 and an open end is unknown; a window whose stride is
   not a positive constant reaches nowhere the checker can name. The base is the same only when it
   is written alike on both sides from literals, variables, `end`, arithmetic and `length`/`size`/
   `rank`, and mentions no variable another argument of the call can write (`f(a[..e], g(), a[e+1..])`
   with `g` changing `e` is refused). Past a step where two places agree exactly (the same field, the
   same index list written alike), the comparison goes on to the next step: `swap(a[k].x, a[k].y)`
   is accepted.
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
   A read-mode argument is borrowed when it is a place or a view of one and its type is an array, a
   tuple or a struct; any other argument is a value computed before the call (`a + 1`, `sum(a)`, a
   widened `[real32]` passed as `[real64]`). A `val` bound to a `var` array, or an `origin` view of
   one, is the place it shares: `val v = a[1..5]` then `axpy(2.0, v, a[5..8])` is refused. A
   function passed beside an `inout` argument — a lambda, a local `def` or a top-level function —
   that reads or writes the borrowed variable, directly or through what it calls, is a conflict
   too: `app(n, () -> n + 1)` with the first parameter `inout`.
3. **Access by another route inside the callee.** Passing a module-level `var` as `inout` to a
   function that reads or writes that `var` by name, directly or through anything it calls, is
   rejected. The checker computes for each function the module-level `var`s it reads and writes,
   transitively; the same summary serves §9. A local passed `inout` to a local `def` or lambda that
   captures it is rejected the same way. A call through a function value the checker cannot follow
   (a parameter of function type) is judged by what the call itself is given: the function values
   passed beside the `inout` argument, under rule 2.
4. **Escaping captures.** An `inout` parameter may be captured by a non-escaping lambda (one passed
   straight as an argument, such as `assert_traps(() -> f(v), "…")`) but never by an escaping one.

### 8.4 Traps and the uniqueness rule

A trap inside the callee leaves the writes it made before the trap in place; nothing is rolled back.
The uniqueness rule (ref §8.2) loses its `mut` case: a `var` array is moved only by `return` and by
assignment to another `var` (and the auto-clone pass makes the latter a copy when the source is used
again, ref §8.3). An `inout` call is not a move and needs no clone.

**Where the auto-clone pass clones.** An array local bound or assigned to a `var` (`var b = a`,
`b = a`) is **moved** when the source is a `val` or `var` bound in the same function that nothing
uses afterwards: no later read or write, no loop around the transfer that the source was bound
outside of, and no lambda capturing it. Otherwise it is **cloned**, and always when the source is
a parameter (the caller keeps it, `inout` or not), a module-level binding, a loop variable or a
name bound by destructuring or a `match`. A view bound or assigned to a `var` is copied (§6.2 rule
2). A `val` bound to a `var` array shares it, as a view of a `var` does (§6.2 rule 4).

**Lowering.** An `inout` array is a tensor argument whose updated value is returned and bound back
to the caller's variable. Every nex function except `main` is emitted `private`; with
`drop-equivalent-buffer-results` before `buffer-deallocation-pipeline`, a result that is its own
argument's buffer disappears, the function returns nothing and writes the caller's buffer in place
(`parallel.mlir`, `axpy`). Kept public, the same function returns its argument and the deallocation
pipeline clones it: a whole-array copy per call. Inside the callee, assigning the whole parameter an
array of the shape it has (`v = v * s`, `v += 1`) copies the computed value over the argument's
buffer; only an array of another shape rebinds the parameter, and reaches the caller when the call
returns.

The callee writes where the caller can see each write as it is made, so a trap leaves them there. An
array the caller holds in storage — a `var` a lambda captures, a module-level `var`, a field of a
struct `var` — is first made the only holder of its buffer (copied where another holder shares it or
the statement around the call is reading it, as a loop over it does), and that buffer itself is what
the call is lent, whole or as a window; after the call the handed-back value is that buffer, or, where
the callee rebound the parameter to another shape, a new one stored into the place. An array in SSA
form needs nothing: a trap leaves its function's frame, and nothing reads it again.

A scalar `inout` is a pointer argument. An element of an array of numbers passed `inout` (`a[i]`,
`m[:, j][i]`) is a value in its array's tensor: its indices are evaluated and bounds-checked once
before the call. Where the array is held in storage (made its buffer's only holder as above) or is one
a `parallel for` body writes in place, the element crosses as its address in that buffer; otherwise
its value crosses in a stack slot. Either address is the argument (to a `def`, a function value or a C
scalar parameter; inside a rank-0 descriptor to a `[*; ..]` one). After the call, unless the element
crossed in an array held in storage, what the address holds is inserted at the same indices into what
the array place holds then. An element of an array of anything
else has storage of its own and crosses as its address. An `inout` slice argument (§8.2) is the subview of §6.3 written in place: a column,
a row, a strided or reversed window and a line of a rank-3 array each reach the callee as a
`memref.subview` of the caller's buffer, with no allocation and no copy, in a `parallel for` body as
in sequential code. A call through a function value (a local `def`, a lambda, a `val` bound to a
function, a parameter of function type) passes an `inout` array as its buffer: the code behind the
value writes it in place and returns only its value, so the same window is written where it lies
there too.

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
only (not over an array's elements), each with an optional `by` step. The iteration space is a box:
no range may use another clause's index. The iterations may run in any order and at the same time;
the loop ends when all of them have.

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
**user-defined function** of type `(T, T) -> T`. The reduction variable is an outer `var` (local
or module-level) of a type the operator applies to: a number for `+` and `*`, an integer or a real
for `min` and `max`, a `bool` for `and` and `or`, a (value, index) pair for `minloc` and `maxloc`,
and `T` for a user function. A built-in operator reduces a scalar, not an array; an array is
reduced element by element by a loop over its indices, or with a user operator. A variable is named
in one `reduce` clause only. Each iteration contributes through exactly one of `v op= e`, `v = v op e`,
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

  Ties go to the lowest index, as in Fortran, whatever the thread count. As in §7.4 a `nan` is
  never the extreme while any candidate is a number: a number beats a `nan` and two `nan`s tie, so
  the variable's starting value counts as one more candidate, and only when every candidate is a
  `nan` is the result a `nan`, the one at the lowest index. A block of a real location starts from
  a `nan` at the largest index, which every candidate beats or ties; an integer one from the type's
  worst value there. The three-argument
  `maxloc(v, x, i)` exists only as this contribution; anywhere else it is a compile error.

#### 9.2.1 Reproducible reductions

**A reduction's result does not depend on the thread count.** The iterations are numbered in a
fixed order — for a header of several clauses, the first clause's index varying fastest, as
Fortran's array element order runs — and that range is cut into
fixed-size blocks (4096 iterations; the size is a compile-time constant, not a tuning knob), each
block is reduced sequentially from the operator's identity (`0` for `+`, `1` for `*`, `+inf` for
a real `min` and the type's largest value for an integer `min`, `-inf` / the type's smallest value
for `max`, …; for a user operator, the variable's starting value), the block partials are combined in
a **fixed pairwise tree** over the block numbers — in rounds, each combining partials 1 and 2, 3 and
4, and so on, an odd last one carried into the next round as it is, until one is left — and the
tree's result is combined once with the
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
   outer `var` array (or `inout` parameter) **owned by the iteration**: in every such write, each
   of the loop's index variables is exactly the subscript of one axis, distinct variables on
   distinct axes, so two iterations can never write the same element (`y[i]`, `m[:, j]`,
   `c[i, j]`, `t[i, :, k]`). `y[i + 1]`, `y[2 * i]` and `y[idx[i]]` are rejected (**PROPOSED**: the
   rule recognizes only the plain index variable), and so is `c[i, :]` under the header
   `i in …, j in …`, since iterations with one `i` and different `j` share that row. Every write to
   one array in a body uses the same subscripts: `c[i, j]` and `c[j, i]` together are rejected.
   Passing a place `inout` is a write to it.
2. **No read of what another iteration writes.** An array written under rule 1(c) may be read in the
   body only at the iteration's own subscript (`y[i]` when writing `y[i]`); `y[i - 1]` is rejected.
   Every other outer binding is read-only for the duration of the loop, and reading it is free:
   value semantics means no other code can change it meanwhile.
3. **No effects through calls.** A function called in the body may receive `inout` only places that
   rule 1 allows the body to write (`normalize(m[:, j])`), and may not itself write a module-level
   `var` (the transitive summary of §8.3), nor read one the body writes element by element, nor —
   for a local function — assign a local of the enclosing function or read a reduction variable.
   `extern` functions not marked `@pure` (§10) are rejected in a parallel body. **The checker must
   see what is called**: a function by its name, a lambda, or a `val` bound to one. Calling a
   function value it cannot see into — a parameter of function type, a `var`, a field — is a
   compile error in a parallel body, and so is calling a function that itself calls one. A
   function or lambda passed as a value (to `map`, say) counts as called by whatever receives it.
   **I/O:** `print` and writing to stderr are allowed, and each call is **atomic** — its whole line
   is written under a lock, so lines never interleave mid-line — but the **order of lines across
   iterations is unspecified**. A program with a `parallel` construct gathers each line and writes
   it whole when it ends, so a trap in the middle of computing a line's value (`print(s"a ${f()}")`)
   leaves none of that line written; a program without one writes the pieces as they come. This is the one deliberately non-reproducible thing in a parallel
   loop. Every other I/O (`read_bytes`, `write_bytes`, opening or writing a file, reading input) is a
   compile error in a parallel body.
4. **The reductions are well formed** (§9.2).
5. **No nested `parallel`.** A `parallel for` or `parallel` expression inside a parallel body is a
   compile error, and the message suggests the two-axis header
   `parallel for j in 1..n, i in 1..m`.
6. **`cycle` is allowed, `exit` is not.** `cycle` ends the current iteration; `exit` (and an
   `exit`/`cycle` naming a loop outside the body) is a compile error, since the iterations have no
   order to leave. `return` is a compile error for the same reason, and so is `stop`; a failed
   `assert` traps instead, and a trap ends the loop as described below. A loop inside the body may
   be left by `exit` as any loop may.

A body the checker cannot prove is a compile error naming the offending write or read, never a
silent fallback to a sequential loop. The wording of the checker's messages is the
implementation's; the documentation's are illustrative.

The body of an `@elemental` function (§7.3) obeys rules 1–3 and 5 as if it were a parallel body.

**A trap inside a parallel body** ends the loop: every iteration already running finishes, no new
one starts, and the trap is raised in the thread that started the loop, as if by its first
statement after the loop: an `assert_traps` around the loop catches it, and with nothing catching
it the program writes it and aborts as any trap does. Which iteration's trap is reported when
several trap is unspecified. A thread looks for a trap between blocks of 4096 iterations, so "no
new one starts" holds per block: the iterations of a block already begun run to its end. (Each
thread runs its share under a catch of its own, so the runtime's `longjmp` never crosses an OpenMP
thread; the first trap's message is kept and raised by the thread that started the loop.)

### 9.5 Lowering

**Every `parallel` construct is one OpenMP region whose code nex outlines itself.** The function
that meets the construct gathers what the region reads into an environment in its frame and opens an
`omp.parallel`; every thread of the team calls the runtime with the region's code, a function of
its own taking the environment, the thread's number and the team's size. Being a function, the code
gives each thread its own copy of every local the body binds, its loop counter and the control word
`cycle` sets. The runtime runs the code under a per-thread catch (§9.4 traps).

| nex | the region's code |
|---|---|
| `parallel for` | the thread's contiguous run of iterations (or, with a `reduce` clause, of blocks), each iteration setting the indices from its number and running the body |
| a `reduce` clause | per block: an accumulator started from the identity, each contribution combined into it, the block's partial stored; after the region the partials are combined in the tree of §9.2.1 and once with the starting value |
| `parallel` element-wise or `map` | the thread's run of the result's elements, in storage order, each computed by the scalar operation over the operands' elements |
| `parallel sum`, `product`, `minval`, `maxval`, `dot` | the thread's run of blocks, each reduced as the sequential reduction reduces it; after the region the same tree |

**A whole element-wise expression is one region.** Under `parallel`, the operators, elemental
calls, conversions and widenings of an element-wise expression are fused into one scalar computation
over the arrays and values at its leaves, so `parallel 0.5 * x + y` reads `x` and `y` once each and
builds no array in between. `and` and `or` are not fused into: their operands are computed whole,
as without `parallel`. A reduction's operand is fused the same way: `parallel sum(x * y)` and
`parallel dot(x, y)` compute each product as its block reduces it and never build the array of
products; the blocks and the tree are unchanged, so the bits are those of the sequential reduction.
**`y = parallel e`, where `y` is a local array that `e` reads at the element it computes, writes `y`'s
own buffer in place**: each element is read before it is written, and no other element is read, so
nothing is allocated. Bufferization copies the buffer first only where something else still holds
`y`'s old value.

**Arrays cross as buffers.** A local the body reads crosses as its address. An array crosses as a
memref descriptor, through a *launcher*: a private function that takes every array the region
reaches as a tensor argument, gives back each one the body writes, fills their fields of the
environment with their buffers and opens the region. One-shot bufferization sees a call that reads
some arrays and writes others as an `inout` argument is written (§8), so a written array is written
in place by every thread at the elements it owns — inside an enclosing loop too — and is copied
first only where the caller still needs its old value or the call also reads it. Inside the code a
written array is a `restrict writable` tensor over that buffer, written back over it at the end,
which bufferization turns into nothing. An array a lambda captures is held in a cell as a counted
object; one the body writes crosses as that object's own buffer, written in place, after the cell
is given a copy of its own if anything else (a `val` sharing it, §8.4) still holds the object. A
lambda made inside the body that captures that array captures the cell, so it reads the object the
body writes: the iteration's own elements as the iteration has written them so far. The
result of a `parallel` element-wise expression is a buffer allocated before the region and freed by
the deallocation pipeline.

**Counts are atomic while a parallel region runs, and plain otherwise.** Strings, cells and closure
environments are counted objects, and a parallel body may copy and drop one shared from outside —
an outer string read, an outer closure called — on several threads at once. From the start of a
region to its end the runtime changes every count with one atomic add (`release` with
acquire-release ordering, so the thread that frees an object sees every other thread's last use of
it); before and after, only one thread runs, and the region's start and end order its plain changes
against the threads', so a plain add is enough. Measured on a loop that only copies and drops
strings, closures and a struct holding both, an atomic count costs about a sixth of the loop's time
even uncontended (PLAN.md, M9), which is why the plain one is kept: the sequential program, and the
sequential parts of a parallel one, do not pay for threads they are not running. A reduction
variable of a type that holds a count (a string built by a user operator) is not compiled yet.

**A failed check leaves the loop.** The runtime function a trap calls is declared never to return,
so a bounds check inside a loop is a branch out of it that LLVM may hoist; with the index moving by
a known step, the loop vectorizes. A clause's first value and step spelled as literals are constants
in the region's code rather than fields of its environment, so `parallel for i in 1..n` over
contiguous arrays vectorizes as the sequential loop does, and one thread runs it as fast. An array
still crosses with dynamic strides: LLVM checks for a unit stride once before the loop and
vectorizes the unit-stride case, so a contiguous array needs no layout of its own.

**Which pipeline a program gets is decided by the program, not by a flag.** A program that contains
a `parallel` construct anywhere holds an `omp.parallel`, so its pass list gains
`convert-openmp-to-llvm` and its link `libomp`; a program with none links no OpenMP runtime at all.
There is no `-fopenmp` equivalent to forget. Only the regions nex writes run on several threads:
every other `linalg` operation still lowers to sequential loops (§9.3, no implicit parallelism).

**The thread count comes from `OMP_NUM_THREADS` only**, the variable every HPC batch script already
sets; nex adds no variable of its own. `OMP_PROC_BIND` and `OMP_PLACES` are honoured as the OpenMP
runtime reads them. `OMP_NUM_THREADS=1` runs the program sequentially and, by §9.2.1, produces
identical bits.

Every operator of §9.2 reduces this way — real and complex `+`, `*`, `min` and `max` on integers
and reals, `and`, `or`, `minloc`, `maxloc` and a user operator — since the combination is nex's own
code, not an `omp.declare_reduction`, whose order would follow the thread count.

### 9.6 Distributed memory: MPI (PROPOSED)

`parallel` (§9.1–9.5) uses the cores of one node. A cluster is many nodes with no shared memory,
and the Fortran answer to it is MPI, with coarrays (§9.7) built on top. nex takes the same road:
**MPI first, as an `mpi` module shipped with nex; coarrays later, over MPI's one-sided operations.**
The model is Fortran's and C's: SPMD, every process (a **rank**) runs the same `main`, and data
moves only where the program moves it.

**MPI is compiled-engine only.** The interpreter never calls C (§16), so a program importing `mpi`
is refused where it imports it: *"`mpi` is not interpreted: the interpreter never calls C, so a
program importing `mpi` runs compiled"* — the wording of the refusal of an `extern` (`interp.sysl`)
with the module named. `import mpi` always names the module nex ships, never a directory `mpi`
beside the program.

#### 9.6.1 What `extern def` reaches today

Every probe below is a test in `compiler/tests_mpi.sysl`, run with Open MPI 5.0.11 under
`mpirun -np 4` (each skips, saying so, without `mpirun`). They fix what the module has to provide.

- **The C binding's handles are pointers nex cannot spell.** Open MPI's `MPI_Comm` is
  `struct ompi_communicator_t *`; MPICH's is an `int`. `c_ptr` is only a callback's data (§10.2.1):
  `extern def MPI_Comm_rank(comm: c_ptr, rank: inout int32): int32` is *"a `c_ptr` is a callback's
  user data: declare `comm: @data(f) c_ptr`, naming the callback parameter it goes with"*.
- **The predefined handles are macros, and in Open MPI they are addresses of globals.**
  `MPI_COMM_WORLD` is `((MPI_Comm) &ompi_mpi_comm_world)`, `MPI_DOUBLE` `&ompi_mpi_double`, `MPI_SUM`
  `&ompi_mpi_op_sum`; MPICH's are integer constants (`MPI_COMM_WORLD` is `0x44000000`, `MPI_SUM`
  `0x58000003`). nex has no way to name a C global: `extern val ompi_mpi_comm_world: int64` is
  *"expected 'def', found 'val'"*. `MPI_IN_PLACE` is `(void *) 1` in Open MPI and `(void *) -1` in
  MPICH, a pointer no array argument can carry.
- **`MPI_Init(int *argc, char ***argv)` wants null pointers**, which nex has no spelling for.
- **The C binding runs only through puns**: declared with each handle as an `int64` obtained from
  `MPI_Comm_f2c(0)`, `MPI_Type_f2c(17)`, `MPI_Op_f2c(3)`, and `argv` as `inout int64` holding zero,
  `MPI_Allreduce` sums across four ranks correctly. It relies on a pointer passing as a 64-bit
  integer, true of LP64 and of nothing the type system knows, and on Open MPI's Fortran handle
  numbers — a workaround, not a binding.
- **The Fortran binding crosses as it is.** Its handles are `INTEGER`s and every argument is by
  reference, which is exactly a `@fortran` extern (§10.6): `mpi_init`, `mpi_comm_rank`,
  `mpi_allreduce`, `mpi_irecv`, `mpi_wait` with `inout [int32]` for the status all run, linked with
  `-lmpi_mpifh -lmpi`. But the constants are each implementation's `mpif.h` values (Open MPI:
  `MPI_COMM_WORLD = 0`, `MPI_DOUBLE_PRECISION = 17`, `MPI_SUM = 3`; MPICH's are its C integers), so a
  program is written for one MPI; and `MPI_IN_PLACE`, `MPI_BOTTOM` and `MPI_STATUS_IGNORE` are
  addresses of common blocks (`mpi_fortran_in_place_`), again unnameable.
- **A nonblocking call outlives the §10.3 copy.** A unit-stride window crosses in place, so
  `mpi_irecv(dense[2..3], …)` then `mpi_wait` lands the message where the window lies. A strided one
  is gathered into a temporary that is valid for the call: `mpi_irecv(strided[1..4 by 3], …)` posted
  before the matching send returns, the temporary is scattered back (zeros) and freed, and the
  message arrives later into freed memory — the variable prints `[0.0, 0.0, 0.0, 0.0]`.
- **An MPI error aborts the job.** The default handler, `MPI_ERRORS_ARE_FATAL`, kills every rank from
  inside the C call; no nex trap is raised and `assert_traps` sees nothing.
- **There is no standard ABI to declare against yet.** MPI 5.0 fixes one (`mpi_abi.h`, handles and
  constants identical across implementations, a `libmpi_abi`). Open MPI 5.0.11 ships no `mpi_abi.h`;
  its `mpi.h` says `MPI_VERSION 3`, `MPI_SUBVERSION 1`. MPICH 4.3 builds it with `--enable-mpi-abi`;
  Open MPI's support is in its 6.x line. Neither is what a cluster has today.

**So the module is not a header transcription.** Its handles, its constants, its buffers' lifetimes
and its errors all need something `extern def` does not have, and the design below supplies them in
one place, the module's shim, rather than in the language.

#### 9.6.2 The module

```nex
import mpi.*

def main() =
  val me = this_rank()                  // in world(), 0 .. num_ranks() - 1
  val p = num_ranks()
  val n = 1000
  var u: [real] = zeros(n + 2)          // one ghost cell at each end
  val left = if me > 0 then me - 1 else no_rank
  val right = if me < p - 1 then me + 1 else no_rank
  for step in 1..100
    exchange
      send(u[2..2], to = left)
      send(u[n + 1..n + 1], to = right)
      recv(u[1..1], from = left)
      recv(u[n + 2..n + 2], from = right)
    u[2..n + 1] = 0.5 * (u[1..n] + u[3..n + 2])
  val total = allreduce(sum(u[2..n + 1]), +)
  if me == 0 then print(total)
```

**Initialisation is implicit.** A program that imports `mpi` has `MPI_Init_thread` called before
its module-level bindings are initialised and `MPI_Finalize` after `main` returns or `stop` runs,
as a Fortran coarray program has; `init` and `finalize` are not functions the program calls.
`stop n` with `n ≠ 0` on any rank, and a trap nothing catches, call `MPI_Abort(world, status)` after
writing the message with the rank in front (`rank 3: trap: index 11 out of bounds 1..10`; `stop n`'s
is `rank 3: stop n`), so one rank's failure ends the job instead of hanging the others in their next
collective. The status is `n` for `stop n` and 134 for a trap, a process ended by `abort`'s. `stop 0`
ends only its own rank's part, through `MPI_Finalize`, which waits for the other ranks to reach
theirs.

**Communicators** are values of type `Comm`: `world()`, `self()`, `split(comm, color, key = this_rank())`
(`MPI_Comm_split`; a color of `no_color` takes the rank out), `dup(comm)`, `split_shared(comm)`
(the ranks of one node, `MPI_COMM_TYPE_SHARED`), `cart(comm, dims, periodic)` with `shift(c, axis,
by)` answering `(from, to)` for a halo. A `Comm` is reference counted and freed when its last value
goes (`MPI_Comm_free`), so there is no `free` to forget. Every function below takes
`comm: Comm = world()` as its last parameter, so a program that never splits never names one.
`this_rank(comm)` and `num_ranks(comm)` are `int`s; `no_rank` is `MPI_PROC_NULL`, to which a send or
receive does nothing.

**No name in the module is a prelude function's**, so `import mpi.*` hides nothing: `rank(a)` and
`size(a)` of an array keep their meaning beside `this_rank()` and `num_ranks()` (Fortran's
`this_image()` and `num_images()`), and `reduce(a, init, f)` beside `reduce_to(x, op, root)`.

**Two kinds of function.** The module's own nex declares the communicators, the point-to-point
functions and everything else a generic `def` can write. The collectives below are **intrinsics**,
as Fortran's `co_sum`, `co_reduce` and `co_broadcast` are: each is declared in `mpi.nex` as an
`@intrinsic def` without a body (so `import mpi.*`, `import mpi.{allreduce}` and `mpi.allreduce`
reach it like any member, and nothing else may declare one), and the compiler types each call from
its operand (`elab_mpi.sysl`), as it types the prelude's reductions. A call becomes calls of the
shim's entry points over `[*; ..]` descriptors (§10.7) and a fresh result the shim writes. They are
intrinsics because what they need — one function over a scalar or an array of any rank, any
element type and any unit, an operator passed as a value, a result one rank higher than the
operand — is more than a generic `def` expresses. A collective is only called: `val f = allreduce`
is *"`allreduce` is a collective of `mpi`, typed at each call from its operand, so it is only
called"*.

**Point to point.** `send(x, to, tag = 0)`, `recv(inout x, from = any_rank, tag = any_tag)`
answering a `Status` (`source`, `tag`, `count`), `sendrecv(x, to, inout y, from, tag = 0)`. They are
written in nex, generic over `[T: Numeric, R: Rank]` and passing `x` to the shim as `[*; ..]`, so
`x` is an array of numbers at any rank — a whole array, a window or a strided view — and the count
is its element count, never written. A scalar and a measured array wait for a generic `[T; R]` that
admits rank 0 and a `T: Numeric` that admits a unit. A `recv` into an array whose element count is
not the message's traps: *"recv: the message from rank 2 holds 12 values; the array holds 10"*. A
`recv` from `no_rank` receives nothing and answers a `Status` of `no_rank` and count 0.

**Nonblocking: the `exchange` block.** A nonblocking send or receive must keep its buffer where it
lies until it completes, which a call cannot promise (§9.6.1). nex makes that a scope: inside an
`exchange` block, `send` and `recv` are `MPI_Isend` and `MPI_Irecv`, and the block's end is
`MPI_Waitall` on all of them. A place named by a `recv` in the block is borrowed by it until the
end, under §8.3's exclusivity rule — reading or writing it inside the block is a compile error —
and a sent array is held by the request (its buffer reference counted, so a later write copies
rather than changing what is in flight, value semantics for free). Code in the block that touches
neither runs while the messages move, which is the overlap of computation and communication a halo
exchange wants:

```nex
exchange
  send(u[:, 2], to = west)
  recv(u[:, 1], from = west)
  interior(u)                // error: `u` is borrowed by the `recv` above until the block ends
```

The overlap is written by computing on another array (or another part, once the checker proves
windows disjoint as §9.4 does). There is no `Request` value and no `wait`: a request that is never
waited on is not expressible.

**Collectives** take the value and answer the result, as nex's own reductions do. Each takes
`comm = world()` last; its other arguments go by position or by name.

| nex | MPI | answers |
|---|---|---|
| `barrier()` | `MPI_Barrier` | nothing |
| `bcast(x, root = 0)` | `MPI_Bcast` | `x` as `root` had it, on every rank |
| `reduce_to(x, op, root = 0, fast = false)` | `MPI_Reduce` | the combination on `root`; `x` elsewhere |
| `allreduce(x, op, fast = false)` | `MPI_Allreduce` | the combination, on every rank |
| `scan(x, op, fast = false)` | `MPI_Scan` | on rank r, the combination of ranks 0 to r |
| `gather(x, root = 0)` | `MPI_Gather` | on `root`, the rank-k pieces along a new last axis, a rank-(k+1) array with one part per rank; elsewhere that array with none |
| `allgather(x)` | `MPI_Allgather` | `gather`'s result on every rank |
| `gather_concat(x, root = 0)` | `MPI_Gatherv` | on `root`, the rank-k pieces joined along their last axis in rank order, a rank-k array; elsewhere an empty one |
| `allgather_concat(x)` | `MPI_Allgatherv` | `gather_concat`'s result on every rank |
| `scatter(x, root = 0)` | `MPI_Scatter` | part r + 1 of `root`'s rank-(k+1) `x` along its last axis, a rank-k array, on rank r |
| `scatter_concat(x, root = 0)` | `MPI_Scatterv` | rank r's part of `root`'s `x`, cut along its last axis as `blocks` cuts it |
| `alltoall(x)` | `MPI_Alltoall` | `x`'s last axis, one part per rank, part k sent to rank k; part k of the result is rank k's |
| `global_sum(x, offset)`, `global_dot(x, y, offset)`, `global_norm2(x, offset)` | — | §9.6.5 |
| `blocks(n, p = num_ranks(), r = this_rank())` | — | `(first, last)`, the part of `1..n` rank `r` owns: the block decomposition every program writes, the first `n % p` ranks one element longer |

**Ranks are static.** `gather` and `allgather` of a rank-k operand answer rank k + 1 and `scatter`
the inverse, so the result's type is known where the call is written; the operands' shapes must
agree across the ranks, and the call checks it at run time before any data moves — every rank sees
every rank's shape, so every rank traps alike, naming two of them: *"allreduce: every rank's operand
has one shape, and rank 1's is [3] where rank 0's is [2]"*. Pieces of differing lengths are the
`_concat` forms' (MPI's `v` forms), which agree on every axis but the last; `scatter`'s operand has
one part per rank along its last axis and `alltoall`'s too, or the call traps with the counts. A
scalar has no axis to cut or join, so `scatter`, `alltoall` and the `_concat` forms refuse one at
compile time.

`op` is `+`, `*`, `min`, `max`, `and`, `or`, `minloc`, `maxloc` — §9.2's operators, which a call
takes as an argument (`allreduce(x, +)`; `+`, `*`, `and` and `or` stand alone only there) — or a
user function `(T, T) -> T` of the operand's element type, a named `def` or a lambda, applied element
by element to an array. `+` and `*` take numbers, `min`, `max`, `minloc` and `maxloc` integers and
reals, `and` and `or` `bool`s; anything else is refused with the operand's type. `minloc` and
`maxloc` answer a pair, `(value, location)`, where the location is the rank the value came from
(an `integer`, or an array of them shaped as `x`), ties going to the lowest rank, as `MPI_MINLOC`
does; on the ranks `reduce_to` leaves alone it is `(x, this_rank())`. The value forms copy as they
must; `x` keeps its value on every rank.

#### 9.6.3 What crosses: types, views and units

**Every element type a `[*; ..]` descriptor carries crosses** (§10.7): a scalar or an array, at any
rank, of

| nex element | moved as | `fast = true` reduces with |
|---|---|---|
| `int8` … `int64`, `uint8` … `uint64` | its bytes | `MPI_INT8_T` … `MPI_UINT64_T` |
| `real32`, `real64` | its bytes | `MPI_FLOAT`, `MPI_DOUBLE` |
| `real16` | its bytes | nex's own operator: MPI has no 16-bit real |
| `complex[real32]`, `complex[real64]` | its bytes | `MPI_C_FLOAT_COMPLEX`, `MPI_C_DOUBLE_COMPLEX` (`+`, `*`) |
| `complex[real16]` | its bytes | nex's own operator |
| `bool` | its bytes | `MPI_C_BOOL` (`and`, `or`) |

A message moves as bytes (`MPI_BYTE`), its element count checked by the shim against the
descriptor's, so the element type is nex's fact on both ends, as a unit is; an operation MPI has no
operator for (`minloc`, `maxloc`, a 16-bit real) is nex's own whatever `fast` says. **A tuple or a
struct is refused** — *"`allreduce` takes its operand as a number or a `bool`, or an array of them;
a tuple or a struct waits for structs by value (DESIGN §15), and this is (real64, real64)"* — until
structs pass by value; then a `@c` struct crosses as `MPI_Type_create_struct` of the layout nex
already computes (§10.2). The one pair D2 has is the answer of `minloc` and `maxloc`, a value and a
rank. A string is refused with its type.

**A view is an MPI datatype, never a copy.** Where §10.3 copies a strided view because C takes a
bare pointer, MPI takes a pointer *and* a description, so every window crosses where it lies:

- rank 1 with stride `s` (negative included): `MPI_Type_create_hvector(n, 1, s * bytes, elem)`;
- rank 2, a window of a column-major root with leading dimension `ld`: `MPI_Type_vector(columns,
  rows, ld, elem)`, and the hvector of a hvector when the first axis is strided too;
- rank k: one `hvector` per axis, innermost first; a box of a dense root is
  `MPI_Type_create_subarray` with `MPI_ORDER_FORTRAN`, which is nex's order.

The module's externs take every buffer as `[*; ..]` (§10.7), so one `send` written in nex covers
every element type and rank, and one entry point of the shim serves each collective; the shim reads
the element type, the extents and the byte strides from the descriptor. The pointer is the window's
first element, as in §10.3. Until D3 builds the datatypes, the shim packs a view that is not one
dense block into a buffer of its own and unpacks a received one, which is correct for a blocking
call. A committed datatype is cached by (element, extents, strides), so a halo exchange in a loop
commits once. A dense array is the element type and a count.

**Units cross as their numbers.** A unit is a static fact of the program and a message carries
none; each end's types are checked locally, against its own declarations, as in any SPMD program.
A collective answers its operand's unit: `allreduce(e, +)` of `[real J]` is `[real J]`, `max` keeps
it, and `*` of a measured value is refused as `product` is (§13.4).

**Shapes.** A rank-k array's shape is known on each rank. A collective `MPI_Allgather`s every
rank's shape before it moves data and traps on every rank where they disagree (§9.6.2); `recv`
checks the message's count against its array's. The `v` variants (`MPI_Gatherv` and the rest) are
the `_concat` forms', written where the pieces' lengths differ, their counts taken from the
gathered shapes.

#### 9.6.4 Errors

Every communicator nex creates has `MPI_ERRORS_RETURN`, and a failed call **traps**, as the value
forms of LAPACK do (§10.5): the message names the operation in nex's terms and the cause from
`MPI_Error_string` — *"send: rank 9 does not exist in a communicator of 8"*, *"recv: message
truncated: 12 values into an array of 10"*. A trap can be caught locally by `assert_traps`, but no
MPI error leaves the other ranks in a known state, so an uncaught one aborts the job (§9.6.2). MPI
reports no error a program could handle the way `solve_inplace` reports a singular matrix, so there
is no `Result` form; fault tolerance (ULFM's `MPI_Comm_shrink`, Fortran's `stat_failed_image`) is §15.

#### 9.6.5 Determinism of reductions

§9.2.1 makes a reduction independent of the thread count. `MPI_Allreduce` gives no such promise:
the standard leaves the bracketing of a commutative operation to the implementation, which chooses
by message size, rank count and topology, so the bits can change with `-np`, with the node layout
and between MPI versions. nex promises:

1. **A distributed reduction is reproducible for a given rank count**, run to run, node layout to
   node layout, implementation to implementation: `reduce_to`, `allreduce` and `scan` with a
   built-in operator combine the ranks' contributions in §9.2.1's fixed pairwise tree over the rank
   numbers (for `scan` on rank r, over ranks 0 to r), the same bits on every rank. The shim builds
   them from an `MPI_Allgather` of the contributions — `MPI_Gather` to the root for `reduce_to` —
   about 4 MB at a time, and a local combination in C, each product and sum rounded on its own as
   nex rounds them (the shim is compiled with `-ffp-contract=off`); never `MPI_Allreduce` with
   `MPI_SUM`. Every built-in operator takes this path, the exact ones too (integers, `min`, `max`,
   `and`, `or`, `minloc`, `maxloc`), so an integer overflow traps as nex's does (*"allreduce: int64
   overflow"*) and a real `min` or `max` follows §7.4's `nan` rule. A **user operator** is folded by
   the compiled program itself, in rank order (`f(f(x0, x1), x2)` …), over an `allgather` of the
   contributions, element by element: the same bits on every rank and every run.
2. **A distributed sum of a distributed array is independent of the rank count**:
   `global_sum(x_local, offset)`, where `x_local` is a vector of numbers and `offset` the global
   index of its first element, reduces the §9.2.1 blocks *aligned to the global numbering* — a block
   a rank holds whole by that rank, a block split between ranks from their pieces' terms in global
   order — gathers the block partials (one number per 4096 elements: 2 MB for a billion), and runs
   the whole tree on every rank: the bits of `sum` over the undistributed array, for any `-np` and
   any cut, as `OMP_NUM_THREADS` changes nothing. The pieces cover `1..n` once each, in any order of
   the ranks, or every rank traps (*"global_sum: the ranks' pieces cover 1..6 once each, and none
   begins at 3"*). `global_dot(x, y, offset)` (the terms `conj(x[i]) * y[i]`) and
   `global_norm2(x, offset)` (of reals and complexes) the same, against `dot` and `norm2`.
3. **`fast = true`** on a reduction hands it to `MPI_Allreduce`, `MPI_Reduce` or `MPI_Scan` with
   MPI's operator, for the code that measures the difference and accepts MPI's bits; where MPI has
   no operator for the type (§9.6.3) the reproducible path runs. A user operator takes no `fast`.

#### 9.6.6 `parallel` inside an MPI program

A rank is one process and its `parallel` constructs use `OMP_NUM_THREADS` threads, the hybrid
MPI+OpenMP layout of every modern cluster (`srun --ntasks-per-node=4 --cpus-per-task=16`). An `mpi`
call is not `@pure`, so §9.4 already refuses it in a parallel body: only the thread that runs `main`
calls MPI, which is **`MPI_THREAD_FUNNELED`**. The program decides the level, as it decides libomp
(§9.5): one with a `parallel` construct asks for `FUNNELED`, one without for `SINGLE`, and a library
providing less traps at start-up with the level it gave.

#### 9.6.7 Building, linking and launching

**The link follows the cluster's MPI**, found in this order: `NEX_MPICC`, else `mpicc` on `PATH`
(what `module load openmpi` or `module load mpich` puts there), asked for its flags —
`mpicc --showme:compile` / `--showme:link` for Open MPI, `mpicc -compile_info` / `-link_info` for
MPICH — else `pkg-config` of `ompi-c` or `mpich`. A program importing `mpi` without one is refused at
the link, naming what was looked for, as a `@fortran` program without gfortran is (§10.6). Each `-L`
directory of the link is also the program's run-time search path, so the executable runs without the
environment `module load` gave the build. A program that does not import `mpi` links no MPI and no
shim.

**One binary is built for one MPI.** The module's shim (`mpi/nex_mpi.c`, beside the module's nex
text `mpi/mpi.nex`, both part of nex) — a C file that includes the found `mpi.h` and the
descriptor's `nex_desc.h` (written beside it), compiled with `-ffp-contract=off` by
the found `mpicc` (by clang with `pkg-config`'s flags where that found the MPI) and kept in nex's cache
directory under a key of its text, the compiler and its flags, so each MPI compiles it once — turns
handles into what nex can hold:
`MPI_Comm_c2f` integers (an `int32` inside `Comm` and the datatype cache) and the predefined
constants read from the header, so nex declares no implementation's numbers. A binary is for the
MPI it was linked against, as a Fortran or C MPI program is. **Where `mpi_abi.h` is found** (MPI
5.0's ABI: MPICH 4.3 built with it, Open MPI 6), the shim is compiled against it and links
`libmpi_abi`, and the binary runs under any MPI that implements the ABI — chosen at run time by the
library path, as the ABI intends.

**Launching.** `nex build` writes an ordinary executable, launched as every MPI program is:
`mpirun -np 64 ./heat` or, in a Slurm batch script, `srun ./heat`. `nex run --np N file.nex` builds
and runs it under `mpirun -n N`, the `mpirun` beside the found `mpicc`, else `mpirun` or `mpiexec` on
`PATH` (`NEX_MPIRUN`, split at its spaces, overrides the launcher, and `-n N` follows it; inside a
Slurm allocation — `SLURM_JOB_ID` set — it is `srun -n N`). `nex test --np N` runs each test as an
N-rank job, and a test that traps on a rank fails with the rank in front of its message (`FAIL t:
rank 2: index out of bounds`). `--np` is not `--interp`'s, which never starts a job. A program
importing `mpi` run without a launcher is a single rank (`MPI_Init` gives a world of one), which is
how it runs in the playground's compiled mode and in `nex test` without `--np`.

#### 9.6.8 Decisions

1. **Rank numbering.** MPI numbers ranks from 0; nex indexes from 1 and Fortran's `this_image()`
   from 1. *Decided: 0-based ranks in `mpi`*, since a rank is an identity, not an index, and
   every `mpirun` message, Slurm's `SLURM_PROCID` and MPI document are 0-based; coarray images
   (§9.7) are 1-based, as Fortran's are.
2. **Implicit `MPI_Init`/`MPI_Finalize`.** *Decided: implicit, by importing `mpi`*, as
   coarrays are; an explicit `init()` is one more thing to forget and to call twice.
3. **The nonblocking form.** The `exchange` block (scoped, checked, no request values) or a
   `Request` value with `wait` (MPI's shape, flexible, not checkable without linear types).
   *Decided: the block*, with `Request` left out until a program needs a request that
   outlives a scope.
4. **The shim's language.** C compiled by the found `mpicc` (the cluster's own source of headers
   and flags), or sysl in the runtime built per MPI. *Decided: C through `mpicc`*, the one file
   that includes `mpi.h`, which also packs buffers and combines reductions.
5. **Default reduction determinism.** Reproducible for a fixed rank count by default with
   `fast = true` to opt out (above), or MPI's own by default with `reproducible = true` to opt in.
   *Decided: reproducible by default*, the rule `parallel` already follows; the cost is one
   allgather of partials, small next to the computation of a real code, and `fast = true` is there
   for the code that measures otherwise.
6. **`global_sum`'s np-independence across rank counts.** Worth a separate entry point, or folded
   into `allreduce` of a distributed array once arrays know their distribution (coarrays).
   *Decided: the separate `global_sum`/`global_dot`/`global_norm2` now*, since they are what
   a Krylov solver needs and the only place rank-count independence is cheap.
7. **Errors.** Traps only (above), or a `Result` form for the errors a fault-tolerant program
   handles. *Decided: traps only*, with fault tolerance as its own later item.
8. **Where the module's functions live.** All in nex over `[*; ..]` externs, or the collectives as
   compiler intrinsics. *Decided: the collectives are intrinsics, as Fortran's `co_sum`,
   `co_reduce` and `co_broadcast` are* (§9.6.2): one function over a scalar or an array of any rank,
   element type and unit, an operator as an argument and a result one rank higher than the operand
   are more than a generic `def` says. The communicators, `send`/`recv`/`sendrecv`, `this_rank`,
   `num_ranks`, `blocks` and the launch are nex.
9. **Ranks of gathered values.** *Decided: static*: `gather` of rank k is rank k + 1, the shapes
   checked at run time; pieces of differing lengths are the `_concat` forms', which keep rank k.
   Structs and tuples wait for structs by value (§15).

### 9.7 Coarrays (planned)

Fortran 2008/2018 coarrays are the distributed-memory model in the language rather than in a
library, and parity with them is the goal after `mpi`. The sketch, each part to be designed when it
is built:

- **Images.** `this_image()` and `num_images()`, 1-based; every image runs `main` (SPMD). An image
  is an MPI rank.
- **Coarrays.** A module-level `var` or a local declared with a codimension — the spelling is
  open: `var u: [real; 100] on *` reads like Fortran's `u(100)[*]` — exists once per image, the same
  shape on all. `u{p}[i]` (or another spelling) reads or writes image `p`'s element; without a
  coindex it is this image's, an ordinary array. A remote window `u{p}[2..9]` is a view (§6) over
  another image, so it crosses as a datatype.
- **Synchronisation.** `sync all`, `sync images(list)`, `sync memory`, `critical` blocks, `lock`
  and `unlock` on a lock variable; segment ordering as Fortran's.
- **Collectives.** `co_sum`, `co_min`, `co_max`, `co_reduce(x, op)`, `co_broadcast(x, source)`,
  in place, as Fortran's subroutines are — reproducible as §9.6.5 is.
- **Teams.** `form team`, `change team … end team`, `team_number`, `get_team`; an image's world
  inside `change team` is its team.
- **Events.** `event post(e{p})`, `event wait(e, until_count = n)`, `event_query`.

**Built over MPI one-sided communication**, as OpenCoarrays builds gfortran's `-fcoarray=lib`: a
coarray is one `MPI_Win_allocate` (collective, symmetric, so its allocation is an implicit
`sync all`), the windows are opened once with `MPI_Win_lock_all` (passive target); a remote read is
`MPI_Get` + `MPI_Win_flush`, a write `MPI_Put`, completed at the next image control statement;
`sync all` is `MPI_Win_flush_all` + `MPI_Barrier`; `sync images` point-to-point messages; events
and locks `MPI_Fetch_and_op` / `MPI_Compare_and_swap` on a counter window; `form team` is
`MPI_Comm_split`, and each team's coarrays live in windows of its communicator. The `mpi` module's
shim, datatype cache and determinism rule are what coarrays reuse; failed images
(`stat_failed_image`) wait for ULFM.

**Decisions for coarrays.**

8. **Coindex spelling.** Fortran's square brackets are nex's indexing. *Decided: braces*,
   `u{p}[i]` — free in expressions today (only import lists use them), short, and visibly not an
   index.
9. **Mixing `mpi` and coarrays in one program.** *Decided: allowed*, with `world()` the
   initial team's communicator, as Fortran compilers built over MPI allow it in practice.

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

- **The attributes of an `extern def` are `@link`, `@symbol`, `@pure` and `@fortran`**; any other
  is an error, as is `@symbol` given twice. **Two externs may not name one C symbol**: the C
  function has one signature.
- **`-L dir` and `-l lib`** (or `-Ldir`, `-llib`) may stand anywhere on the command line before
  `--`, before or after the file. The command line's directories are searched before the program's
  `@link`s are linked, so a `@link("mylib")` finds `libmylib` in a `-L` directory.
- **An argument or result that is an 8- or 16-bit integer or a `bool` is widened as clang widens
  it** (sign- or zero-extended by the caller, as Apple's arm64 ABI requires), and every C
  declaration nex makes is clang's declaration of the same prototype.
- **`@pure` is what lets a call run anywhere order is not fixed**: a parallel body (§9.4) and an
  `@elemental` function call only `@pure` externs, directly or through any function they call.

### 10.2 What crosses

| nex parameter | C sees |
|---|---|
| `int8` … `int64` | `int8_t` … `int64_t` |
| `uint8` … `uint64` | `uint8_t` … `uint64_t` |
| `real32`, `real64`, `real16` | `float`, `double`, `_Float16` |
| `complex[real32]`, `complex[real64]` | `float _Complex`, `double _Complex`, **by value** |
| `bool` | `bool` (`_Bool`) |
| `inout` scalar | a pointer to it (`int32_t *info`) |
| `string` (read mode only) | `const char *` to the string's own NUL-terminated UTF-8, valid for the call |
| `[T; …]` read mode | `const T *` to the first element of the window |
| `[T; …]` `inout` | `T *` to the first element; C's writes land in the caller's array |
| a `@c` struct, read mode or `inout` | `const S *` / `S *` to the struct, laid out as C lays it out |
| a function type `(A, B) -> R` | a C function pointer (§10.2.1) |
| `c_ptr` | `void *`, opaque, only as a callback's `@data` partner (§10.2.1) |
| `[*; ..]`, read mode or `inout` | `const nex_desc *`: any array of numbers or `bool` at any rank, or a scalar, described (§10.7) |
| return: a scalar, a complex or `void` | the value, or C `void` |

**Complex scalars cross by value.** nex mirrors clang's ABI for `_Complex` on each target, so
`double _Complex` arguments and results agree with C: on arm64 a complex is a homogeneous
floating-point aggregate in two consecutive FP registers; on x86-64 System V it is two SSE values
(a `complex[real64]` in two SSE registers, a `complex[real32]` packed in one). On arm64 an argument
is passed as clang passes it, the array of its two parts (`[2 x double]`), so arguments past the
eight FP registers go on the stack whole, and a result comes back as the struct of its parts.
Complex **arrays** cross as pointers to interleaved (re, im) pairs, C99's layout.

**`@c` structs cross by reference.** A struct declared `@c` has C's field order, alignment and
padding, and passes as a pointer (`const S *` in read mode, `S *` as `inout`). A read-mode struct
is passed as a copy, so a C function that writes it changes nothing of the caller's. A `@c` struct
holds only numbers, `bool` and other `@c` structs, and is not generic; `@c` is the one attribute a
struct takes. A struct **by value** does not cross yet (§15).

**What else is refused**: an `inout` string, an array of anything but numbers or `bool`, a struct
not declared `@c`, a tuple or an enum as a parameter; a string, an array or a struct as a result.
`c_ptr` is a type only an `extern` declaration names, only as a `@data(f)` parameter whose `f` is a
parameter of function type of the same extern, and never `inout`.

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
no `@data` partner is a compile error, as is a function value held in a variable: without a partner
the argument is a `def` or an `extern` named directly, or a lambda that captures nothing.

**A callback's types cross by value.** Its parameters and result are numbers, `bool` and complexes
as the table above passes them, never `inout`; an array, a string or a struct does not cross to a
callback, since C hands over no extent with a pointer. Its type holds one `c_ptr`, where C hands the
user data back, exactly when it has a `@data` partner, and an extern has one `@data` per callback.

**A trap inside a callback never crosses C's frames.** The callback stops, C's call goes on, and
every callback C makes after it in the same call returns zero (or nothing) without running; when C
returns, the trap is raised in the nex frame that made the extern call, where `assert_traps` or the
program's end sees it like any other. A trap in a callback of a callback ends the inner extern call,
then the outer. With nothing to catch it, a trap ends the program where it happens, as any trap does.

**A callback runs on the thread that made the extern call, while the call runs.** Called after the
call returned, or on a thread C started, it has no nex frame to give a trap back to and no hold on
its closure, and the program ends with a trap saying so.

**An `extern` is a function value** where everything it takes and returns crosses by value — numbers,
`bool` and complexes, none `inout`: `val f = cbrt`. Passed for a callback with no `@data` partner it
is C's own function pointer. Any other extern is only called.

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
auto-clone. `@strided` may mark an array parameter of any rank, and passes the view as it lies at
every rank. A copy is to a dense column-major block, so a copied rank-2 view's leading dimension is
its own row count.

**Whether a copy is needed is decided at run time**, from the strides of the array as it lies, since
a parameter or a computed slice step is not known at compile time; where they are (a dense local, a
constant), the test folds away. **An `inout` window is written where it lies**: C gets a pointer into
the buffer of the window's root (the outermost array of the place), so its leading dimension is the
root's, and a value that shares the root keeps its elements — the root is copied whole first,
every stride kept, exactly where value semantics needs it. `strip` of a measured array is the same
array and copies nothing.

**Lowering.** The pointer is `memref.extract_aligned_pointer_as_index` plus the offset from
`memref.extract_strided_metadata`; the leading dimension is the stride of the memref's first
dimension, which is nex's second axis (§3.2). A call with an `inout` array goes through a wrapper
function taking each root as a tensor, so that bufferization sees an ordinary call writing an
`inout` argument; the window is a `memref.subview` of the root's buffer. A copy is made and given
back by the runtime (`nex_c_gather`, `nex_c_scatter`) from the memref descriptor. `blas.mlir` calls `cblas_dgemm` from Accelerate on a
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
   *(unverified on Linux)*, through the LP64 (`int32`) interface. **A program whose `@` or
   linear-algebra prelude calls BLAS or LAPACK links it with no flag**, and one that calls neither
   links none; `NEX_BLAS` names other link options in its place (`NEX_BLAS="-L/opt/openblas/lib
   -lopenblas"`). **Which library is the default is chosen once, by the runtime's `library`
   feature** (`platform`, or `openblas` found through `pkg-config`), so the interpreter and the
   programs the compiler links use the same one.

**Both engines run one implementation of every linear-algebra operation**: the runtime's
(`sh.sysl.nex_runtime`, on the `blas` and `lapack` packages). The compiler emits a call of its entry
for the operation with each operand where it lies — the address of its first element, its extents,
its leading dimension and its flag — and the interpreter calls the same functions on its own arrays,
so the two answer bit for bit alike.

The routine follows the shape: `gemm`, `gemv` (`T` flag for vector-matrix), `dot` (`dotu` for
complex: nex's `@` does not conjugate). `x @ conj(transpose(Y))`, which `gemv` has no flag for, is
`gemm` with `x` as one row. With static extents the decision is made at compile time; with dynamic
ones the compiler emits both paths and a run-time test, both writing one result buffer made before
the test; the test stays in the emitted code because the small path is a `linalg` operation inline. Operands that fail §10.3's stride rules are copied first, and so is a matrix whose column
stride is less than its row count. The prelude's `dot(x, y)` is a reduction (§9.2.1), reproducible
and never dispatched; `x @ y` is the product and dispatches.

**`C = alpha * (A @ B) + beta * C` is one BLAS update**, `gemm` with `alpha` and `beta` (`gemv` where
`B` or `A` is a vector), writing `C` where it lies with no buffer for the product. The forms
recognized are an assignment to a `var` local `C` of `real32`, `real64` or complex elements that no
lambda captures, whose value is the sum, in either order, of

- a product term: `A @ B`, `alpha * (A @ B)` or `(A @ B) * alpha`, and
- a term of `C`: `C`, `beta * C` or `C * beta`,

and the compound `C += P` for a product term `P`. `alpha` and `beta` are scalars of `C`'s number type,
any expression (a literal, a variable, a call); an operand written `transpose(X)` or
`conj(transpose(X))` keeps its flag. Each operand is evaluated once, in the order written. **Where
an operand of `@` reads `C`** (`C = A @ C + C`, `C = C[1..2, :] @ B + C`) BLAS would read the storage
it writes, so the statement takes the general path: the product made, then the sum. Any other
spelling — a difference, three terms, `C` on a slice, a captured `C` — is the general path too.

The update goes to BLAS exactly where the product alone would, by the rules above; with dynamic
extents both paths are emitted under the run-time test. **Below the threshold the statement is the
expression as written**: the product computed inline, then `alpha * P + beta * C` element by
element, each operation rounded as written, as an unrecognized statement would be. Through BLAS the
update rounds as the library's `gemm` does: `alpha` scales the sum, then `beta * C` is added, and as
BLAS specifies, a `beta` of zero leaves `C`'s old elements unread (a NaN there does not reach the
result) and an `alpha` of zero leaves `A` and `B` unread. Both engines make the same call
(`la_update` in the runtime), so they answer bit for bit alike. Where `C` has not the product's
extents the statement traps *"shape mismatch"* on either path.

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
| `det(A)` | `?getrf` | the determinant: U's diagonal multiplied in order, negated per row interchange, each product rounded as nex's `*` rounds it (a complex one's four products unfused); `0.0` for a singular matrix (no trap) |
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

**The number types are LAPACK's four**: `real32`, `real64`, `complex[real32]` and
`complex[real64]` (`s`, `d`, `c`, `z`). An integer matrix is taken as `real64`; `solve` and `lstsq`
meet their two operands in one type as `@` does; `real16` is a compile error. A matrix argument has
rank 2 and a right-hand side rank 1 or 2. Where the extents that must agree are both static — a
square matrix for `solve`, `inv`, `det`, `chol`, `eigvals`, `eig` and `eigh`, the right-hand side's
rows — a mismatch is a compile error; otherwise the call traps (*"inv: the matrix is not square"*).
Static extents carry into the results.

**What each result is**, where the table leaves a choice:

- `lu(A)` of an m × n `A`, with k = min(m, n): `L` is m × k with a unit diagonal, `U` is k × n, and
  `p` is an `[integer]` permutation of `1..m` with `A[p[i], :] == (L @ U)[i, :]` — the row
  interchanges applied in order, not LAPACK's `ipiv`.
- `qr(A)` is the thin factorization: `Q` is m × k with orthonormal columns, `R` is k × n.
- `svd(A)` is thin: `U` is m × k, `s` has k values, `V` is n × k.
- `chol` reads one triangle only, the lower, or the upper with `upper = true`, and does not check
  that `A` is symmetric; the result's other triangle is zero. `eigh` reads the lower triangle.
- `eigvals` and `eig` give the values in LAPACK's order, unsorted, a conjugate pair adjacent with
  its positive imaginary part first; each vector has unit 2-norm and its largest component real.
- `lstsq` is the minimum-norm solution, singular values below machine precision taken as zero
  (`?gelsd` with `rcond = -1`), so a rank-deficient `A` does not fail.
- `det` is the product of `U`'s diagonal, its sign flipped once per row interchange: exactly `0.0`
  where `?getrf` finds a zero pivot.

**The value forms** take and return values, copying their inputs because LAPACK overwrites them,
and **trap** when LAPACK's `info` reports failure, with a message naming the routine and the cause
in the user's terms: *"solve: matrix is singular (U[3,3] = 0)"*, *"chol: matrix is not positive
definite (leading minor 4)"*, *"svd: did not converge"*. The indices in a message are 1-based, as
LAPACK's `info` already is. Only the solvers (`solve`, `inv`, …) trap on a singular matrix. An
`info` below zero names an argument LAPACK refused, which no well-typed call makes: *"solve:
LAPACK's dgesv refused its argument 4"*.

**The `inout` forms** factor in place without the copy and do **not** trap on what LAPACK reports:
they return LAPACK's `info` as an `integer`, for the code that wants to handle a singular matrix
itself. There are four:

| Function | LAPACK | Writes |
|---|---|---|
| `solve_inplace(A, ipiv, B)` | `?gesv` | `A` with its LU factors, `ipiv` with the pivots, `B` with the solution |
| `lu_inplace(A, ipiv)` | `?getrf` | `A` with L below the diagonal and U on and above it, `ipiv` |
| `chol_inplace(A, upper = false)` | `?potrf` | the triangle it reads with the factor; the other is untouched |
| `qr_inplace(A, tau)` | `?geqrf` | `A` with R and the reflectors, `tau` with their scales |

Their arrays are borrowed as they are, so each is of one of the four types exactly (`ipiv` is
`[int32]`, `tau` and `B` are of `A`'s element type), and carries no unit: the factors written over a
measured matrix would not share its unit (§13.6). A window crosses where it lies (§10.3). An `ipiv`
or `tau` shorter than min(m, n), or a `B` without `A`'s rows, traps.

Column-major storage means no transposes, and the leading-dimension rules are §10.3's. **LAPACK is
called as Fortran**: every argument by reference, and each `character` argument's length (1) passed
after the others, as gfortran's convention has it and as an f2c-built LAPACK ignores.

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
     `@symbol` overrides it (a module procedure's `__mod_MOD_name`). Fortran names are
     case-insensitive, so `faxpy` and `FAXPY` are one symbol and two externs cannot declare both.
     `@fortran` takes no arguments.
  2. **Every argument by reference**, as Fortran passes it: a read-mode scalar passes the address of
     a temporary copy, an `inout` scalar the address of the caller's place. In a parallel body each
     thread has its own temporaries.
  3. **Hidden string lengths**: each `string` argument passes its pointer in place and its length
     in bytes as an extra trailing argument (`size_t`, gfortran's convention since gfortran 8), in
     order after all the declared arguments, so `len(s)` in Fortran is the string's byte count,
     trailing blanks included. Fortran strings are not NUL-terminated and Fortran reads no
     terminator. A string is read-only (`intent(in)`): an `inout` string is an error.
  4. **Arrays** pass as for C (§10.2, §10.3): column-major is native, so a dense array or a
     leading-dimension view crosses with no copy, a view strided along the first axis is copied in
     (and back for `inout`), and Fortran's 1-based indexing matches nex's.
  5. **Complex** is by reference like every other argument; a `complex(8)` or `complex(4)` function
     result comes back by value as a C `_Complex` does, which is gfortran's convention on arm64 and
     x86-64 (no `-ff2c`).
  6. **`bool` is a default `logical`** — gfortran's kind 4, 4 bytes, `.true.` stored as 1 and any
     nonzero read as true — as argument, `inout` and function result. An array of `bool` is an
     error, since a `[bool]` holds bytes and a `logical` array 4-byte words: declare it `[int32]`
     (0 and 1). A `logical(c_bool)` is reached through `bind(c)`, where it is C's `bool`.

**Callbacks to Fortran.** A Fortran procedure calls an `external` dummy with every argument by
reference, so the trampoline nex passes for a callback parameter of a `@fortran` extern takes an
address for each argument and reads it as a value (a `logical` as 4 bytes); its result returns by
value, a `logical` as 4 bytes. Its parameters are numbers, `bool` and complexes and never `inout`.
Fortran hands a callback no user data, so a `@fortran` extern has no `c_ptr` and no `@data`, and its
callback is a `def`, a C `extern` (called through the trampoline, since C takes values) or a lambda
that captures nothing. Traps in a callback behave as in §10.2.1.

**A `@fortran` extern is only called**: it is not a function value, and is not passed as a callback,
since nothing but a Fortran caller passes its arguments by reference. A `def` that calls it is.

What does not cross: Fortran assumed-shape (`a(:)`) dummies of a non-`bind(c)` procedure, which
need gfortran's array descriptor; derived types (a `@c` struct is an error on a `@fortran` extern);
`optional` arguments. Each is reached through a `bind(c)` wrapper written in Fortran. LAPACK and BLAS
(§10.4, §10.5) are themselves Fortran and are called through these rules.

**Linking.** `nex build` and `nex run` link the gfortran runtime automatically when the program has
a `@fortran` extern, so a static Fortran archive links as it is: the runtime's directory is what
`gfortran -print-file-name=libgfortran.dylib` names (`libgfortran.so` elsewhere), linked with
`-lgfortran` and recorded as the program's run-time search path. The gfortran asked is
`NEX_GFORTRAN`, else Homebrew's `/opt/homebrew/bin/gfortran`; with none there the link is refused
with a message saying so. A program calling only `bind(c)` procedures links no Fortran runtime of its
own: a Fortran shared library names its runtime itself. The Fortran library comes from
`@link("name")` or `-l name`, found on the default search path or a `-L dir` given on the command
line; a procedure no linked library defines is the linker's undefined-symbol error naming the
mangled symbol (`_fdot_`).

### 10.7 Any type, any rank: `[*; ..]` and its descriptor

Fortran 2018 lets a `bind(c)` procedure take an argument of **any type at any rank** —
`type(*), dimension(..)` — which C receives as a `CFI_cdesc_t *` from `ISO_Fortran_binding.h`: the
base address, the element type and size, the rank, and an extent and byte stride per axis. It is how
MPI's Fortran 2008 bindings (`mpi_f08`) give one `MPI_Send` for every buffer, and how a library such
as HDF5, NetCDF or PETSc offers one entry point over every element type. nex has the same thing, for
the same reason: **one `extern` takes any array of numbers or `bool`, at any rank, or a scalar, and C
gets a pointer, the shape, the strides and the element type.**

```nex
extern def nex_send(x: [*; ..], to: int32, tag: int32)
extern def nex_recv(x: inout [*; ..], from: int32, tag: int32): int32

def send[T: Numeric, R: Rank](x: [T; R], to: integer, tag: integer = 0) =
  nex_send(x, int32(to), int32(tag))
```

```c
#include "nex_desc.h"
void nex_send(const nex_desc *x, int32_t to, int32_t tag);
int32_t nex_recv(const nex_desc *x, int32_t from, int32_t tag);
```

Without it a library over every element type could not be written in nex: a generic body cannot
hand its `[T; R]` to an `extern`, whose parameter has one element type and one rank; an `extern`
is not generic; and nex has no overloading by type to give one `extern` per element type.

**The spelling `[*; ..]` (PROPOSED)** is nex's array type `[T; axes]` with Fortran's two wildcards in
their places: `*` for the element type, as `type(*)`, and `..` for the axes, as `dimension(..)`. It
reads as what it is, an array type, and needs no new keyword. The two go together: `[*]` and
`[real; ..]` are refused (*"an array of any element type is of any rank too: `[*; ..]`"*, and *"`..`
is an assumed rank, which an array of any element type has: …"*), since a parameter of one element
type at any rank is what a generic `def` over `[T; R]` already writes.

**What may be passed:**

- **an array of any element type C has a code for** — `int8` … `int64`, `uint8` … `uint64`,
  `real16`, `real32`, `real64`, `complex[real16]`, `complex[real32]`, `complex[real64]`, `bool` — at
  any rank, whole, a window, a strided view or a reversed one;
- **a scalar of those types, as rank 0**: `nex_send(2.5, …)`, `nex_recv(count, …)`;
- **a measured value or array, as its numbers**: the unit is a static fact and the descriptor
  carries none (§13.7), so neither `strip` nor a unit-free declaration is needed;
- **a generic body's `[T; R]` or `T`**, where `T`'s constraint admits only numbers and `bool`
  (`Numeric`, `Float`, `Integral`, `Real`, `Complex`): the body is checked once against the
  constraint (§2.6), and each instance hands C the descriptor of its own element type and rank.
  `T: Eq` admits `string`, so it is refused: *"…, and argument 1 is [T], whose `T: Eq` admits more
  than numbers and `bool`: constrain it `T: Numeric`"*.

**`inout` makes it writable**, as for any `extern` parameter: the argument is a place (§8), borrowed
for the call under §8.3's exclusivity rule, and C writes where the view lies — through a strided or
reversed view, into the elements the view names. A read-mode argument is a promise that C does not
write, as in §10.2. The descriptor says which it is.

**The descriptor** is the C struct `nex_desc` of `include/nex_desc.h`, which nex ships:

```c
typedef enum nex_type {
    NEX_INT8 = 1, NEX_INT16, NEX_INT32, NEX_INT64,          /* 1-4 */
    NEX_UINT8, NEX_UINT16, NEX_UINT32, NEX_UINT64,          /* 5-8 */
    NEX_REAL16, NEX_REAL32, NEX_REAL64,                     /* 9-11 */
    NEX_COMPLEX_REAL16, NEX_COMPLEX_REAL32, NEX_COMPLEX_REAL64, /* 12-14 */
    NEX_BOOL                                                /* 15 */
} nex_type;

typedef struct nex_dim { int64_t extent; int64_t stride; } nex_dim;

typedef struct nex_desc {
    void *base;          /* the first element: index 1 along every axis */
    int64_t elem_size;   /* bytes of one element */
    int32_t type;        /* a nex_type */
    int32_t rank;        /* 0 for a scalar */
    int32_t contiguous;  /* 1 where the elements are one dense column-major block */
    int32_t writable;    /* 1 for an inout parameter */
    nex_dim dim[];       /* rank axes, nex's first axis first */
} nex_desc;
```

C receives `const nex_desc *` for every `[*; ..]` parameter, read mode or `inout`. Element
(i₀, i₁, …), each counted from 0, is at `(char *)base + i₀·dim[0].stride + i₁·dim[1].stride + …`; the
header's `nex_desc_at` computes it and `nex_desc_count` the element count. It follows `CFI_cdesc_t`
where the two agree, so a C routine written against one reads the other: `base` is `base_addr`,
`elem_size` is `elem_len`, `dim[k].extent` and `dim[k].stride` are `extent` and `sm` — **strides in
bytes**, which is what lets one descriptor describe a column of a matrix and a view into an array of
complexes alike — and `dim[0]` is the first axis, Fortran's order. It leaves out `lower_bound`, since
C counts from 0 whatever the nex array's origin (§6.4), and the `version` and `attribute` fields,
whose job `writable` and `contiguous` do. A `bool` element is one byte, 0 or 1, C's `bool`; a
`complex[real16]` is two `_Float16`, the real part first.

**Views cross with no copy.** Where §10.3 copies a strided view because C gets a bare pointer, a
descriptor carries the strides, so every view crosses where it lies: `m[2..3, 2..3]` of a 3×4 matrix
is `base` at `m[2, 2]` with strides 8 and 24; `x[4..1 by -1]` is `base` at `x[4]` with stride −8;
`m[1..3 by 2, 4..1 by -3]` has strides 16 and −72. `contiguous` is 1 exactly where the elements form
one dense column-major block from `base` (an axis of extent 0 or 1 is dense whatever its stride), so
a C routine that wants a flat buffer tests it and copies only where it must. `@strided` says nothing
of a `[*; ..]` parameter and is refused on one. This is the ground of §9.6.3's views as MPI
datatypes: the module's shim builds the datatype from the descriptor's extents and strides.

**Lifetime: the descriptor and what it points at are valid for the call only.** The descriptor lies
in the caller's frame, and an `inout` window is the caller's buffer only while the call runs (§10.3);
a C function that keeps either past its return reads freed or reused memory. A nonblocking operation
that must outlive its call is §9.6.2's `exchange` block, which holds the buffer itself.

**What is refused:**

- an argument that is a `string`, a struct (a `@c` one included), a tuple, an enum or a function, or
  an array of any of them: *"a `[*; ..]` parameter takes an array of numbers or `bool`, or one such
  value, which C reads through a descriptor, and argument 1 is [P]"*. A `@c` struct has a C type of
  its own and is declared as such (§10.2); an array of them in a descriptor is for later (§15);
- `[*; ..]` anywhere but a C `extern`'s parameter — a `def`'s parameter, a variable, a field, a
  result, a callback's parameter, a `@host` function's: *"`[*; ..]` is an array of any element type
  at any rank, which only a C `extern`'s parameter takes; a `def` over any array is generic,
  `def f[T: Numeric, R: Rank](x: [T; R])`"*;
- on a `@fortran` extern: a plain Fortran procedure takes no descriptor, and a `type(*),
  dimension(..)` dummy is a `bind(c)` procedure's, whose `CFI_cdesc_t` is reached through a C wrapper
  declared as a C `extern`;
- `@strided` on it, as above; and an extern with one is only called, never a function value (§10.2.1).

**Compiled only**, like every `extern`: the interpreter never calls C (§16).

**Lowering.** The descriptor is an `llvm.struct<(ptr, i64, i32, i32, i32, i32, array<R x
struct<(i64, i64)>>)>` filled where the call is made, from `memref.extract_strided_metadata` of the
argument's buffer — the aligned pointer plus the offset for `base`, the buffer's sizes and strides
(times the element's bytes) for the axes, nex's first axis being the buffer's last dimension (§3.2)
— and stored in a slot of the caller's frame, whose address is the argument. A scalar is stored in a
slot of its own and described at rank 0. An `inout` window goes through the wrapper of §10.3, the
descriptor built inside it over the subview of the root's buffer; nothing is gathered or scattered.

---

## 11. Lexical changes

**Keywords** (ref §2.3) gain `inout`, `parallel`, `extern`, `enum`, and the loop and program
controls `exit`, `cycle` and `stop` (§11.1). `mut` stays reserved and means nothing. `by` (the step
of a range) and `reduce` (the `parallel for` clause) are contextual, so `reduce` remains a prelude
name. `unit` is a keyword: it declares a unit of measure (§13.1) and is no type, so `def f(): unit`
is an error that suggests `void`. The type names of
§2.1 are prelude type names, not keywords.

**Units**: a `<` written directly after a numeric literal, a name, a `]` or a `)`, with no space,
opens a unit of measure only if the text after it, up to a `>` on the same line, is valid unit
syntax (`9.81<m/s^2>`, `real32<m/s>`, §13.2) **and** the annotation ends the operand: what follows
the `>` cannot begin an operand (§13.2 lists what may). Otherwise it is the comparison, so `1<x`,
`0<x and x>1`, `0<x>1` and `lo<x<hi` compare. Inside the brackets, names are unit names in their own
namespace, so `in` is a unit there. A `<` after anything else, or after a space, is the comparison.

**Operator precedence**: `^` binds tighter than unary minus, so `-x^2` is `-(x^2)` as in Fortran and
mathematics, and `^` is right-associative (`2^3^2` is `2^(3^2)`). `^` is the only power operator;
there is no `**`. Logical `not` is not a tight unary: it binds below the comparisons and above `and`
(Fortran's `.not.`, Python's `not`), so `not a < b < c` is `not (a < b < c)` over the whole chain and
`not a and b` is `(not a) and b`; unary minus is unchanged (`-a < b` is `(-a) < b`). A unit annotation `<u>` is a postfix at the level of a call and a subscript, so it
binds tighter than `^`, unary minus and juxtaposition: `-3.0<m>^2` is `-((3.0<m>)^2)`.

**Chained comparisons**: two or more of `==`, `!=`, `<`, `<=`, `>`, `>=` in a row, mixed freely, are
one chained comparison, as in ref §4.6: `0 < x < 1`, `lo <= x < hi`, `a == b == c`. The parser
builds one node for the whole run (`Chain(operands, ops)`; a single comparison stays a `BinOp`) and
never rewrites it into `and`, which would write the middle operand twice. Parentheses end a chain:
`(a < b) < c` compares a `bool` with `c`. Each operand is evaluated **at most once, left to right**.
- **On scalars** the chain stops at the first false comparison and the operands after it are not
  evaluated: `0 < f() < g()` calls `g` only when `0 < f()` holds.
- **On arrays** (any operand an array, §7.1) each comparison is element-wise and the results are
  combined with an element-wise `and`, so `0.0 < a <= 1.0` is a `[bool]` of `a`'s shape. Every
  operand is evaluated exactly once, whole, before the comparisons; there is no per-element
  short-circuit. Shapes and broadcasting follow §7.1 pairwise.

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
- **`stop`** ends the program with exit status 0; **`stop n`** with status `n`. What was printed
  before it is written out first.
- **A `for` header takes a step**: `for k in n..1 by -1`, `for k in 1..n by 2`, read in the direction
  of travel exactly as a subscript's `by` (§5.4). A stepped range is a value (`val odd = 1..n by 2`).
- **A `for` over a range counts in integers**, as Fortran's `DO` does: the loop variable has the
  common type of the two bounds (`for k in 1..n` with `n: int32` counts in `int32`), the step must
  promote to it, and a range of reals is a compile error. The loop variable is read-only.
- **The bounds and the step are evaluated once, before the first pass**, and the number of passes
  is fixed then, as Fortran's `DO` fixes its iteration count: changing a variable the header read
  changes nothing, and the loop variable never steps past the last value it takes, so
  `for k in 120..127` with `k: int8` runs eight times without overflowing. A step of 0 traps.
- In a `parallel for` body, `cycle` ends that iteration and is allowed; `exit` is a compile error
  (§9.4).

### 11.2 The program

- **The entry point** is `def main()` or `def main(args: [string])`, returning `void`; any other
  signature of `main` is a compile error, and so is a program without one. `args` holds only the user's arguments, without the program name, 1-based:
  `args[1]` is the first, and an index outside `1..length(args)` traps. The exit status is 0 when
  `main` returns, `n` after `stop n`, and non-zero after an uncaught trap.
- **The top level of a file holds only declarations** (`import`, `const`, module-level `val` and
  `var`, `def`, `struct`, `enum`, `extern`); there are no top-level statements.
- **`print`** writes to standard output, **`eprint`** to standard error.
- **No `intent(out)`.** A function returns its results; several are returned as a tuple and taken
  apart with `val (q, r) = f(…)`.
- **`nex test`** runs every `@test def` in the project, in any module, prints one line per failure
  and then a summary, and exits non-zero on any failure. `nex test <substring>` runs only the tests
  whose names contain it. A trap fails its own test; the others still run.

### 11.3 Functions, statements and lambdas

- **A function with no declared result type takes it from its first `return`**, in source order, or
  from its body's value where it has none; every other result must promote to that type. A function
  that calls itself before its type is known (`def fact(n: integer) = … fact(n - 1)`) is a compile
  error asking for the type to be declared.
- **A function that returns `void` discards the value its body ends with**, as a statement does:
  `def main() = compute()` calls `compute` and returns nothing. A statement may be any expression,
  and an `if` used as a statement needs no common type for its branches.
- **A compound assignment never narrows its target**: `x op= v` computes `x op v` under §2.2, and
  the result must be `x`'s type. `n /= 2` with `n` an integer is a compile error, since `/` gives a
  real; `n = n div 2` is the integer division.
- **A lambda's parameter types come from its position** — a parameter of function type, an
  annotated binding — or are written (`(x: real) -> …`). A lambda bound by `val f = x -> …` with a
  type left out takes it from its first call (`f(10)` makes `x` an `int64`) or from the function
  type its first use expects, and keeps it: a later call with another type is checked against it.
  One whose types nothing fixes is a compile error. A `def` inside a body is a named lambda; it may
  call itself where it declares its result type.
- **How deep calls may nest is the engine's.** Interpreted, a call that would make more than 10,000
  calls nested at once — `main` among them — traps with `calls nested more than 10000 deep`, a trap
  like any other, which `assert_traps` catches. Compiled, the limit is the machine stack's, and running
  past it ends the program as the system ends a stack overflow. A program that recurses deeper than
  10,000 calls writes the recursion as a loop.
- **A default argument is an expression filled in at the call** (ref §6.5, the knob a CAD call
  leaves out: `cylinder(r: real<mm>, h: real<mm> = 10<mm>, segments: integer = 64)`). Where nex
  differs from Fortran's `optional` and `present()`: a parameter left out has a value, its default,
  and the callee cannot tell it was left out. The rules:
  - **It is evaluated at every call that leaves the argument out, afresh**, in its parameter's
    place among the arguments, which a call evaluates in parameter order: `id: integer = next_id()`
    calls `next_id` once per such call, and not at all in a call that gives `id`.
    Nothing is evaluated once and shared, so a default never remembers an earlier call.
  - **It sees the module-level names of the function's own module**, as a module-level binding's
    initializer does — functions (declared anywhere in it), bindings, constants, and the private
    ones too, wherever the call is — **and the parameters before its own**:
    `cylinder(r: real<m>, h: real<m> = 2 * r)`, `total(xs: [integer], n: integer = length(xs))`.
    A parameter it reads holds that call's argument, or that parameter's own default where the call
    left it out too; each argument is still evaluated once, before the defaults after it. A
    parameter's name hides a module-level name in the defaults after it. **It may not name its own
    parameter or a later one** (`h: real = 2 * r` before `r` is a compile error naming both), nor
    does it see the caller's locals.
  - **A default may call a function declared after it, and that call may leave out arguments the
    later function defaults** (`n: integer = g()` before `def g(k: integer = 3)`): every function's
    defaults are known before any call fills them in, whatever the declaration order and across
    modules. **A default may not reach its own function**, directly (`def f(n: integer = f(1))`)
    or through other functions' defaults (`def f(x = g())` with `def g(y = f())`): the cycle is a
    compile error naming each function on it, at the call that closes it, even where that call
    gives every argument. A function body may call the function with every argument given; a body
    elaborated while the defaults are (its result type undeclared, needed by a default) that
    leaves out an argument whose default is in the cycle is refused the same way.
  - **A default may read an `inout` parameter before it** (`by: integer = length(v)` after
    `v: inout [integer]`): it is an argument evaluated before the call starts, so the borrow rules
    of an argument beside a borrow apply (§8.3 rule 2) — a value computed from the place is legal, a
    read-mode array that is the place is refused at the call, as `f(a, a)` is. A default reading
    an `inout` parameter reads the place the call borrows, so that place may not call a function
    in a subscript (`f(a[g()])`), which would be evaluated twice.
  - **A lambda in a default captures no parameter**: the default is filled in at the call, where a
    lambda cannot capture the callee's parameter. It takes the value as an argument instead.
  - **An `@elemental` function applied to an array** does not fill a default that reads the
    parameter that array is passed for, which would see the whole array and not one element: such
    a call gives that argument. A default reading a scalar argument beside the array is filled.
  - **It is checked against its parameter's type** as an initializer is (§2.2–§2.4): a literal adopts
    it (`x: real = 1`), an integer widens, a narrowing is an error, and a measured parameter needs a
    default of its dimension (`r: real<mm> = 5<mm>`; `= 5.0` is an error, and `= 0.5<cm>` converts).
    In a generic `def`, it must have its parameter's type for every instance, so a parameter of type
    `T` takes no literal default.
  - **Defaults come last.** Once a parameter has a default, every parameter after it has one, so a
    call by position leaves out a trailing run; a named argument leaves out any defaulted parameter
    (`damp(10.0, floor = 6.0)`). A parameter without a default after one with a default is a compile
    error at the first such parameter, naming both.
  - **An `inout` parameter has none** (it borrows the caller's variable), **nor has an `extern`'s**
    (an `extern` transcribes the C prototype; a default belongs to a `def` that wraps it).
  - **A function value carries no defaults.** A function type has no parameter names or defaults,
    so a call through a function value, a function-typed parameter or a returned closure gives every
    argument, by position; a `def` with defaults passed as a value has its full type (`(int64,
    int64) -> void`). A local `def` is a function value, so its parameters take no default.

### 11.4 Structs, tuples, enums and `match`

The reference's structs, tuples, sum types and `match` (ref §3.4–§3.7, §4.16, §4.17, §7.5) stand,
with these rules (**PROPOSED** where marked).

- **A constructor takes its fields by position or by name**, as a call takes its arguments, a
  Fortran structure constructor's keyword components: `Point(y = 2.0, x = 1.0)`,
  `Rect(h = 2, w = 1)`. **PROPOSED.**
- **A struct's field may have a default** (`segments: integer = 64`), which a constructor that
  leaves the field out takes, under the rules of a parameter's default (§11.3) but two: evaluated
  afresh at each such constructor, checked against the field's type, it **sees the struct's module
  and no field**, not even an earlier one, and **a defaulted field may stand anywhere**, before a
  field without one, since a struct is declared as data and a constructor that leaves a field out
  names the fields after it. A field with no default is given. A generic struct's field whose type names a
  type parameter has no default, as a generic parameter of type `T` takes no literal one. **A
  variant's field has no default**: a variant is built and matched with all of its fields, and a
  pattern that left one out would not say which.
- **A variant's fields may be of any type**, not only the scalars the reference allows; §3.1 and
  §6.2 already store arrays and views in enum payloads. **PROPOSED.**
- **A struct or an enum cannot contain itself** by value, directly or through other structs, enums
  or tuples (`struct Node` with a field `next: Node`, `enum List` with `Cons(head: real, tail:
  List)`); it may hold itself through an array (`kids: [Node]`), which is a handle.
- **`==` and `!=` compare structs, tuples and enums field by field**: two values are equal where
  they are the same variant, for an enum, and every field is equal as `==` compares the field's
  type, so a `nan` field makes them unequal. A field that is an array is equal where the two arrays
  have the same shape and `all(a == b)` holds; arrays of different shapes make the values unequal,
  where `==` on the arrays themselves would trap (§7.1). A struct, tuple or enum that holds a
  function value, in a field at any depth or as an array's elements, has no `==`: comparing two is a
  compile error naming the field, and `Eq` (§2.6) does not admit it. A tuple built in place or a
  bare variant on one side takes its type from the other (`t == (1, 2.0)` with `t: (real, real)`,
  `s == Empty`); a tuple is never a struct, so `p == (1.0, 2.0)` with `p: Point` is a compile
  error. `<` and the other orderings are not defined on them.
- **Struct, enum and variant names share the top level** with functions and module-level bindings,
  and each is declared once: a variant `Empty` in two enums is a redeclaration. A local binding of
  the same name shadows a variant.
- **A tuple built in place converts element by element** to the tuple its position expects:
  `val t: (real, real) = 1, n` adopts `1` and widens `n`. A tuple value as a whole does not widen:
  `val u: (real, real) = t` with `t: (int64, int64)` is a compile error. **PROPOSED.**
- **A destructuring pattern nests**: `val a, (b, c) = 1, (2.5, true)`, and `for` takes the same
  patterns. Parentheses group a tuple inside another, and are what a type annotation needs.
- **A binding takes apart only tuples.** A variant pattern in a `val` or `var` (`val Converged(x) =
  s`) is a compile error, even where the enum has a single variant: a binding cannot fail, and `match`
  is how a variant is taken apart.
- **A tuple assignment stores a tuple into a list of places**: `a, b = b, a`, `p.x, (v[1], _) =
  f()`. The right side is evaluated whole first, then each element is stored into its target left to
  right, so `a, b = b, a` swaps. A target is anything a plain assignment may store into, or `_`. A
  right side written as a tuple converts element by element to the targets' types, as a tuple built
  in place does; a tuple value is stored as it is, without widening. A place written twice in one
  list (`a, a = 1, 2`) is a compile error, and a list of targets takes only `=`, never `+=`.
- **A module-level destructuring binding** (`val a, b = 10, 20`) evaluates its initializer once and
  binds each name as a module-level binding; one that binds no name (`val _, _ = …`) is a compile
  error, since the top level holds no statements.
- **A field is a place**: `p.x = v`, `o.i.v += 1`, `t.2 = 5` and `z.re = 1.0` write through a
  `var` or an `inout` parameter, and `p.x` or `t.1` may be passed `inout`. **PROPOSED** for `z.re`
  and `z.im`, as Fortran's `z%re`.
- **`x.f(args)` calls the field `f`** where `x` names a struct value with a function-typed field of
  that name, and is `f(x, args)` otherwise.
- **A `match` arm is a variant pattern, a name or `_`.** A variant with fields is matched with all of
  them, `Circle(r)`, `Rect(w, _)`; writing `Circle` alone for a variant with fields is a compile
  error. A field's sub-pattern is a name or `_`. A tuple pattern, as an arm or as a field's
  sub-pattern, is a compile error: a tuple is taken apart by a destructuring binding, inside the arm
  where it is a field. Every variant is covered once, by its arm or by a
  catch-all; an arm that repeats a variant or follows a catch-all is a compile error. The arms meet
  in one type as an `if`'s branches do, a literal arm adopting the others' type (§2.3).
- **What a lambda captures** (ref §4.11, §8.3 rule 4): a lambda **escapes** unless it is written
  straight as an argument; a `val`-bound lambda and a local `def` escape. An escaping lambda may not
  capture an `inout` parameter (**PROPOSED** for a local `def`, which Fortran's internal procedures
  would allow; nex's may be returned). A `var` array moves into the one lambda that captures it, and
  a second lambda capturing it is a compile error; a scalar `var` or a `val` may be captured by any
  number. **A lambda captures the variable, not its value**, as a Fortran internal procedure reaches
  its host's variables: a write the function makes after the lambda is made is seen by the lambda,
  a write the lambda makes is seen by the function, and every lambda capturing one `var` shares it.
  The variable lives as long as the last lambda holding it, so a returned closure keeps counting
  (a `counter()` returning a lambda that adds 1 to its local `n`), and two calls make two variables. A binding is a new
  variable each time it runs: a lambda made on one pass of a loop keeps that pass's `val` and loop
  variable.
- **`print` spells an aggregate as the reference does**: a tuple `(1, a)`, a struct
  `Point { x=1.0, y=2.0 }`, a variant `Converged(3.14)` or `Diverged`, each field as `print` spells
  it alone (a string without quotes). A generic struct prints by its own name, without its type
  arguments: `Pair { fst=1, snd=b }`.
- **Strings, function values and the cells a lambda captures are reference counted**, and freed
  when the last reference goes, so a program's memory is bounded by what it holds rather than by what
  it has built. **A cycle is not reclaimed**: a lambda stored into a `var` it captures itself, local
  `def`s that call one another, and a local `def` that calls itself and is captured by another
  lambda too keep themselves alive for the rest of the run. A local `def` that calls itself and is
  captured by nothing else makes no cycle. A cycle is bounded by the program's shape, not by how long
  it runs, except where it is made inside a loop.
- **A caught trap gives back everything the frames it abandons held**: their strings, function
  values, cells, aggregates and arrays, and the storage of every array they computed, as returning
  would have, on every thread a `parallel` construct runs. What the trapping code already stored
  outside those frames stays stored (§8.4). So a program that catches a trap any number of times
  (`assert_traps` in a loop, a parallel loop that traps in every round) holds no more afterwards than
  before. The cost falls on the path that does not trap only where something is owned: a function
  holding a counted value registers its slots with the runtime on entry and takes them off on
  return (two calls and a store per slot), each temporary is also written to a slot of the frame
  and cleared when released, and each array buffer carries two links on a per-thread list. A
  function of numbers and arrays alone registers nothing. A trap releases what it abandons before
  it returns to the catch, while those frames are still on the stack.

### 11.5 Modules

The reference's folder-as-module system (ref §9) stands — a module is a directory, its path is the
directory's below the project's root with `/` read as `.`, every `.nex` file in it belongs to it, a
`module a.b` declaration is optional and must match the directory, `private` keeps a declaration to
its module, and a `@test module` exists only in a test build — with these rules:

- **The root module is the program's own file, alone.** `nex run prog.nex` reads `prog.nex` and the
  modules it imports, which are the directories beside it; the other files beside it are not read,
  so a directory of independent programs stays one. The root module declares no `module`.
- **An import names what it takes**: `import a.b.{x, y as z}`, or every public name of the module
  with `import a.b.*`, as Fortran's `use a_b` does. An import names a module, not a declaration
  inside one, and a brace list names at least one member.
- **A bare `import a.b` gives qualified access**: `a.b.x` is the module's public `x`, written with
  the whole path the import names, as Python's `import a.b` does — `import a` alone does not reach
  `a.b.x`. Every kind of top-level name is reached this way: a call `geom.dist(p, q)`, a constructor
  `geom.Point(1.0, 2.0)`, a variant `opt.Empty` or `opt.Some(3)`, a binding read or a public `var`
  assigned (`lib.count = 0`), a function as a value, and a type in an annotation, `p: geom.Point`,
  `geom.Pair[integer, real]`. A private member is "the module `geom` has no public member `x`".
  Bare and listed imports of one module may stand together. **A local shadows a module**: where a
  parameter, binding or loop variable is named as the path's first word, `a.b` is that local's field.
  The first word may be neither a name the module declares nor one another import binds. Units are
  not reached through a module, having one namespace (below).
- **A `module` declaration is the first line of its file, and imports come before every other
  declaration.**
- **A module sees its own declarations, in every one of its files, `private` ones included, and what
  it imports; nothing else.** No module sees the root module's names, and an importer sees only the
  public ones: importing a private name is "the module `a` has no public member `x`".
- **An imported name may not be one the module declares itself**, nor may two imports bind one name
  to two declarations; importing the same declaration twice is harmless. Two modules may each declare
  a name, each seeing its own.
- **Imports may not form a cycle**: the cycle is reported at the `import` that closes it, naming
  every module on it. The modules are elaborated with each after the modules it imports.
- **A module-level binding belongs to its module and exists once in the program.** Every module's
  bindings are initialized before `main` runs, each after the bindings its initializer reads. An
  importer reads a public `var` and may assign it, as a Fortran program may a module variable.
- **A struct's or an enum's value prints by its own name**, without its module's path.
- **Patterns need no import**: a `match` arm names a variant of the scrutinee's enum, wherever that
  enum is declared.
- **Units have one namespace across the program**: a `unit` declared in any module is the program's,
  since a dimension is the same quantity in every module (§13.1).
- **The source prelude** is the directory `--prelude-path <dir>` names, else `$NEX_HOME/lib/prelude`
  where that exists; with neither, the built-in prelude stands alone. A `--prelude-path` that names no
  directory is an error rather than a silent fall-back. Its files are the module `prelude`, may say
  `module prelude`, import nothing, and are seen by every module without an import. A module's own
  declarations and its imports shadow the source prelude's names, which shadow the built-in prelude's;
  the source prelude's `private` names are its own. What the built-in prelude provides is unchanged.
- **Tests.** `@test def name()` takes no parameters and returns nothing; anything else is a compile
  error. A test, like a `@test module`, exists only in `nex test`'s build: `nex run` and `nex build`
  neither elaborate nor emit it, and an ordinary module importing a `@test module` is a compile error
  there. A program built for testing needs no `main`. `nex test <file> [substring]` builds the root
  module `<file>`, every module it imports and every module directory beneath it, imported or not,
  and runs the tests whose names — `stats.tests.test_mean`, a test of the root module by its own name
  — hold the substring, in source order with each module after those it imports.
- **Each test runs in a process of its own**, from the module-level bindings' initial values, so no
  test sees what another changed and a trap ends only its own test. A test passes when it returns.
  It fails on a trap, reported by the trap's message (`FAIL test_fails: assert_eq failed`), and on
  `stop n` with `n` not 0 (`stopped with status 3`). What a passing test prints is not shown. The last
  line is the summary, `6 passed, 3 failed`, with `, 2 filtered out` where a substring left tests out;
  the exit status is 1 when any test failed and 0 otherwise.

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

- **A `unit` declaration is a top-level declaration.** `unit` is a keyword (§11); the type
  whose only value is `()` is `void`.
- **A unit expression** is built from unit names and `1`: juxtaposition multiplies, `/` divides and
  `^n` raises to a constant power — an integer, optionally negative (`s^-1`), or a parenthesized
  rational (`m^(1/2)`). `^` binds tightest, juxtaposition next, `/` loosest and left-associative,
  and parentheses group: `kg m / s^2` is (kg·m)/s², and `J / kg K` is J/(kg·K).
- **A derived unit** (`N = kg m / s^2`) is another name for its expression. **A scaled unit**
  (`in = 0.0254 m`) is a positive numeric literal times a unit expression. The factor is **exact**:
  a decimal literal is read as the rational it spells, and factors compose exactly, so `ft` is
  exactly 0.3048 m and `psi` exactly 6894.757293168361… Pa as a rational. A definition may not
  refer to itself, directly or through another unit. The prelude's angle units are scaled by a
  power of π as well, held exactly beside the rational (`deg` is π/180 `rad`, §13.9); a module's
  own declaration writes a decimal factor, so it scales from one of them (`unit grad = 0.9 deg`).
- **Two units are the same unit** when they reduce to the same exponents of the same base units and
  the same factor. `N` and `kg m / s^2` are one unit, `Hz` and `1/s` are one, and so are `J` and
  `N m` (as in SI, torque and energy are not told apart). `mm` and `m` have the same **dimension**
  and different factors: two units, convertible (§13.3).
- **Unit names live in their own namespace** and appear only inside `<…>`, in `unit`
  declarations and directly after a numeric literal (`10mm`, §13.2), so a variable named `m`, `s`
  or `g` does not clash with the unit, and the keyword `in` is an ordinary unit name there
  (`2.0<in>`, `2in`). A module's own `unit` declaration of a prelude
  unit's name shadows it in that module, as any prelude name may be shadowed. `ms` is the
  millisecond; the metre-second is `m s`.
- **A base unit is its name.** A module's `unit m` declares the same dimension the prelude's `m`
  is, so the prelude's units built on it (`N`, `Pa`, `in`) meet the module's `m`: a program may
  declare the base units it uses and still convert `to<m>(1.0<N> / 1.0<kg> * 1.0<s^2>)`. A base
  unit of a name the prelude does not have (`unit apple`) is a dimension of its own.

### 13.2 Spelling a unit

| Form | Example |
|---|---|
| a literal | `9.81<m/s^2>`, `2.0<in>`, `1.0e5<Pa>` |
| a literal in one unit, shorthand | `10mm`, `2.5in`, `1e5Pa`, `-3mm` |
| a real type | `real<m>`, `real32<m/s>`, `real16<Pa>` |
| a complex type | `complex<V>`, `complex[real32]<ohm>` |
| an array type | `[real<m>; :, :]`, `[real32<Pa>; 3, 3]`, `[complex<V>]` |
| dimensionless | `<1>`: `real<1>` is `real` |

- **`<` opens a unit only directly after a numeric literal, a name, a `]` or a `)`, with no space,
  only when unit syntax up to a `>` on the same line follows, and only when the annotation ends
  the operand**: the token after the `>` cannot begin an operand. It must be a binary operator (a
  `-` counts as one), `)`, `]`, `}`, `,`, `=`, `then`, `do`, `else`, a comment or the end of the
  line; a `(` against the `>` is a call on the annotated operand (`to<mm>(x)`). `x<y`, `1<x` and
  `2 < x` are comparisons; `2<x>` is the literal 2 with unit `x`.
- **`<unit>` is a postfix operator on any operand**, at the level of a call `(…)` and a subscript
  `[…]`: tighter than `^`, unary minus, juxtaposition and every binary operator, and chained left to
  right with the other postfixes (`x[i]<m>`, `f(x)<m>`, `to<mm>(x)`).

  | Written | Read as |
  |---|---|
  | `9.81<m/s^2> * t` | a unit, then `*` |
  | `f(2.0<in>)` | a unit |
  | `0<x>1` | comparisons: `1` begins an operand |
  | `lo<x<hi` | comparisons |
  | `a<b>-c` | `a` in unit `b`, minus `c` |
  | `2 * 3.0<m>` | `2 * (3.0<m>)` |
  | `3.0<m>^2` | `(3.0<m>)^2` |
  | `-3.0<m>` | `-(3.0<m>)` |
  | `2pi<rad>` | `2 * (pi<rad>)` |
  | `(a + b)<m>`, `strip(y)<m>` | a unit on the parenthesised operand, on the call |
  | `if x<m> then …` | a unit: `then` cannot begin an operand |

- **A unit's name written directly against a decimal literal, with no space, is that literal in
  that unit**: `10mm` is `10<mm>`, `2.5in` is `2.5<in>`, `1e5Pa` (the exponent first, then the
  unit) is `1e5<Pa>`. It is one operand, so it reads exactly as the bracketed form does: `-10mm` is
  `-(10mm)`, `10mm^2` is `(10mm)^2`, `2 * 10mm` is `2 * (10mm)`, and `0mm < x < 1cm` is a chained
  comparison.
  - **One name is the whole unit.** A compound unit is bracketed, `9.81<m/s^2>`: in `9.81m/s^2` the
    `s` is a value, divided by. A bracket after the name is a compile error (`10mm<in>`), since the
    literal already has its unit.
  - **The name is a unit's when the program has one by that name**: the prelude's (§13.9) or one a
    `unit` declaration makes in any module, before or after the literal. Any other name is what the
    literal multiplies (§4.4), so `2x`, `2pi`, `2e` and `2i` (§12) are products as before; the
    prelude has no unit `i`, `e` or `pi`.
  - **In that position the unit wins over a value of the same name**: with a local `m`, `3m` is three
    metres, and `3 * m` (or `3 m`, with the space) multiplies by the local.
  - **Only a decimal literal takes one.** A hex, binary or octal literal's digits may be letters
    (`0x10cd` is one number), so a unit's name against one is a compile error: `0x10<mm>`.

- **The checker accepts an annotation only on a dimensionless operand**: it attaches a unit to a
  number. An operand that already carries a unit is a compile error pointing to `to<u>(x)`, which
  is how a value changes unit (§13.3).
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
  whose factor is 0.001 × 0.0254), except that an angle can drop out of it (below).
- **`^` takes a constant exponent** when its base carries a unit: `x^2` is `real<m^2>` for
  `x: real<m>`, and a rational exponent is allowed (`<m^(1/2)>`). The exponent is written as an
  integer literal, optionally negative (`x^-1`), or a fraction of two (`x^(1/2)`, `x^(-1/2)`); a
  real literal (`x^2.0`, `x^(1.0/2.0)`), a named value and a zero denominator are refused, and so is
  an exponent that carries a unit. `x^n` with `n` computed needs a dimensionless `x`: `strip(x)^n`.
  A result whose scale has no exact value (`1.0<mm>^(1/2)`, since √0.001 is irrational) is refused;
  convert to a unit of scale 1 first.
- **A bare literal is dimensionless.** With `x: real<m>`, `x + 1.0` and `x > 0.0` are compile errors;
  write `x + 1.0<m>` and `x > 0.0<m>`.
- **An expected type converts** (**PROPOSED**): a binding, an argument, a returned value or an
  assignment of the same dimension and another scale is converted to the target's unit, as `+`
  converts its right operand. `val d: real<mm> = 1.0<in>` holds `25.4<mm>`. A different dimension
  is a compile error.
- **An angle is a kind of unit**: the angle units are those whose dimension holds the base unit
  `rad` — the prelude's `rad`, `deg`, `turn`, `arcmin`, `arcsec` and `sr` (= `rad^2`), and any
  unit declared from them. They are checked where an angle meets a plain number and drop out of
  products, so `rotate(part, 30)` meant in degrees does not compile, and `r * theta` is a length.
  - **Angle units convert like any others**: `90.0<deg> + 0.5<rad>` is a `real<deg>` (the right
    operand converted to the left one's unit), and `to<rad>(180.0<deg>)` is π rad.
  - **A plain number is not an angle.** With `theta: real<rad>`, `theta + 0.5`, `theta > 0.0`, an
    `if` with an angle in one branch and a plain number in another, `theta = 2.0`, and passing a
    plain number to a parameter typed `real<rad>` or `real<deg>` are compile errors whose hint names
    both forms: *"a bare number is not an angle; write `30<rad>` for radians or `30<deg>` for
    degrees"*. The literal `0` is no exception, as it is none for any other unit (`theta = 0.0<rad>`).
    An angle where a plain number is expected is refused the same way, and `strip(theta)` takes its
    number.
  - **An angle drops out where it meets another dimension in `*` or `/`**: the operand is taken in
    radians and its angle removed, so `2.0<m> * 30.0<deg>` is a `real<m>` holding π/3, and
    `theta / t` a `real<1/s>`. A result that is an angle and nothing else keeps it: `2.0 * theta`
    and `omega * t` are angles, `theta * phi` is `rad^2`, and `theta / phi` is a plain number. The
    angle drops at the operator where it meets the other dimension, so `theta * r / r` is a plain
    number while `theta * (r / r)` is an angle. A unit parameter counts as a dimension other than
    angle: `r * theta` with `r: real<U>` is a `real<U>`. `@` and `dot` follow the same rule.
  - **A unit that mixes an angle with another dimension meets that dimension without it** in every
    place two units must meet: `rad/s` and `1/s` (and so `Hz`) are one dimension, as in SI, so
    `val omega: real<rad/s> = theta / t` holds, `omega * t` is an angle and `omega * r` a
    `real<m/s>`. A declared unit that mixes the two (`unit rpm = turn / min`) is taken in base units
    where its angle drops out: `2.0<rpm> * 1.0<m>` is a `real<m/s>`.
- **`to<u>(x)`** converts explicitly, on a scalar and element-wise on an array: `to<mm>(1.0<in>)` is
  `25.4<mm>`. A target of another dimension is a compile error.
- **`strip(x)`** removes the unit and gives the number in `x`'s own unit, dimensionless:
  `strip(25.4<mm>)` is `25.4`, and `strip(to<m>(d))` is the length in metres. On an array it is a
  view of the same storage, with no copy. **A unit is attached by multiplying**: `y * 1.0<m>`.
- **A conversion to a real or complex type keeps the unit**: `real32(x)` for `x: real<m>` is a
  `real32<m>`, and `complex(x)` a `complex<m>`. **An integer conversion of a value with a unit is
  refused** (`int32(x)`, `to_integer(x)`), since integers carry no unit: `int32(strip(x))`.
- **An `if` takes its first branch's unit**: every other branch must have the same dimension and
  is converted to that unit, as `+` converts its right operand, so `if c then 1.0<m> else 2.0<mm>`
  is a `real<m>`. A branch of another dimension, or a dimensionless one beside a unit, is a compile
  error.

### 13.4 Prelude functions

- `sqrt` halves every exponent: `sqrt(a)` for `a: real<m^2>` is `real<m>`.
- `abs`, `conj`, `floor`, `ceil`, `round`, `trunc`, `min`, `max`, `minval`, `maxval`, `sum` and
  `norm2` keep the unit; `min`, `max` and `hypot` convert their second argument as `+` does.
  `sign(x)` and `arg(z)` return a plain number: the sign is −1, 0 or 1 whatever `x` measures, and
  `arg(z)` is in radians.
  `atan2(y, x)` takes two values of one dimension and returns an angle, a `real<rad>`: the unit
  they share cancels, so `atan2(1.0<m>, 2.0<mm>)` is an angle like `atan2(1.0, 2.0)`.
- **`sin`, `cos` and `tan` take an angle**, in any angle unit, converted to radians
  (`sin(30.0<deg>)`), **or a plain number, which is radians**, as in Fortran; another unit, `sr`
  among them, is a compile error. They return a plain number.
- `exp`, `log`, `asin`, `acos`, `atan` and the other elementary functions need a dimensionless
  argument — an angle is not one. **The inverse functions `asin`, `acos` and `atan`, and `atan2`,
  return an angle**, a `real<rad>` of the argument's width (`real64<rad>` for an integer argument),
  and element by element an array of angles; the others return a dimensionless result. The angle
  goes back into `sin` unchanged (`sin(asin(x))`), converts with `to<deg>(atan(x))`, and is refused
  where a plain number is expected, as any angle is: `strip(asin(x))` is its number in radians.
  `asin`, `acos` and `atan` do not take a complex argument.
- `product(a)` has unit `U^n`; for an `a` that carries a unit, `n` must be a static extent
  (**PROPOSED**), and otherwise it is a compile error that suggests `strip`.
- `print` and string interpolation show the unit after the value, separated by a space: with
  `val g = 9.81<m/s^2>`, `print(g)` prints `9.81 m/s^2`. The unit is spelled as the type carries it,
  in a form that reads back as the same unit (`8.314 J/(mol K)`). A complex value's unit follows
  both parts (`25.4+50.8i mm`), and inside a tuple or a struct each value with a unit is followed by
  its own (`(0.3048 m, 2.0 s)`, `Beam { length=12.0 ft }`). An array prints its elements and
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
is held stripped.

- **An array literal is in the unit of its first element that carries one**, and every other
  element of that dimension is converted to it, as `+` converts its right operand:
  `[1.0<m>, 2.0<mm>]` is a `[real<m>]` holding 1.0 and 0.002. An element of another dimension, or a
  dimensionless one, is a compile error (`[0.0, 1.0<m>]` asks for `0.0<m>`). Where the literal's type
  is expected, every element is converted to that type's unit.
- **A unit written after an array gives it to every element**: `[1.0, 2.0]<m>` is a `[real<m>]`,
  the same storage under another type, as `strip(a)` is the reverse.
- **The element-wise operators, and the prelude functions applied element by element, follow the
  scalar rules of §13.3 and §13.4 for one element**: `a + b` needs one dimension and converts `b`'s
  elements to `a`'s unit, `a * b` and `a / b` combine units, a measured scalar broadcasts with its
  unit, `a^2` takes a constant exponent, `sqrt(a)` halves the exponents, an array of angles drops
  out of a product in radians, and `sin(a)` needs an array of angles or of plain numbers.
- **`product(a, dim = k)`** multiplies the extent of axis `k`, so its unit is `U` to that extent:
  the axis is written as an integer literal and its extent is static, or, for an `a` that carries a
  unit, it is a compile error that suggests `strip` (**PROPOSED**).

The products and solvers carry units through:

| Operation | Unit |
|---|---|
| `A @ x`, `A @ B` | the product of the operands' units |
| `dot(x, y)` | the product of the operands' units |
| `sum(a)`, `norm2(a)` | `a`'s unit |
| `solve(A, b)`, `lstsq(A, b)` | `b`'s unit divided by `A`'s |
| `inv(A)` | the reciprocal of `A`'s unit |
| `det(A)` | `A`'s unit to the power n; `A` carrying a unit needs a static extent n |
| `eigvals`, `svdvals`; the values of `eig` and `eigh`, the `R` of `qr`, the `U` of `lu`, the `s` of `svd` | `A`'s unit; the other factors — the vectors, `Q`, `L`, `p`, `svd`'s `U` and `V` — are dimensionless |
| `chol(A)` | the square root of `A`'s unit, whose scale must have an exact root |
| `solve_inplace`, `lu_inplace`, `chol_inplace`, `qr_inplace` | none: they take arrays without a unit |

### 13.7 C and Fortran

**An `extern` parameter never carries a unit**, and neither does its result: an `extern def`
whose signature writes a unit (`x: real<m>`, `: real<m>`) is a compile error. Passing a
unit-carrying value to one is a compile error that names `strip`: `cbrt(strip(v))`. An array strips as a view, with no copy, so
`cblas_ddot(n, strip(x), 1, strip(y), 1)` copies nothing. A result is given its unit by
multiplying: `cbrt(strip(v)) * 1.0<m>`. A nex function passed as a callback (§10.2.1) has
unit-free parameters and result for the same reason.

### 13.8 Cost

Units exist only in the type checker and are erased before MLIR is emitted, so a program with units
compiles to the same code as the same program without them. **Mixing scales costs one
multiplication by a constant**: the ratio of two exact factors, rounded once to the operand's width
at compile time — the same single rounding a hand conversion makes; a ratio that involves π is first taken to more than 50 significant digits. Where no scales are mixed, no
conversion is emitted. The multiplication is an ordinary one: a conversion past the width's range is
an infinity, or the overflow trap under `--fpe-trap` (§2.5).

### 13.9 The prelude units

| Units | Definitions |
|---|---|
| SI base | `m` `kg` `s` `A` `K` `mol` `cd` |
| SI derived | `N = kg m / s^2`, `J = N m`, `W = J / s`, `Pa = N / m^2`, `Hz = 1 / s`, `C = A s`, `V = W / A`, `ohm = V / A` |
| Angle | `rad` (a base unit), `sr = rad^2`, `deg = π/180 rad`, `turn = 2π rad`, `arcmin = deg / 60`, `arcsec = arcmin / 60` |
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
| `byte` and `[byte]` | §3.3.1 | §3.1 | gone: bytes are `[uint8]`, an ordinary array (`read_bytes`/`write_bytes` take and give `[uint8]`); `==` on them is element-wise like any array's (§7.1), so whole-buffer equality is `all(a == b)` |
| Promotion | §3.2, §4.4 | §2.2 | a lattice across widths; integer meets real gives the real's width; a typed scalar promotes an array |
| Index base | §4.14 (0-based) | §3.2, §5.1 | **1-based**, as Fortran; axis numbers (`extent(a, k)`, `dim =`) are 1-based too |
| Range syntax | §4.14 (`..` half-open, `..=` inclusive) | §5.1 | `a..b` is **inclusive** (Fortran `a:b`); `a..<b` is half-open; `..=` is gone |
| `range(lo, hi)` | §10 (prelude) | §5.1, §11 | gone: a range is written `lo..hi` or `lo..<hi`, and is an array value anywhere an expression may stand |
| Literal typing | §2.4 | §2.3 | literals and `pi`/`e`/`inf`/`nan`/`i` take their context's width |
| Conversions | §10.7 | §2.4 | a conversion function per type name |
| Generic constraints | §6.10 | §2.6 | widened to sized types; `Integral`, `Rank` added |
| Checking a generic | §6.10 (once, against its constraints) | §2.6 | at each instance; one name holds one generic `def` beside at most one concrete one |
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
| Keywords | §2.3 | §11 | `inout`, `parallel`, `extern`, `enum`, `exit`, `cycle`, `stop`, `unit` |
| Chained comparisons | §4.6 (scalars) | §11 | one `Chain` node, never an `and` rewrite; on arrays the comparisons combine element-wise, every operand evaluated once, no per-element short-circuit |
| `^` and unary minus | — | §11 | `^` binds tighter than unary minus (`-x^2` is `-(x^2)`) and is right-associative |
| Loop control | — | §11.1 | `exit`, `cycle`, named loops, `stop n`, `by` in a `for` header |
| Program entry | — | §11.2 | `main()` or `main(args: [string])`, 1-based `args`; declarations only at the top level; `eprint` |
| Real division by zero | — | §2.5 | IEEE (`inf`, `nan`); traps only under `--fpe-trap` |
| `f"..."` specifier against its value | §10.6 (run-time trap) | §2.5 | compile error |
| Result inference, void bodies, compound assignment, lambda parameter types | §6 | §11.3 | first `return` fixes an undeclared result; a `void` function discards its body's value; `op=` never narrows; a `val`-bound lambda's types come from its first call |
| Elemental functions | — | §7.3 | every prelude scalar math function is elemental; `@elemental` for user functions |
| Reductions | §10 | §7.4 | Fortran names: `minval`, `maxval`, `minloc`, `maxloc`, `any`, `all`, `count`, `norm2`; `dim =` in place of the reference's `sum_axis`; `dot` conjugates |
| Array elements | §3.3 | §3.1 | any element type but an array; structs and tuples of scalars stored inline |
| Tuple fields | — | §3.1 | 1-based: `t.1`, `t.2` |
| Default arguments | §6.5 | §11.3 | defaults come last; a default sees the function's module and the parameters before its own; `inout`, `extern` and local-`def` parameters and function values take none |
| Struct and variant constructors | §3.5, §3.7 | §11.4 | fields by position or by name; a struct's field may have a default, a variant's may not; variant fields of any type; no type contains itself by value |
| Tuple conversion, module-level destructuring | §4.17 | §11.4 | a tuple built in place converts element by element; a module-level `val a, b = …` evaluates once |
| Modules, the source prelude and `nex test` | §9, §10 | §11.5 | the root module is the entry file alone; `import m.*` is allowed, and a bare `import m` gives qualified access, `m.x`; a missing `--prelude-path` is an error; tests run one process each; `@test def` with parameters is an error, not a helper |
| Field places, `x.f(args)` | §4.16 | §11.4 | fields, tuple elements and `z.re`/`z.im` are assignable and passable `inout`; a function field is called |
| `match` | §7.5 | §11.4 | a fielded variant is matched with its fields; coverage, repeats and unreachable arms are compile errors |
| Escaping lambdas | §4.11 | §8.3, §11.4 | only a lambda written as an argument does not escape; an escaping one may not capture `inout` |
| Units of measure | — | §13 | `unit` declarations (base, derived, scaled by an exact factor); `9.81<m/s^2>`, `real<m>`, `[real<Pa>; :, :]`; same-dimension scales convert to the left operand's unit, other dimensions are a compile error; `to<u>`, `strip`; erased before code generation |
| Unit generics | §6.10 | §2.6, §13.5 | `U: Unit` parameters (`real<U^2>`) |
| Prelude units | — | §13.9 | SI base, derived and scaled, imperial and US customary; `usgal` / `ukgal`, no `gal` |
| The empty type | `unit` (§3.1) | §2.1, §11 | spelled `void`; `unit` is a keyword that declares a unit of measure (§13.1), and a type written `unit` is an error suggesting `void` |

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
- **Arrays of `@c` structs in a `[*; ..]` descriptor** (§10.7): a type code for "a struct of
  `elem_size` bytes" and a way to name its layout to C, should a library want one entry point over
  records as well as numbers.
- **Unit-polymorphic externs**: an `extern` declaration whose parameters carry units (§13.7), so a C
  routine can be given its units once in its declaration instead of `strip` at every call.

Not in the language, and not planned: implicit parallelism (§9.3), static extents as generic
parameters (§3.4), batched `@` on rank ≥ 3 (§7.2), a call-site marker for `inout` (§8.1).

---

## 16. Embedding nex

A sysl program hosts nex scripts on the interpreter, the engine that needs no toolchain (PLAN.md
M13): it loads a script, calls its functions with values, reads and writes its module-level
bindings, and gives it functions and types of its own — a 3D modeller giving a model its geometry
kernel. The API is the library's `embed.sysl`; `examples/embed/` is a host.

### 16.1 Loading

- **`load_script(text, file, host, opts)`** loads a script from text, `file` naming it in
  diagnostics; it is one module and imports nothing. **`load_script_file(entry, host, opts)`** loads
  the project whose root module is `entry`, with every module it imports and the source prelude
  `opts.prelude` names, as `nex run` does.
- **A script needs no `main`.** A host calls it by name; a `main`, where there is one, is what `run`
  calls, and it is held to §11.2 as a program's is.
- **A refused script is its diagnostics as values**, never printed: each is a `NexDiagnostic` with
  its file, its line and column (from 1), its span in that file, its message and its text rendered as
  `nex` prints it. The parser's, the elaborator's and the interpreter's refusals all come back this
  way, an unreadable entry as one diagnostic.

### 16.2 Running and calling

- **The module-level bindings are initialized on the first request** — `run`, `call`, `get` or
  `set` — in the order a program initializes them, and keep their values from one request to the
  next. A trap while they initialize answers that request and every later one, the bindings never
  having been made.
- **`run(args)`** calls `main` with `args` as the program's arguments and answers the status: 0 when
  `main` returns, the code `stop` gives. **`call(name, args)`** calls the top-level function `name`
  with values, each checked against its parameter's type (§16.3), and answers its result.
  **`call_named(name, positional, named)`** names arguments as a nex call does: `positional` fills
  the leading parameters, `named` (each a `NexField`) any others by name. **A parameter a host's call
  leaves out takes its default exactly as a nex call's does** (§11.3): evaluated afresh at every call,
  in parameter order, seeing the module-level names of the function's own module, its unit
  converted to the parameter's. A trap in a default leaves the function's own frame, at the default,
  since the host's call has no nex frame of its own. A function taking an `inout` parameter is
  refused, since a host passes values, not places. A `stop` inside a call is an error, `ScriptStop`.
- **`get(name)`** reads a module-level binding, one taken apart by a destructuring `val` among them;
  **`set(name, v)`** writes a `var`, the value checked against its type. A `val` is not written.
- **What a script prints goes to the host's `write`**, standard output and standard error apart.
- **A request that cannot be made is refused before anything runs**, no default evaluated: a name
  the script does not declare, more arguments than parameters, a named argument the function has no
  parameter for or one given twice, a parameter with no default left out, a value of the wrong type
  — `ScriptRefused` with the reason, worded as the elaborator's refusal of the same nex call.
- **Dropping the script lets go of everything it holds**: its compiled code, its bindings and the
  host's objects in them. A host that reloads an edited script after every keystroke holds one
  script at a time, and `examples/embed` reloads its model 50 times on a counted heap with nothing
  left at exit.

### 16.3 Values across the boundary

- **A value crosses as a `NexValue`**: `NInt(v, bits, signed)`, `NReal(v, bits)`,
  `NComplex(re, im, bits)`, `NBool`, `NStr`, `NArray`, `NTuple`, `NStruct(name, fields)` with its
  fields by name, `NVariant(name, fields)` for an enum's variant, `NHandle` for a host type's object,
  and `NNothing` for a function returning nothing. An integer is held in a `long` widened by its own
  signedness, a `uint64` above `int64`'s range as its bit pattern; a real of any width as the
  `real64` it widens to exactly.
- **A number with a unit crosses as the number in the unit its declared type names.** A host
  function declared `box(w: real<mm>)` and called as `box(1.0<in>)` is handed `25.4`; a function
  returning `real<mm^3>` hands the host cubic millimetres. The unit is the declaration's, so a host
  reads one convention however the script spelled its lengths (§13).
- **An array crosses as its extents and one buffer of its elements**, column-major (§3.2): `Ints`,
  `Reals`, `Complexes` (real and imaginary parts alternating) or `Bools`, a value per element only for
  elements that are not numbers or `bool`. It is the elements, not a view: a slice or a transposed
  array crosses as the elements it shows, each axis from 1. **It crosses as a copy**: a script
  writing an array it was given leaves the host's buffer as it was, and a buffer it answers is the
  host's own.
- **Every value is checked against the type it meets** — a parameter of the function called, the
  result of a host function, a binding set — and a mismatch names where the value was going:
  `argument 1 of \`f\`, \`x\`, is int8, and the int64 given, 128, does not fit it`. An integer
  crosses into any integer type it fits and into a real or a complex; a real crosses into a real or a
  complex at least as wide, a complex into a complex at least as wide; everything else into its own
  type alone. An array's rank must be its type's, a static extent the same, and its elements must
  fill its extents; a struct is given every field, by name, and no other; a variant is named, with
  its fields in order.

### 16.4 Host functions and host types

```nex
@host struct Solid

@host extern def box(w: real<mm>, h: real<mm>, d: real<mm>): Solid
@host @pure extern def volume(s: Solid): real<mm^3>
```

- **A host function is an `extern def` marked `@host`**: a function the embedding program gives
  under that name, not a C function. Its parameters and result are any type a host holds — numbers
  with their units, `bool`, strings, arrays, tuples, structs, enums and host types — but not
  functions; it takes its arguments by value, so no parameter is `inout`, and none has a default. Its
  attributes are `@host` and `@pure`, which a parallel body (§9.4) requires as it does of a C extern.
  It is only called, never a function value: a `def` wrapping the call is one.
- **A host type is a struct marked `@host` with no fields**: the host's own object, which nex holds
  and passes back and never looks inside. A script does not construct one; it has `==`, true where
  the two are the host's same object, and prints as its name and the host's number, `Solid#7`. A
  struct without fields that is not `@host` is refused, as is a `@host` struct with fields, a generic
  one or one also `@c`.
- **The host gives each by name before loading** (`Host.give`, `Host.give_type`), and a script
  declaring a host function or type its host does not give is refused at load. A host function is a
  sysl closure taking the arguments as values of the declared parameter types; it answers a value,
  checked against the declared result, or a message, which traps.
- **A host type's object is reference counted**: every value holding it shares it, the host's copy
  included, and when the last lets go the type's `release` is called with the host's number for it —
  when a script's local goes out of scope, when a binding is overwritten, when the script is dropped.
  A host function makes an object through the `HostType` `give_type` answered, so that the host's
  table of functions and the functions in it do not hold each other.
- **A compiled program has no host**: the compiler refuses a `@host` function or type, and a program
  declaring one runs embedded. Compiling a script for a host — a shared library the host loads, its
  host functions passed in as callbacks — is the 3D modeller's later item in PLAN.md.

### 16.5 Traps, `stop`, and stopping a runaway

- **A trap is an `Err`**, `ScriptTrap(message, stack)`: the message `nex run` writes after `trap: `,
  and the nex frames the trap left, innermost first — each the function's name and the file, line and
  column of the call or statement in it where the trap happened, or of the function's declaration
  where neither says. A module-level binding's initializer is the frame `module level`. A trap
  `assert_traps` catches leaves no stack.
- **The host may bound a run**: `opts.budget` is the steps one `run` or `call` may take — a call's
  entry and a loop's pass are a step each, so an `@elemental` function applied to an array, and the
  function `map`, `filter`, `reduce` or `flatMap` is given, take a step an element — and `cancel()`, called from a host function or from
  `write`, stops the run in progress at its next step. Either ends the run with `ScriptHalt`, which
  `assert_traps` does not catch; the next request starts with the budget whole and uncancelled. Calls
  nest at most 10,000 deep, as everywhere (§11.3).
- **Another thread stops a run through the script's `CancelToken`.** `cancel_token()` answers a
  `&sync CancelToken`, one atomic word shared with the script and nothing else of it, so a
  modeller's UI thread may hold it while a worker thread runs the script; its `cancel()` halts the run
  in progress at its next step, as `Script.cancel()` does, and the step reads it without a lock. A
  cancel that arrives between requests is cleared by the next one starting, so a host cancels a run
  it knows has begun.

### 16.6 The sandbox

`opts.sandbox` is for scripts from untrusted sources. A sandboxed script may not `stop` — its host
decides when it ends — and the rest of what an untrusted script must not do the interpreter already
refuses to every script: an `extern` (the interpreter never calls C) and a host function its host
does not give. nex has no file I/O to refuse. A runaway sandboxed script is bounded by the budget,
which a host running untrusted scripts sets.
