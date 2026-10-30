! The Fortran twin of axpy.nex: the same arrays, the same fifty passes, timed the same way.
program axpy
  use iso_fortran_env, only: int64, real64
  implicit none
  integer, parameter :: n = 10000000, reps = 50
  real(real64), parameter :: a = 1.0e-3_real64
  real(real64), allocatable :: x(:), y(:)
  integer(int64) :: t0, t1, rate
  integer :: i, r

  allocate(x(n), y(n))
  do i = 1, n
    x(i) = 1.0_real64 / i
    y(i) = 1.0_real64 * mod(i, 7)
  end do
  call system_clock(t0, rate)
  do r = 1, reps
    y = a * x + y
  end do
  call system_clock(t1)
  print '(I0)', int(real(t1 - t0, real64) * 1.0e9_real64 / rate / reps, int64)
  print '(ES25.17)', sum(y)
end program axpy
