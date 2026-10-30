#!/usr/bin/env zsh
# Builds nex's release tarball locally and proves it: `nex-<version>-darwin-arm64.tar.gz`, which
# unpacks to a prefix holding `bin/nex`, `bin/libnex_rt.a` and `share/nex/include/nex_desc.h`.
#
#     zsh scripts/package.zsh [out-dir]
#
# `out-dir` defaults to `dist/`. The script tags nothing, uploads nothing and touches no remote:
# it prints the tarball's SHA-256 for the Homebrew formula and stops.
#
# What it checks, with the unpacked copy and no environment but `NEX_LLVM_HOME` (the Homebrew LLVM
# that `nex` drives is not part of the tarball):
#   1. `nex --version` answers `nex <version>`, the version in `sysl.hocon`.
#   2. `nex run --interp` runs a program with no toolchain.
#   3. `nex run` compiles and runs one through MLIR and clang, where an LLVM with `mlir-opt` is found.

set -eu

root=${0:A:h:h}
out=${1:-$root/dist}
arch=$(uname -m)

[[ $(uname -s) == Darwin && $arch == arm64 ]] || { print -u2 "package.zsh: only macOS arm64 is built"; exit 1 }

version=$(grep -m1 '^ *version *=' $root/sysl.hocon | cut -d'"' -f2)
[[ -n $version ]] || { print -u2 "package.zsh: no version in sysl.hocon"; exit 1 }

asset=nex-$version-darwin-arm64.tar.gz
work=$(mktemp -d)
trap 'rm -rf $work' EXIT

stage=$work/stage
mkdir -p $stage/bin $stage/share/nex/include $out

cd $root
sysl build compiler -o $stage/bin/nex
sysl build-c runtime -o $stage/bin/libnex_rt.a
rm -f $stage/bin/libnex_rt.a.h
cp include/nex_desc.h $stage/share/nex/include/
cp LICENSE README.md $stage/share/nex/

COPYFILE_DISABLE=1 tar -czf $out/$asset -C $stage .
(cd $out && shasum -a 256 $asset > $asset.sha256)

prefix=$work/prefix
mkdir -p $prefix
tar -xzf $out/$asset -C $prefix

said=$($prefix/bin/nex --version)
[[ $said == "nex $version" ]] || { print -u2 "package.zsh: unpacked nex says '$said', not 'nex $version'"; exit 1 }

cat > $work/hello.nex <<'NEX'
def main() =
  print("Hello, nex!")
  print(6 * 7)
NEX

[[ $($prefix/bin/nex run --interp $work/hello.nex) == $'Hello, nex!\n42' ]] || { print -u2 "package.zsh: the interpreter's hello is wrong"; exit 1 }

llvm=${NEX_LLVM_HOME:-/opt/homebrew/opt/llvm}

if [[ -x $llvm/bin/mlir-opt ]]
then
    ran=$(NEX_RUNTIME=$prefix/bin/libnex_rt.a NEX_LLVM_HOME=$llvm $prefix/bin/nex run $work/hello.nex)
    [[ $ran == $'Hello, nex!\n42' ]] || { print -u2 "package.zsh: the compiled hello is wrong"; exit 1 }
    print "compiled hello: ok"
else
    print "no mlir-opt in $llvm/bin: the compiled hello was not run"
fi

print "wrote $out/$asset"
cat $out/$asset.sha256
