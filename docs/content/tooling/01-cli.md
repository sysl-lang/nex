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

| option | effect |
|---|---|
| `--fpe-trap` | real division by zero, invalid operations and overflow trap instead of giving `inf` or `nan` (gfortran's `-ffpe-trap=zero,invalid,overflow`); `nex run` takes it too |
| `-L dir` | adds `dir` to the library search path |
| `-l name` | links the library `name`, beside those named by `@link("name")` |

A program with a `@fortran` extern is linked against the gfortran runtime automatically
([Interoperability](/spec/11-interop/)).

{{< note >}}
`nex build --no-blas` disables the dispatch of `@` to BLAS and is a proposed flag. The compiler's own
loops are then used for every product.
{{< /note >}}

## 1.3 nex test

```
nex test
```

Finds every function marked `@test` in the project's test modules, compiles them and runs each. It
prints one line for each failing test and then a summary of how many passed and failed, and exits
non-zero when any failed. A trap inside a test fails that test only; the others still run.

```
nex test axpy
```

runs only the tests whose names contain the given substring.

```nex
@test
def axpy_adds() =
  val y = 2.0 * [1.0, 2.0] + [10.0, 20.0]
  assert(y == [12.0, 24.0])
```

{{< note >}}
`nex test` is not yet implemented.
{{< /note >}}

## 1.4 Finding the prelude

The prelude is part of the installation. The compiler finds it through the `NEX_HOME` environment
variable, or `--prelude-path` on the command line, when it is not in the default place.

{{< note >}}
The spelling of these two options may change.
{{< /note >}}
