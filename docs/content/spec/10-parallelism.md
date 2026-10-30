---
title: Parallelism
summary: parallel for, reductions, parallel map and reduction expressions, the race-freedom rules the compiler proves, reproducible results, and running on OpenMP.
weight: 100
---

nex runs on several threads only where the program says `parallel`. A `parallel for` loop or a
`parallel` expression is checked by the compiler: it either proves the iterations cannot race, or
it rejects the program with an error naming the offending write or read. Reductions give the
**same bits** for every thread count, and the same bits as the code without `parallel`.

Underneath, a parallel program runs on the OpenMP runtime, so it is controlled by the environment
variables an HPC batch script already sets.

## 10.1 `parallel for`

```nex
parallel for i in 1..n do y[i] = a * x[i] + y[i]

parallel for j in 1..cols(m)
  m[:, j] = m[:, j] / norm2(m[:, j])       // each iteration owns column j
```

The header is `parallel for` *index* `in` *range*, the same as a sequential `for`: `do` introduces a
one-line body, and a body on the following indented lines takes no `do`. The range is an integer
range, `lo..hi` or `lo..<hi`, with an optional step (`1..n by 2`). A `parallel for` iterates over indices only, never
directly over an array's elements. The iterations may run in any order, at the same time. The loop
ends when every iteration has finished.

Several indices in one header make a multi-dimensional iteration space:

```nex
parallel for i in 1..rows(c), j in 1..cols(c)
  c[i, j] = dot(a[i, :], b[:, j])
```

This is how a loop nest is made parallel. A `parallel` construct inside a parallel body is a compile
error, and the message suggests the two-axis header (`parallel for j in 1..n, i in 1..m`).

**Compared with Fortran.** `parallel for` is what `do concurrent` and `!$omp parallel do` both
express, with one difference: in Fortran it is your *promise* that the iterations are independent.
`do concurrent` asserts it and the compiler believes you. `!$omp parallel do` with a wrong
`shared`/`private` list compiles and races. In nex the compiler *checks* the claim (§10.4). A loop
that does not pass the check does not compile, and nex never quietly falls back to a sequential
loop.

### Batched matrix products

`@` takes operands of rank 1 and 2, as Fortran's `matmul` does (see
[Array expressions](/spec/05-array-expressions/)). A batch of products is a `parallel for` over the
trailing axis:

```nex
parallel for k in 1..n do C[:, :, k] = A[:, :, k] @ B[:, :, k]
```

Each iteration writes its own slab `C[:, :, k]` and reads only its own slabs of `A` and `B`, so the
loop passes the check. Each slice is a view, so nothing is copied to make the operands. There is no
batched `@` on rank-3 arrays, and none is planned.

{{< note >}}
If this idiom turns out slower than a vendor's batched `gemm`, an explicit batched routine may be
added. The idiom above will keep working either way.
{{< /note >}}

## 10.2 Reductions

A reduction is declared in the loop header, after the ranges, with the word `reduce`, the variable
and its operator:

```nex
var total = 0.0
var peak = 0.0
parallel for i in 1..n reduce total: +, peak: max
  total += x[i] * y[i]
  peak = max(peak, abs(x[i]))
print(total, peak)
```

The OpenMP equivalent is `!$omp parallel do reduction(+:total) reduction(max:peak)`. Fortran 2023
spells it `do concurrent (i = 1:n) reduce(+:total) reduce(max:peak)`.

`reduce` is a word only in this position. The prelude function `reduce` keeps its name.

### 10.2.1 The operators

| Operator | Applies to | Identity |
|---|---|---|
| `+` | integer, real, complex | `0` |
| `*` | integer, real, complex | `1` |
| `min` | integer, real | `+inf` for reals; the type's largest value for integers |
| `max` | integer, real | `-inf` for reals; the type's smallest value for integers |
| `and` | `bool` | `true` |
| `or` | `bool` | `false` |
| `minloc`, `maxloc` | a `(value, index)` tuple | see §10.2.3 |
| a user function `(T, T) -> T` | `T` | the variable's starting value |

