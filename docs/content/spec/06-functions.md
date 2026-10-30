---
title: Bindings and Functions
summary: const, val and var bindings; def functions; generics over element type and rank; lambdas and function values; read-mode and inout parameters and the exclusivity rules that make Fortran's aliasing rule a compile-time check.
weight: 60
---

This chapter covers how names are bound and how functions are written and called. The part a
Fortran programmer will want to read closely is §6.8 to §6.11: how a function changes its caller's
data. nex keeps Fortran's model — arguments are passed without copying, and a dummy that the
procedure modifies must not be aliased — and checks the aliasing rule at compile time instead of
trusting the programmer to keep it.

## 6.1 Bindings: `const`, `val`, `var`

Every name is introduced by one of three keywords. All three may appear at module level or inside a
function or block.

| Keyword | Mutable | Storage | Evaluated |
|---|---|---|---|
| `const` | no | none; the value may be inlined | at compile time |
| `val`   | no | yes | at run time, where it is declared |
| `var`   | yes | yes | at run time, where it is declared |

```nex
const tol = 1.0e-10                 // a compile-time constant
val n = 1000                        // fixed once computed
val x = linspace(0.0, 1.0, n)       // any expression; an array here
var residual = 1.0                  // may be reassigned
var u = fill(n, 0.0)                // contents may be written: u[1] = 0.5
```

A type annotation is optional; without one the type is inferred from the initializer. An empty
literal needs one, since nothing else says what it holds, and so does a binding that wants a static
shape or a narrower element type than the literal would give:

```nex
val data: [real] = []
val a: [real; 3, 3] = [[1.0, 0.0, 0.0],
                       [0.0, 1.0, 0.0],
                       [0.0, 0.0, 1.0]]
val h: real32 = 0.1                 // the literal takes the binding's width
```

A **`val`** is immutable all the way down: it cannot be reassigned, and the elements of a `val`
array or the fields of a `val` struct cannot be written. A **`var`** can be reassigned, and its
elements and fields can be written in place:

```nex
var data = [1.0, 2.0, 3.0]
data[1] = 10.0                      // writes one element
data[2..3] = 0.0                    // writes a window (slice assignment, /spec/04-arrays/)
data = [4.0, 5.0, 6.0, 7.0]         // rebinds to a different (longer) array

var p = Point(0.0, 0.0)
p.x = 5.0
```

Fortran draws the line differently: `parameter` is the only immutable kind, and every other variable
may be written. In nex a name you never write should be a `val`; the compiler then guarantees no
code anywhere changes it, which is what makes the value semantics of
[chapter 8](/spec/08-values-and-memory/) cheap.

**Compound assignment.** `+=`, `-=`, `*=`, `/=` and `%=` combine an operator with assignment.
`n += 5` means `n = n + 5`, and the target may be anything `=` accepts: a `var`, a field of one, an
element, or a slice (`a[2..4] += 1.0`, element-wise). Compound assignment is a statement, never part
of an expression. There is no `^=`, and no `div=`, `and=` or `or=`.

## 6.2 `const` and constant expressions

A `const` is a compile-time fact. Its right-hand side must be a **constant expression**: a numeric or
boolean literal, another `const`, a prelude constant (`pi`, `e`, `inf`, `nan`, `i`), an arithmetic,
comparison or logical operator applied to constant expressions, or a call to a **pure** function
whose arguments are all constant expressions and whose result is a scalar.

```nex
const tau     = 2 * pi
const max_it  = 1000
const sqrt2   = sqrt(2.0)          // sqrt is pure

def square(x: real): real = x * x
const nine    = square(3.0)        // a user function, pure, scalar result

const bad     = print(1)           // error: print is not pure
```

A function is pure when it performs no I/O, writes no `var` outside itself, and calls only pure
functions. The prelude's mathematical functions are pure; `print` and the `assert` family are not.
A `const` that calls a function declared later in the module needs that function's return type
written out. A value that is not a compile-time constant — an array, a struct, the result of
`linspace` — is a module-level `val` instead.

Prefer `const` to `val` for anything that is a true constant of the problem: physical constants,
tolerances, iteration limits. It is Fortran's `parameter`.

