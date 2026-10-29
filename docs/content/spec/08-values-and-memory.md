---
title: Values and Memory
summary: Value semantics, the copies the compiler makes and the ones it leaves out, views and how long their storage lives, reference counting with no garbage collector, traps, and what the absence of aliasing gives the optimizer and the reader.
weight: 80
---

nex has no pointers, no `allocate` and no `deallocate`. An array is a value, like a number: binding
it, passing it and returning it never lets two names change the same data behind each other's back.
This chapter says what that promise is, what it costs, and how the compiler keeps the cost near zero.
Most of it is bookkeeping the compiler does for you; it is set out here so you can predict where a
copy happens and where one does not.

## 8.1 Value semantics

Every binding holds a **value**. Assigning an array to another name, passing it, returning it or
storing it in a struct behaves as if the whole array were copied: a later write through one name is
never seen through the other.

```nex
var a = [1.0, 2.0, 3.0]
var b = a
b[1] = 99.0
print(a[1])                        // 1.0: a is unchanged
print(b[1])                        // 99.0

val snapshot = a
a[2] = 0.0
print(snapshot[2])                 // 2.0: snapshot keeps the value it was given
```

Fortran's array assignment `b = a` agrees: it copies. The difference is that nex has no `pointer`
attribute, no `target`, no `associate` that writes through, and no `equivalence` or `common`
overlay, so there is no other way for two names to reach one array. The only way to change a
caller's data is an `inout` argument, and that is visible in the callee's signature
([§6.8](/spec/06-functions/)).

"As if copied" is the meaning, not the cost. The sections that follow describe when the compiler
actually copies; in ordinary code it rarely needs to.

## 8.2 The two regimes: `val` shares, `var` owns

- **A `val` array** cannot be changed by anyone, so any number of bindings, views, struct fields and
  closures may share its storage. Binding a `val` to another `val`, passing it, or returning it copies
  nothing.
- **A `var` array** may be changed, so it is the **unique owner** of its storage: at every point in
  the program, at most one live binding can write a given buffer, and no other binding can see it
  being written. This is the **uniqueness rule**.

Everything else in this chapter follows from keeping both regimes true at once.

## 8.3 Copies the compiler inserts, and copies it leaves out

You do not write copies. The compiler places them where the uniqueness rule needs one, and removes
every one it can prove unnecessary. The copies are silent: no warning and no annotation.

**A `var` array moves** — hands over its storage without copying — when it is

- **returned** from a function, or
- **assigned to another `var`** and not used again afterwards.

If the source *is* used again, the assignment copies, so each `var` owns its own buffer:

```nex
def build(n: integer) =
  var v = fill(n, 0.0)
  for k in 1..n do v[k] = k * k
  v                                // moved to the caller: no copy

var a = build(1000)                // a owns the array build made
var b = a                          // a is used again below, so b gets a copy
b[1] = -1.0
print(a[1], b[1])                  // 1.0 and -1.0

var c = b                          // b is never used again: c takes b's storage, no copy
c[2] = 0.0
```

The compiler chooses where to place a copy so that as many transfers as possible are moves: when a
value is used twice, it copies at the earlier use and moves at the last one.

**A `var` made from a shared value gets its own buffer.** `var w = a[1..4]` copies the window
(§8.5 rule 2), and `var w = v` with `v` a `val` gives `w` storage of its own, so that writing `w`
cannot be seen through `v`.

{{< note >}}
Whether the copy from a `val` into a `var` is left out when it cannot be observed (for example when
`v` is not used again) may change.
{{< /note >}}

**Arguments copy nothing.** A read-mode argument is borrowed: the callee reads the caller's storage
for the duration of the call, whether the caller holds it as a `val` or a `var`. An `inout` argument
is an exclusive borrow of the caller's place and is written in place. Neither moves the array, so
the caller keeps using it after the call with no copy:

```nex
var a = [3.0, 4.0]
val n1 = norm2(a)                  // borrowed, read, returned
scale(a, 1.0 / n1)                 // borrowed inout, written in place
val n2 = norm2(a)                  // a is still a's: 1.0
```

