! The Fortran twin of gemv.nex.
program gemv
  use iso_fortran_env, only: int64, real64
  implicit none
  integer, parameter :: n = 4000, reps = 20
  real(real64), allocatable :: a(:, :), x(:), y(:)
  real(real64) :: xj
  integer(int64) :: t0, t1, rate
  integer :: i, j, r

  allocate(a(n, n), x(n), y(n))
  do j = 1, n
    x(j) = 1.0_real64 * mod(j, 5) - 2.0_real64
    do i = 1, n
      a(i, j) = 1.0_real64 / (i + j)
    end do
  end do
  call system_clock(t0, rate)
  do r = 1, reps
    do i = 1, n
      y(i) = 0.0_real64
    end do
    do j = 1, n
      xj = x(j)
      do i = 1, n
        y(i) = y(i) + a(i, j) * xj
      end do
    end do
  end do
  call system_clock(t1)
  print '(I0)', int(real(t1 - t0, real64) * 1.0e9_real64 / rate / reps, int64)
  print '(ES25.17)', sum(y)
end program gemv