## 6.3 Scope and shadowing

A binding is visible from its declaration to the end of the block that contains it. An inner block
or function may declare a name that shadows an outer one; declaring the same name twice in one block
is an error.

```nex
val x = 1
def foo() =
  val x = 2                // shadows the module-level x inside foo
  x + 1

val x = 3                  // error: x is already declared in this block
```

Shadowing applies to prelude names too. In particular `i` is the imaginary unit until a binding
named `i` — very often a loop index — shadows it ([§2](/spec/02-lexical/)).

## 6.4 Function declarations

A function is declared with `def`. A body that is one expression follows the `=` on the same line;
a longer body is an indented block, and its last expression is the result:

```nex
def square(x: real) = x * x

def hypotenuse(a: real, b: real) = sqrt(a * a + b * b)

def normalize(v: [real]) =
  val mag = sqrt(sum(v * v))
  if mag == 0.0 then v else v / mag
```

There is no distinction between a function and a subroutine. A function with nothing to return
returns `void`, the type whose only value is `()`, and its call is a statement — what Fortran writes
as a `subroutine` and `call`.

**Return types** are inferred. One may be written after the parameter list, and must be for a
recursive function:

```nex
def factorial(n: integer): integer =
  if n <= 1 then 1 else n * factorial(n - 1)
```

**`return`** leaves the function early with a value, or with `()` when none is given:

```nex
def first_negative(v: [real]) =
  for x in v do if x < 0.0 then return x
  0.0
```

**Recursion**, direct and mutual, needs no declarations in advance. Functions that call each other
must be in the same module. Unlike Fortran there is no `recursive` attribute: every function may
recurse.

**Overloading.** Several `def`s may share a name if their parameter types differ. The call picks the
closest match, ranking numeric promotions as [chapter 3](/spec/03-types/) does. A concrete overload
is always preferred to a generic one (§6.6).

**Several results.** A function returns all of its results; there is no `intent(out)`. Several
results are returned as a tuple and taken apart where they arrive:

```nex
def min_and_max(v: [real]) = (minval(v), maxval(v))

val (lo, hi) = min_and_max(samples)
```

A tuple's fields may also be read by position, from 1: `t.1`, `t.2`. Destructuring is the clearer
form and the usual one.

**Elemental functions.** A scalar function marked `@elemental` applies to arrays element by element,
as Fortran's `ELEMENTAL` procedures and every math function of the prelude do. Called on an array of
any rank it returns an array of the same shape. Since it may print or trap, the call is computed for
every element before the surrounding whole-array expression uses it, so what it prints comes in
element order; under `parallel` it fuses into the expression's loop
([Array expressions §5.4](/spec/05-array-expressions/)):

```nex
@elemental
def smoothstep(x: real) =
  val t = min(max(x, 0.0), 1.0)
  t * t * (3.0 - 2.0 * t)

val s = smoothstep(2.0 * u - 0.5)   // one loop over u
```

The body of an `@elemental` function obeys the rules of a `parallel for` body
([Parallelism](/spec/10-parallelism/)): no `inout` parameters, no writes to module-level `var`s, and
no I/O except `print`. Applying an unmarked scalar function to an array is a compile error, and the
message suggests marking it `@elemental` or calling `map`.

## 6.5 Parameters, defaults and named arguments

Each parameter is `name: type`, optionally followed by a mode (§6.8) and a default. Parameters with
defaults must come last, so a positional call may leave trailing arguments off; a parameter without
a default after one with a default is a compile error:

```nex
def damp(x: real, factor: real = 0.5, floor: real = 0.0) =
  max(factor * x, floor)

damp(10.0)                         // 5.0
damp(10.0, 0.9)                    // 9.0
damp(10.0, floor = 6.0)            // 6.0: factor defaulted, floor named
damp(10.0, factor = 0.1, floor = 2.0)
```

A **named argument** `name = expr` fills the parameter of that name. Named arguments come after the
positional ones, in any order, and may skip parameters that have defaults. A parameter supplied
twice, or one left unfilled with no default, is a compile error. As with Fortran's keyword
arguments, the names are part of the function's interface.

