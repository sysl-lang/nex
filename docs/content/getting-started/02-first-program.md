---
title: Your First Program
summary: Write a program, run it with nex run.
weight: 20
---

## 2.1 Hello

Save this as `hello.nex`:

```nex
def main() =
  print("Hello from nex")
```

Run it:

```
nex run hello.nex
```

`nex run` compiles `hello.nex` to a native binary and runs it. Nothing is interpreted.

## 2.2 A small array program

```nex
def main() =
  val x = [1.0, 2.0, 3.0, 4.0]
  val y = [4.0, 3.0, 2.0, 1.0]
  val z = 2.0 * x + y          // one fused loop, no temporary arrays
  print(z)
  print(sum(x * y))
  print(z[2..3])               // like Fortran's z(2:3)
  print(z[end])                // the last element
```

Arrays are 1-based, as in Fortran, and `2..3` includes both ends. `end` stands for the last index of
the axis it appears in. An index outside the array is a run-time error that stops the program with a
message; it never wraps around.

## 2.3 Variables

`val` binds a value that cannot change; `var` binds one that can:

```nex
def main() =
  val n = 5
  var total = 0.0
  for k in 1..n
    total += k
  print(total)
```

`for k in 1..n` runs `n` times, like Fortran's `do k = 1, n`.
