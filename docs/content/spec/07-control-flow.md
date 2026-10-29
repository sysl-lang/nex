---
title: Control Flow
summary: if/then/else as expressions, match over sum types, for loops over ranges and arrays, while, blocks and end markers, and when to write a loop at all.
weight: 70
---

nex has four control-flow constructs: `if`, `match`, `for` and `while`, and four statements that
leave them early: `exit`, `cycle`, `return` and `stop`. Each construct is an expression, each body is
an indented block (or a one-line body after `then` or `do`), and each block may be closed by an
optional `end` marker. The
parallel form of `for` is in [Parallelism](/spec/10-parallelism/).

## 7.1 `if` / `then` / `else`

`if` is an expression: it has a value, and the two branches must agree on its type.

```nex
val sign = if x > 0.0 then 1 else if x < 0.0 then -1 else 0
```

`then` is **required when the body is on the same line** and optional when the body starts on a new,
indented line:

```nex
if residual < tol
  print("converged")
  done = true
else
  step(x)
```

A chain uses `else if`, or the single word `elif`; the two mean the same thing:

```nex
val regime =
  if re < 2300.0
    "laminar"
  elif re < 4000.0
    "transitional"
  else
    "turbulent"
```

The value of an `if` is the value of the last expression in the branch taken. An `if` without an
`else` has type `void`, and so must its body: it is a statement, run for its effect.

```nex
if n > nmax
  print(s"n = $n exceeds $nmax")
```

**For a Fortran programmer**: the block `if` is Fortran's `IF (...) THEN … ELSE IF … ELSE … END IF`
without the `THEN` on every line and with a value. The inline form `if c then a else b` is what
Fortran 2023's conditional expression `(c ? a : b)` writes. Both branches are type-checked, but only
the one taken is evaluated.

## 7.2 `match` and patterns

`match` inspects a value of a sum type (an `enum`, [§3](/spec/03-types/)) and picks the arm for
its variant. The value being inspected sits to the **left** of `match`; the arms follow on indented
lines, each `pattern -> body`:

```nex
enum Solve =
  Converged(x: real)
  Diverged
  MaxIters(iters: integer, last: real)

def report(s: Solve): real =
  s match
    Converged(x)      -> x
    Diverged          -> nan
    MaxIters(n, last) ->
      print(s"stopped after $n iterations")
      last
```

A `match` is an expression. Every arm's body has the same type, and that is the type of the `match`.
An arm's body may be a single expression after `->` or an indented block, as in the last arm above.

### 7.2.1 Patterns

| Pattern | Matches |
|---|---|
| `Variant` | a variant with no fields, by name |
| `Variant(p1, …, pn)` | a variant with fields, binding each field to its sub-pattern, in declaration order |
| `name` | anything, binding it to `name` |
| `_` | anything, binding nothing |

Inside a variant pattern each sub-pattern is a name or `_`; a pattern does not nest a second variant
inside the first. `name` and `_` at the top of an arm are catch-alls.

```nex
enum Color =
  Red
  Green
  Blue

def is_red(c: Color): bool =
  c match
    Red -> true
    _   -> false
```

### 7.2.2 Exhaustiveness

Every variant must be covered, by an arm that names it or by a catch-all. A `match` that leaves a
variant uncovered is a **compile error**, not a runtime trap. So is an arm that can never be reached:
two arms for the same variant, or any arm after a catch-all.

Fortran's nearest construct is `SELECT TYPE` or a `SELECT CASE` over an integer code; `match` is
checked by the compiler for completeness, which neither of those is.

### 7.2.3 What `match` does not do

`match` takes a value of an `enum` type, and nothing else: there is no `match` over integers, reals,
strings, structs or tuples, and an arm has no guard (`if` condition). A tuple is taken apart by
destructuring instead — in a `val` or `var` binding (`val lo, hi = bracket(f, x0)`) or in a `for` header
(§7.3.4). A choice over integer values is an `if`/`elif` chain.

## 7.3 `for` loops

`for` runs its body once for each value of a range or element of an array. `do` introduces a
**one-line body** on the same line as the header, and only that; a body that starts on a new,
indented line takes no `do`:

```nex
for k in 1..n do x[k] = k * h

for k in 1..n
  x[k] = k * h
  y[k] = f(x[k])
```

