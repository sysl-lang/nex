---
title: Building a Binary
summary: nex build, parallel programs and BLAS linkage.
weight: 30
---

## 3.1 nex build

```
nex build hello.nex
```

produces a native executable. Run it directly:

```
./hello
```

The binary does not need nex installed. See [the command-line reference](/tooling/01-cli/) for the
options: `--fpe-trap` to stop on a floating-point division by zero, invalid operation or overflow,
as gfortran's `-ffpe-trap` does, and `-L dir` / `-l name` to link a library of your own. A program
that calls Fortran through `@fortran` gets the gfortran runtime linked automatically.

## 3.2 Parallel programs

A program with `parallel for` loops or `parallel` reductions reads its thread count from
`OMP_NUM_THREADS`, the variable your batch scripts already set:

```
OMP_NUM_THREADS=8 ./sim
```

nex adds no variable of its own. `OMP_NUM_THREADS=1` runs the program sequentially, and a parallel
reduction produces the same bits at any thread count. `OMP_PROC_BIND` and `OMP_PLACES` are honoured as
the OpenMP runtime reads them.

## 3.3 BLAS and LAPACK

`A @ B` on `real32`, `real64` and complex matrices calls BLAS (`gemm`, `gemv`, `dot`) when the
operands are large or are transposed, and the linear-algebra functions in the prelude call LAPACK. A
build links the library for its platform:

- macOS: Accelerate, with nothing to install.
- Linux: OpenBLAS.

{{< note >}}
OpenBLAS linkage on Linux is untested, and no build option turns BLAS dispatch off. A BLAS result can differ from the compiler's own loop in the last bits, because the
library sums in a different order.
{{< /note >}}
