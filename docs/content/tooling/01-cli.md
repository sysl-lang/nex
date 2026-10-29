---
title: Command Line
summary: nex run, nex build and nex test.
weight: 10
---

## 1.1 nex run

```
nex run program.nex
```

Compiles the program to a native binary and runs it. Standard output is the program's output; a
run-time error (an out-of-range index, an integer overflow that traps) prints its message and exits
non-zero.

## 1.2 nex build

```
nex build program.nex
```

Compiles the program to a native executable and leaves it on disk.

{{< note >}}
`nex build --no-blas` disables the dispatch of `@` to BLAS and is a proposed flag. The compiler's own
loops are then used for every product.
{{< /note >}}

## 1.3 nex test

```
nex test
```

Finds the functions marked `@test` in the project's modules, compiles them and runs each, reporting
which pass.

```nex
@test
def axpy_adds() =
  val y = 2.0 * [1.0, 2.0] + [10.0, 20.0]
  assert(y == [12.0, 24.0])
```

{{< note >}}
`nex test` and the `@test` attribute are planned but not yet implemented, and the exact name of the
assertion function may change.
{{< /note >}}

## 1.4 Finding the prelude

The prelude is part of the installation. The compiler finds it through the `NEX_HOME` environment
variable, or `--prelude-path` on the command line, when it is not in the default place.

{{< note >}}
The spelling of these two options may change.
{{< /note >}}
