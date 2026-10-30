#!/usr/bin/env zsh
# Builds nex's release tarball locally and proves it: `nex-<version>-<os>-<arch>.tar.gz`, which
# unpacks to a prefix holding `bin/nex`, `bin/libnex_rt.a`, `share/nex/include/nex_desc.h` and
# `share/nex/{LICENSE,README.md}`.
#
#     zsh scripts/package.zsh [--target aarch64-linux|x86_64-linux] [--sysroot <dir>] [out-dir]
#
# `out-dir` defaults to `dist/`. The script tags nothing, uploads nothing and touches no remote:
# it prints the tarball's SHA-256 and stops.
#
# **With no `--target` it builds for this Mac** (`nex-<version>-darwin-arm64.tar.gz`). **With
# `--target` it cross-builds for Linux from the Mac** (`nex-<version>-linux-aarch64.tar.gz`,
# `…-linux-x86_64.tar.gz`): sysl compiles for the target and Homebrew's clang links with `ld.lld`
# against a Linux sysroot — glibc, libgcc, OpenBLAS, the headers — which `--sysroot` names and
# which defaults to `dist/sysroot-<target>`, the one `scripts/linux-sysroot.zsh <target>` copies out
# of the `nex-linux` Docker image (Ubuntu 24.04).
#
# What it checks, with the unpacked copy and no environment but `NEX_LLVM_HOME`:
#   1. `nex --version` answers `nex <version>`, the version in `sysl.hocon`.
#   2. `nex run --interp` runs a program with no toolchain.
#   3. `nex run` compiles and runs one through MLIR and clang, where an LLVM with `mlir-opt` is found.
# On this Mac directly; for a Linux target inside the `nex-linux` image (`nex-linux-amd64` for
# x86_64), where a Docker answers and has the image, and otherwise not at all, which it says.

set -eu

root=${0:A:h:h}
target=""
sysroot=""
out=""

while (( $# ))
do
    case $1 in
        --target) target=$2; shift 2 ;;
        --sysroot) sysroot=${2:A}; shift 2 ;;
        -*) print -u2 "package.zsh: unknown option $1"; exit 1 ;;
        *) out=$1; shift ;;
    esac
done

out=${${out:-$root/dist}:A}

version=$(grep -m1 '^ *version *=' $root/sysl.hocon | cut -d'"' -f2)
[[ -n $version ]] || { print -u2 "package.zsh: no version in sysl.hocon"; exit 1 }

case $target in
    "")
        [[ $(uname -s) == Darwin && $(uname -m) == arm64 ]] || { print -u2 "package.zsh: with no --target, only macOS arm64 is built"; exit 1 }
        asset=nex-$version-darwin-arm64.tar.gz ;;
    aarch64-linux) asset=nex-$version-linux-aarch64.tar.gz; image=nex-linux ;;
    x86_64-linux)  asset=nex-$version-linux-x86_64.tar.gz;  image=nex-linux-amd64 ;;
    *) print -u2 "package.zsh: the target is aarch64-linux or x86_64-linux"; exit 1 ;;
esac

# Under `out` rather than the system's temporary directory, which a Docker VM on a Mac does not see.
mkdir -p $out
work=$(mktemp -d $out/.package.XXXXXX)
trap 'rm -rf $work' EXIT

stage=$work/stage
mkdir -p $stage/bin $stage/share/nex/include

cd $root

if [[ -z $target ]]
then
    sysl build compiler -o $stage/bin/nex
    sysl build-c runtime -o $stage/bin/libnex_rt.a
else
    sysroot=${sysroot:-$root/dist/sysroot-$target}
    [[ -f $sysroot/MULTIARCH ]] || { print -u2 "package.zsh: no Linux sysroot at $sysroot; make one with \`zsh scripts/linux-sysroot.zsh $target\`"; exit 1 }

    multi=$(<$sysroot/MULTIARCH)
    clang=${NEX_LLVM_HOME:-/opt/homebrew/opt/llvm}/bin/clang
    lld=${LLD:-$(whence -p ld.lld || true)}
    [[ -x $lld ]] || { print -u2 "package.zsh: a cross link needs ld.lld (Homebrew's lld) on PATH, or LLD naming it"; exit 1 }

    # The sysroot reaches every clang sysl drives through SYSL_EXTRA_CFLAGS, except the one that
    # measures a `c const` block, which is told where the headers are by `--include-path`.
    cross=(--target $target --cc $clang --include-path $sysroot/usr/include/$multi --include-path $sysroot/usr/include)
    export SYSL_EXTRA_CFLAGS="--sysroot=$sysroot --ld-path=$lld"

    sysl build compiler $cross -o $stage/bin/nex
    sysl build-c runtime $cross -o $stage/bin/libnex_rt.a
fi

rm -f $stage/bin/libnex_rt.a.h
cp include/nex_desc.h $stage/share/nex/include/
cp LICENSE README.md $stage/share/nex/

COPYFILE_DISABLE=1 tar -czf $out/$asset -C $stage .
(cd $out && shasum -a 256 $asset > $asset.sha256)

cat > $work/hello.nex <<'NEX'
def main() =
  print("Hello, nex!")
  print(6 * 7)
NEX

if [[ -n $target ]]
then
    if docker image inspect $image > /dev/null 2>&1
    then
        # The image's own NEX_LLVM_HOME (/usr/lib/llvm-23) is the LLVM the compiled hello uses.
        docker run --rm -v $out:/dist:ro -v $work:/work $image sh -c "
            set -e
            mkdir -p /opt/nex && tar -xzf /dist/$asset -C /opt/nex
            test \"\$(/opt/nex/bin/nex --version)\" = 'nex $version'
            test \"\$(/opt/nex/bin/nex run --interp /work/hello.nex)\" = \"\$(printf 'Hello, nex!\n42')\"
            test \"\$(/opt/nex/bin/nex run /work/hello.nex)\" = \"\$(printf 'Hello, nex!\n42')\"
        " || { print -u2 "package.zsh: the unpacked $target nex failed its checks in $image"; exit 1 }
        print "version, interpreted and compiled hello in $image: ok"
    else
        print "no Docker image $image (\`zsh scripts/linux-sysroot.zsh $target\` builds it): the $target tarball was not run"
    fi

    print "wrote $out/$asset"
    cat $out/$asset.sha256
    exit 0
fi

prefix=$work/prefix
mkdir -p $prefix
tar -xzf $out/$asset -C $prefix

said=$($prefix/bin/nex --version)
[[ $said == "nex $version" ]] || { print -u2 "package.zsh: unpacked nex says '$said', not 'nex $version'"; exit 1 }

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
