// DESIGN.md §9 (parallel): the three parallel shapes nex emits, at the tensor level, through the
// pipeline.
//
//   - a parallel map is a linalg.generic with "parallel" iterators (`iota`);
//   - a `parallel for` whose iterations each write their own element is an scf.forall with
//     shared_outs, one tensor.parallel_insert_slice per written array (`axpy`);
//   - a parallel reduction with a declared operator is an scf.parallel with an scf.reduce region
//     over the read-only buffer of its operand (`sum`).
//
// Expected output: 1000000.0 (sum of 2i + 1 for i in 0..1000), then the highest OpenMP thread id
// that ran an iteration of `axpy`: 0 through the sequential pipeline, > 0 through the OpenMP one
// (run with OMP_NUM_THREADS=4 it prints 3).
//
// Pipelines: PLAN.md § "The pipeline, revised" -- the sequential one, and the OpenMP one, which
// adds scf-forall-to-parallel, convert-linalg-to-parallel-loops, convert-scf-to-openmp and
// convert-openmp-to-llvm. Both link libomp (for omp_get_thread_num); the OpenMP build needs it.
// No array is copied: shared_outs write the caller's buffers in place, and because `axpy` is
// private, drop-equivalent-buffer-results turns the two results that are its own arguments into
// nothing -- `axpy` returns no value and the caller's buffers are the answer, which is the `inout`
// calling convention (DESIGN.md §7). A public function keeps its results, and
// buffer-deallocation-pipeline then clones each one: a whole-array copy per call.

module {
  func.func private @nex_print_real(f64)
  func.func private @nex_print_int(i64)
  func.func private @omp_get_thread_num() -> i32

  func.func @iota(%n: index) -> tensor<?xf64> {
    %e = tensor.empty(%n) : tensor<?xf64>
    %r = linalg.generic {indexing_maps = [affine_map<(d0) -> (d0)>], iterator_types = ["parallel"]}
        outs(%e : tensor<?xf64>) {
    ^bb0(%o: f64):
      %i = linalg.index 0 : index
      %ii = arith.index_cast %i : index to i64
      %f = arith.sitofp %ii : i64 to f64
      linalg.yield %f : f64
    } -> tensor<?xf64>
    return %r : tensor<?xf64>
  }

  func.func private @axpy(%a: f64, %x: tensor<?xf64>, %y: tensor<?xf64>, %tid: tensor<?xi64>)
      -> (tensor<?xf64>, tensor<?xi64>) {
    %c0 = arith.constant 0 : index
    %n = tensor.dim %x, %c0 : tensor<?xf64>
    %r:2 = scf.forall (%i) in (%n) shared_outs(%yo = %y, %to = %tid) -> (tensor<?xf64>, tensor<?xi64>) {
      %xi = tensor.extract %x[%i] : tensor<?xf64>
      %yi = tensor.extract %yo[%i] : tensor<?xf64>
      %m = arith.mulf %a, %xi : f64
      %s = arith.addf %m, %yi : f64
      %t32 = func.call @omp_get_thread_num() : () -> i32
      %t = arith.extsi %t32 : i32 to i64
      // An element write is a fill of the one-element slice it writes: it bufferizes to a store
      // into a subview of the shared buffer. (tensor.from_elements here would bufferize to an
      // allocation plus a memref.copy -- a memrefCopy call -- per iteration.)
      %ys = tensor.extract_slice %yo[%i] [1] [1] : tensor<?xf64> to tensor<1xf64>
      %st = linalg.fill ins(%s : f64) outs(%ys : tensor<1xf64>) -> tensor<1xf64>
      %ts = tensor.extract_slice %to[%i] [1] [1] : tensor<?xi64> to tensor<1xi64>
      %tt = linalg.fill ins(%t : i64) outs(%ts : tensor<1xi64>) -> tensor<1xi64>
      scf.forall.in_parallel {
        tensor.parallel_insert_slice %st into %yo[%i] [1] [1] : tensor<1xf64> into tensor<?xf64>
        tensor.parallel_insert_slice %tt into %to[%i] [1] [1] : tensor<1xi64> into tensor<?xi64>
      }
    }
    return %r#0, %r#1 : tensor<?xf64>, tensor<?xi64>
  }

  func.func @sum(%x: tensor<?xf64>) -> f64 {
    %c0 = arith.constant 0 : index
    %c1 = arith.constant 1 : index
    %n = tensor.dim %x, %c0 : tensor<?xf64>
    %m = bufferization.to_buffer %x read_only : tensor<?xf64> to memref<?xf64, strided<[?], offset: ?>>
    %zero = arith.constant 0.0 : f64
    %s = scf.parallel (%i) = (%c0) to (%n) step (%c1) init (%zero) -> f64 {
      %v = memref.load %m[%i] : memref<?xf64, strided<[?], offset: ?>>
      scf.reduce(%v : f64) {
      ^bb0(%l: f64, %rr: f64):
        %t = arith.addf %l, %rr : f64
        scf.reduce.return %t : f64
      }
    }
    return %s : f64
  }

  func.func @max_i64(%t: tensor<?xi64>) -> i64 {
    %c0 = arith.constant 0 : index
    %c1 = arith.constant 1 : index
    %n = tensor.dim %t, %c0 : tensor<?xi64>
    %z = arith.constant 0 : i64
    %r = scf.for %i = %c0 to %n step %c1 iter_args(%acc = %z) -> (i64) {
      %v = tensor.extract %t[%i] : tensor<?xi64>
      %m = arith.maxsi %acc, %v : i64
      scf.yield %m : i64
    }
    return %r : i64
  }

  func.func @main() -> i32 {
    %n = arith.constant 1000 : index
    %a = arith.constant 2.0 : f64
    %one = arith.constant 1.0 : f64
    %zi = arith.constant 0 : i64
    %x = func.call @iota(%n) : (index) -> tensor<?xf64>
    %ye = tensor.empty(%n) : tensor<?xf64>
    %y = linalg.fill ins(%one : f64) outs(%ye : tensor<?xf64>) -> tensor<?xf64>
    %te = tensor.empty(%n) : tensor<?xi64>
    %t = linalg.fill ins(%zi : i64) outs(%te : tensor<?xi64>) -> tensor<?xi64>
    %r:2 = func.call @axpy(%a, %x, %y, %t)
        : (f64, tensor<?xf64>, tensor<?xf64>, tensor<?xi64>) -> (tensor<?xf64>, tensor<?xi64>)
    %s = func.call @sum(%r#0) : (tensor<?xf64>) -> f64
    func.call @nex_print_real(%s) : (f64) -> ()
    %mx = func.call @max_i64(%r#1) : (tensor<?xi64>) -> i64
    func.call @nex_print_int(%mx) : (i64) -> ()
    %c = arith.constant 0 : i32
    return %c : i32
  }
}