A `for` loop is an expression of type `void`. Its loop variable is local to the loop: it is a new
binding for each iteration and does not exist after the loop ends. (In Fortran the `DO` variable
survives the loop with a value one step past the last; nex has nothing to survive.)

### 7.3.1 Ranges: inclusive and half-open

`lo..hi` is **inclusive** — it runs from `lo` to `hi`, both included, exactly as Fortran's
`DO k = lo, hi`. `lo..<hi` is **half-open** — it stops before `hi`.

```nex
for k in 1..5 do print(k)      // 1 2 3 4 5
for k in 1..<5 do print(k)     // 1 2 3 4
for k in 1..0 do print(k)      // runs zero times
```

As in Fortran, a range whose upper bound is below its lower bound is **empty**, and the loop runs
zero times; there is no one-trip loop. `for k in 1..n` runs `n` times, and `for k in 0..<n` also
runs `n` times, for code that counts from zero.

A range is a value. It can be bound to a name and passed to a function, and the same range serves as
a loop header and as an array subscript:

```nex
val interior = 2..n-1
for k in interior
  u_new[k] = 0.5 * (u[k - 1] + u[k + 1])
val edge = u[interior]          // the same window as a slice
```

There is no `range(…)` function: `lo..hi` and `lo..<hi` are how a range is written. A range's bounds
are integers. `end`, which means "the last index" inside a subscript, is not an index in a `for`
header: write `for k in 1..length(a)`, or loop over the array itself (§7.3.3).

### 7.3.2 Steps: `by`, and counting down

`by k` after a range takes every `k`-th value, starting from the first bound. It is Fortran's
`DO j = lo, hi, k`:

```nex
for j in 1..n by 2 do odd_sum += a[j]       // 1, 3, 5, …, up to n
for j in 2..<n by 3 do print(j)             // 2, 5, 8, … stopping before n
```

A negative step counts down. The bounds are read **in the direction of travel**: the first bound is
where the loop starts and the second is where it stops, so a countdown is written high bound first:

```nex
for k in n..1 by -1                          // n, n-1, …, 1
  x[k] = (b[k] - dot(u[k, k+1..n], x[k+1..n])) / u[k, k]
```

Without the `by -1`, `n..1` is an empty range when `n > 1`, and the loop does not run — the same
answer Fortran gives for `DO k = n, 1`. A step of `0` traps.

A `for` header follows exactly the rules of `by` in a subscript ([Arrays](/spec/04-arrays/)). A
stepped range is a value like any other range: `val odd = 1..n by 2` may be bound, passed, looped
over and used as a subscript.

### 7.3.3 Looping over an array

`for x in a` binds `x` to each element of `a` in turn:

```nex
var total = 0.0
for x in samples
  total += x * x
```

`a` may be a slice, which loops over the window without copying it (`for x in m[:, j]` walks
column `j`). Over a rank-1 array the order is first element to last.

{{< note >}}
Over an array of rank 2 or more, `for x in a` visits every element in storage order — column-major,
first index fastest, as Fortran stores it. This order is proposed and may change.
{{< /note >}}

### 7.3.4 `enumerate`: index and element together

`enumerate(a)` pairs each element with its index, and the loop header takes the pair apart with no
parentheses. Indices are **1-based**, so they are the same numbers that index `a`:

```nex
for k, x in enumerate(v)
  if x < 0.0 then print(s"v[$k] = $x is negative")
```

The same destructuring works for any array of tuples, such as the result of `zip(a, b)`:

```nex
for x, y in zip(xs, ys)
  sxy += x * y
```

### 7.3.5 The name `i`

`i` is the imaginary unit, and a loop variable named `i` shadows it inside the loop, so `2i` in that
body means `2 * i`, the index times two. This is deliberate, and it is the usual reason to name a
loop index `j`, `k`, `m` or `n` in code that also uses complex numbers. The rule is in
[Lexical structure](/spec/02-lexical/).

## 7.4 `while` loops

`while` runs its body as long as its condition is true, testing before each pass. The `do` rule is
the same as `for`'s — `do` for a one-line body, none for an indented block:

```nex
while abs(dx) > tol do dx = newton_step(x, dx)

var it = 0
while abs(f(x)) > tol and it < max_iter
  x = x - f(x) / df(x)
  it += 1
```

A `while` loop is an expression of type `void`. It is Fortran's `DO WHILE (…)`.

