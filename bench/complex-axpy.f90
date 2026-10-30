! The Fortran twin of complex-axpy.nex.
program complex_axpy
  use iso_fortran_env, only: int64, real64
  implicit none
  integer, parameter :: n = 10000000, reps = 50
  complex(real64), parameter :: a = (1.0e-3_real64, 2.0e-3_real64)
  complex(real64), allocatable :: x(:), y(:)
  complex(real64) :: s
  integer(int64) :: t0, t1, rate
  integer :: i, r

  allocate(x(n), y(n))
  do i = 1, n
    x(i) = cmplx(1.0_real64 / i, 0.5_real64, real64)
    y(i) = cmplx(1.0_real64 * mod(i, 7), 1.0_real64, real64)
  end do
  call system_clock(t0, rate)
  do r = 1, reps
    y = a * x + y
  end do
  call system_clock(t1)
  print '(I0)', int(real(t1 - t0, real64) * 1.0e9_real64 / rate / reps, int64)
  s = sum(y)
  print '(ES25.17)', real(s)
  print '(ES25.17)', aimag(s)
end program complex_axpy