A default expression is evaluated at **each call** that uses it, not once when the function is
declared, and only by a call that leaves its argument out.

A default may use the **parameters before its own**, which hold that call's arguments, or their own
defaults where the call left them out too:

```nex
def cylinder(r: real<m>, h: real<m> = 2.0 * r) = print(3.0 * r * r * h)
def total(xs: [integer], n: integer = length(xs), from: integer = 1): integer = sum(xs[from..n])

cylinder(1.0<m>)                   // h is 2.0 m
total([1, 2, 3, 4], from = 3)      // n is 4: 7
```

The call evaluates its arguments once each, in parameter order, and each default after the
arguments before it. A default that uses its own parameter or a later one is a compile error, and
it never sees the caller's locals. A default may read an `inout` parameter before it as any other
argument beside the borrow may (§6.8): `by: integer = length(v)` after `v: inout [integer]` is
legal. A lambda written in a default may not capture a parameter.

A default may call a function declared later in the file, or in another module, and that call may
leave out arguments the later function defaults in turn. A default may not reach its own function,
directly or through other functions' defaults; the cycle is a compile error naming each function on
it:

```nex
def label(n: integer = first_id()) = print(n)
def first_id(seed: integer = 1): integer = seed * 100      // label() prints 100

def f(x: integer = g()): integer = x
def g(y: integer = f()): integer = y    // error: `f` → `g` → `f`
```

Defaults and named arguments need a call to one named, non-overloaded `def`. A call to an overloaded
name, to a function value (§6.7) or through method notation (`x.f(…)`) passes every argument by
position.

## 6.6 Generic functions

A function may take **type parameters** in square brackets after its name. The caller never writes
them; they are inferred from the arguments, and the compiler emits a specialized copy of the function
for each combination it is called with. A generic function that is never called produces no code.

```nex
def larger[T: Ord](a: T, b: T): T = if a < b then b else a

val h: real32 = 0.5
larger(3, 7)                       // T is integer
larger(h, real32(1.5))             // T is real32
larger(2, 1.5)                     // T is real: the arguments widen to a common type
```

A bound restricts what a parameter may stand for. The bounds are a fixed set:

| Bound | Admits |
|---|---|
| `Any` (also written as a bare `[T]`) | every type |
| `Numeric` | every integer, real and complex type |
| `Integral` | `int8` … `int64`, `uint8` … `uint64` |
| `Real` | every integer and real type |
| `Float` | `real16`, `real32`, `real64` |
| `Complex` | `complex[real16]`, `complex[real32]`, `complex[real64]` |
| `Ord` | every integer and real type: those with `<` |
| `Eq` | every numeric type, `bool`, `string`: those with `==` |
| `Rank` | not a type but a rank (below) |

{{< note >}}
The name `Integral` may change.
{{< /note >}}

When one type parameter is matched by several numeric arguments, they widen along the promotion
lattice of [chapter 3](/spec/03-types/), as `larger(2, 1.5)` shows.

**Rank-generic code.** A parameter bounded by `Rank` stands for a rank. An array type whose shape is
that parameter has that many axes, all of dynamic extent, so one definition serves vectors, matrices
and higher-rank arrays:

```nex
def total[T: Numeric, R: Rank](a: [T; R]): T = sum(a)

def axpy[T: Float, R: Rank](alpha: T, x: [T; R], y: inout [T; R]) =
  y = alpha * x + y

var y = fill((3, 4), 0.0)
axpy(2.0, fill((3, 4), 1.0), y)    // T is real, R is 2
val s = total([1, 2, 3])           // T is integer, R is 1
```

The element type and the rank are both inferred, and the compiler specializes once per (type, rank)
pair it meets. Inside the body `rank(a)` is the constant `R`. Rank-generic code works through
whole-array operations, `map`, the reductions, `extent`, `size` and `flatten`; it cannot write an
index list such as `a[i, j]`, whose length would have to be `R`. Static extents are not generic
parameters: a generic function takes dynamic axes, and a caller's static shape converts to them.

This replaces what Fortran does with a generic interface over specific procedures, one per kind and
rank: the specific procedures are written by the compiler.