### 10.2.2 The rules

The reduction variable is a `var` declared outside the loop, of a type the operator applies to.
Each iteration contributes to it through exactly one of these forms, where `e` does not mention
`v`:

| Form | Operators |
|---|---|
| `v op= e` | `+`, `*` (`v += e`, `v *= e`) |
| `v = v op e` | `+`, `*` |
| `v = op(v, e)` | `min`, `max`, a user function |
| `v = v and e`, `v = v or e` | `and`, `or` |
| `v = minloc(v, e, i)`, `v = maxloc(v, e, i)` | `minloc`, `maxloc` |

The variable is not read anywhere else in the body. Its value before the loop is the **starting
value**. After the loop it holds the starting value combined with every iteration's contribution.

```nex
var above = 0
var all_positive = true
parallel for i in 1..n reduce above: +, all_positive: and
  above += if x[i] > threshold then 1 else 0
  all_positive = all_positive and x[i] > 0.0
```

Rejected:

```nex
var s = 0.0
parallel for i in 1..n reduce s: +
  s += x[i]
  y[i] = s                 // error: the reduction variable `s` is read in the body
```

```nex
var s = 0.0
parallel for i in 1..n do s += x[i]
// error: `s` is written by every iteration; declare it `reduce s: +`
```

### 10.2.3 `minloc` and `maxloc`

`minloc` and `maxloc` reduce a (value, index) pair, as Fortran's `MINLOC`/`MAXLOC` intrinsics and
OpenMP's `minloc`/`maxloc` reductions do. The operator keeps the prelude function's name, and the
contribution is its three-argument form: the running pair, the candidate value and its index:

```nex
var worst = (0.0, 0)
parallel for i in 1..n reduce worst: maxloc
  worst = maxloc(worst, abs(r[i]), i)
val (largest, where) = worst
print("largest residual ", largest, " at ", where)
```

Ties go to the lowest index, as in Fortran, whatever the thread count.

### 10.2.4 User-defined operators

Any function of type `(T, T) -> T` can be a reduction operator. It is named in the header and
called in the contribution. A tuple accumulator lets a reduction carry more than one number. Here
is a compensated (Kahan–Babuška) sum, which carries a running sum and the rounding error lost from
it:

```nex
def kahan_add(a: (real, real), b: (real, real)): (real, real) =
  val (sa, ca) = a
  val (sb, cb) = b
  val s = sa + sb
  val lost = if abs(sa) >= abs(sb) then (sa - s) + sb else (sb - s) + sa
  (s, ca + cb + lost)

var acc = (0.0, 0.0)
parallel for i in 1..n reduce acc: kahan_add
  acc = kahan_add(acc, (x[i], 0.0))
val (s, c) = acc
val total = s + c
```

**The starting value is the operator's identity.** Every block of §10.3 starts from it, so it must
satisfy `f(start, x) == x` for every `x`. Here it is `(0.0, 0.0)`, a zero sum with zero
compensation. A starting value that is not an identity is counted more than once.

The compiler **assumes the operator is associative**. It cannot check that, and it does not need to
for reproducibility: the combination order is fixed (§10.3), so the result is the same on every run
and every thread count, associative or not. The function runs inside the parallel body and obeys
every rule of §10.4.

To accumulate onto a non-zero total, reduce from the identity and add the total after the loop.

## 10.3 Reproducibility

**A reduction's result does not depend on the thread count.** nex fixes the order in which the
contributions are combined:

1. The index range is cut into **fixed-size blocks** of 4096 iterations. The size is a
   compile-time constant of the language, not a tuning knob.
2. Each block is reduced **sequentially, in index order**, from the operator's identity (for a
   user operator, the variable's starting value).
3. The block results are combined in a **fixed pairwise tree** over the block numbers: block 1
   with block 2, block 3 with block 4, then those pairs, and so on.
4. The tree's result is combined once with the variable's starting value.

