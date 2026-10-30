! The Fortran twin of dot.nex.
program dot
  use iso_fortran_env, only: int64, real64
  implicit none
  integer, parameter :: n = 10000000, reps = 50
  real(real64), allocatable :: x(:), y(:)
  real(real64) :: s
  integer(int64) :: t0, t1, rate
  integer :: i, r

  allocate(x(n), y(n))
  do i = 1, n
    x(i) = 1.0_real64 / i
    y(i) = 1.0_real64 * mod(i, 7)
  end do
  s = 0.0_real64
  call system_clock(t0, rate)
  do r = 1, reps
    s = s + sum(x * y)
    x(1) = 1.0_real64 + s * 1.0e-30_real64
  end do
  call system_clock(t1)
  print '(I0)', int(real(t1 - t0, real64) * 1.0e9_real64 / rate / reps, int64)
  print '(ES25.17)', s
end program dot
