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

```
nex run --np 4 heat.nex
```

runs a program importing `mpi` as a 4-rank MPI job ([Parallelism](/spec/10-parallelism/)): under
`mpirun -n 4`, the `mpirun` of the MPI the program links; under `srun -n 4` inside a Slurm allocation
(`SLURM_JOB_ID` set); or under the launcher `NEX_MPIRUN` names, which is given `-n 4` after its own
words (`NEX_MPIRUN="mpirun --oversubscribe"`). Without `--np` such a program is a job of one rank.
A rank that traps, or stops with a status other than 0, writes its message with its rank in front
(`rank 2: trap: index out of bounds`) and ends the whole job.

The MPI is the one `NEX_MPICC` names, else `mpicc` on `PATH`, else what `pkg-config` knows as
`ompi-c` or `mpich`. A program that does not import `mpi` links none.

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
| `-o file` | names the executable (`nex build` only) |

`nex run --interp` and `nex test --interp` run the program in the interpreter instead, which needs no
LLVM toolchain; `nex --version` prints the version.

The compiler finds LLVM (`mlir-opt`, `mlir-translate`, `clang`) at `NEX_LLVM_HOME`, else Homebrew's
`opt/llvm`, and the runtime archive `libnex_rt.a` at `NEX_RUNTIME`, else beside the `nex` executable.
`NEX_BLAS` names the BLAS and LAPACK link options in place of the platform's.

A program with a `@fortran` extern is linked against the gfortran runtime automatically
([Interoperability](/spec/11-interop/)).

## 1.3 nex test

```
nex test main.nex
```

Finds every function marked `@test` in the program's modules and in the test modules beneath its
directory, compiles them and runs each. It prints one line for each failing test and then a summary
of how many passed and failed, and exits non-zero when any failed. A trap inside a test fails that
test only; the others still run.

```
nex test main.nex axpy
```

runs only the tests whose names contain the given substring. `nex test --np 4 main.nex` runs each
test as a 4-rank MPI job, and a test that traps on a rank fails with the rank in front of its
message.

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

The prelude is built into the compiler. A source prelude directory, read beside it, is the one
`--prelude-path` names, else `$NEX_HOME/lib/prelude` where that exists; without either, the built-in
prelude alone is used.