**Overloads and generics together.** A name may have a generic definition and concrete ones. A
concrete overload that accepts the arguments wins; the generic is used only when none does. Two
generic definitions that both accept a call are an ambiguity error.

## 6.7 Lambdas and function values

Functions are values. A `def` may be passed by name, and a **lambda** writes one in place:

```nex
x -> x * x
(x, y) -> x + y
(x: real) -> 2.0 * x                // a parameter type, where context does not give one
x ->
  val y = x * x
  y + 1.0
```

A single parameter needs no parentheses; several do. A parameter's type is inferred from where the
lambda is used, and must be written when nothing gives it.

A **function type** is written with `->`: `real -> real`, `(real, real) -> real`, `() -> void`. A
parameter's mode is part of its type, written the same way as in a declaration:
`(inout [real], real) -> void`.

```nex
def apply(f: real -> real, x: real) = f(x)

apply(square, 3.0)                       // 9.0
apply(x -> x + 1.0, 3.0)                 // 4.0
val scaled = map(v, x -> 2.0 * x)        // the prelude's map takes a function

def make_shift(a: real) = x -> x + a     // returns a closure
val shift5 = make_shift(5.0)
shift5(3.0)                              // 8.0
```

A lambda **captures** the bindings it mentions. A captured `val` is shared; since nothing can change
it, it does not matter whether the lambda holds the value or a reference to it.

{{< note >}}
The rules for a lambda that captures a `var` array (whether the capture moves the array into the
closure or copies it) may change.
{{< /note >}}

A lambda is **non-escaping** when it is passed straight to a call as an argument, so it cannot be
called after that call returns, and **escaping** otherwise: returned, stored, or bound to a name.
The difference matters for `inout` parameters (§6.10).

Fortran passes procedures as arguments too; the difference is that a nex lambda can capture local
variables, as an internal procedure can, and can be returned.

## 6.8 Parameter modes: read and `inout`

A parameter has one of two modes.

- **Read mode**, the default. The function reads the argument and may not change it: assigning to
  the parameter, or writing one of its elements or fields, is a compile error. Nothing is copied to
  make the call — an array argument is borrowed, and the callee reads the caller's storage. This is
  Fortran's `intent(in)`, and it is the default because it is what most arguments are.
- **`inout`**, written before the type. The function may read and write the argument, and every
  write lands in the caller's variable. This is Fortran's `intent(inout)`.

```nex
def scale(v: inout [real], s: real) =
  v = v * s                        // or one element at a time: for k in 1..length(v) do v[k] *= s

def swap(a: inout integer, b: inout integer) =
  val t = a
  a = b
  b = t

var x = [1.0, 2.0, 3.0]
scale(x, 2.0)                      // x is now [2.0, 4.0, 6.0]
var p = 1
var q = 2
swap(p, q)                         // p is 2, q is 1
```

An `inout` parameter is an **exclusive borrow** of the caller's place. The callee works on the
caller's storage directly: nothing is copied in, nothing is copied out, nothing is returned, and the
caller still owns the variable afterwards. When the call returns the caller sees every write. The
mode applies to scalars, arrays and structs alike; a scalar `inout` is passed by reference.

**The call site has no marker.** `scale(x, 2.0)` reads the same whether `v` is `inout` or not, as a
Fortran call does. A marker would add nothing, because every misuse of an `inout` argument is a
compile error at the call (§6.9, §6.10).

There is no `intent(out)`. A function that produces a new array returns it, and the caller binds it:
`val y = solve(a, b)`. Returning an array costs no copy ([chapter 8](/spec/08-values-and-memory/)).
`inout` is for updating data that already exists — a state vector stepped in time, a matrix factored
in place, a work array reused across iterations.

## 6.9 What may be an `inout` argument

The argument to an `inout` parameter is a **place** rooted in something mutable:

| Place | Example |
|---|---|
| a `var` | `scale(x, 2.0)` |
| an `inout` parameter of the calling function | `scale(v, 0.5)` inside a function with `v: inout [real]` |
| a field of one of those | `advance(p.pos, dt)` |
| an element | `swap(a[i], a[j])` (subject to §6.10) |
| a slice | `scale(m[:, j], 2.0)`, `scale(a[1..n by 2], -1.0)` |

