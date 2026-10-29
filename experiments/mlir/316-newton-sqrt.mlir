// testdata/corpus/316-06-numerical-methods-newton-s-method-for-sqrt.nex, by hand: a scalar function
// with a `while` loop over two mutable reals, `abs`, and real printing.
//
// A `var` carried around a loop is an scf.while iteration argument, not a memory slot, so the
// loop's state stays in SSA form and nothing needs mem2reg.

module {
  func.func private @nex_print_real(f64)

  func.func @newton_sqrt(%x: f64, %tol: f64) -> f64 {
    %two = arith.constant 2.0 : f64
    %guess0 = arith.divf %x, %two : f64
    %r:2 = scf.while (%guess = %guess0, %delta = %guess0) : (f64, f64) -> (f64, f64) {
      %ad = math.absf %delta : f64
      %more = arith.cmpf ogt, %ad, %tol : f64
      scf.condition(%more) %guess, %delta : f64, f64
    } do {
    ^bb0(%guess: f64, %delta: f64):
      %q = arith.divf %x, %guess : f64
      %s = arith.addf %guess, %q : f64
      %next = arith.divf %s, %two : f64
      %d = arith.subf %next, %guess : f64
      scf.yield %next, %d : f64, f64
    }
    return %r#0 : f64
  }

  func.func @main() -> i32 {
    %two = arith.constant 2.0 : f64
    %tol1 = arith.constant 1.0e-12 : f64
    %a = func.call @newton_sqrt(%two, %tol1) : (f64, f64) -> f64
    func.call @nex_print_real(%a) : (f64) -> ()

    %thousand = arith.constant 1000.0 : f64
    %tol2 = arith.constant 1.0e-9 : f64
    %b = func.call @newton_sqrt(%thousand, %tol2) : (f64, f64) -> f64
    func.call @nex_print_real(%b) : (f64) -> ()

    %zero = arith.constant 0 : i32
    return %zero : i32
  }
}