Threads only decide *who* computes which block, never the order of combination. So
`OMP_NUM_THREADS=1` and `OMP_NUM_THREADS=64` give **identical bits**.

**The whole-array reductions use the same tree.** `sum(x)`, `product(x)`, `dot(x, y)`, `norm2(x)`
and their `dim =` forms block and combine exactly as `parallel sum(x)` does. Adding or removing
`parallel` never changes a result.

**The order is not left to right.** A floating-point `sum(x)` therefore differs in its last bits
from a Fortran `DO` loop that accumulates one element at a time. It is also **more accurate**: the
rounding error of pairwise summation grows as O(log n) rather than O(n). A loop you write element
by element without `reduce` is an ordinary sequential loop and accumulates in source order, exactly
as written:

```nex
var s = 0.0
for i in 1..n do s += x[i]      // left to right, as written; one thread
```

Integer reductions are exact, so their order cannot be observed, except that an overflow traps.

**Compared with OpenMP.** In C or Fortran with `!$omp parallel do reduction(+:s)`, each thread sums
its own chunk and the partials are combined in an order that depends on the thread count and the
schedule. The answer changes in its last bits when the job moves to a node with a different core
count. In nex, it does not.

## 10.4 What the compiler proves

Inside the body of a `parallel for`, or the function passed to `parallel map` (§10.5), the
compiler proves the six things below. A body it cannot prove is a compile error that names the offending
write or read.

{{< note >}}
The wording of the error messages shown in this chapter is illustrative and may change. What is
settled is which loops are rejected and that the error names the write or read at fault.
{{< /note >}}

### 1. No write to shared state

A body may assign only to:

- bindings declared inside the body;
- the loop's declared reduction variables, in the forms of §10.2.2;
- elements or slices of an outer `var` array (or an `inout` parameter) **owned by the iteration**:
  in the write, some axis's subscript is exactly one of the loop's index variables, with distinct
  index variables on distinct axes. Then no two iterations can write the same element.

```nex
parallel for i in 1..n do y[i] = 2.0 * x[i]                 // owned: y[i]
parallel for j in 1..cols(m) do m[:, j] = m[:, j] * w[j]    // owned: column j
parallel for i in 1..n, k in 1..p do t[i, :, k] = f(i, k)   // owned: t[i, :, k]
```

Rejected:

```nex
parallel for i in 1..n-1 do y[i + 1] = x[i]
// error: write to `y[i + 1]` is not owned by the iteration; its subscript must be the index `i`

parallel for i in 1..n do y[idx[i]] = x[i]
// error: write to `y[idx[i]]` is not owned by the iteration; two iterations may write one element

var last = 0.0
parallel for i in 1..n do last = x[i]
// error: `last` is declared outside the loop and written by every iteration
```

{{< note >}}
The ownership rule is proposed and may change. As specified, it recognizes only the plain index
variable as a subscript, so `y[i + 1]` and `y[2 * i]` are rejected even where the writes are in
fact disjoint. Write such a loop over the index the write uses (`for j in 2..n do y[j] = x[j - 1]`).
{{< /note >}}

### 2. No read of what another iteration writes

An array written under rule 1 may be read in the body only at the iteration's own subscript.

```nex
parallel for i in 1..n do y[i] = y[i] + a * x[i]        // accepted: reads its own y[i]

parallel for i in 2..n do y[i] = y[i] + y[i - 1]
// error: `y[i - 1]` reads an element another iteration writes
```

A loop-carried dependence like the second loop is a sequential recurrence. Write it as a plain
`for`.

Every other outer binding is read-only for the duration of the loop, and reading it is free. nex
arrays are values, so no other code can change them while the loop runs. There is no `shared` or
`private` list to write, as there is in OpenMP.

### 3. No effects through calls

A function called in the body:

- may receive as an `inout` argument only a place the body itself is allowed to write by rule 1;
- may not write a module-level `var`, directly or through anything it calls;
- if it is an `extern` function, must be declared `@pure`.

