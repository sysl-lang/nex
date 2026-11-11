#!/bin/zsh
# The perf oracle (PLAN.md "The perf oracle"): builds the `nex` CLI and its runtime from this
# checkout, compiles every kernel with `nex`, its twin with `gfortran -O2` (`-fopenmp` for the
# parallel ones) and, where the Scala reference is built, with the reference's AOT backend; runs
# each best of five and prints one table row per kernel.
#
#     zsh bench/run.zsh                  every kernel
#     zsh bench/run.zsh axpy gemm        only these
#     zsh bench/run.zsh --ir point-distance
#                                        print the kernel's LLVM IR as `clang -O2` optimizes it
#     zsh bench/run.zsh --scale          every parallel kernel at each thread count
#     zsh bench/run.zsh --scale parallel-dot
#
# Every Fortran twin is built three ways: `gfortran -O2` (the twin the exit bar is measured
# against), `gfortran -O3 -mcpu=native`, and LLVM `flang -O3 -mcpu=native`, which lowers through
# MLIR and LLVM as nex does. A missing flang leaves its column out.
#
# Columns: the time per pass each program prints for itself (best of five), the ratio nex / gfortran
# -O2 and the verdict against the exit bar (1.25x; BLAS gemm 1.1x against `cblas_dgemm` from C), the
# ratio nex / the fastest Fortran, whether every checksum agrees, the large allocations (>= 1 MiB,
# counted by `alloc-count.dylib` interposed on the binary) of nex and of the twin, the Scala
# reference's whole-process time against nex's whole-process time (the reference has no `extern`, so
# it cannot time itself), and the load average when the row ran. The parallel kernels run with
# OMP_NUM_THREADS = the performance-core count.
#
# --scale prints one row per kernel and thread count: OMP_NUM_THREADS at 1, 2, 4, the performance-
# core count, 8, 12 and every core, then unset (the OpenMP runtime's own choice). The speedups are
# nex's and the fastest Fortran's over the same program at one thread.
#
# Environment: NEX_REF (default ~/dev/nex) is the Scala reference, used when its JVM classes are
# built; NEX_FLANG (default: `flang` on PATH, else Homebrew's) is flang; BENCH_WORK keeps the
# binaries in a directory of your choosing rather than a temporary one.

emulate -L zsh
setopt err_return pipe_fail

bench=${0:A:h}
root=${bench:h}
work=${BENCH_WORK:-$(mktemp -d -t nex-bench)}
ref=${NEX_REF:-$HOME/dev/nex}
llvm=${NEX_LLVM_HOME:-/opt/homebrew/opt/llvm}
flang=${NEX_FLANG:-${commands[flang]:-/opt/homebrew/opt/flang/bin/flang}}
[[ -x $flang ]] || flang=""
pcores=$(sysctl -n hw.perflevel0.physicalcpu)
cores=$(sysctl -n hw.physicalcpu)
runs=5
mkdir -p $work

kernels=(axpy dot nrm2 gemv gemm stencil complex-axpy point-distance axpy-real32 blas-gemm
         parallel-axpy parallel-dot parallel-mandel)

log() { print -u2 -- "$*" }

build_nex() {
    log "building nex and its runtime into $work"
    (cd $root && sysl build compiler -o $work/nex > $work/build.log 2>&1)
    (cd $root && sysl build-c runtime -o $work/libnex_rt.a >> $work/build.log 2>&1)
    clang -O2 -dynamiclib $bench/alloc-count.c -o $work/alloc-count.dylib
}

# The Scala reference's AOT compiler, run straight from its built classes: a java command line, or
# nothing where the reference is not built.
ref_java=()

