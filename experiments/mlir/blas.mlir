// DESIGN.md §11 (C FFI and BLAS): a nex array, and a view of one, handed to cblas_dgemm.
//
// A column-major nex matrix of shape (m, n) is a memref<n x m> (axes reversed, DESIGN.md §2.3).
// What BLAS needs from it is read off the memref, never copied:
//
//   pointer = aligned base + offset (memref.extract_strided_metadata)
//   ld      = the stride of memref axis 0, which is nex axis 1 (the column stride)
//
// That works for a whole array and for any view whose element stride along nex axis 0 is 1. A view
// strided along axis 0 (`m[0..4 by 2, :]`) has no BLAS spelling and is copied first.
//
//   A = [[1, 2, 3], [4, 5, 6]]                  2 x 3, ld 2
//   B = [[7, 8], [9, 10], [11, 12]]             3 x 2, ld 3
//   Big = [[0,0,0], [1,2,3], [4,5,6], [0,0,0]]  4 x 3; Big[1..3, :] == A, as a view: offset 1, ld 4
//
// Expected output: A @ B = [[58, 64], [139, 154]], printed C[0,0], C[1,0], C[0,1], C[1,1], once
// from A, once from the view of Big, and once from linalg.matmul (the below-threshold path):
//   58.0 139.0 64.0 154.0 58.0 139.0 64.0 154.0 58.0 139.0 64.0 154.0
//
// Link: -framework Accelerate (macOS); any CBLAS (OpenBLAS: -lopenblas) has the same entry.

