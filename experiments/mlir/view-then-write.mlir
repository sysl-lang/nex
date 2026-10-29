// DESIGN.md §5.3: a view whose source is written while the view is still live keeps the value it
// had when it was taken. At the tensor level this needs nothing from nex: tensor.extract_slice is a
// value, and one-shot-bufferize makes the one copy it takes to keep it one (it copies only when
// the write would otherwise be visible through the view).
//
//   var a = [0.0, 1.0, 2.0, 3.0]
//   val v = a[0..2]        // a view
//   a[0] = 99.0            // the source is written while v is live
//   print(v[0])            // 0.0
//   print(a[0])            // 99.0
//   print(a[1..3][0])      // 1.0: a view taken and dropped before any write needs no copy
//
// Expected output: 0.0, 99.0, 1.0.

module {
  func.func private @nex_print_real(f64)

  func.func @main() -> i32 {
    %c0 = arith.constant 0 : index
    %a0 = arith.constant dense<[0.0, 1.0, 2.0, 3.0]> : tensor<4xf64>
    // `var a`: a fresh buffer the program owns, not the read-only constant.
    %e = tensor.empty() : tensor<4xf64>
    %a = linalg.copy ins(%a0 : tensor<4xf64>) outs(%e : tensor<4xf64>) -> tensor<4xf64>
    %v = tensor.extract_slice %a[0] [2] [1] : tensor<4xf64> to tensor<2xf64>
    %w = tensor.extract_slice %a[1] [2] [1] : tensor<4xf64> to tensor<2xf64>
    %w0 = tensor.extract %w[%c0] : tensor<2xf64>
    %n = arith.constant 99.0 : f64
    %a2 = tensor.insert %n into %a[%c0] : tensor<4xf64>
    %v0 = tensor.extract %v[%c0] : tensor<2xf64>
    %x0 = tensor.extract %a2[%c0] : tensor<4xf64>
    func.call @nex_print_real(%v0) : (f64) -> ()
    func.call @nex_print_real(%x0) : (f64) -> ()
    func.call @nex_print_real(%w0) : (f64) -> ()
    %z = arith.constant 0 : i32
    return %z : i32
  }
}
