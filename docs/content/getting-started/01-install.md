---
title: Install
summary: Install the nex compiler with Homebrew.
weight: 10
---

## 1.1 Homebrew

```
brew install sysl-lang/tap/nex
```

{{< note >}}
nex has not been released yet, so the formula does not exist yet. This page shows the intended
installation.
{{< /note >}}

Check the install:

```
nex --version
```

## 1.2 What else you need

nex compiles through MLIR and LLVM, which the package carries. Programs that use `@` on large
matrices or the linear-algebra routines link a BLAS and LAPACK library: Accelerate on macOS, which is
already installed, and OpenBLAS on Linux (for example `apt install libopenblas-dev`).

{{< note >}}
The OpenBLAS path on Linux is not yet verified.
{{< /note >}}
