! The Fortran twin of parallel-mandel.nex, built with `-fopenmp`. Its loop nest runs the same
! points in the same storage order: `i` fastest, the outer `j` divided among the threads.
program parallel_mandel
  use iso_fortran_env, only: int64, real64
  implicit none
  integer, parameter :: w = 1024, h = 1024, maxit = 256, reps = 5
  integer, allocatable :: c(:, :)
  integer(int64) :: s, t0, t1, rate
  real(real64) :: cx, cy, x, y, t
  integer :: i, j, k, r

  allocate(c(w, h))
  c = 0
  s = 0
  call system_clock(t0, rate)
  do r = 1, reps
    !$omp parallel do private(i, k, cx, cy, x, y, t)
    do j = 1, h
      do i = 1, w
        cx = -2.0_real64 + 2.5_real64 * (i - 1) / w
        cy = -1.25_real64 + 2.5_real64 * (j - 1) / h
        x = 0.0_real64
        y = 0.0_real64
        k = 0
        do while (k < maxit .and. x * x + y * y <= 4.0_real64)
          t = x * x - y * y + cx
          y = 2.0_real64 * x * y + cy
          x = t
          k = k + 1
        end do
        c(i, j) = k
      end do
    end do
    !$omp end parallel do
    s = s + sum(int(c, int64))
  end do
  call system_clock(t1)
  print '(I0)', int(real(t1 - t0, real64) * 1.0e9_real64 / rate / reps, int64)
  print '(I0)', s
end program parallel_mandel
