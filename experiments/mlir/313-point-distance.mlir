// testdata/corpus/313-02-arrays-element-wise-fusion-point-distance.nex, by hand: a whole-array
// expression (`2a + b - 1.0`), a struct passed to a function, and `sqrt`.
//
// Each nex operator is emitted as its own linalg.generic on tensors, exactly as a naive emitter
// would; `linalg-fuse-elementwise-ops` fuses the three into one loop, and one-shot bufferization
// turns the tensors into buffers. The struct is flattened into its fields: `distance` takes four
// reals, so no aggregate type is needed below the nex IR.

#id = affine_map<(d0) -> (d0)>

module {
  func.func private @nex_print_real(f64)
  func.func private @nex_print_array_real(memref<?xf64, strided<[?], offset: ?>>)
      attributes {llvm.emit_c_interface}

  func.func @distance(%p1x: f64, %p1y: f64, %p2x: f64, %p2y: f64) -> f64 {
    %dx = arith.subf %p1x, %p2x : f64
    %dy = arith.subf %p1y, %p2y : f64
    %dx2 = arith.mulf %dx, %dx : f64
    %dy2 = arith.mulf %dy, %dy : f64
    %s = arith.addf %dx2, %dy2 : f64
    %r = math.sqrt %s : f64
    return %r : f64
  }

  func.func @main() -> i32 {
    %a = arith.constant dense<[1.0, 2.0, 3.0, 4.0, 5.0]> : tensor<5xf64>
    %b = arith.constant dense<[10.0, 20.0, 30.0, 40.0, 50.0]> : tensor<5xf64>
    %two = arith.constant 2.0 : f64
    %one = arith.constant 1.0 : f64

    %e0 = tensor.empty() : tensor<5xf64>
    %t0 = linalg.generic {indexing_maps = [#id, #id], iterator_types = ["parallel"]}
        ins(%a : tensor<5xf64>) outs(%e0 : tensor<5xf64>) {
      ^bb0(%x: f64, %o: f64):
        %m = arith.mulf %two, %x : f64
        linalg.yield %m : f64
    } -> tensor<5xf64>

    %e1 = tensor.empty() : tensor<5xf64>
    %t1 = linalg.generic {indexing_maps = [#id, #id, #id], iterator_types = ["parallel"]}
        ins(%t0, %b : tensor<5xf64>, tensor<5xf64>) outs(%e1 : tensor<5xf64>) {
      ^bb0(%x: f64, %y: f64, %o: f64):
        %s = arith.addf %x, %y : f64
        linalg.yield %s : f64
    } -> tensor<5xf64>

    %e2 = tensor.empty() : tensor<5xf64>
    %result = linalg.generic {indexing_maps = [#id, #id], iterator_types = ["parallel"]}
        ins(%t1 : tensor<5xf64>) outs(%e2 : tensor<5xf64>) {
      ^bb0(%x: f64, %o: f64):
        %s = arith.subf %x, %one : f64
        linalg.yield %s : f64
    } -> tensor<5xf64>

    %buf = bufferization.to_buffer %result read_only : tensor<5xf64> to memref<5xf64>
    %view = memref.cast %buf : memref<5xf64> to memref<?xf64, strided<[?], offset: ?>>
    func.call @nex_print_array_real(%view) : (memref<?xf64, strided<[?], offset: ?>>) -> ()

    %zero = arith.constant 0.0 : f64
    %three = arith.constant 3.0 : f64
    %four = arith.constant 4.0 : f64
    %d = func.call @distance(%zero, %zero, %three, %four) : (f64, f64, f64, f64) -> f64
    func.call @nex_print_real(%d) : (f64) -> ()

    %rc = arith.constant 0 : i32
    return %rc : i32
  }
}