find_ref() {
    local classes=$ref/jvm/target/scala-3.8.3/classes
    local export=$ref/jvm/target/streams/compile/dependencyClasspath/_global/streams/export
    [[ -d $classes && -f $export ]] || return 0
    local cp=$classes
    local jar
    for jar in ${(s.:.)$(tail -1 $export)}; do
        # A jar the reference resolved from ~/.ivy2/local may only be in Coursier's cache here.
        if [[ ! -f $jar && $jar == */.ivy2/local/* ]]; then
            local name=${jar:t:r} ver=${${jar:h:h}:t}
            jar=$HOME/Library/Caches/Coursier/v1/https/repo1.maven.org/maven2/io/github/edadma/$name/$ver/$name-$ver.jar
        fi
        cp+=":$jar"
    done
    ref_java=(java -cp $cp io.github.edadma.nex.run compile --prelude-path $ref/prelude)
}

# Each kernel's binaries: `<k>-nex`; the twin `<k>-twin` (gfortran -O2, or C for BLAS gemm); for a
# Fortran twin `<k>-gf3` (gfortran -O3 -mcpu=native) and `<k>-flang`; `<k>-ref` where the reference
# has it.
build_kernel() {
    local k=$1
    local -a omp
    if [[ $k == parallel-* ]]; then omp=(-fopenmp); fi
    $work/nex build $bench/$k.nex -o $work/$k-nex > $work/$k.build.log 2>&1
    rm -f $work/$k-gf3 $work/$k-flang
    if [[ $k == blas-gemm ]]; then
        clang -O2 $bench/blas-gemm.c -framework Accelerate -o $work/$k-twin
    else
        gfortran -O2 $omp $bench/$k.f90 -o $work/$k-twin
        gfortran -O3 -mcpu=native $omp $bench/$k.f90 -o $work/$k-gf3
        # flang's Homebrew runtime was built for a newer macOS, which ld warns about.
        if [[ -n $flang ]]; then
            $flang -O3 -mcpu=native $omp $bench/$k.f90 -o $work/$k-flang >> $work/$k.build.log 2>&1
        fi
    fi
    if (( $#ref_java )) && [[ -f $bench/scala/$k.nex ]]; then
        # The reference compiles every .nex in the file's directory, so each kernel gets its own.
        mkdir -p $work/ref-$k
        cp $bench/scala/$k.nex $work/ref-$k/main.nex
        # A kernel the reference cannot compile is reported, and the row goes on without it.
        rm -f $work/$k-ref
        if (cd $work/ref-$k && $ref_java main.nex >> $work/$k.build.log 2>&1); then
            cp $work/ref-$k/main $work/$k-ref
        else
            log "$k: the Scala reference did not compile it; see $work/$k.build.log"
        fi
    fi
}

# Runs `$1` five times: sets `best_pass` (the least of its first output line, ns), `best_wall`
# (the least whole-process time, s) and `sums` (its output after the first line, from the last run).
best_pass=0 best_wall=0 sums=""

measure() {
    local exe=$1 self_timed=$2 r t0 t1 out wall pass
    best_pass=0 best_wall=0
    for r in {1..$runs}; do
        t0=$EPOCHREALTIME
        out=$($exe)
        t1=$EPOCHREALTIME
        wall=$(( t1 - t0 ))
        if (( r == 1 || wall < best_wall )); then best_wall=$wall; fi
        if [[ $self_timed == yes ]]; then
            # nex prints a large real in exponent form (`1.15E7`); arithmetic reads either form.
            pass=${${(f)out}[1]}
            pass=$(( int(${pass// /}) ))
            if (( r == 1 || pass < best_pass )); then best_pass=$pass; fi
            sums=${(F)${${(f)out}[2,-1]}}
        else
            sums=$out
        fi
    done
}

# Whether two checksum lists agree to a relative 1e-9 (the sums are taken in different orders).
agree() {
    local -a a b
    a=(${(f)1}) b=(${(f)2})
    (( $#a == $#b )) || { print no; return }
    local k x y
    for k in {1..$#a}; do
        x=$(( ${a[k]// /} )) y=$(( ${b[k]// /} ))
        if (( abs(x - y) > 1e-9 * (abs(x) + abs(y)) + 1e-300 )); then print no; return; fi
    done
    print yes
}

# Times kernel `$1`'s programs at the current OMP_NUM_THREADS: sets `t_twin`, `t_gf3`, `t_flang`
# and `t_nex` (ns per pass; 0 for a program not built), `t_best` (the fastest Fortran), `nex_wall`,
# `nex_sums`, `twin_sums`, and `sums_ok` (yes when every program's checksums agree with nex's).
t_twin=0 t_gf3=0 t_flang=0 t_nex=0 t_best=0 nex_wall=0 nex_sums="" twin_sums="" sums_ok=yes

measure_all() {
    local k=$1 v
    sums_ok=yes
    measure $work/$k-nex yes
    t_nex=$best_pass nex_wall=$best_wall nex_sums=$sums
    measure $work/$k-twin yes
    t_twin=$best_pass twin_sums=$sums
    [[ $(agree "$nex_sums" "$sums") == yes ]] || sums_ok=no
    t_best=$t_twin
    for v in gf3 flang; do
        if [[ -x $work/$k-$v ]]; then
            measure $work/$k-$v yes
            [[ $(agree "$nex_sums" "$sums") == yes ]] || sums_ok=no
            if (( best_pass < t_best )); then t_best=$best_pass; fi
        else
            best_pass=0
        fi
        typeset -g t_$v=$best_pass
    done
    # blas-gemm and its C twin print microseconds per product, not nanoseconds.
    if [[ $k == blas-gemm ]]; then (( t_twin *= 1000, t_nex *= 1000, t_best *= 1000 )); fi
}

# A time in ms, or `-` for a program not built.
ms() { if (( $1 )); then printf '%.2f' $(( $1 / 1e6 )); else print -- -; fi }

large_allocs() {
    local line
    line=$(DYLD_INSERT_LIBRARIES=$work/alloc-count.dylib $1 2>&1 >/dev/null | grep '^large allocations:')
    print ${line##*: }
}

ir() {
    local k=$1 pipeline
    $work/nex emit $bench/$k.nex > $work/$k.mlir
    pipeline=$(<$root/experiments/mlir/pipeline.txt)
    if grep -q omp.parallel $work/$k.mlir; then
        pipeline=${pipeline/convert-func-to-llvm/convert-openmp-to-llvm,convert-func-to-llvm}
    fi
    $llvm/bin/mlir-opt $work/$k.mlir --pass-pipeline=$pipeline -o $work/$k.lowered.mlir
    $llvm/bin/mlir-translate --mlir-to-llvmir $work/$k.lowered.mlir -o $work/$k.ll
    $llvm/bin/clang -Wno-override-module -O2 -S -emit-llvm $work/$k.ll -o -
}

zmodload zsh/mathfunc zsh/datetime

if [[ $1 == --ir ]]; then
    shift
    build_nex
    for k in $@; do ir $k; done
    return 0
fi

if [[ $1 == --scale ]]; then
    shift
    if (( $# )); then kernels=($@); else kernels=(${(M)kernels:#parallel-*}); fi
    build_nex
    log "machine: $(sysctl -n machdep.cpu.brand_string), $pcores performance of $cores cores"
    log "work: $work"
    printf '%-16s %7s %9s %9s %9s %9s %8s %7s %7s %-5s %6s\n' kernel threads gfO2_ms gfO3_ms \
        flang_ms nex_ms nex/best best_x nex_x sums load
    counts=(1 2 4 $pcores 8 12 $cores default)
    counts=(${(u)counts})
    for k in $kernels; do
        build_kernel $k
        best1=0 nex1=0
        for th in $counts; do
            if [[ $th == default ]]; then unset OMP_NUM_THREADS; else export OMP_NUM_THREADS=$th; fi
            load=$(sysctl -n vm.loadavg | awk '{print $2}')
            measure_all $k
            if (( nex1 == 0 )); then best1=$t_best nex1=$t_nex; fi
            printf '%-16s %7s %9s %9s %9s %9s %8.2f %7.2f %7.2f %-5s %6s\n' $k $th \
                $(ms $t_twin) $(ms $t_gf3) $(ms $t_flang) $(ms $t_nex) $(( 1.0 * t_nex / t_best )) \
                $(( 1.0 * best1 / t_best )) $(( 1.0 * nex1 / t_nex )) $sums_ok $load
        done
    done
    unset OMP_NUM_THREADS
    return 0
fi

(( $# )) && kernels=($@)
build_nex
find_ref

log "machine: $(sysctl -n machdep.cpu.brand_string), $pcores performance cores"
log "work: $work"

printf '%-15s %9s %9s %9s %9s %7s %-7s %8s %-5s %9s %8s %6s\n' kernel gfO2_ms gfO3_ms flang_ms \
    nex_ms ratio verdict nex/best sums alloc_n/t ref/nex load
for k in $kernels; do
    build_kernel $k
    load=$(sysctl -n vm.loadavg | awk '{print $2}')
    if [[ $k == parallel-* ]]; then export OMP_NUM_THREADS=$pcores; else unset OMP_NUM_THREADS; fi

    measure_all $k

    ratio=$(( 1.0 * t_nex / t_twin ))
    bar=1.25
    [[ $k == blas-gemm ]] && bar=1.1
    if (( ratio <= bar )); then verdict=meets; else verdict=MISSES; fi

    refcol=n/a
    if [[ -x $work/$k-ref ]]; then
        measure $work/$k-ref no
        refcol=$(printf '%.2f' $(( best_wall / nex_wall )))
        [[ $(agree "$sums" "$nex_sums") == yes ]] || refcol="$refcol!"
    fi

    allocs="$(large_allocs $work/$k-nex)/$(large_allocs $work/$k-twin)"

    printf '%-15s %9s %9s %9s %9s %7.2f %-7s %8.2f %-5s %9s %8s %6s\n' $k $(ms $t_twin) \
        $(ms $t_gf3) $(ms $t_flang) $(ms $t_nex) $ratio $verdict $(( 1.0 * t_nex / t_best )) \
        $sums_ok $allocs $refcol $load
done
