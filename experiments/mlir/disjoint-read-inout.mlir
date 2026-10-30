// DESIGN §8.3 rule 2 accepts a read-mode window beside an `inout` window of the same array when the
// two are provably disjoint: `axpy(2, y[1..4], y[5..8])`, `x` read and `y` written. §6.3 promises
// that passing a slice copies nothing. One-shot bufferization does not keep that promise here: it
// copies the read window `%x` into a fresh buffer before the call, though its offsets and sizes are
// constants that cannot overlap the written window's.
//
// The call is the cause, not the slices: one-shot's conflict analysis sees a call that reads one
// alias of `%a` and writes another in place, and it does not ask whether the two subviews overlap
// (the disjoint-subset reasoning it has serves only a matching extract_slice / insert_slice pair).
// The copy is correct, and costs one window's allocation and copy per call. Without it the emitter
// would have to pass the two windows as memrefs, around bufferization.
//
// Run: mlir-opt with pipeline.txt's passes up to `drop-equivalent-buffer-results` and the
// canonicalize, cse, canonicalize after it; `@main` shows one `memref.alloc` of `memref<4xi64>` and
// one `memref.copy` into it. The program prints 1 1 1 1 3 3 3 3 either way.

module {
  func.func private @nex_print_int(i64)

  func.func private @axpy(%alpha: i64, %x: tensor<?xi64>, %y: tensor<?xi64>) -> tensor<?xi64> {
    %c0 = arith.constant 0 : index
    %c1 = arith.constant 1 : index
    %n = tensor.dim %y, %c0 : tensor<?xi64>
    %r = scf.for %i = %c0 to %n step %c1 iter_args(%t = %y) -> (tensor<?xi64>) {
      %xi = tensor.extract %x[%i] : tensor<?xi64>
      %yi = tensor.extract %t[%i] : tensor<?xi64>
      %p = arith.muli %alpha, %xi : i64
      %s = arith.addi %yi, %p : i64
      %w = tensor.insert %s into %t[%i] : tensor<?xi64>
      scf.yield %w : tensor<?xi64>
    }
    return %r : tensor<?xi64>
  }

  func.func @main() -> i32 {
    %c0 = arith.constant 0 : index
    %c1 = arith.constant 1 : index
    %c8 = arith.constant 8 : index
    %two = arith.constant 2 : i64
    %ones = arith.constant dense<1> : tensor<8xi64>
    %a = bufferization.alloc_tensor() copy(%ones) : tensor<8xi64>
    %x = tensor.extract_slice %a[0] [4] [1] : tensor<8xi64> to tensor<4xi64>
    %y = tensor.extract_slice %a[4] [4] [1] : tensor<8xi64> to tensor<4xi64>
    %xd = tensor.cast %x : tensor<4xi64> to tensor<?xi64>
    %yd = tensor.cast %y : tensor<4xi64> to tensor<?xi64>
    %r = func.call @axpy(%two, %xd, %yd) : (i64, tensor<?xi64>, tensor<?xi64>) -> tensor<?xi64>
    %rs = tensor.cast %r : tensor<?xi64> to tensor<4xi64>
    %b = tensor.insert_slice %rs into %a[4] [4] [1] : tensor<4xi64> into tensor<8xi64>
    scf.for %i = %c0 to %c8 step %c1 {
      %e = tensor.extract %b[%i] : tensor<8xi64>
      func.call @nex_print_int(%e) : (i64) -> ()
    }
    %z = arith.constant 0 : i32
    return %z : i32
  }
}