The full list of places a copy can occur:

| Where | Copy made when |
|---|---|
| `var b = a`, `a` a `var` | `a` is used again later |
| `var w = v`, `v` a `val` or a view | at the binding |
| a `val` (or view) of a `var` | the `var` is written while the `val` or view is still used (§8.5 rule 4) |
| a view that escapes | it is returned, stored, captured by an escaping closure, or bound at module level (§8.5 rule 3) |
| `rebase(w)` | always: it makes a 1-based array from an offset view |
| slice assignment `a[r1] = a[r2]` | the two windows may overlap ([§4](/spec/04-arrays/)) |
| an array passed to a C or BLAS routine | the routine needs unit stride and the view does not have it ([§11](/spec/11-interop/)) |

A Fortran programmer will recognise the last two: they are where a Fortran compiler also introduces
a temporary.

## 8.4 Bindings that hold a scalar or a struct

Scalars are copied every time; there is nothing to share. (A scalar `inout` argument is the one
case passed by reference, as every Fortran argument is.) A struct is a value in the
same sense as an array: `var q = p` followed by `q.x = 1.0` leaves `p` unchanged, and a struct
holding arrays follows the regimes of §8.2 field by field.

## 8.5 Views

A slice with at least one kept axis — `a[2..5]`, `m[:, j]`, `a[1..n by 2]`, `t[:, :, k]` — is a
**view**: a window onto the source's storage with its own offset, extents and strides. Taking a view
allocates nothing and copies nothing. A view has an ordinary array type (`a[2..5]` is `[real]`), and
every function that takes an array takes a view; whether a value is a view or an owned array is never
observable, only its cost.

```nex
val col = m[:, 3]                  // no copy: a window onto column 3 of m
val s = sum(col)
val e = sum(x[1..end by 2])        // a strided view, passed without copying
```

Five rules make views fit value semantics:

1. **Read-only.** Nothing writes through a view. Writing a window of the source is slice assignment
   on the source (`m[:, 3] = 0.0`) or passing the slice expression as an `inout` argument
   ([§6.9](/spec/06-functions/)) — never a write through a named view.
2. **A view bound to a `var` is a copy.** `var w = a[1..4]` gives `w` its own array; `w[1] = 1.0`
   changes only `w`.
3. **A view that escapes is copied.** A view that would outlive the expression or block that took it
   — returned from the function, stored in a struct, tuple or enum payload, captured by an escaping
   closure, or bound at module level — is copied into a dense array at that point. Passing a view as
   an argument is not an escape, and neither is binding it to a local `val`.
4. **The source does not change under it.** If the source is a `var` and is written while a view of it
   is still in use, the view keeps the values it had when it was taken: the compiler copies the view
   before the write. A view whose last use comes before the write costs nothing.
5. **A view keeps its source's storage alive** for as long as the view lives, by holding a reference
   on the source's buffer (§8.6).

```nex
var a = [1.0, 2.0, 3.0, 4.0]
val head = a[1..2]
a[1] = 100.0                       // head is used below, so it is copied first
print(head[1])                     // 1.0

val tail = a[3..4]
print(sum(tail))                   // last use of tail
a[3] = 0.0                         // no copy: tail is no longer used
```

Rule 4 is the one place nex departs from what a Fortran `associate` or pointer to a section would do:
those see later writes to the source, and a nex view never does.

**Offset views.** `origin(a, o1, o2, …)` is a view whose axes start at the given indices instead of 1
(see [§4](/spec/04-arrays/)). It obeys every rule above and one more: it is **local to the function
that took it**. Passing it as an argument, returning it, storing it, binding it at module level or
capturing it in an escaping closure is a compile error:

```
an `origin` view cannot leave this function; `rebase(w)` makes an ordinary 1-based array
```

So every array a function receives starts at index 1, and no function has to ask what bounds its
arguments have.

## 8.6 Reference counting, no garbage collector

