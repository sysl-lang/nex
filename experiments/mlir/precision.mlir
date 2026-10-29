// DESIGN.md §3 (sized precision): every width nex has lowers through the pipeline as it stands.
//
//   real16 = f16, real32 = f32, real64 = f64; complexN = complex<fN>; integerN = iN.
//
// Expected output:
//   3.75                    real16: 1.5 + 2.25, widened to f64 for printing
//   1.5                     real16 sqrt(2.25)
//   0.8414709568023682      real32 sin(1.0), widened (f32 sin, printed as the f64 it widens to)
//   -5.0+10.0i              complex32: (1 + 2i) * (3 + 4i), componentwise over f32
//   1                       integer8: 127 + 1 overflows (llvm.intr.sadd.with.overflow)
//   0                       integer8: 100 + 27 does not
//   3000000000.0            integer32 3_000_000 * 1000 widened to integer64, then to real64
//   0.30000001192092896     real32 0.1 * 3, widened to real64 (the real32 rounding stays visible)

module {
  func.func private @nex_print_real(f64)
  func.func private @nex_print_int(i64)
  func.func private @nex_print_complex(f64, f64)

  func.func @main() -> i32 {
    %h1 = arith.constant 1.5 : f16
    %h2 = arith.constant 2.25 : f16
    %hs = arith.addf %h1, %h2 : f16
    %hw = arith.extf %hs : f16 to f64
    func.call @nex_print_real(%hw) : (f64) -> ()
    %hq = math.sqrt %h2 : f16
    %hqw = arith.extf %hq : f16 to f64
    func.call @nex_print_real(%hqw) : (f64) -> ()

    %one = arith.constant 1.0 : f32
    %s = math.sin %one : f32
    %sw = arith.extf %s : f32 to f64
    func.call @nex_print_real(%sw) : (f64) -> ()

    %ar = arith.constant 1.0 : f32
    %ai = arith.constant 2.0 : f32
    %br = arith.constant 3.0 : f32
    %bi = arith.constant 4.0 : f32
    // nex's textbook product: (ac - bd) + (ad + bc)i, emitted over complex.re / complex.im.
    %a = complex.create %ar, %ai : complex<f32>
    %b = complex.create %br, %bi : complex<f32>
    %are = complex.re %a : complex<f32>
    %aim = complex.im %a : complex<f32>
    %bre = complex.re %b : complex<f32>
    %bim = complex.im %b : complex<f32>
    %ac = arith.mulf %are, %bre : f32
    %bd = arith.mulf %aim, %bim : f32
    %ad = arith.mulf %are, %bim : f32
    %bc = arith.mulf %aim, %bre : f32
    %pre = arith.subf %ac, %bd : f32
    %pim = arith.addf %ad, %bc : f32
    %p = complex.create %pre, %pim : complex<f32>
    %pr = complex.re %p : complex<f32>
    %pi = complex.im %p : complex<f32>
    %prw = arith.extf %pr : f32 to f64
    %piw = arith.extf %pi : f32 to f64
    func.call @nex_print_complex(%prw, %piw) : (f64, f64) -> ()

    %x127 = arith.constant 127 : i8
    %x1 = arith.constant 1 : i8
    %r1 = "llvm.intr.sadd.with.overflow"(%x127, %x1) : (i8, i8) -> !llvm.struct<(i8, i1)>
    %o1 = llvm.extractvalue %r1[1] : !llvm.struct<(i8, i1)>
    %o1w = arith.extui %o1 : i1 to i64
    func.call @nex_print_int(%o1w) : (i64) -> ()
    %x100 = arith.constant 100 : i8
    %x27 = arith.constant 27 : i8
    %r2 = "llvm.intr.sadd.with.overflow"(%x100, %x27) : (i8, i8) -> !llvm.struct<(i8, i1)>
    %o2 = llvm.extractvalue %r2[1] : !llvm.struct<(i8, i1)>
    %o2w = arith.extui %o2 : i1 to i64
    func.call @nex_print_int(%o2w) : (i64) -> ()

    %m = arith.constant 3000000 : i32
    %k = arith.constant 1000 : i32
    %mw = arith.extsi %m : i32 to i64
    %kw = arith.extsi %k : i32 to i64
    %prod = arith.muli %mw, %kw : i64
    %pf = arith.sitofp %prod : i64 to f64
    func.call @nex_print_real(%pf) : (f64) -> ()

    %tenth = arith.constant 0.1 : f32
    %three = arith.constant 3.0 : f32
    %t3 = arith.mulf %tenth, %three : f32
    %t3w = arith.extf %t3 : f32 to f64
    func.call @nex_print_real(%t3w) : (f64) -> ()

    %z = arith.constant 0 : i32
    return %z : i32
  }
}
