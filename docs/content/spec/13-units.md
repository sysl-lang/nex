---
title: Units of Measure
summary: Units on reals and complex numbers — declaring them, spelling them, arithmetic and conversion between scales, prelude functions, generic units, linear algebra, C calls, cost, and the prelude's SI and US customary units.
weight: 125
---

A real or complex value may carry a **unit of measure**. The compiler follows units through every
expression and rejects a program that adds a length to a force or stores a pressure where a length
belongs. Units exist only at compile time: a program with units compiles to the same machine code
as the same program without them.

```nex
def main() =
  val g = 9.81<m/s^2>
  val v0 = 20.0<m/s>
  val theta = 0.6<rad>
  val range = v0^2 * sin(2.0 * theta) / g     // real<m>
  val height = v0^2 * sin(theta)^2 / (2.0 * g) // real<m>
  print(range)
  print(height + 1.5<ft>)                      // adds in metres: the left operand's unit
```

## 13.1 Declaring units

```nex
unit m                          // a base unit: a dimension of its own
unit N = kg m / s^2             // a derived unit
unit in = 0.0254 m              // a scaled unit: an exact factor times a unit
unit ft = 12 in
unit lbf = 4.4482216152605 N
unit psi = lbf / in^2
```

A `unit` declaration stands at the top level of a file, beside `def` and `const`. The prelude
already declares the common SI and US customary units (§13.9), so most programs declare none.

**A unit expression** is made of unit names and `1`:

- juxtaposition multiplies: `kg m`, `N m`;
- `/` divides: `m / s`, `lbf / in^2`;
- `^` raises to a constant power: an integer, which may be negative (`s^-1`), or a rational in
  parentheses (`m^(1/2)`).

`^` binds tightest, juxtaposition next, and `/` loosest, left to right; parentheses group. So
`kg m / s^2` is (kg·m)/s², and `J / kg K` is J/(kg·K).

**Base, derived and scaled.** `unit m` makes a new base unit, a dimension of its own. `unit N = kg m
/ s^2` gives a name to a unit expression. `unit in = 0.0254 m` is a positive number times a unit,
and the number is **exact**: `0.0254` means exactly 254/10000, and factors multiply exactly, so `ft`
is exactly 0.3048 m with no rounding along the way.

**When two units are the same.** Two units are the same when they come down to the same powers of
the same base units with the same factor. `N` and `kg m / s^2` are one unit; `Hz` and `1 / s` are
one; `J` and `N m` are one, as in SI, so torque and energy are not told apart. `mm` and `m` have the
same **dimension**, length, but different factors: they are different units that convert into each
other (§13.3).

**Unit names have their own namespace.** They appear only inside `<…>`, in `unit` declarations and
directly after a numeric literal (`10mm`, §13.2), so a variable called `m`, `s` or `g` never clashes
with a unit, and `in`, a keyword elsewhere, is an ordinary unit name there (`2.0<in>`, `2in`). Spacing matters: `ms` is the millisecond, `m s` the
metre-second.

`unit` is a keyword, so it is no variable's name and no type's: the type whose only value is `()`
is `void` ([Types](/spec/03-types/)), and `def f(): unit` is an error that suggests it.

## 13.2 Spelling a unit

| Where | Example |
|---|---|
| a literal | `9.81<m/s^2>`, `2.0<in>`, `1.0e5<Pa>` |
| a literal in one unit, shorthand | `10mm`, `2.5in`, `1e5Pa`, `-3mm` |
| a real type | `real<m>`, `real32<m/s>`, `real16<Pa>` |
| a complex type | `complex<V>`, `complex[real32]<ohm>` |
| an array type | `[real<m>; :, :]`, `[real32<Pa>; 3, 3]`, `[complex<V>]` |
| dimensionless | `<1>`: `real<1>` is `real` |

The `<` follows the end of an operand directly, with no space — a literal, a name, a `]` or a `)`
— and two more things must hold for it to open a unit:

- the text after it up to a `>` on the same line is valid unit syntax, and
- **the annotation ends the operand**: what follows the `>` cannot begin an operand. It is a binary
  operator (a `-` counts as one), `)`, `]`, `}`, `,`, `=`, `then`, `do`, `else`, a comment or the end
  of the line. A `(` against the `>` is a call on the annotated operand, as in `to<mm>(x)`.