Arrays, strings, and structs that hold them live on the heap. Each heap value carries a **reference
count**: sharing it (a second `val`, a view, a captured value) adds one, a binding going out of scope
removes one, and the storage is freed the moment the count reaches zero. There is no garbage
collector, no collection pause and no runtime beyond the counts.

Freeing is therefore deterministic: an array's storage is returned when its last binding or view goes
out of scope, at a point you can find in the source. A `var` array, being uniquely owned, is freed at
the end of its binding's scope unless it was moved out first.

Compared with Fortran: a nex local array behaves like an `allocatable` local, which Fortran also frees
automatically on return; what nex adds is that you never write `allocate`, and that a shared
immutable array costs no copy.

## 8.7 Traps

A **trap** stops the computation with a message. It is how nex reports an error that only the
running program can detect:

- integer overflow, at every width, signed and unsigned;
- integer division by zero (real division by zero, an invalid real operation and real overflow give
  `inf` or `nan` unless the program is built with `--fpe-trap`, which makes them traps too);
- an index or slice bound outside its axis, including any negative index or an index into an empty
  axis;
- a shape mismatch between operands, or between a dynamic shape and a static one it is converted to;
- a conversion whose value does not fit its target (`uint32(-1)`, `int32` of NaN);
- a failed `assert`.

A trap that nothing catches prints its message and ends the program.

Nothing is rolled back. A function whose `inout` argument traps part-way leaves the caller's data with
every write made before the trap:

```nex
def fill_reciprocals(v: inout [real], d: [integer]) =
  for k in 1..length(v) do v[k] = 1.0 / d[k]
```

Called with `d = [1, 2, 0, 4]`, it writes `v[1]` and `v[2]`, traps at `k = 3`, and leaves `v[3]` and
`v[4]` as they were. This is what a Fortran program that stops in the middle of an update does too,
with the difference that nex always stops instead of continuing with a wrong value.

**Testing for a trap.** `assert_traps(thunk)` runs a function of no arguments and passes if calling
it traps; it fails if the function returns normally. `assert_traps(thunk, text)` also requires the
trap's message to contain `text`:

```nex
@test
def test_index_past_the_end_traps() =
  val a = [1, 2, 3]
  assert_traps(() -> a[4])
  assert_traps(() -> a[0])

def expect_trap(v: inout [real]) =
  assert_traps(() -> fill_reciprocals(v, [1, 2, 0, 4]))

@test
def test_partial_update_survives_a_trap() =
  var v = fill(4, 0.0)
  expect_trap(v)
  assert_eq(v, [1.0, 0.5, 0.0, 0.0])
```

A lambda passed straight to `assert_traps` does not escape, so it may capture an `inout` parameter
([§6.10](/spec/06-functions/)) and the writes made before the trap reach the caller. A trap inside a `parallel for` ends the loop and is
raised after it ([§10](/spec/10-parallelism/)).

## 8.8 What "no aliasing" buys

Value semantics plus the exclusivity rules of [§6.10](/spec/06-functions/) mean that, in every nex
program, **two names that can be written never refer to overlapping storage**. That is the property a
Fortran compiler assumes and cannot check, and the property C asks for with `restrict` and trusts.
In nex it is checked, and it pays twice.

**The optimizer.** Because no write can be seen through another name, the compiler may keep values
in registers across writes, reorder and vectorize loops, and fuse a whole-array expression such as
`y = alpha * x + y` into one loop with no temporary, without the run-time overlap tests or
conservative copies that a language with aliasing needs. An `inout` array argument is written in place
with no copy-in or copy-out. Reductions and parallel loops are proved free of races from the same
facts ([§10](/spec/10-parallelism/)).

**The reader.** A call can change only what its signature says it can: its `inout` arguments, and the
module-level `var`s it writes. A `val` you are holding cannot change under you; neither can a view,
nor an array you passed to a read-mode argument. To know what `solve(a, b, x)` modifies, read the
parameter list of `solve` — not its body, and not the bodies of everything it calls.
