// The runtime's spelling of a real against its oracle: real-spelling.out was printed by the reference
// interpreter's formatValue rule run on JDK 27 (Double.toString for what is not a whole number below
// 1e15). The values sit on each boundary the rule has: 1e-3 and 1e7 for plain decimal, 1e15 for the
// whole-number path, the subnormal and largest doubles, -0.0, and digits that only a shortest
// round-trip search gets right (0.1 + 0.2, 1e23).

module {
  func.func private @nex_print_real(f64)

  func.func @main() -> i32 {
    %v = arith.constant dense<[0.001, 1.0e-4, 0.30000000000000004, 123456.789, 1234567.5, 12345678.5,
        10000000.5, 1.5e15, 1.0e20, 1.0e-20, -2.5e-7, 4.9e-324, 1.7976931348623157e308, -0.0,
        0.6666666666666666, 1.0e15, 9.999999999999999e14, 0.5, -1.25e-3, 4.9e-3, 1.0e22, 1.0e23]>
        : tensor<22xf64>
    %c0 = arith.constant 0 : index
    %c1 = arith.constant 1 : index
    %n = arith.constant 22 : index
    scf.for %i = %c0 to %n step %c1 {
      %x = tensor.extract %v[%i] : tensor<22xf64>
      func.call @nex_print_real(%x) : (f64) -> ()
    }
    %rc = arith.constant 0 : i32
    return %rc : i32
  }
}
