// DESIGN.md §5.4: does a negative stride survive `tensor.extract_slice`, one-shot bufferization's
// `memref.subview` and `expand-strided-metadata` with nothing copied? It does: the subview's layout
// is `strided<[?], offset: ?>` with the stride negative at run time, and the offset is the far end,
// so element i is at offset + i·stride as for any other view. Writing through one with
// `tensor.insert_slice` is in place too.
//
//   a = [10, 20, 30, 40, 50, 60, 70]
//   print each of a[5..2 by -1]        50 40 30 20   offset 4, stride -1, a dynamic stride
//   print each of a[.. by -2]          70 50 30 10   offset 6, stride -2, a static stride
//   print sum(a[.. by -1]) through a function taking tensor<?xi64>      280
//   m = [[1, 2, 3], [4, 5, 6]] (nex shape (2, 3)), m[:, end..1 by -1]: tensor<3x2> rows reversed
//   print each of its elements in storage order                        3 6 2 5 1 4
//   b = [1, 2, 3, 4]; b[.. by -1] = [7, 8, 9, 10]; print each of b     10 9 8 7
//
// Expected output: negative-stride.out.

module {
  func.func private @nex_print_int(i64)

  func.func @sum(%v: tensor<?xi64>) -> i64 {
    %c0 = arith.constant 0 : index
    %c1 = arith.constant 1 : index
    %n = tensor.dim %v, %c0 : tensor<?xi64>
    %z = arith.constant 0 : i64
    %r = scf.for %i = %c0 to %n step %c1 iter_args(%acc = %z) -> (i64) {
      %x = tensor.extract %v[%i] : tensor<?xi64>
      %s = arith.addi %acc, %x : i64
      scf.yield %s : i64
    }
    return %r : i64
  }

  func.func @print_all(%v: tensor<?xi64>) {
    %c0 = arith.constant 0 : index
    %c1 = arith.constant 1 : index
    %n = tensor.dim %v, %c0 : tensor<?xi64>
    scf.for %i = %c0 to %n step %c1 {
      %x = tensor.extract %v[%i] : tensor<?xi64>
      func.call @nex_print_int(%x) : (i64) -> ()
    }
    return
  }

  func.func @main() -> i32 {
    %c0 = arith.constant 0 : index
    %c1 = arith.constant 1 : index
    %c2 = arith.constant 2 : index
    %c3 = arith.constant 3 : index
    %c4 = arith.constant 4 : index
    %cm1 = arith.constant -1 : index
    %a0 = arith.constant dense<[10, 20, 30, 40, 50, 60, 70]> : tensor<7xi64>
    %ea = tensor.empty() : tensor<7xi64>
    %a = linalg.copy ins(%a0 : tensor<7xi64>) outs(%ea : tensor<7xi64>) -> tensor<7xi64>

    %v1 = tensor.extract_slice %a[%c4] [%c4] [%cm1] : tensor<7xi64> to tensor<?xi64>
    func.call @print_all(%v1) : (tensor<?xi64>) -> ()

    %v2 = tensor.extract_slice %a[6] [4] [-2] : tensor<7xi64> to tensor<4xi64>
    %v2d = tensor.cast %v2 : tensor<4xi64> to tensor<?xi64>
    func.call @print_all(%v2d) : (tensor<?xi64>) -> ()

    %v3 = tensor.extract_slice %a[6] [7] [-1] : tensor<7xi64> to tensor<7xi64>
    %v3d = tensor.cast %v3 : tensor<7xi64> to tensor<?xi64>
    %s3 = func.call @sum(%v3d) : (tensor<?xi64>) -> i64
    func.call @nex_print_int(%s3) : (i64) -> ()

    // m: nex shape (2, 3), tensor<3x2>; m[:, end..1 by -1] reverses tensor axis 0.
    %m0 = arith.constant dense<[[1, 4], [2, 5], [3, 6]]> : tensor<3x2xi64>
    %em = tensor.empty() : tensor<3x2xi64>
    %m = linalg.copy ins(%m0 : tensor<3x2xi64>) outs(%em : tensor<3x2xi64>) -> tensor<3x2xi64>
    %r = tensor.extract_slice %m[%c2, 0] [3, 2] [%cm1, 1] : tensor<3x2xi64> to tensor<3x2xi64>
    scf.for %j = %c0 to %c3 step %c1 {
      scf.for %i = %c0 to %c2 step %c1 {
        %x = tensor.extract %r[%j, %i] : tensor<3x2xi64>
        func.call @nex_print_int(%x) : (i64) -> ()
      }
    }

    // b[.. by -1] = [7, 8, 9, 10], written in place.
    %b0 = arith.constant dense<[1, 2, 3, 4]> : tensor<4xi64>
    %eb = tensor.empty() : tensor<4xi64>
    %b = linalg.copy ins(%b0 : tensor<4xi64>) outs(%eb : tensor<4xi64>) -> tensor<4xi64>
    %w = arith.constant dense<[7, 8, 9, 10]> : tensor<4xi64>
    %b2 = tensor.insert_slice %w into %b[%c3] [4] [%cm1] : tensor<4xi64> into tensor<4xi64>
    %b2d = tensor.cast %b2 : tensor<4xi64> to tensor<?xi64>
    func.call @print_all(%b2d) : (tensor<?xi64>) -> ()

    %z = arith.constant 0 : i32
    return %z : i32
  }
}