Otherwise, or after a space, `<` is the comparison: `x<y`, `1<x` and `2 < x` compare, while `2<x>`
is the literal 2 with unit `x`.

**`<unit>` is a postfix operator on any operand**, at the level of a call `(…)` and a subscript
`[…]`. It binds tighter than `^`, unary minus, juxtaposition and every binary operator, and chains
left to right with the other postfixes: `x[i]<m>`, `f(x)<m>`, `to<mm>(x)`.

| Written | Read as |
|---|---|
| `9.81<m/s^2> * t` | a unit, then `*` |
| `f(2.0<in>)` | a unit |
| `0<x>1` | comparisons: `1` begins an operand |
| `lo<x<hi` | comparisons |
| `a<b>-c` | `a` in unit `b`, minus `c` |
| `2 * 3.0<m>` | `2 * (3.0<m>)` |
| `3.0<m>^2` | `(3.0<m>)^2` |
| `-3.0<m>` | `-(3.0<m>)` |
| `2pi<rad>` | `2 * (pi<rad>)` |
| `(a + b)<m>`, `strip(y)<m>` | a unit on the parenthesised operand, on the call |
| `if x<m> then …` | a unit: `then` cannot begin an operand |

**A unit's name written directly against a decimal literal, with no space, is that literal in that
unit**: `10mm` is `10<mm>`, `2.5in` is `2.5<in>`, and `1e5Pa` — the exponent first, then the unit —
is `1e5<Pa>`. It is one operand and reads as the bracketed form does: `-10mm` is `-(10mm)`, `10mm^2`
is `(10mm)^2`, and `0mm < x < 1cm` is a chained comparison.

- **One name is the whole unit.** A compound unit is bracketed, `9.81<m/s^2>`; in `9.81m/s^2` the
  `s` is a value, divided by. A bracket after the name, `10mm<in>`, is a compile error.
- **The name is a unit's when the program has one by that name**: the prelude's or one a `unit`
  declaration makes in any module. Any other name is what the literal multiplies, so `2x`, `2pi` and
  `2i` are products as before.
- **The unit wins over a value of the same name**: with a local `m`, `3m` is three metres, and
  `3 * m` multiplies by the local.
- **Only a decimal literal takes one**, since a hex literal's digits may be letters (`0x10cd` is one
  number): write `0x10<mm>`.

An annotation attaches a unit to a **dimensionless** operand. One written on an operand that
already carries a unit is a compile error, which points to `to<u>(x)`: that is how a value changes
unit.

Plain `real` is dimensionless, and so is a literal written without a unit. A unit can be attached to
a real or complex type of any width; integers count things and carry no unit, and an integer
literal written with a unit is a real (`12<in>` is `12.0<in>`). A literal with a unit takes its
width from its context as any literal does: beside a `real32<m>`, `9.81<m/s^2>` is a
`real32<m/s^2>`.

{{< note >}}
Restricting units to real and complex types may change.
{{< /note >}}

## 13.3 Arithmetic and conversion

**`+`, `-` and comparisons need the same dimension.**

- Two values of the **same unit** add as plain numbers.
- Two values of the **same dimension and different scales** are converted to the **left operand's
  unit**, with the conversion factor computed at compile time:

  ```nex
  val gap = 10.0<mm> + 1.0<in>     // 35.4<mm>
  val fits = 1.0<ft> > 300.0<mm>   // true: compared in feet
  ```

- Two values of **different dimensions** never mix:

  ```nex
  val bad = 1.0<in> + 1.0<lbf>     // error: cannot add in and lbf: length and force are different dimensions
  ```

**`*` and `/` combine units.** `3.0<m> / 2.0<s>` is a `real<m/s>`, and `2.0 * x` has the unit of
`x`. A product keeps the names it was made of: `1.0<mm> * 1.0<in>` is a `real<mm in>`, an area.

**`^` takes a constant exponent** on a value with a unit: `x^2` is `real<m^2>` for `x: real<m>`,
and a rational power is allowed (`real<m^(1/2)>`). A power whose exponent is not known at compile
time needs a dimensionless base.

**A literal without a unit is dimensionless**, so it does not combine with a length by `+` or `<`:

```nex
val x = 2.0<m>
val y = x + 1.0                    // error: cannot add m and a dimensionless value; write 1.0<m>
val z = x + 1.0<m>                 // 3.0<m>
val positive = x > 0.0<m>
```