A slice argument borrows exactly that window of the array and the callee writes it in place. Column
`j` of `m` is scaled where it lies; the rest of `m` is untouched. A window keeps its shape: a callee
assigning its parameter an array of another shape traps there, with *"shape mismatch"*, where a
whole array would take the new array and its caller would see it. An element may be taken through
any number of slices (`a[2..][k]`, `m[:, j][i]`, `a[.. by -1][1]`), and its indices are evaluated
once and checked against the array's bounds before the call starts, so an index out of bounds traps
before the callee runs. The same holds for an `extern` taking a scalar `inout` or a `[*; ..]`
parameter, which receives the element as a descriptor of rank 0.

{{< note >}}
That an `inout` slice is written in place without any temporary copy, including a strided one, is the
design's intent but has not yet been confirmed in the generated code; the detail of how a strided
window is passed may change. What the caller observes does not change.
{{< /note >}}

Anything else is rejected — a `val`, a literal, the result of a call, an arithmetic expression:

```nex
val c = [1.0, 2.0]
scale(c, 2.0)                      // error: an inout argument must be a `var`
scale([1.0, 2.0], 2.0)             // error: an inout argument must be a `var`
```

No hidden copy is made to let these through: a copy's writes could not reach anything, so the call
would silently do nothing useful. Fortran forbids the same thing — the actual argument to an
`intent(inout)` dummy must be definable — and nex states the rule in the same terms.

A **view bound to a name is not a place**. A slice bound with `val` is a read-only view
([chapter 8](/spec/08-values-and-memory/)), and a slice bound with `var` is a copy. To update a
window of `a`, pass the slice expression itself:

```nex
var a = [1.0, 2.0, 3.0, 4.0]
scale(a[1..2], 10.0)               // a is [10.0, 20.0, 3.0, 4.0]

var w = a[3..4]                    // w is a new array holding a copy of the window
scale(w, 10.0)                     // w is [30.0, 40.0]; a is unchanged
```

## 6.10 Exclusivity

For the whole of a call, the callee has the **only** access to each place it borrows `inout`. Four
rules enforce that, all at compile time.

**1. One root in two `inout` arguments, only if the places are visibly disjoint.** A *root* is the
variable a place starts from: `a` is the root of `a`, `a[i]` and `a[1..k]`. Passing two places with
the same root to two `inout` parameters is accepted only when the checker can see from the source
text alone that they cannot overlap:

- two **different fields** of a local struct `var`: `swap(p.x, p.y)`;
- on one axis, **constant windows or constant indices that do not overlap**:
  `f(a[1..4], a[5..8])`, `swap(a[1], a[2])`, `f(m[:, 1], m[:, 2])`;
- on one axis, **a split at one expression `e`**, the same expression written on both sides:
  `f(a[1..e], a[e+1..n])`, `f(a[..<e], a[e..])`, `f(m[:, ..e], m[:, e+1..])`.

Every other pair is a compile error, including pairs that are disjoint at run time but not visibly
so:

```nex
swap(a, a)                         // error: the same place twice
swap(a[i], a[j])                   // error: a[i] and a[j] may overlap;
                                   //        borrow a[e] and a[e+1] at one split point e
f(a[1..k], a[j..n])                // error: a[1..k] and a[j..n] may overlap;
                                   //        borrow a[1..e] and a[e+1..] at one split point e
```

The message suggests the split form, which is how such code is written, on the first axis where the
two places differ: two windows `..e` and `e+1..` there, or, where both places are elements, the
elements `e` and `e+1` with the other subscripts kept (`m[e, 1]` and `m[e+1, 1]`). No run-time check
is made: the rule is decided by the source, so a program that compiles cannot fail it.

The split form is what divide-and-conquer algorithms need. The fast Walsh–Hadamard transform updates
the two halves of the array against each other and then recurses into each:

