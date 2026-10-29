// DESIGN.md §2.3 and §5 (storage and views): column-major rank-2 and rank-3 arrays as tensors with
// their axes reversed, and slices as tensor.extract_slice, which bufferize to strided memref
// subviews of the source -- no allocation and no copy.
//
// A nex array of shape (d0, d1, ..., dk) is a tensor<dk x ... x d1 x d0>: tensor axis R-1-a is nex
// axis a, so the identity (row-major) tensor layout is nex's column-major storage, and nex index
// [i, j] is tensor index [j, i].
//
//   M: [real; 3, 4], M[i, j] = 10i + j            tensor<4x3xf64>
//   A: [real; 4, 3, 2], A[i, j, k] = i + 10j + 100k   tensor<2x3x4xf64>
//
// Expected output:
//   138.0    sum(M)
//   36.0     sum(M[:, 2])          a column: contiguous
//   46.0     sum(M[1, :])          a row: stride 3
//   72.0     sum(M[0..3 by 2, 1..4])  strided on both axes
//   1476.0   sum(D), D = (A + A) * 0.5, two elementwise ops fused into one loop nest
//   1338.0   sum(D[:, :, 1])       a rank-2 plane of a rank-3 array

#id2 = affine_map<(d0, d1) -> (d0, d1)>
#id3 = affine_map<(d0, d1, d2) -> (d0, d1, d2)>