```nex
def normalize(v: inout [real]) =
  v = v / norm2(v)

parallel for j in 1..cols(m) do normalize(m[:, j])      // accepted: column j is owned

var calls = 0                                          // a module-level var
def counted(x: real): real =
  calls += 1
  x * x

parallel for i in 1..n do y[i] = counted(x[i])
// error: `counted` writes the module-level var `calls`
```

The compiler knows which module-level `var`s each function reads and writes, transitively. It is
the same summary that checks `inout` arguments (see
[Values and memory](/spec/08-values-and-memory/)).

{{< note >}}
The mechanism that computes the module-level `var` summary is proposed and may change.
{{< /note >}}

An `extern` function is assumed to have effects unless it is declared `@pure`, and the compiler
believes `@pure` without proof (see [Interoperability](/spec/11-interop/)).

**I/O.** `print` and writing to stderr are allowed in a parallel body. Each call is **atomic**: its
whole line is written at once, so lines never interleave mid-line. The **order of lines across
iterations is unspecified**. This is the one deliberately non-reproducible thing in a parallel
loop. Every other kind of I/O (`read_bytes`, `write_bytes`, opening or writing a file, reading
input) is a compile error in a parallel body.

```nex
parallel for i in 1..n
  y[i] = solve(i)
  print("block ", i, " done")          // each line intact; order varies from run to run
```

### 4. The reductions are well formed

Each reduction variable is contributed to in one of the forms of §10.2.2 and read nowhere else.

### 5. No nested `parallel`

A `parallel for` or a `parallel` expression inside a parallel body is a compile error. A loop nest
is made parallel with one header over several indices (§10.1):

```nex
parallel for j in 1..n
  parallel for i in 1..m do c[i, j] = 0.0
// error: `parallel` inside a parallel body; write `parallel for j in 1..n, i in 1..m`
```

### 6. `cycle`, but not `exit`

`cycle` in a parallel body ends the current iteration and is allowed. `exit` is a compile error: the
iterations run in no order, so there is no "rest of the loop" to leave.

```nex
parallel for i in 1..n
  if mask[i] then cycle                // accepted: skips this iteration
  y[i] = f(x[i])
```

The same rules bind the body of an `@elemental` function ([Functions](/spec/06-functions/)).

### Traps in a parallel body

A trap inside a parallel body, such as an out-of-bounds index, ends the loop. Every iteration
already running finishes, no new one starts, and the trap is raised in the thread that started the
loop, as if by its first statement after the loop. If several iterations trap, which one is
reported is unspecified.

{{< note >}}
This trap behaviour is proposed and may change.
{{< /note >}}

## 10.5 Parallel map and reduction expressions

`parallel` also prefixes an expression whose value is computed element by element:

```nex
val y = parallel exp(-x * x)                    // elemental calls fuse into the loop
val w = parallel map(x, t -> if t > 0.0 then t else 0.0)   // or parallel x.map(…)
val d = parallel sum(x * y)
val r = parallel 2a + b                          // a whole-array expression
```

The forms are:

- `map`;
- the reductions `sum`, `product`, `minval`, `maxval` and `dot`, with or without `dim =`, which give
  the same bits as their sequential forms (§10.3);
- any whole-array element-wise expression, elemental calls included.

{{< note >}}
`parallel` before a whole-array element-wise expression (`parallel 2a + b`) is proposed and may
change.
{{< /note >}}

The general prelude `reduce(a, init, f)` has no parallel form. A custom parallel combination is a
`parallel for … reduce s: f` with a user operator (§10.2.4), where the identity and the
contribution are written out.

The function passed to `parallel map` obeys the rules of §10.4. It may read what it captures, and
it may not write to anything outside itself.

## 10.6 No implicit parallelism

A whole-array expression or reduction without `parallel` runs on **one thread**, even though it
would always be safe to run in parallel. Threads are started only by a `parallel` you wrote.