```nex
def butterfly(lo: inout [real], hi: inout [real]) =
  for k in 1..length(lo)
    val x = lo[k]
    val y = hi[k]
    lo[k] = x + y
    hi[k] = x - y

def walsh_hadamard(a: inout [real]) =
  val n = length(a)                // a power of two
  if n == 1 then return
  val h = n div 2
  butterfly(a[1..h], a[h+1..n])    // accepted: a split at h
  walsh_hadamard(a[1..h])
  walsh_hadamard(a[h+1..n])

var signal = [1.0, 0.0, 1.0, 0.0, 0.0, 1.0, 1.0, 0.0]
walsh_hadamard(signal)
```

The two halves are borrowed together by `butterfly` because both bounds are written in terms of the
same `h`. Each recursive call borrows a slice of an `inout` parameter, which is itself a place. Nothing
is copied at any level.

**2. An `inout` argument and another argument reading an overlapping place of the same root.** A
read-mode array argument is borrowed, not copied, so it would see the callee's writes as they happen.
An `inout` window and a read-mode window of one array may go to the same call only when they are
visibly disjoint, by exactly the three forms of rule 1 — non-overlapping constant windows or indices,
a split at one expression `e`, or distinct constant indices on one axis:

```nex
def axpy(alpha: real, x: [real], y: inout [real]) =
  y = y + alpha * x

axpy(2.0, a[1..4], a[5..8])        // accepted: constant windows that do not overlap
axpy(2.0, a[..<e], a[e..])         // accepted: a split at e
axpy(2.0, m[:, 1], m[:, 2])        // accepted: distinct constant columns
axpy(2.0, a, a)                    // error: a is borrowed inout and read in the same call
axpy(2.0, a[1..k], a[j..n])        // error: the read may overlap the inout window
```

An argument that is evaluated to a scalar before the call starts does not conflict, since it has
nothing left to read: `scale(a, a[1])` and `scale(a, 1.0 / sum(a))` are legal. Arguments are
evaluated left to right, and the exclusive access starts after the last one. Where the windows are
not visibly disjoint, take a copy explicitly — `val x = a[j..n]` is a view, so bind
`var x = a[j..n]` — or write the update as slice assignment, `a[1..3] += a[4..6]`, whose right-hand
side is evaluated before anything is written.

**3. No access by another route inside the callee.** Passing a module-level `var` as an `inout`
argument to a function that reads or writes that same `var` by name, directly or through anything it
calls, is rejected. The checker computes, for every function, which module-level `var`s it reads and
writes.

{{< note >}}
The way the checker computes that summary may change; the rule itself stands.
{{< /note >}}

**4. No escaping capture.** Inside the callee, an `inout` parameter may be captured by a non-escaping
lambda — one passed straight as an argument — but never by an escaping one, which could outlive the
borrow:

```nex
def check_scale(v: inout [real]) =
  assert_traps(() -> scale(v, 1.0 / v[1]))   // accepted: the lambda is an argument and does not escape
  val later = () -> scale(v, 0.5)            // error: captures inout v and escapes
```

## 6.11 `inout` and Fortran's aliasing rule

A Fortran programmer already knows the rule `inout` enforces. The standard forbids a procedure from
modifying a dummy argument through one name while the same storage is reachable through another
dummy argument or through host or module association. Compilers rely on that rule to keep values in
registers and to vectorize, but they almost never check it: a program that breaks it compiles, and
then computes something wrong, often only at higher optimization levels.

nex keeps the rule and makes it a compile error. §6.10's rule 1 is the rule between two dummy
arguments that are both modified, rule 2 the rule between a modified dummy and any other dummy, and
rule 3 the rule for module variables. What you could rely on in correct Fortran you can rely on in
nex, and code that would have been incorrect Fortran does not compile.

Two differences remain:

- **Disjointness must be visible.** Fortran is satisfied if two sections do not in fact overlap when
  the program runs. nex needs to see it in the source: constant bounds, or one split point written
  identically on both sides. Code that splits at a computed point is written with the split form.
- **No copy-in/copy-out.** A Fortran compiler may pass a non-contiguous section through a temporary
  and copy it back on return. A nex `inout` slice is the caller's storage, so a trap in the middle of
  the callee leaves exactly the writes made before it ([chapter 8](/spec/08-values-and-memory/)).