## 7.5 Leaving a loop early

`exit` leaves the innermost enclosing loop, and `cycle` skips the rest of the body and goes to that
loop's next iteration. They are Fortran's `EXIT` and `CYCLE`, under the same names:

```nex
var found = 0
for k in 1..length(v)
  if v[k] == 0.0 then cycle            // skip zeros
  if v[k] < 0.0
    found = k
    exit                               // stop at the first negative
```

A loop may be **named** with a label before `for` or `while`; `exit` and `cycle` followed by the
name act on that loop rather than the innermost one, as Fortran's named `DO` constructs do:

```nex
outer: for j in 1..n
  for k in 1..m
    if a[k, j] < 0.0 then cycle outer  // next column
    if a[k, j] > limit then exit outer // stop the whole search
    total += a[k, j]
```

`return` ends the whole function from inside any loop:

```nex
def first_negative(v: [real]): integer =
  for k in 1..length(v)
    if v[k] < 0.0 then return k
  0                                    // none found
```

**`stop`** ends the program, from anywhere, with exit status 0; `stop n` ends it with exit status
`n`. It is Fortran's `STOP` and `STOP n`:

```nex
if not converged
  eprint(s"no convergence after $max_iter iterations")
  stop 1
```

Inside the body of a `parallel for`, `cycle` is allowed (it ends that iteration) and `exit` is a
compile error, since the iterations have no order to leave ([Parallelism](/spec/10-parallelism/)).

## 7.6 Blocks, scope and `end` markers

A body is an **indented block**: the lines below the header, indented further than it. The block
ends at the first line indented no further than the header. Every body — of an `if` branch, a
`match` arm, a `for`, a `while`, a `def` — opens a new scope, and a binding made inside it is not
visible after it ends.

A block is itself an expression whose value is its last line's (a statement as the last line gives
`void`):

```nex
val rms =
  val s = sum(x * x)
  sqrt(s / length(x))
```

Any block may be closed with an `end` marker, bare or naming the construct it closes:

```nex
def back_substitute(u: [real; :, :], b: [real]): [real] =
  val n = length(b)
  var x = fill(n, 0.0)
  for k in n..1 by -1
    var s = b[k]
    for j in k+1..n
      s -= u[k, j] * x[j]
    end for
    x[k] = s / u[k, k]
  end for
  x
end def
```

The markers are **optional and change nothing**: indentation alone decides where a block ends, and
a marker only makes a long block easier to read. This is the reverse of Fortran, where `END DO` and
`END IF` are what close the block. A marker is `end` as the first word of a line outside any
brackets; `end` inside `a[…]` is the last-index expression ([Arrays](/spec/04-arrays/)), and the two
never collide.

## 7.7 Loops or whole-array expressions

Most array arithmetic in nex needs no loop. A whole-array expression says the same thing as a loop
over every element, and is usually the better choice:

```nex
y = a * x + y                       // rather than: for k in 1..n do y[k] = a * x[k] + y[k]
u[2..end-1] = 0.5 * (u[1..end-2] + u[3..end])
```

**Write the whole-array expression when the operation is element-wise.** It is shorter, it cannot
get an index wrong, and the compiler fuses each such expression into a single loop over the data,
with no temporary array for the intermediate results ([Array expressions](/spec/05-array-expressions/)).
It is what Fortran 90 array syntax does, and it runs as fast as the hand-written loop.

**Write a loop when** an element depends on one computed earlier in the same pass (a recurrence,
back substitution, a Gauss–Seidel sweep), when the body branches per element in a way one expression would make
unclear, or when the work per index is a sequence of steps rather than one
formula.

**Reductions are a special case.** `sum(x)`, `dot(x, y)` and the other prelude reductions add in a
fixed pairwise order that is more accurate than adding left to right and gives the same bits with or
without `parallel`. A loop `for k in 1..n do s += x[k]` adds in source order, as written, which is
what a Fortran `DO` loop does; the two can differ in the last bits. Prefer the prelude reduction
unless the left-to-right order is what you need ([Parallelism](/spec/10-parallelism/)).

**For parallel work**, neither a loop nor an array expression ever runs on more than one thread by
itself. A loop whose iterations are independent becomes parallel when written `parallel for`, and
the compiler proves the iterations do not race ([Parallelism](/spec/10-parallelism/)).