**A declared type converts.** A value bound, passed, returned or assigned to a place whose unit has
the same dimension and another scale is converted to that unit; a different dimension is a compile
error:

```nex
val d: real<mm> = 1.0<in>          // 25.4<mm>
val w: real<kg> = 1.0<m>           // error: a real<m> cannot be stored in a real<kg>: length is not mass
```

{{< note >}}
Conversion at a declared type may change.
{{< /note >}}

**`to<u>(x)`** converts explicitly, on a scalar or element by element on an array:
`to<mm>(1.0<in>)` is `25.4<mm>`. Converting to a unit of another dimension is a compile error.

**`strip(x)`** removes the unit and gives the number in `x`'s own unit: `strip(25.4<mm>)` is
`25.4`, and `strip(to<m>(d))` is a length in metres. On an array, `strip` is a view of the same
elements and copies nothing. To give a plain number a unit, multiply: `y * 1.0<m>`.

**An angle is a kind of unit.** `rad`, `deg`, `turn`, `arcmin`, `arcsec` and `sr` convert among
themselves like lengths do (`90.0<deg> + 0.5<rad>` is a `real<deg>`), but a plain number is not an
angle: `theta + 0.5`, `theta > 0.0` and `rotate(part, 30)` for a parameter `real<rad>` do not
compile; write `30<deg>` or `0.5<rad>`. Where an angle meets another dimension in `*` or `/` it
drops out, in radians: `2.0<m> * 30.0<deg>` is a `real<m>`, and `theta / t` a `real<1/s>`. An
angle times a plain number stays an angle, and an angle over an angle is a plain number. `rad/s`
and `1/s` are one dimension, so `omega: real<rad/s>` holds `theta / t`, and `omega * t` is an angle.

## 13.4 Units through the prelude

- `sqrt` halves every power: the square root of a `real<m^2>` is a `real<m>`.
- `abs`, `conj`, `floor`, `ceil`, `round`, `trunc`, `min`, `max`, `minval`, `maxval`, `sum` and
  `norm2` keep the unit. `min`, `max` and `hypot` convert their second argument as `+` does.
- `atan2(y, x)` takes two values of one dimension and gives a plain number, in radians.
- `sin`, `cos` and `tan` take an angle in any angle unit (`sin(30.0<deg>)`), or a plain number,
  which is radians.
- `exp`, `log`, `asin`, `acos`, `atan` and the other elementary functions take and return
  dimensionless values; an angle is not one. The inverse functions return radians as a plain
  number: `asin(x) * 1.0<rad>` makes it an angle.
- `product(a)` has `a`'s unit to the power of its length, so an `a` that carries a unit needs a
  static extent.
- `print` and string interpolation show the unit after the number, separated by a space:

  ```nex
  val g = 9.81<m/s^2>
  print(g)                         // 9.81 m/s^2
  print(8.314<J/(mol K)>)          // 8.314 J/(mol K)
  ```

  An array prints its elements and then its unit once.

{{< note >}}
The units of `product`, and the printing of arrays with units, may change.
{{< /note >}}

## 13.5 Generic units

A generic parameter bounded by `Unit` stands for any unit:

```nex
def sqr[U: Unit](x: real<U>) = x * x                   // real<U^2>

def mean[U: Unit](a: [real<U>]) = sum(a) / length(a)   // real<U>
```

`sqr(3.0<m>)` is `9.0<m^2>` and `sqr(2.0<s>)` is `4.0<s^2>`. The unit is inferred from the argument.
Because units vanish before code is generated, both calls run the same compiled function.

## 13.6 Linear algebra

Every element of an array carries the array's one unit. A matrix whose columns have different
units (a state vector of positions and velocities, say) is held without units.

| Operation | Unit of the result |
|---|---|
| `A @ x`, `A @ B`, `dot(x, y)` | the product of the two units |
| `sum(a)`, `norm2(a)` | `a`'s unit |
| `solve(A, b)`, `lstsq(A, b)` | `b`'s unit divided by `A`'s |
| `inv(A)` | one over `A`'s unit |
| `det(A)` | `A`'s unit to the power n; a static extent n is needed |
| `eigvals`, `eigh` values, `svdvals`; the `R` of `qr`, the `U` of `lu`, the `s` of `svd` | `A`'s unit, the other factors dimensionless |
| `chol(A)` | the square root of `A`'s unit |

A stiffness matrix in `N/m` and a load vector in `N` give displacements in metres:

