// A trap raised inside MLIR-generated frames, caught and resumed by the runtime, as `assert_traps`
// needs; and the same trap with nothing catching it, which ends the program.
//
// `@traps` prints a strided view of a buffer it allocated (stride 2 from offset 1, so the runtime's
// printer has to honour both) and calls `@divide`, which traps on a zero divisor as 145's
// complex division does. `nex_catch_trap` runs it under a catch: the two generated frames are
// abandoned, the catch answers true, and the line after `@divide` never prints. A body that returns
// answers false, and a second trap after the first is caught too, so the catch put its context back.
//
// The last trap is raised outside any catch: its message goes to standard error, everything printed
// before it stays printed, and the program aborts.

module {
  func.func private @nex_print_real(f64)
  func.func private @nex_print_int(i64)
  func.func private @nex_print_array_real(memref<?xf64, strided<[?], offset: ?>>)
      attributes {llvm.emit_c_interface}
  func.func private @nex_trap_complex_div_zero()
  func.func private @nex_catch_trap(() -> ()) -> i1
  func.func private @nex_print_last_trap()

  func.func @divide(%x: f64, %d: f64) -> f64 {
    %zero = arith.constant 0.0 : f64
    %is_zero = arith.cmpf oeq, %d, %zero : f64
    scf.if %is_zero {
      func.call @nex_trap_complex_div_zero() : () -> ()
    }
    %q = arith.divf %x, %d : f64
    return %q : f64
  }

  func.func @traps() {
    %c0 = arith.constant 0 : index
    %c1 = arith.constant 1 : index
    %c6 = arith.constant 6 : index
    %data = memref.alloc() : memref<6xf64>
    scf.for %i = %c0 to %c6 step %c1 {
      %n = arith.index_cast %i : index to i64
      %r = arith.sitofp %n : i64 to f64
      %one = arith.constant 1.0 : f64
      %v = arith.addf %r, %one : f64
      memref.store %v, %data[%i] : memref<6xf64>
    }
    %odd = memref.subview %data[1] [3] [2] : memref<6xf64> to memref<3xf64, strided<[2], offset: 1>>
    %view = memref.cast %odd : memref<3xf64, strided<[2], offset: 1>> to memref<?xf64, strided<[?], offset: ?>>
    func.call @nex_print_array_real(%view) : (memref<?xf64, strided<[?], offset: ?>>) -> ()

    %x = arith.constant 1.0 : f64
    %d = arith.constant 0.0 : f64
    %q = func.call @divide(%x, %d) : (f64, f64) -> f64
    func.call @nex_print_real(%q) : (f64) -> ()
    return
  }

  func.func @returns() {
    %x = arith.constant 1.5 : f64
    func.call @nex_print_real(%x) : (f64) -> ()
    return
  }

  func.func @main() -> i32 {
    %traps = func.constant @traps : () -> ()
    %returns = func.constant @returns : () -> ()

    %t1 = func.call @nex_catch_trap(%traps) : (() -> ()) -> i1
    %n1 = arith.extui %t1 : i1 to i64
    func.call @nex_print_int(%n1) : (i64) -> ()
    func.call @nex_print_last_trap() : () -> ()

    %t2 = func.call @nex_catch_trap(%returns) : (() -> ()) -> i1
    %n2 = arith.extui %t2 : i1 to i64
    func.call @nex_print_int(%n2) : (i64) -> ()

    %t3 = func.call @nex_catch_trap(%traps) : (() -> ()) -> i1
    %n3 = arith.extui %t3 : i1 to i64
    func.call @nex_print_int(%n3) : (i64) -> ()

    func.call @traps() : () -> ()
    %rc = arith.constant 0 : i32
    return %rc : i32
  }
}
