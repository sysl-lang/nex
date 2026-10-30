! The Fortran twin of parallel-dot.nex, built with `-fopenmp`.
program parallel_dot
  use iso_fortran_env, only: int64, real64
  implicit none
  integer, parameter :: n = 10000000, reps = 50
  real(real64), allocatable :: x(:), y(:)
  real(real64) :: s, t
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
    t = 0.0_real64
    !$omp parallel do reduction(+:t)
    do i = 1, n
      t = t + x(i) * y(i)
    end do
    !$omp end parallel do
    s = s + t
    x(1) = 1.0_real64 + s * 1.0e-30_real64
  end do
  call system_clock(t1)
  print '(I0)', int(real(t1 - t0, real64) * 1.0e9_real64 / rate / reps, int64)
  print '(ES25.17)', s
end program parallel_dot
