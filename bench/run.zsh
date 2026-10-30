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
#
# Columns: the time per pass the kernel prints for itself (best of five), the ratio nex / twin and
# the verdict against the exit bar (1.25x; BLAS gemm 1.1x against `cblas_dgemm` from C), whether
# the checksums agree, the large allocations (>= 1 MiB, counted by `alloc-count.dylib` interposed on
# the binary) of nex and of the twin, the Scala reference's whole-process time against nex's whole-
# process time (the reference has no `extern`, so it cannot time itself), and the load average when
# the row ran. The parallel kernels run with OMP_NUM_THREADS = the performance-core count.
#
# Environment: NEX_REF (default ~/dev/nex) is the Scala reference, used when its JVM classes are
# built; BENCH_WORK keeps the binaries in a directory of your choosing rather than a temporary one.

emulate -L zsh
setopt err_return pipe_fail

bench=${0:A:h}
root=${bench:h}
work=${BENCH_WORK:-$(mktemp -d -t nex-bench)}
ref=${NEX_REF:-$HOME/dev/nex}
llvm=${NEX_LLVM_HOME:-/opt/homebrew/opt/llvm}
pcores=$(sysctl -n hw.perflevel0.physicalcpu)
runs=5
mkdir -p $work

kernels=(axpy dot nrm2 gemv gemm stencil complex-axpy point-distance axpy-real32 blas-gemm
         parallel-axpy parallel-dot)

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

# Each kernel's binaries: `<k>-nex`, the twin `<k>-twin`, and `<k>-ref` where the reference has it.
build_kernel() {
    local k=$1
    $work/nex build $bench/$k.nex -o $work/$k-nex > $work/$k.build.log 2>&1
    case $k in
        blas-gemm) clang -O2 $bench/blas-gemm.c -framework Accelerate -o $work/$k-twin ;;
        parallel-*) gfortran -O2 -fopenmp $bench/$k.f90 -o $work/$k-twin ;;
        *) gfortran -O2 $bench/$k.f90 -o $work/$k-twin ;;
    esac
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

(( $# )) && kernels=($@)
build_nex
find_ref

log "machine: $(sysctl -n machdep.cpu.brand_string), $pcores performance cores"
log "work: $work"

printf '%-15s %12s %12s %7s %-7s %-5s %9s %8s %6s\n' kernel twin_ms nex_ms ratio verdict sums alloc_n/t ref/nex load
for k in $kernels; do
    build_kernel $k
    load=$(sysctl -n vm.loadavg | awk '{print $2}')
    if [[ $k == parallel-* ]]; then export OMP_NUM_THREADS=$pcores; else unset OMP_NUM_THREADS; fi

    measure $work/$k-twin yes
    twin_pass=$best_pass twin_sums=$sums
    measure $work/$k-nex yes
    nex_pass=$best_pass nex_wall=$best_wall nex_sums=$sums
    # blas-gemm and its C twin print microseconds per product, not nanoseconds.
    if [[ $k == blas-gemm ]]; then (( twin_pass *= 1000, nex_pass *= 1000 )); fi

    ratio=$(( 1.0 * nex_pass / twin_pass ))
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

    printf '%-15s %12.2f %12.2f %7.2f %-7s %-5s %9s %8s %6s\n' $k $(( twin_pass / 1e6 )) \
        $(( nex_pass / 1e6 )) $ratio $verdict $(agree "$nex_sums" "$twin_sums") $allocs $refcol $load
done
