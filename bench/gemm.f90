! The Fortran twin of gemm.nex: the same triple loop, not `matmul`.
program gemm
  use iso_fortran_env, only: int64, real64
  implicit none
  integer, parameter :: n = 1000, reps = 3
  real(real64), allocatable :: a(:, :), b(:, :), c(:, :)
  real(real64) :: bkj
  integer(int64) :: t0, t1, rate
  integer :: i, j, k, r

  allocate(a(n, n), b(n, n), c(n, n))
  do j = 1, n
    do i = 1, n
      a(i, j) = 1.0_real64 / (i + j)
      b(i, j) = 1.0_real64 * mod(i * 7 + j * 3, 11) - 5.0_real64
    end do
  end do
  call system_clock(t0, rate)
  do r = 1, reps
    do j = 1, n
      do i = 1, n
        c(i, j) = 0.0_real64
      end do
      do k = 1, n
        bkj = b(k, j)
        do i = 1, n
          c(i, j) = c(i, j) + a(i, k) * bkj
        end do
      end do
    end do
  end do
  call system_clock(t1)
  print '(I0)', int(real(t1 - t0, real64) * 1.0e9_real64 / rate / reps, int64)
  print '(ES25.17)', sum(c)
end program gemm
