---
title: Install
summary: Install the nex compiler with Homebrew on macOS, or from a release tarball on Linux.
weight: 10
---

## 1.1 macOS: Homebrew

```
brew install sysl-lang/tap/nex
```

The formula installs LLVM (`mlir-opt`, `mlir-translate` and `clang`, which nex drives to compile a
program) with it.

Check the install:

```
nex --version
```

## 1.2 Linux: the release tarball

nex runs on Linux on `aarch64` (AWS Graviton, `hpc7g`) and `x86_64` (`hpc7a`). A release is a
tarball, `nex-<version>-linux-aarch64.tar.gz` or `nex-<version>-linux-x86_64.tar.gz`, which unpacks
to a prefix holding `bin/nex`, the runtime archive `bin/libnex_rt.a` (found beside `nex`), and
`share/nex/`:

```
mkdir -p ~/nex
tar -xzf nex-0.1.0-linux-aarch64.tar.gz -C ~/nex
export PATH=~/nex/bin:$PATH
nex --version
```

The binary needs glibc 2.39 or newer — Ubuntu 24.04, or a distribution of the same age — and
OpenBLAS's shared library at run time, because the interpreter in it calls BLAS and LAPACK. What a
program needs depends on what it uses. On Ubuntu 24.04:

| for | packages |
|---|---|
| `nex` itself, and `nex run --interp` | `libopenblas0` |
| compiling (`nex build`, `nex run`) | LLVM 23 with MLIR from [apt.llvm.org](https://apt.llvm.org): `clang-23 llvm-23 lld-23 mlir-23-tools` |
| `parallel` (OpenMP) | `libomp-23-dev` |
| `@` and the linear-algebra routines | `libopenblas-dev` |
| `@fortran` externs | `gfortran` |
| `import mpi` | `libopenmpi-dev openmpi-bin`, or the cluster's MPI (`module load openmpi`) |

```
apt install clang-23 llvm-23 lld-23 mlir-23-tools libomp-23-dev libopenblas-dev gfortran libopenmpi-dev openmpi-bin
```

nex finds LLVM at `NEX_LLVM_HOME`, else at `/usr/lib/llvm-23` (where apt.llvm.org puts it), else
above an `mlir-opt` on `PATH`, as `module load llvm` leaves one. gfortran is the one on `PATH`
unless `NEX_GFORTRAN` names another, and MPI is the `mpicc` on `PATH` unless `NEX_MPICC` does.

**What has been run.** Both tarballs are cross-built from macOS and checked in Ubuntu 24.04
containers: every program of the test corpus passes on both engines, the perf oracle's kernels
match their gfortran twins' checksums (the `parallel` ones under OpenMP, the BLAS one under
OpenBLAS), the Fortran programs link gfortran's runtime, and the MPI programs pass under Open MPI
4.1 with `mpirun -np 4`. The `x86_64` check ran under emulation, not on an x86 machine. Neither has
yet run on a cluster, under Slurm, over EFA, or against MPICH.

{{< note >}}
A `@link(framework = "…")` names a macOS framework and is refused on Linux; link the library
itself, as `@link("openblas")`.
{{< /note >}}

### Building the Linux tarballs

They are built on a Mac with Docker (colima), sysl and Homebrew's LLVM and lld:

```
zsh scripts/linux-sysroot.zsh aarch64-linux
zsh scripts/package.zsh --target aarch64-linux
zsh scripts/linux-check.zsh aarch64-linux
```

`linux-sysroot.zsh` builds the Ubuntu 24.04 image of `scripts/linux/Dockerfile` (LLVM 23, gfortran,
OpenBLAS, Open MPI) and copies its headers and libraries out as the sysroot the cross link uses;
`package.zsh` writes `dist/nex-<version>-linux-<arch>.tar.gz` and runs it in that image; and
`linux-check.zsh` runs the whole check above there. The same three with `x86_64-linux` make the
x86_64 tarball.

## 1.3 BLAS and LAPACK

Programs that use `@` on large matrices or the linear-algebra routines link a BLAS and LAPACK
library: Accelerate on macOS, which is already installed, and OpenBLAS (`-lopenblas`) on Linux.
`NEX_BLAS` names other link options, for example a vendor library:
`NEX_BLAS="-L/opt/armpl/lib -larmpl"`.
