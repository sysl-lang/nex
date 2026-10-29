#!/usr/bin/env zsh
# Lowers each hand-written proof through the pipeline in pipeline.txt, links it with the runtime,
# runs it, and compares its output byte for byte with the corpus program's .out file.
#
# usage: zsh experiments/mlir/run.zsh            (from anywhere; LLVM from NEX_LLVM_HOME or Homebrew)

emulate -L zsh
setopt err_return no_unset

here=${0:A:h}
repo=${here:h:h}
llvm=${NEX_LLVM_HOME:-/opt/homebrew/opt/llvm}
pipeline=$(<$here/pipeline.txt)
work=$(mktemp -d)
failed=0

typeset -A oracle
oracle=(
  316-newton-sqrt         $repo/testdata/corpus/316-06-numerical-methods-newton-s-method-for-sqrt.out
  313-point-distance      $repo/testdata/corpus/313-02-arrays-element-wise-fusion-point-distance.out
  145-complex-elementwise $repo/testdata/corpus/145-elementwise-complex-via-componentwise-lowering.out
  real-spelling           $here/real-spelling.out
)

for proof in 316-newton-sqrt 313-point-distance 145-complex-elementwise real-spelling; do
  src=$here/$proof.mlir
  expected=${oracle[$proof]}
  $llvm/bin/mlir-opt $src --pass-pipeline=$pipeline -o $work/$proof.llvm.mlir
  $llvm/bin/mlir-translate --mlir-to-llvmir $work/$proof.llvm.mlir -o $work/$proof.ll
  $llvm/bin/clang -Wno-override-module -O2 $work/$proof.ll $here/runtime/nex_rt.c -o $work/$proof
  $work/$proof > $work/$proof.got
  if cmp -s $work/$proof.got $expected; then
    print "ok    $proof"
  else
    print "FAIL  $proof"
    diff $work/$proof.got $expected
    failed=1
  fi
done

rm -rf $work
return $failed