module {
  func.func private @nex_print_real(f64)
  func.func private @cblas_dgemm(i32, i32, i32, i32, i32, i32, f64, !llvm.ptr, i32, !llvm.ptr, i32,
                                 f64, !llvm.ptr, i32)

  // The FFI view of a rank-2 nex array: its first element's address and its leading dimension.
  func.func @blas_arg(%m: memref<?x?xf64, strided<[?, 1], offset: ?>>) -> (!llvm.ptr, i32) {
    %base, %off, %sz:2, %st:2 = memref.extract_strided_metadata %m
        : memref<?x?xf64, strided<[?, 1], offset: ?>> -> memref<f64>, index, index, index, index, index
    %p = memref.extract_aligned_pointer_as_index %m : memref<?x?xf64, strided<[?, 1], offset: ?>> -> index
    %pi = arith.index_cast %p : index to i64
    %ptr = llvm.inttoptr %pi : i64 to !llvm.ptr
    %offi = arith.index_cast %off : index to i64
    %first = llvm.getelementptr %ptr[%offi] : (!llvm.ptr, i64) -> !llvm.ptr, f64
    %ld = arith.index_cast %st#0 : index to i32
    return %first, %ld : !llvm.ptr, i32
  }

  // C (m x n) = A (m x k) @ B (k x n), every operand column-major.
  func.func @gemm(%a: memref<?x?xf64, strided<[?, 1], offset: ?>>,
                  %b: memref<?x?xf64, strided<[?, 1], offset: ?>>,
                  %c: memref<?x?xf64, strided<[?, 1], offset: ?>>) {
    %c0 = arith.constant 0 : index
    %c1 = arith.constant 1 : index
    %k = memref.dim %a, %c0 : memref<?x?xf64, strided<[?, 1], offset: ?>>
    %m = memref.dim %a, %c1 : memref<?x?xf64, strided<[?, 1], offset: ?>>
    %n = memref.dim %b, %c0 : memref<?x?xf64, strided<[?, 1], offset: ?>>
    %mi = arith.index_cast %m : index to i32
    %ni = arith.index_cast %n : index to i32
    %ki = arith.index_cast %k : index to i32
    %pa, %lda = func.call @blas_arg(%a) : (memref<?x?xf64, strided<[?, 1], offset: ?>>) -> (!llvm.ptr, i32)
    %pb, %ldb = func.call @blas_arg(%b) : (memref<?x?xf64, strided<[?, 1], offset: ?>>) -> (!llvm.ptr, i32)
    %pc, %ldc = func.call @blas_arg(%c) : (memref<?x?xf64, strided<[?, 1], offset: ?>>) -> (!llvm.ptr, i32)
    %colmajor = arith.constant 102 : i32
    %notrans = arith.constant 111 : i32
    %one = arith.constant 1.0 : f64
    %zero = arith.constant 0.0 : f64
    func.call @cblas_dgemm(%colmajor, %notrans, %notrans, %mi, %ni, %ki, %one, %pa, %lda, %pb, %ldb,
                           %zero, %pc, %ldc)
        : (i32, i32, i32, i32, i32, i32, f64, !llvm.ptr, i32, !llvm.ptr, i32, f64, !llvm.ptr, i32) -> ()
    return
  }

  func.func @print_c(%c: memref<2x2xf64>) {
    %c0 = arith.constant 0 : index
    %c1 = arith.constant 1 : index
    // nex C[i, j] is memref [j, i]; printed in storage order.
    %x00 = memref.load %c[%c0, %c0] : memref<2x2xf64>
    %x10 = memref.load %c[%c0, %c1] : memref<2x2xf64>
    %x01 = memref.load %c[%c1, %c0] : memref<2x2xf64>
    %x11 = memref.load %c[%c1, %c1] : memref<2x2xf64>
    func.call @nex_print_real(%x00) : (f64) -> ()
    func.call @nex_print_real(%x10) : (f64) -> ()
    func.call @nex_print_real(%x01) : (f64) -> ()
    func.call @nex_print_real(%x11) : (f64) -> ()
    return
  }

  memref.global "private" constant @A : memref<3x2xf64> = dense<[[1.0, 4.0], [2.0, 5.0], [3.0, 6.0]]>
  memref.global "private" constant @B : memref<2x3xf64> = dense<[[7.0, 9.0, 11.0], [8.0, 10.0, 12.0]]>
  memref.global "private" constant @Big : memref<3x4xf64> =
      dense<[[0.0, 1.0, 4.0, 0.0], [0.0, 2.0, 5.0, 0.0], [0.0, 3.0, 6.0, 0.0]]>

  func.func @main() -> i32 {
    %a = memref.get_global @A : memref<3x2xf64>
    %b = memref.get_global @B : memref<2x3xf64>
    %big = memref.get_global @Big : memref<3x4xf64>
    %c = memref.alloc() : memref<2x2xf64>

    %ad = memref.cast %a : memref<3x2xf64> to memref<?x?xf64, strided<[?, 1], offset: ?>>
    %bd = memref.cast %b : memref<2x3xf64> to memref<?x?xf64, strided<[?, 1], offset: ?>>
    %cd = memref.cast %c : memref<2x2xf64> to memref<?x?xf64, strided<[?, 1], offset: ?>>
    func.call @gemm(%ad, %bd, %cd) : (memref<?x?xf64, strided<[?, 1], offset: ?>>,
        memref<?x?xf64, strided<[?, 1], offset: ?>>, memref<?x?xf64, strided<[?, 1], offset: ?>>) -> ()
    func.call @print_c(%c) : (memref<2x2xf64>) -> ()

    // Big[1..3, :] -- memref rows 0..3, columns 1..3: offset 1, row stride 4.
    %v = memref.subview %big[0, 1] [3, 2] [1, 1] : memref<3x4xf64> to memref<3x2xf64, strided<[4, 1], offset: 1>>
    %vd = memref.cast %v : memref<3x2xf64, strided<[4, 1], offset: 1>> to memref<?x?xf64, strided<[?, 1], offset: ?>>
    func.call @gemm(%vd, %bd, %cd) : (memref<?x?xf64, strided<[?, 1], offset: ?>>,
        memref<?x?xf64, strided<[?, 1], offset: ?>>, memref<?x?xf64, strided<[?, 1], offset: ?>>) -> ()
    func.call @print_c(%c) : (memref<2x2xf64>) -> ()

    // Below the BLAS threshold `A @ B` is a linalg.matmul. With every axis reversed, nex's
    // C = A @ B is storage's C' = B' @ A', so the operands go in swapped.
    %c2 = memref.alloc() : memref<2x2xf64>
    %zf = arith.constant 0.0 : f64
    linalg.fill ins(%zf : f64) outs(%c2 : memref<2x2xf64>)
    linalg.matmul ins(%b, %a : memref<2x3xf64>, memref<3x2xf64>) outs(%c2 : memref<2x2xf64>)
    func.call @print_c(%c2) : (memref<2x2xf64>) -> ()

    %z = arith.constant 0 : i32
    return %z : i32
  }
}