The reason is MPI. The typical scientific code runs one MPI rank per core. A compiler that threaded
each rank's array expressions without being asked would put several threads on every core and
slow the whole job down. nex leaves the decision to you, as Fortran and OpenMP do. nex has no
auto-parallelizing switch, and none is planned.

**The one exception is outside nex's control.** A large `@` is dispatched to BLAS (see
[Interoperability](/spec/11-interop/)), and a BLAS may thread inside the library. That is governed
by the library's own variables: `OPENBLAS_NUM_THREADS` for OpenBLAS, `VECLIB_MAXIMUM_THREADS` for
Apple Accelerate. Under one MPI rank per core, set the one for your BLAS to `1`.

## 10.7 Running a parallel program

**OpenMP is switched on by the program, not by a flag.** A program that contains `parallel`
anywhere is compiled against the OpenMP runtime and linked with it. A program with no `parallel`
links no OpenMP runtime at all. There is no `-fopenmp` to forget.

nex adds no environment variables of its own. The standard OpenMP ones apply:

| Variable | Effect |
|---|---|
| `OMP_NUM_THREADS` | the number of threads |
| `OMP_PROC_BIND` | whether threads are pinned to cores, as the OpenMP runtime reads it |
| `OMP_PLACES` | which cores (or sockets) the threads are placed on |

```sh
OMP_NUM_THREADS=16 OMP_PROC_BIND=close OMP_PLACES=cores ./simulate
```

**For debugging, run with `OMP_NUM_THREADS=1`.** The program then runs sequentially and, because
every reduction has a fixed order (§10.3), it produces **identical bits** to the 64-thread run. A
difference between the two is a bug in your program, not rounding noise.

**Hybrid MPI + OpenMP.** Run fewer MPI ranks than cores, typically one per node or one per socket,
and give each rank `OMP_NUM_THREADS` equal to the cores it owns. Bind each rank's threads to its
own cores with `OMP_PROC_BIND=close` and `OMP_PLACES=cores`, and with your MPI launcher's
binding option, so that ranks do not share cores. If the program also calls a threaded BLAS, set
that library's thread count so that, at any moment, only `parallel` or only BLAS is using a rank's
cores. Results do not depend on the split: changing the number of threads per rank does not change
a reduction's bits.

## 10.8 Many nodes: the `mpi` module

`parallel` uses the cores of one node. A program that runs across a cluster imports `mpi`, the
module nex ships: every process, a **rank**, runs the same `main`, and data moves only where the
program moves it.

```nex
import mpi.*

def main() =
  val me = rank()
  barrier()
  print(s"rank ${me} of ${size()}")
```

| name | what it is |
|---|---|
| `world()` | every rank of the job, a `Comm` |
| `self()` | this rank alone |
| `rank(comm = world())` | this process's rank in `comm`, counted from 0 |
| `size(comm = world())` | how many ranks `comm` holds |
| `barrier(comm = world())` | waits until every rank of `comm` has reached it |
| `no_rank` | the rank a send or receive to which does nothing (`MPI_PROC_NULL`) |

`import mpi.*` makes `rank` and `size` the module's, so `rank(a)` and `size(a)` of an array are then
refused; a program that needs both writes `import mpi` and calls `mpi.rank()`.

**Starting and ending are implicit.** Importing `mpi` makes the program initialise MPI before its
module-level bindings and finalise it after `main` returns. A trap nothing catches, or `stop n` with
`n` not 0, writes its message with the rank in front (`rank 2: trap: index out of bounds`) and ends
the whole job, so the other ranks never hang waiting for the one that failed.

**MPI programs run compiled.** The interpreter never calls C, so `nex run --interp` refuses a
program importing `mpi` at the `import`. `nex run --np 4 program.nex` runs it as a 4-rank job
([Command Line](/tooling/01-cli/)); `nex build` writes an executable you start with your cluster's
`mpirun` or `srun`. The program links the cluster's MPI — the `mpicc` that `module load` puts on
`PATH`, or the one `NEX_MPICC` names — and one built against Open MPI runs under Open MPI.
