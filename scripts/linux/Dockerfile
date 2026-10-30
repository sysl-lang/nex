# The Linux machine nex is built against and tested on: Ubuntu 24.04 with what a nex program needs
# at run time — LLVM/MLIR 23 (mlir-opt, mlir-translate, clang, libomp), gfortran, OpenBLAS and
# Open MPI. `scripts/linux-sysroot.zsh` builds it and copies its system headers and libraries out as
# the sysroot the cross build links against; the same image runs the unpacked tarball.
#
#     docker build --build-arg BASE=<ubuntu:24.04 for the architecture> -t nex-linux scripts/linux
#
# The base is a build argument naming an image already pulled for the architecture wanted
# (`linux-sysroot.zsh` pulls and tags it), because Docker's legacy builder (colima's) ignores both
# `docker build --platform` and `FROM --platform` once it has `ubuntu:24.04` for its own.

ARG BASE=ubuntu:24.04
FROM $BASE

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl gnupg \
 && curl -fsSL https://apt.llvm.org/llvm-snapshot.gpg.key | gpg --dearmor -o /usr/share/keyrings/llvm.gpg \
 && echo "deb [signed-by=/usr/share/keyrings/llvm.gpg] http://apt.llvm.org/noble/ llvm-toolchain-noble-23 main" \
      > /etc/apt/sources.list.d/llvm.list \
 && apt-get update \
 && apt-get install -y --no-install-recommends \
      clang-23 llvm-23 lld-23 mlir-23-tools libomp-23-dev \
      gfortran libgfortran5 libopenblas-dev liblapack-dev \
      libopenmpi-dev openmpi-bin \
      libc6-dev libgcc-13-dev libstdc++-13-dev zlib1g-dev pkg-config file \
 && rm -rf /var/lib/apt/lists/*

ENV NEX_LLVM_HOME=/usr/lib/llvm-23
