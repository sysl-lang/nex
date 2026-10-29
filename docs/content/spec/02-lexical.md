---
title: Lexical Structure
summary: Source files and literate sources, indentation and end markers, comments, identifiers, keywords, literals and operators.
weight: 20
---

## 2.1 Source files

A nex source file is UTF-8 text with the extension `.nex`. A file with the extension `.lnex` is a
**literate source** (§2.2): a Markdown document whose indented blocks are the program. Whether a file
is literate is decided by its extension alone. A module may mix `.nex` and `.lnex` files freely
([chapter 9](/spec/09-modules/)).

Unlike Fortran, nex has no fixed form and no line-length limit, and it is case-sensitive: `X` and
`x` are different names.

## 2.2 Literate sources

A `.lnex` file is read as Markdown. The compiler extracts the program from it before lexing, and
every other rule in this specification applies to the extracted text exactly as to a `.nex` file.

- **Code lines** are indented by at least four spaces. Exactly four spaces are removed; any
  indentation beyond them is the program's own, so nex's indented blocks work normally inside a
  literate file.
- **A tab in the indentation of a code line is a compile error.** Indent code with spaces.
- **Prose** is every other line: headings, paragraphs, lists, links, mathematics. A line indented by
  one to three spaces is prose.
- **An indented block that continues a Markdown list item is prose**, not code, as Markdown itself
  reads it. To start code after a list, end the list with an ordinary paragraph first.