```nex
def main() =
  val K = [[ 2.0e6, -1.0e6],
           [-1.0e6,  1.0e6]] * 1.0<N/m>
  val f = [0.0, 500.0] * 1.0<N>
  val u = solve(K, f)              // [real<m>]
  print(to<mm>(u))
```

{{< note >}}
The units of `inv`, `det` and the factorizations may change.
{{< /note >}}

## 13.7 Calling C and Fortran

C and Fortran know nothing of units, so an `extern` parameter never carries one. Passing a value
with a unit to an `extern` is a compile error that suggests `strip`; a result gets its unit back by
multiplying:

```nex
@link("m")
extern def cbrt(x: real): real

val v = 8.0<m^3>
val side = cbrt(strip(v)) * 1.0<m>   // 2.0<m>
```

`strip` of an array is a view, so passing it to BLAS or LAPACK copies nothing. A nex function passed
to C as a callback has parameters and a result without units, for the same reason.

## 13.8 Cost

Units are checked by the compiler and then removed, before any code is generated. A program that
never mixes scales runs exactly the code it would without units. Mixing scales costs one
multiplication by a constant: the conversion factor, worked out exactly at compile time and rounded
once to the operand's precision, which is the same single rounding a conversion written by hand
makes.

## 13.9 The prelude's units

| Units | Definitions |
|---|---|
| SI base | `m` `kg` `s` `A` `K` `mol` `cd` |
| SI derived | `N = kg m / s^2`, `J = N m`, `W = J / s`, `Pa = N / m^2`, `Hz = 1 / s`, `C = A s`, `V = W / A`, `ohm = V / A` |
| Angle | `rad` (a base unit), `sr = rad^2`, `deg = π/180 rad`, `turn = 2π rad`, `arcmin = deg / 60`, `arcsec = arcmin / 60` |
| SI scaled | `mm = 0.001 m`, `cm = 0.01 m`, `km = 1000 m`, `g = 0.001 kg`, `ms = 0.001 s`, `us = 0.000001 s`, `ns = 0.000000001 s`, `kPa = 1000 Pa`, `MPa = 1000000 Pa`, `GPa = 1000000000 Pa`, `kN = 1000 N`, `kJ = 1000 J`, `kW = 1000 W` |
| Imperial and US customary | `in = 0.0254 m`, `ft = 12 in`, `yd = 3 ft`, `mi = 5280 ft`, `lb = 0.45359237 kg`, `oz = 0.0625 lb`, `lbf = 4.4482216152605 N`, `slug = lbf s^2 / ft`, `psi = lbf / in^2`, `ksi = 1000 psi`, `BTU = 1055.05585262 J`, `hp = 550 ft lbf / s`, `usgal = 231 in^3`, `ukgal = 0.00454609 m^3` |

The inch, pound and pound-force are the international definitions; `lbf` is a pound under standard
gravity (9.80665 m/s²), `BTU` is the International Table BTU and `hp` the mechanical horsepower.
**There is no `gal`**: the US and UK gallons differ by about a fifth, so a program says which.
Temperatures are in kelvin, `K`; Celsius and Fahrenheit are not yet units (see
[Later](/spec/appendix-later/)).

## 13.10 A worked example: a cantilever beam

The tip deflection of a cantilever of length L, carrying a point load F at its end, is
δ = F L³ / (3 E I), with E the modulus of the material and I the second moment of area of the
section:

```nex
def tip_deflection(F: real<N>, L: real<m>, E: real<Pa>, I: real<m^4>): real<m> =
  F * L^3 / (3.0 * E * I)

def main() =
  val F = 2.0<kN>
  val L = 1.5<m>
  val E = 200.0<GPa>                         // steel
  val I = 8.0e-6<m^4>
  print(to<mm>(tip_deflection(F, L, E, I)))  // 1.40625 mm
```

`F` is in kilonewtons and `E` in gigapascals; each converts to the parameter's unit at the call.
Two slips the compiler catches:

```nex
val S = 5.33e-5<m^3>                         // the section modulus, not I
val d = tip_deflection(F, L, E, S)
// error: argument I of tip_deflection is a real<m^4>; a real<m^3> was given

val d2: real<m> = F * L^2 / (3.0 * E * I)
// error: a dimensionless value cannot be stored in a real<m>
```

In Fortran both programs compile, run, and print a wrong number.
