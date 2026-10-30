#!/bin/sh
# Run inside the nex-linux image by `scripts/linux-sysroot.zsh`: writes the system headers and
# libraries a cross link needs to standard output as a tar stream, which unpacks as a sysroot clang
# can use from macOS.
#
# The tree is assembled on the container's own disk and only then streamed out, because a bind
# mount from the Mac is case-insensitive and does not keep Linux's permissions faithfully.
#
# A Debian sysroot is full of ABSOLUTE symbolic links (`libm.so -> /lib/aarch64-linux-gnu/libm.so.6`,
# the `/etc/alternatives` chain behind `libopenblas.so`), which on the Mac would point into the Mac's
# own root. Each is replaced by a copy of the file it resolves to here, so the tree stands alone.
set -eu

dst=/tmp/sysroot
multi=$(gcc -print-multiarch)

mkdir -p "$dst/usr"

# Left out: what a link does not need and is most of the size (perl, the GCC back end's own
# executables, LLVM's shared library), and the kernel's netfilter headers, whose names differ only in
# case (`xt_CONNMARK.h`, `xt_connmark.h`) and so collide on the Mac's case-insensitive disk.
tar -C /usr -cf - \
    --exclude='include/linux/netfilter*' \
    --exclude="lib/$multi/perl*" --exclude="lib/$multi/dri" --exclude="lib/$multi/gconv" \
    --exclude="lib/$multi/libLLVM*" \
    --exclude='cc1*' --exclude='f951' --exclude='lto1' --exclude='lto-wrapper' \
    include "lib/$multi" "lib/gcc/$multi" | tar -C "$dst/usr" -xf -
ln -s usr/lib "$dst/lib"
ln -s usr/include "$dst/include"

# The dynamic loader, which `libc.so` names by its absolute path: `/lib/ld-linux-aarch64.so.1`, or
# `/lib64/ld-linux-x86-64.so.2`.
cp -a /usr/lib/ld-linux* "$dst/usr/lib/" 2>/dev/null || true
if [ -d /usr/lib64 ]
then
    cp -a /usr/lib64 "$dst/usr/"
    ln -s usr/lib64 "$dst/lib64"
fi

find "$dst" -type l | while read -r link
do
    case $(readlink "$link") in
        /*)
            real=$(readlink -f "${link#"$dst"}" || true)
            rm -f "$link"
            if [ -n "$real" ] && [ -e "$real" ]
            then
                cp -a -L "$real" "$link"
            fi
            ;;
    esac
done

echo "$multi" > "$dst/MULTIARCH"
tar -C "$dst" -cf - .
