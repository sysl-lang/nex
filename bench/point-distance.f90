! The Fortran twin of point-distance.nex.
program point_distance
  use iso_fortran_env, only: int64, real64
  implicit none
  integer, parameter :: n = 10000000, reps = 50
  real(real64), allocatable :: x1(:), y1(:), x2(:), y2(:), d(:)
  integer(int64) :: t0, t1, rate
  integer :: i, r

  allocate(x1(n), y1(n), x2(n), y2(n), d(n))
  do i = 1, n
    x1(i) = 1.0_real64 * mod(i, 7)
    y1(i) = 1.0_real64 * mod(i, 11)
    x2(i) = 1.0_real64 / i
    y2(i) = 1.0_real64 * mod(i, 3)
  end do
  call system_clock(t0, rate)
  do r = 1, reps
    d = sqrt((x2 - x1)**2 + (y2 - y1)**2)
  end do
  call system_clock(t1)
  print '(I0)', int(real(t1 - t0, real64) * 1.0e9_real64 / rate / reps, int64)
  print '(ES25.17)', sum(d)
end program point_distance