- **A fenced block** (between ` ``` ` lines) is not code. Use it for sample output, diagrams or
  data; the fences and everything between them are dropped.
- **Line ends are normalized**: a CRLF line end is read as LF.

Prose and fenced lines are replaced by blank lines rather than removed, so a line number in a
compiler message is the line number in the `.lnex` document.

````markdown
# Kinetic energy

The kinetic energy of a particle of mass $m$ and speed $v$ is $\frac12 m v^2$.

    def kinetic(m: real, v: real): real = 0.5 * m * v^2

    def main() =
        print(kinetic(2.0, 3.0))

Running it prints:

```
9.0
```
````

The program in this document is the two indented blocks, with their first four spaces removed.

## 2.3 Lines and indentation

nex is indentation-based. A block is a sequence of lines indented further than the line that opens
it, and it ends at the first line indented no further than that opening line (the *off-side rule*).
A block is opened by a line that ends with:

- `=` in a `def`, `val` or `var`;
- `then` or `else` in an `if`;
- the header of a `for` or `while` (no `do`: `do` introduces only a body on the same line);
- `->` in a function literal or a `match` arm;
- `match` after its scrutinee.

The `if` and the loops also have one-line forms (`if x > 0 then x else -x`,
`for k in 1..n do s += k`); see [chapter 7](/spec/07-control-flow/).

```nex
def normalize(v: [real]): [real] =
  val mag = sqrt(sum(v * v))
  if mag == 0.0 then
    v
  else
    v / mag
```

Indentation is made of spaces. The convention is two spaces per level.

**Statements.** A statement ends at the end of its line. Two statements may share a line separated by
`;`. A statement continues onto the next line when its line ends with a binary operator, or while a
`(` or `[` is open; inside brackets the off-side rule is suspended, so an array literal or an argument
list may be laid out freely:

```nex
val x = 1; val y = 2

val energy = kinetic(m1, v1) +
  kinetic(m2, v2)

val m = [[1.0, 2.0, 3.0],
         [4.0, 5.0, 6.0]]
```

This replaces Fortran's `&` continuation: no marker is needed.

## 2.4 End markers and the two roles of `end`

Any indented block may be closed by an optional **end marker**: the word `end`, optionally followed
by the keyword of the construct it closes or, for a `def`, `struct` or `enum`, by its name. A marker
never changes the meaning of a program; it is there for the reader of a long block, as Fortran's
`end do` and `end if` are.

```nex
def normalize(v: [real]): [real] =
  val mag = sqrt(sum(v * v))
  if mag == 0.0 then
    v
  else
    v / mag
  end if
end normalize
```

Inside a subscript, `end` is something else: **the last index of the axis being indexed**
([chapter 4](/spec/04-arrays/)).

```nex
a[end]          // the last element
a[2..end-1]     // the interior, Fortran's a(2:n-1)
m[:, end]       // the last column
```

The compiler tells the two apart by position:

- `end` as the **first word of a line, outside any brackets**, is an end marker;
- `end` **inside brackets**, or anywhere other than the start of a line, is an index expression.
  It must then be inside a subscript list: `end` inside an array literal, in a `for` header or as an
  ordinary value (`val n = end`) is a compile error.

A subscript continued onto a new line that begins with `end` (`a[1,` then `end]` on the next line) is
inside brackets, so it is the index. No end marker can stand inside brackets, so the rule never
misreads a program.

## 2.5 Comments

A line comment starts with `//` and runs to the end of the line. A block comment is `/* … */`, and
block comments nest.

```nex
// a line comment

/* a block comment
   over several lines */

/* an outer /* nested */ comment */
```

`!` does not start a comment as it does in Fortran.

## 2.6 Identifiers

An identifier starts with an ASCII letter or an underscore and continues with ASCII letters, digits
and underscores:

```
identifier ::= (letter | '_') (letter | digit | '_')*
letter     ::= 'a'..'z' | 'A'..'Z'
digit      ::= '0'..'9'
```

A lone `_` is not a name: it is the placeholder that discards a value in a pattern or a
destructuring binding.

## 2.7 Keywords

These words are reserved and cannot be used as identifiers:

```
and       as        const     cycle     def       div       do
else      end       enum      exit      extern    false     for
if        import    in        inout     match     module    mut
not       or        parallel  private   return    stop      struct
then      true      val       var       while
```

`mut` is reserved and has no meaning; a parameter that the callee may modify is `inout`.

These words are reserved for future use:

```
class     extends   given     implicit  package
pub       trait     type      where     yield
```

**Contextual words** are keywords only in one position and ordinary names everywhere else:

- `by` introduces the step of a range, in a subscript or anywhere else: `a[1..n by 2]`,
  `for k in n..1 by -1`.
- `reduce` introduces the reduction clause of a `parallel for`
  ([chapter 10](/spec/10-parallelism/)). Everywhere else `reduce` is the prelude function of that
  name.
- `unit` followed by a name at the start of a top-level declaration declares a unit of measure
  (`unit ft = 12 in`, [chapter 13](/spec/13-units/)). Everywhere else `unit` is the type.

**Units of measure** are written in angle brackets directly after an operand, with no space: after
a numeric literal, a name, a `]` or a `)` — `9.81<m/s^2>`, `real<mm>`, `x[i]<m>`, `(a + b)<m>`.
Inside the brackets, names are unit names, so `in` is the inch there. **A unit annotation must end
its operand**: a glued `<` is a unit bracket only when unit syntax and a `>` follow on the same line
*and* what follows that `>` cannot begin an operand — a binary operator (a `-` counts as one), `)`,
`]`, `}`, `,`, `=`, `then`, `do`, `else`, a comment or the end of the line. A `(` against the `>` is
a call on the annotated operand, as in `to<mm>(x)`. Otherwise, or after a space, `<` is the
comparison: `1<x`, `0<x>1` and `lo<x<hi` compare, and `a<b>-c` is `a` in unit `b`, minus `c`.

**Type names are not keywords.** `integer`, `real`, `complex`, `int8` … `int64`, `uint8` …
`uint64`, `real16`, `real32`, `real64`, `bool`, `string` and `unit` are names the prelude defines
([chapter 3](/spec/03-types/)), and `bfloat16` is reserved as a type name. Nor are `pi`, `e`, `inf`,
`nan` and `i`: they are prelude constants and may be shadowed (§2.8).

## 2.8 Literals

**Booleans**: `true` and `false`.

**Integers**: decimal, hexadecimal with `0x`, binary with `0b`, or octal with `0o`. An underscore
may separate digits.

```nex
42
1_000_000
0xFF
0b1010_1010
0o755
```

**Reals** have a fractional part, an exponent, or both. The exponent letter is `e` (or `E`); there
is no `d` exponent, because a real literal is not tied to a precision (see below).

```nex
3.14
1.0
2.5e-3
6.022e23
1_234.567_89
```

**A numeric literal has no kind suffix**, unlike Fortran's `1.0_real32` or `1.0d0`. Its type comes
from where it is used: in `x * 2.0` with `x: real32` the literal is a `real32`, and in
`val n: int16 = 300` the literal is an `int16`. With nothing to adapt to, an integer literal is an
`integer` (64-bit) and a real literal is a `real` (64-bit). The rules are in
[§3.7](/spec/03-types/).

**Juxtaposition.** A numeric literal immediately followed by a name or an opening parenthesis is
multiplied by it, as in written mathematics:

```nex
2x            // 2 * x
2pi           // 2 * pi
4a*c          // (4 * a) * c
2(x + 1)      // 2 * (x + 1)
3sin(t)       // 3 * sin(t)
```

The rule applies only when the left side is a numeric literal: `xy` is the name `xy`, and `(a)(b)`
is a call. Juxtaposition binds tighter than `*` and `/` and looser than `^`, which is how the
mathematics reads: `2x^3` is `2 * x^3`, and `1/2x` is `1 / (2 * x)`. This is also why a literal can
carry no suffix: `1.0f32` would read as `1.0 * f32`.

**The imaginary unit.** nex has no complex literal token. `i` is a prelude constant, the imaginary
unit, and a complex value is written with ordinary arithmetic and juxtaposition:

```nex
2i                 // 0.0+2.0i
3.0 + 4.5i         // 3.0+4.5i
exp(pi * i)        // -1.0+0.0i, to rounding
```

Because `i` is an ordinary name, **any binding named `i` shadows the unit within its scope**, and
juxtaposition then multiplies by whatever `i` names:

```nex
val z = 3 + 2i            // 3.0+2.0i: i is the imaginary unit
for i in 1..3
  print(2i)               // 2, 4, 6: i is the loop index, so 2i is 2 * i, an integer
print(2i)                 // 0.0+2.0i: the loop's i is out of scope again
```

This is deliberate: `i` is the most common loop index in numerical code and is not worth a reserved
word. Inside a scope that binds `i`, name the unit some other way (`val im = i` taken outside the
scope, or `complex(0.0, 1.0)`), or name the index `j`, `k`, `m` or `n`.

**Strings** are double-quoted, with the escapes `\n`, `\t`, `\r`, `\\`, `\"`, `\x41` and
`\u{1F600}`:

```nex
"hello, world"
"line one\nline two"
```

**Interpolated strings** start with `s`. `$name` inserts the value of a binding and `${expression}`
the value of any expression, each in the form `print` would show; `$$` is a literal `$`.

```nex
s"n = $n"
s"x + y = ${x + y}"
s"last = ${a[end]}"
s"cost: $$$price"
```

`$name.field` inserts `name` followed by the text `.field`; write `${name.field}` to insert the
field.

**Unit**: `()`, the one value of type `unit`.

**Array literals** are bracketed lists, nested once per axis: `[1.0, 2.0, 3.0]`,
`[[1, 2], [3, 4]]`. Their shape and storage order are in [chapter 4](/spec/04-arrays/).

## 2.9 Operators and punctuation

Operators, from the most tightly binding to the least:

| Level | Operators | Associativity | Meaning |
|---|---|---|---|
| 1 | `.` | left | field access |
| 2 | `f(…)`, `a[…]`, `x<unit>` | left | call, subscript, unit annotation |
| 3 | `^` | right | power (Fortran's `**`) |
| 4 | unary `-`, `not` | right | negation |
| 5 | juxtaposition | left | `2x`, `2pi`, `2(x + 1)` |
| 6 | `*`, `/`, `div`, `%`, `@` | left | product, quotient, integer quotient, remainder, matrix product |
| 7 | `+`, `-` | left | sum, difference |
| 8 | `..`, `..<` | left | ranges |
| 9 | `==`, `!=`, `<`, `<=`, `>`, `>=` | chained | comparison |
| 10 | `and` | left | logical and |
| 11 | `or` | left | logical or |
| 12 | `->` | right | function literal, function type |
| 13 | `,` | right | tuple |

Comparisons chain: `0 <= k < n` means `0 <= k and k < n`, with `k` evaluated once.

`^` binds tighter than unary minus, so `-x^2` is `-(x^2)`, as in mathematics and as Fortran's
`-x**2` is; write `(-x)^2` for the square of the negation. `^` is right-associative: `2^3^2` is
`2^(3^2)`, which is 512. An exponent may itself be negated: `x^-1` is `x^(-1)`. The power operator is
`^` only; there is no `**`.

**Ranges.** `lo..hi` is the **inclusive** range from `lo` to `hi`, Fortran's `lo:hi`: `1..n` has
`n` elements and `for k in 1..n` runs `n` times. `lo..<hi` is the **half-open** range that stops
before `hi`. A range is a value that can be bound to a name and passed like any other, and the same
forms serve `for` headers and subscripts. There is no `range()` function and no `..=` operator;
`a..=b` is a syntax error. In a subscript a bound may be left out (`a[k..]`, `a[..<k]`), and `by`
adds a stride (`a[1..n by 2]`); see [chapter 4](/spec/04-arrays/).

**`@`** between two operands is the matrix product, Fortran's `matmul`
([chapter 5](/spec/05-array-expressions/)). At the start of a declaration, `@` introduces an
annotation such as `@link(…)` or `@fortran` ([chapter 11](/spec/11-interop/)).

**`div` and `%`.** `div` is integer division truncating toward zero, and `%` the remainder with the
sign of the dividend (Fortran's `mod`). `//` is not division: it begins a comment.

**Assignment** is `=`, with the compound forms `+=`, `-=`, `*=`, `/=` and `%=`. Assignment is a
statement, not an expression.

**Other punctuation**: `:` before a type and as a whole-axis subscript, `;` between statements and
before the axes of an array type (`[real; :, :]`), `( )` for grouping, calls and tuples, `[ ]` for
arrays, subscripts and type arguments, and `_` as a placeholder.
