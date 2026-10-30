#!/usr/bin/env zsh
# Makes the Linux sysroot `scripts/package.zsh --target` links against: the system headers and
# libraries of the `nex-linux` image (`scripts/linux/Dockerfile`, Ubuntu 24.04 with glibc, libgcc,
# gfortran, OpenBLAS and Open MPI), copied out of a container into `out-dir`.
#
#     zsh scripts/linux-sysroot.zsh aarch64-linux|x86_64-linux [out-dir]
#
# `out-dir` defaults to `dist/sysroot-<target>`. It needs a running Docker (`colima start` on a Mac);
# an `x86_64-linux` one needs a Docker that runs amd64 images, which colima's aarch64 VM does under
# QEMU (`colima start --arch aarch64 --vm-type vz`), as does any x86_64 Linux machine natively.

set -eu
setopt pipe_fail

root=${0:A:h:h}
target=${1:-}

case $target in
    aarch64-linux) platform=linux/arm64; image=nex-linux ;;
    x86_64-linux)  platform=linux/amd64; image=nex-linux-amd64 ;;
    *) print -u2 "linux-sysroot.zsh: the target is aarch64-linux or x86_64-linux"; exit 1 ;;
esac

out=${2:-$root/dist/sysroot-$target}
out=${out:A}

# Ubuntu 24.04 for the target's architecture, named by its manifest's digest: the one name Docker's
# legacy builder cannot resolve to its own architecture instead.
digest=$(docker manifest inspect ubuntu:24.04 | jq -r ".manifests[] | select(.platform.architecture == \"${platform#linux/}\") | .digest")
[[ $digest == sha256:* ]] || { print -u2 "linux-sysroot.zsh: no ubuntu:24.04 for ${platform#linux/}"; exit 1 }
docker build --build-arg BASE=ubuntu@$digest -t $image $root/scripts/linux
[[ -n $(docker run --rm $image uname -m | grep -x ${target%%-*}) ]] || { print -u2 "linux-sysroot.zsh: the image $image is not ${target%%-*}"; exit 1 }
if [[ -e $out ]]; then chmod -R u+rwX $out; rm -rf $out; fi
mkdir -p $out
docker run --rm -i $image sh -s < $root/scripts/linux/export-sysroot.sh | tar -C $out -xf -

print "wrote the $target sysroot at $out ($(du -sh $out | cut -f1))"
