! The Fortran library nex's `@fortran` tests call (DESIGN §10.6): Fortran 2003 `bind(c)`
! procedures, which nex declares as C functions, and plain Fortran 77/90 procedures compiled by
! gfortran, which nex declares `@fortran`. `matmul` and the string intrinsics reach gfortran's runtime,
! so a program calling them links libgfortran.

! A `bind(c)` function: a C function to nex, its arguments by value.
function nf_hypot(x, y) bind(c, name="nf_hypot") result(r)
  use iso_c_binding, only: c_double
  real(c_double), value :: x, y
  real(c_double) :: r
  r = sqrt(x * x + y * y)
end function

! A `bind(c)` subroutine with an array and a `logical(c_bool)` by value.
subroutine nf_fill_bc(n, x, v, neg) bind(c, name="nf_fill_bc")
  use iso_c_binding, only: c_int, c_double, c_bool
  integer(c_int), value :: n
  real(c_double) :: x(n)
  real(c_double), value :: v
  logical(c_bool), value :: neg
  if (neg) then
    x = -v
  else
    x = v
  end if
end subroutine

! A function with a real result, its scalars and arrays by reference.
double precision function fdot(n, x, y)
  integer n
  double precision x(n), y(n)
  fdot = dot_product(x, y)
end function

! `y = a x + y`, with `info` as LAPACK reports a bad argument: the argument's number, negated.
subroutine faxpy(n, a, x, y, info)
  integer n, info
  double precision a, x(*), y(*)
  if (n < 0) then
    info = -1
    return
  end if
  y(1:n) = a * x(1:n) + y(1:n)
  info = 0
end subroutine

! The `m` by `n` block of `a`, whose leading dimension is `lda`, scaled by `s`.
subroutine fscale(m, n, a, lda, s)
  integer m, n, lda
  double precision a(lda, *), s
  a(1:m, 1:n) = s * a(1:m, 1:n)
end subroutine

! `c = a b` through gfortran's own `matmul`, which lives in libgfortran.
subroutine fmatmul(m, k, n, a, b, c)
  integer m, k, n
  double precision a(m, k), b(k, n), c(m, n)
  c = matmul(a, b)
end subroutine

! The sum of an integer array and of an `integer*8` and an `integer*2` scalar.
integer function fisum(n, x, big, small)
  integer n, x(n)
  integer*8 big
  integer*2 small
  fisum = sum(x) + int(big) + small
end function

! Single precision and its own `real` result.
real function fsdot(n, x, y)
  integer n
  real x(n), y(n)
  fsdot = dot_product(x, y)
end function

! The length of `s` without its trailing blanks: a `character(*)` argument, its length hidden.
integer function flen_trim(s)
  character(*) s
  flen_trim = len_trim(s)
end function

! How often `t` occurs in `s`, overlapping: two `character(*)` arguments, their lengths hidden after
! every declared argument, in order.
subroutine fcount(s, t, n)
  character(*) s, t
  integer n, i
  n = 0
  if (len(t) == 0) return
  do i = 1, len(s) - len(t) + 1
    if (s(i:i + len(t) - 1) == t) n = n + 1
  end do
end subroutine

! A string's length and a number on either side of it, so the hidden length is seen to trail.
subroutine fsandwich(a, s, b, total)
  integer a, b, total
  character(*) s
  total = a + len(s) * 100 + b * 10000
end subroutine

! A default `logical` result and an `inout` one.
logical function fpositive(x)
  double precision x
  fpositive = x > 0
end function

subroutine fall_positive(n, x, ok)
  integer n
  double precision x(n)
  logical ok
  ok = ok .and. all(x > 0)
end subroutine

! A `complex(8)` function, and a `complex(8)` array conjugated in place.
complex(8) function fcmul(a, b)
  complex(8) a, b
  fcmul = a * b
end function

subroutine fconj(n, z)
  integer n
  complex(8) z(n)
  z = conjg(z)
end subroutine

! Simpson's rule over `n` (even) intervals of a function nex passes, which Fortran calls with its
! argument by reference.
subroutine fsimpson(f, a, b, n, r)
  double precision, external :: f
  double precision a, b, r, h
  integer n, i
  h = (b - a) / n
  r = f(a) + f(b)
  do i = 1, n - 1
    if (mod(i, 2) == 1) then
      r = r + 4 * f(a + i * h)
    else
      r = r + 2 * f(a + i * h)
    end if
  end do
  r = r * h / 3
end subroutine

! `out(i) = g(i, x(i))`: a callback of an integer and a real.
subroutine fapply(g, n, x, out)
  integer n, i
  double precision x(n), out(n)
  double precision, external :: g
  do i = 1, n
    out(i) = g(i, x(i))
  end do
end subroutine

! How many of `x` the predicate `p` holds for: a callback with a `logical` result.
subroutine fcount_if(p, n, x, k)
  logical, external :: p
  integer n, k, i
  double precision x(n)
  k = 0
  do i = 1, n
    if (p(x(i))) k = k + 1
  end do
end subroutine

! A callback that returns nothing, called once per element with a `complex(8)` and a `logical`.
subroutine feach(s, n, z)
  external s
  integer n, i
  complex(8) z(n)
  do i = 1, n
    call s(z(i), mod(i, 2) == 0)
  end do
end subroutine