module {
  func.func private @nex_print_real(f64)

  func.func @sum1(%v: tensor<?xf64>) -> f64 {
    %c0 = arith.constant 0 : index
    %c1 = arith.constant 1 : index
    %n = tensor.dim %v, %c0 : tensor<?xf64>
    %z = arith.constant 0.0 : f64
    %r = scf.for %i = %c0 to %n step %c1 iter_args(%acc = %z) -> (f64) {
      %x = tensor.extract %v[%i] : tensor<?xf64>
      %s = arith.addf %acc, %x : f64
      scf.yield %s : f64
    }
    return %r : f64
  }

  func.func @sum2(%m: tensor<?x?xf64>) -> f64 {
    %c0 = arith.constant 0 : index
    %c1 = arith.constant 1 : index
    %n0 = tensor.dim %m, %c0 : tensor<?x?xf64>
    %n1 = tensor.dim %m, %c1 : tensor<?x?xf64>
    %z = arith.constant 0.0 : f64
    %r = scf.for %a = %c0 to %n0 step %c1 iter_args(%acc = %z) -> (f64) {
      %r2 = scf.for %b = %c0 to %n1 step %c1 iter_args(%acc2 = %acc) -> (f64) {
        %x = tensor.extract %m[%a, %b] : tensor<?x?xf64>
        %s = arith.addf %acc2, %x : f64
        scf.yield %s : f64
      }
      scf.yield %r2 : f64
    }
    return %r : f64
  }

  func.func @sum3(%t: tensor<?x?x?xf64>) -> f64 {
    %c0 = arith.constant 0 : index
    %c1 = arith.constant 1 : index
    %c2 = arith.constant 2 : index
    %n0 = tensor.dim %t, %c0 : tensor<?x?x?xf64>
    %n1 = tensor.dim %t, %c1 : tensor<?x?x?xf64>
    %n2 = tensor.dim %t, %c2 : tensor<?x?x?xf64>
    %z = arith.constant 0.0 : f64
    %r = scf.for %a = %c0 to %n0 step %c1 iter_args(%acc = %z) -> (f64) {
      %plane = tensor.extract_slice %t[%a, 0, 0] [1, %n1, %n2] [1, 1, 1]
          : tensor<?x?x?xf64> to tensor<?x?xf64>
      %s = func.call @sum2(%plane) : (tensor<?x?xf64>) -> f64
      %acc2 = arith.addf %acc, %s : f64
      scf.yield %acc2 : f64
    }
    return %r : f64
  }

  func.func @main() -> i32 {
    %ten = arith.constant 10.0 : f64
    %hundred = arith.constant 100.0 : f64
    %half = arith.constant 0.5 : f64

    // M[i, j] = 10i + j, stored as T[j][i].
    %me = tensor.empty() : tensor<4x3xf64>
    %M = linalg.generic {indexing_maps = [#id2], iterator_types = ["parallel", "parallel"]}
        outs(%me : tensor<4x3xf64>) {
    ^bb0(%o: f64):
      %j = linalg.index 0 : index
      %i = linalg.index 1 : index
      %ji = arith.index_cast %j : index to i64
      %ii = arith.index_cast %i : index to i64
      %jf = arith.sitofp %ji : i64 to f64
      %if = arith.sitofp %ii : i64 to f64
      %t = arith.mulf %ten, %if : f64
      %v = arith.addf %t, %jf : f64
      linalg.yield %v : f64
    } -> tensor<4x3xf64>

    %Md = tensor.cast %M : tensor<4x3xf64> to tensor<?x?xf64>
    %s0 = func.call @sum2(%Md) : (tensor<?x?xf64>) -> f64
    func.call @nex_print_real(%s0) : (f64) -> ()

    // M[:, 2]: tensor row 2, contiguous.
    %col = tensor.extract_slice %M[2, 0] [1, 3] [1, 1] : tensor<4x3xf64> to tensor<3xf64>
    %cold = tensor.cast %col : tensor<3xf64> to tensor<?xf64>
    %s1 = func.call @sum1(%cold) : (tensor<?xf64>) -> f64
    func.call @nex_print_real(%s1) : (f64) -> ()

    // M[1, :]: tensor column 1, stride 3.
    %row = tensor.extract_slice %M[0, 1] [4, 1] [1, 1] : tensor<4x3xf64> to tensor<4xf64>
    %rowd = tensor.cast %row : tensor<4xf64> to tensor<?xf64>
    %s2 = func.call @sum1(%rowd) : (tensor<?xf64>) -> f64
    func.call @nex_print_real(%s2) : (f64) -> ()

    // M[0..3 by 2, 1..4]: tensor offsets [1, 0], sizes [3, 2], strides [1, 2].
    %blk = tensor.extract_slice %M[1, 0] [3, 2] [1, 2] : tensor<4x3xf64> to tensor<3x2xf64>
    %blkd = tensor.cast %blk : tensor<3x2xf64> to tensor<?x?xf64>
    %s3 = func.call @sum2(%blkd) : (tensor<?x?xf64>) -> f64
    func.call @nex_print_real(%s3) : (f64) -> ()

    // A[i, j, k] = i + 10j + 100k, stored as T[k][j][i].
    %ae = tensor.empty() : tensor<2x3x4xf64>
    %A = linalg.generic {indexing_maps = [#id3], iterator_types = ["parallel", "parallel", "parallel"]}
        outs(%ae : tensor<2x3x4xf64>) {
    ^bb0(%o: f64):
      %k = linalg.index 0 : index
      %j = linalg.index 1 : index
      %i = linalg.index 2 : index
      %ki = arith.index_cast %k : index to i64
      %ji = arith.index_cast %j : index to i64
      %ii = arith.index_cast %i : index to i64
      %kf = arith.sitofp %ki : i64 to f64
      %jf = arith.sitofp %ji : i64 to f64
      %if = arith.sitofp %ii : i64 to f64
      %a = arith.mulf %hundred, %kf : f64
      %b = arith.mulf %ten, %jf : f64
      %c = arith.addf %a, %b : f64
      %v = arith.addf %c, %if : f64
      linalg.yield %v : f64
    } -> tensor<2x3x4xf64>

    %ce = tensor.empty() : tensor<2x3x4xf64>
    %C = linalg.generic {indexing_maps = [#id3, #id3, #id3], iterator_types = ["parallel", "parallel", "parallel"]}
        ins(%A, %A : tensor<2x3x4xf64>, tensor<2x3x4xf64>) outs(%ce : tensor<2x3x4xf64>) {
    ^bb0(%x: f64, %y: f64, %o: f64):
      %v = arith.addf %x, %y : f64
      linalg.yield %v : f64
    } -> tensor<2x3x4xf64>
    %de = tensor.empty() : tensor<2x3x4xf64>
    %D = linalg.generic {indexing_maps = [#id3, #id3], iterator_types = ["parallel", "parallel", "parallel"]}
        ins(%C : tensor<2x3x4xf64>) outs(%de : tensor<2x3x4xf64>) {
    ^bb0(%x: f64, %o: f64):
      %v = arith.mulf %x, %half : f64
      linalg.yield %v : f64
    } -> tensor<2x3x4xf64>

    %Dd = tensor.cast %D : tensor<2x3x4xf64> to tensor<?x?x?xf64>
    %s4 = func.call @sum3(%Dd) : (tensor<?x?x?xf64>) -> f64
    func.call @nex_print_real(%s4) : (f64) -> ()

    // D[:, :, 1]: tensor plane 1.
    %pl = tensor.extract_slice %D[1, 0, 0] [1, 3, 4] [1, 1, 1] : tensor<2x3x4xf64> to tensor<3x4xf64>
    %pld = tensor.cast %pl : tensor<3x4xf64> to tensor<?x?xf64>
    %s5 = func.call @sum2(%pld) : (tensor<?x?xf64>) -> f64
    func.call @nex_print_real(%s5) : (f64) -> ()

    %z = arith.constant 0 : i32
    return %z : i32
  }
}
