// testdata/corpus/145-elementwise-complex-via-componentwise-lowering.nex, by hand: four whole-array
// operators over `[complex]`.
//
// The arrays are tensors of complex<f64>. `+` and `-` are complex.add / complex.sub, which are
// componentwise. `*` and `/` are NOT complex.mul / complex.div: their complex-to-standard lowerings
// add C99 Annex G infinity recovery (mul) and Smith's algorithm (div), and nex defines both by the
// textbook formulas, with a trap on a zero divisor. So the emitter writes nex's own formula over
// complex.re / complex.im, which is what keeps the output bit-identical to the reference.

#id = affine_map<(d0) -> (d0)>

module {
  func.func private @nex_print_array_complex(memref<?xcomplex<f64>, strided<[?], offset: ?>>)
      attributes {llvm.emit_c_interface}
  func.func private @nex_trap_complex_div_zero()

  func.func private @print(%t: tensor<2xcomplex<f64>>) {
    // A tensor parameter bufferizes to a fully dynamic strided memref, so the buffer is read at that
    // layout: asking for the identity layout here would make bufferization copy it.
    %buf = bufferization.to_buffer %t read_only
        : tensor<2xcomplex<f64>> to memref<2xcomplex<f64>, strided<[?], offset: ?>>
    %view = memref.cast %buf
        : memref<2xcomplex<f64>, strided<[?], offset: ?>> to memref<?xcomplex<f64>, strided<[?], offset: ?>>
    func.call @nex_print_array_complex(%view) : (memref<?xcomplex<f64>, strided<[?], offset: ?>>) -> ()
    return
  }

  func.func @main() -> i32 {
    %a = arith.constant dense<[(1.0, 2.0), (3.0, 4.0)]> : tensor<2xcomplex<f64>>
    %b = arith.constant dense<[(10.0, 20.0), (30.0, 40.0)]> : tensor<2xcomplex<f64>>

    %e0 = tensor.empty() : tensor<2xcomplex<f64>>
    %sum = linalg.generic {indexing_maps = [#id, #id, #id], iterator_types = ["parallel"]}
        ins(%a, %b : tensor<2xcomplex<f64>>, tensor<2xcomplex<f64>>) outs(%e0 : tensor<2xcomplex<f64>>) {
      ^bb0(%x: complex<f64>, %y: complex<f64>, %o: complex<f64>):
        %r = complex.add %x, %y : complex<f64>
        linalg.yield %r : complex<f64>
    } -> tensor<2xcomplex<f64>>
    func.call @print(%sum) : (tensor<2xcomplex<f64>>) -> ()

    %e1 = tensor.empty() : tensor<2xcomplex<f64>>
    %diff = linalg.generic {indexing_maps = [#id, #id, #id], iterator_types = ["parallel"]}
        ins(%a, %b : tensor<2xcomplex<f64>>, tensor<2xcomplex<f64>>) outs(%e1 : tensor<2xcomplex<f64>>) {
      ^bb0(%x: complex<f64>, %y: complex<f64>, %o: complex<f64>):
        %r = complex.sub %x, %y : complex<f64>
        linalg.yield %r : complex<f64>
    } -> tensor<2xcomplex<f64>>
    func.call @print(%diff) : (tensor<2xcomplex<f64>>) -> ()

    // (ar*br - ai*bi) + (ar*bi + ai*br)i
    %e2 = tensor.empty() : tensor<2xcomplex<f64>>
    %prod = linalg.generic {indexing_maps = [#id, #id, #id], iterator_types = ["parallel"]}
        ins(%a, %b : tensor<2xcomplex<f64>>, tensor<2xcomplex<f64>>) outs(%e2 : tensor<2xcomplex<f64>>) {
      ^bb0(%x: complex<f64>, %y: complex<f64>, %o: complex<f64>):
        %ar = complex.re %x : complex<f64>
        %ai = complex.im %x : complex<f64>
        %br = complex.re %y : complex<f64>
        %bi = complex.im %y : complex<f64>
        %rr = arith.mulf %ar, %br : f64
        %ii = arith.mulf %ai, %bi : f64
        %re = arith.subf %rr, %ii : f64
        %ri = arith.mulf %ar, %bi : f64
        %ir = arith.mulf %ai, %br : f64
        %im = arith.addf %ri, %ir : f64
        %r = complex.create %re, %im : complex<f64>
        linalg.yield %r : complex<f64>
    } -> tensor<2xcomplex<f64>>
    func.call @print(%prod) : (tensor<2xcomplex<f64>>) -> ()

    // b / a: denom = ar*ar + ai*ai, trap if zero; ((br*ar + bi*ai) + (bi*ar - br*ai)i) / denom
    %zero = arith.constant 0.0 : f64
    %e3 = tensor.empty() : tensor<2xcomplex<f64>>
    %quot = linalg.generic {indexing_maps = [#id, #id, #id], iterator_types = ["parallel"]}
        ins(%b, %a : tensor<2xcomplex<f64>>, tensor<2xcomplex<f64>>) outs(%e3 : tensor<2xcomplex<f64>>) {
      ^bb0(%x: complex<f64>, %y: complex<f64>, %o: complex<f64>):
        %xr = complex.re %x : complex<f64>
        %xi = complex.im %x : complex<f64>
        %yr = complex.re %y : complex<f64>
        %yi = complex.im %y : complex<f64>
        %yr2 = arith.mulf %yr, %yr : f64
        %yi2 = arith.mulf %yi, %yi : f64
        %den = arith.addf %yr2, %yi2 : f64
        %z = arith.cmpf oeq, %den, %zero : f64
        scf.if %z {
          func.call @nex_trap_complex_div_zero() : () -> ()
        }
        %p1 = arith.mulf %xr, %yr : f64
        %p2 = arith.mulf %xi, %yi : f64
        %nr = arith.addf %p1, %p2 : f64
        %p3 = arith.mulf %xi, %yr : f64
        %p4 = arith.mulf %xr, %yi : f64
        %ni = arith.subf %p3, %p4 : f64
        %re = arith.divf %nr, %den : f64
        %im = arith.divf %ni, %den : f64
        %r = complex.create %re, %im : complex<f64>
        linalg.yield %r : complex<f64>
    } -> tensor<2xcomplex<f64>>
    func.call @print(%quot) : (tensor<2xcomplex<f64>>) -> ()

    %rc = arith.constant 0 : i32
    return %rc : i32
  }
}
