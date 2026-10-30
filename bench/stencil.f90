! The Fortran twin of stencil.nex.
program stencil
  use iso_fortran_env, only: int64, real64
  implicit none
  integer, parameter :: n = 10000000, pairs = 50
  real(real64), allocatable :: x(:), y(:)
  integer(int64) :: t0, t1, rate
  integer :: i, s

  allocate(x(n), y(n))
  do i = 1, n
    x(i) = 1.0_real64 * mod(i, 13)
    y(i) = x(i)
  end do
  call system_clock(t0, rate)
  do s = 1, pairs
    do i = 2, n - 1
      y(i) = (x(i - 1) + x(i) + x(i + 1)) / 3.0_real64
    end do
    do i = 2, n - 1
      x(i) = (y(i - 1) + y(i) + y(i + 1)) / 3.0_real64
    end do
  end do
  call system_clock(t1)
  print '(I0)', int(real(t1 - t0, real64) * 1.0e9_real64 / rate / (2 * pairs), int64)
  print '(ES25.17)', sum(x)
end program stencil
