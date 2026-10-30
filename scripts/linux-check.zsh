#!/usr/bin/env zsh
# Runs nex's Linux check (`scripts/linux/smoke.sh`) on a Linux release tarball inside the
# `nex-linux` Docker image: the corpus on both engines, the perf oracle's kernels against their
# twins, OpenMP, OpenBLAS, gfortran and Open MPI.
#
#     zsh scripts/linux-check.zsh aarch64-linux|x86_64-linux [np]
#
# The tarball is `dist/nex-<version>-linux-<arch>.tar.gz` (`scripts/package.zsh --target`); the image
# is the one `scripts/linux-sysroot.zsh` builds. `np` (default 4) is the MPI programs' rank count.

set -eu

root=${0:A:h:h}

case ${1:-} in
    aarch64-linux) image=nex-linux; arch=aarch64; extra=() ;;
    # On an aarch64 Docker host the amd64 image runs under QEMU, whose emulated processor topology
    # fails an assertion in libomp's affinity code (kmp_affinity.cpp: `count[level] > 0`); OpenMP
    # runs with affinity off there. A real x86_64 machine needs nothing.
    x86_64-linux)  image=nex-linux-amd64; arch=x86_64
                   extra=(); [[ $(uname -m) == arm64 || $(uname -m) == aarch64 ]] && extra=(-e KMP_AFFINITY=disabled) ;;
    *) print -u2 "linux-check.zsh: the target is aarch64-linux or x86_64-linux"; exit 1 ;;
esac

version=$(grep -m1 '^ *version *=' $root/sysl.hocon | cut -d'"' -f2)
asset=nex-$version-linux-$arch.tar.gz
[[ -f $root/dist/$asset ]] || { print -u2 "linux-check.zsh: no $root/dist/$asset; build it with \`zsh scripts/package.zsh --target $1\`"; exit 1 }

docker run --rm $extra -v $root:/nex:ro $image bash -c "
    mkdir -p /opt/nex && tar -xzf /nex/dist/$asset -C /opt/nex
    bash /nex/scripts/linux/smoke.sh /opt/nex /nex /tmp/check ${2:-4}
"
