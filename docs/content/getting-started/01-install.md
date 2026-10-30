---
title: Install
summary: Install the nex compiler with Homebrew.
weight: 10
---

## 1.1 Homebrew

```
brew install sysl-lang/tap/nex
```

The formula installs LLVM (`mlir-opt`, `mlir-translate` and `clang`, which nex drives to compile a
program) with it. nex 0.1.0 has been built and tested on macOS (Apple silicon) only.

Check the install:

```
nex --version
```

## 1.2 What else you need

nex compiles through MLIR and LLVM, which Homebrew installs with it (`NEX_LLVM_HOME` names another
LLVM). Programs that use `@` on large
matrices or the linear-algebra routines link a BLAS and LAPACK library: Accelerate on macOS, which is
already installed, and OpenBLAS on Linux (for example `apt install libopenblas-dev`).

{{< note >}}
The OpenBLAS path on Linux is untested: nex has not been run on Linux.
{{< /note >}}
