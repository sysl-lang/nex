#!/bin/bash
# nex's Linux check, run inside the nex-linux image against an unpacked release tarball and a
# checkout of this repository (`scripts/linux-check.zsh` mounts both):
#
#     bash smoke.sh <prefix> <repo> <work> [np]
#
# It runs, compiled and interpreted, every `testdata/corpus` and `testdata/v2` program and compares
# each with its `.out`; the perf oracle's kernels compiled, each checksum against its gfortran twin's
# (a `parallel` kernel under OpenMP, `blas-gemm` against OpenBLAS); and the `testdata/mpi` programs
# under `mpirun -np <np>`. One line per failure, then a summary; exits non-zero if anything failed.
set -u

prefix=$1 repo=$2 work=$3 np=${4:-4}
nex=$prefix/bin/nex
fails=0 passes=0
mkdir -p "$work"
export OMPI_ALLOW_RUN_AS_ROOT=1 OMPI_ALLOW_RUN_AS_ROOT_CONFIRM=1

fail() { echo "FAIL $*"; fails=$((fails + 1)); }
pass() { passes=$((passes + 1)); }

# The C and Fortran libraries the FFI programs of testdata/v2 `@link`.
ffi=$work/ffi
mkdir -p "$ffi"
clang-23 -O2 -shared -fPIC "$repo/testdata/ffi/nexffi.c" -I "$prefix/share/nex/include" -o "$ffi/libnexffi.so"
gfortran -O2 -shared -fPIC "$repo/testdata/ffi/nexfort.f90" -J "$ffi" -o "$ffi/libnexfort.so"

# The perf oracle's kernels time themselves through macOS's `clock_gettime_nsec_np`; this is it.
cat > "$work/clock.c" <<'C'
#include <stdint.h>
#include <time.h>
uint64_t clock_gettime_nsec_np(int clock) {
    struct timespec t;
    clock_gettime(clock == 4 ? CLOCK_MONOTONIC_RAW : CLOCK_MONOTONIC, &t);
    return (uint64_t)t.tv_sec * 1000000000u + (uint64_t)t.tv_nsec;
}
C
clang-23 -O2 -c "$work/clock.c" -o "$work/clock.o"
ar rcs "$ffi/libbenchclock.a" "$work/clock.o"

# -- the corpus, on both engines ------------------------------------------------------------------
for dir in corpus v2
do
    for src in "$repo/testdata/$dir"/*.nex
    do
        name=$(basename "$src" .nex)
        expected="$repo/testdata/$dir/$name.out"
        [ -f "$expected" ] || continue

        if (cd "$repo/testdata/$dir" && timeout 120 "$nex" run -L "$ffi" "$src" > "$work/out" 2> "$work/err")
        then
            if cmp -s "$work/out" "$expected"; then pass; else fail "$dir/$name (compiled): output differs: $(diff "$work/out" "$expected" | head -3 | tr '\n' ' ')"; fi
        else
            fail "$dir/$name (compiled): $(head -c 400 "$work/err" | tr '\n' ' ')"
        fi

        grep -q -E '^ *(@link|@fortran|extern )' "$src" && continue

        if (cd "$repo/testdata/$dir" && timeout 120 "$nex" run --interp "$src" > "$work/out" 2> "$work/err")
        then
            if cmp -s "$work/out" "$expected"; then pass; else fail "$dir/$name (interpreted): output differs: $(diff "$work/out" "$expected" | head -3 | tr '\n' ' ')"; fi
        else
            fail "$dir/$name (interpreted): $(head -c 400 "$work/err" | tr '\n' ' ')"
        fi
    done
done

# -- the perf oracle's kernels: checksums against the twins ---------------------------------------
agree() {
    awk 'NR == FNR { a[FNR] = $0; n = FNR; next }
         { m = FNR; x = a[FNR] + 0; y = $0 + 0; d = x - y; if (d < 0) d = -d
           s = (x < 0 ? -x : x) + (y < 0 ? -y : y); if (d > 1e-9 * s + 1e-300) bad = 1 }
         END { exit (bad || n != m) }' "$1" "$2"
}

for k in axpy dot nrm2 gemv gemm stencil complex-axpy point-distance axpy-real32 blas-gemm parallel-axpy parallel-dot
do
    if ! "$nex" build "$repo/bench/$k.nex" -o "$work/$k" -L "$ffi" -l benchclock 2> "$work/err"
    then
        fail "bench/$k (nex build): $(head -c 400 "$work/err" | tr '\n' ' ')"; continue
    fi

    case $k in
        blas-gemm) twin_ok=0; echo 'unsigned long long clock_gettime_nsec_np(int);' > "$work/clock.h"
                   clang-23 -O2 -D_GNU_SOURCE -include "$work/clock.h" "$repo/bench/blas-gemm.c" "$work/clock.o" $(pkg-config --cflags --libs openblas) -o "$work/$k-twin" 2> "$work/err" || twin_ok=1 ;;
        parallel-*) twin_ok=0; gfortran -O2 -fopenmp "$repo/bench/$k.f90" -o "$work/$k-twin" 2> "$work/err" || twin_ok=1 ;;
        *) twin_ok=0; gfortran -O2 "$repo/bench/$k.f90" -o "$work/$k-twin" 2> "$work/err" || twin_ok=1 ;;
    esac
    [ $twin_ok = 0 ] || { fail "bench/$k (twin build): $(head -c 400 "$work/err" | tr '\n' ' ')"; continue; }

    "$work/$k" > "$work/$k.nex.out" 2> "$work/err" || { fail "bench/$k (nex run): $(head -c 400 "$work/err" | tr '\n' ' ')"; continue; }
    "$work/$k-twin" > "$work/$k.twin.out" 2>&1 || { fail "bench/$k (twin run)"; continue; }
    tail -n +2 "$work/$k.nex.out" > "$work/a"
    tail -n +2 "$work/$k.twin.out" > "$work/b"
    if agree "$work/a" "$work/b"
    then
        pass; echo "ok   bench/$k: $(head -1 "$work/$k.nex.out") vs twin $(head -1 "$work/$k.twin.out") per pass; checksums agree"
    else
        fail "bench/$k: checksums differ: nex $(tr '\n' ' ' < "$work/a") twin $(tr '\n' ' ' < "$work/b")"
    fi
done

# -- MPI ------------------------------------------------------------------------------------------
for src in "$repo/testdata/mpi"/*.nex
do
    name=$(basename "$src" .nex)
    if (cd "$repo/testdata/mpi" && timeout 300 "$nex" run --np "$np" "$src" > "$work/out" 2> "$work/err")
    then
        pass; echo "ok   mpi/$name -np $np: $(head -2 "$work/out" | tr '\n' ' ')"
    else
        fail "mpi/$name (-np $np): $(head -c 600 "$work/err" | tr '\n' ' ')"
    fi
done

echo "SUMMARY: $passes passed, $fails failed"
[ $fails = 0 ]
