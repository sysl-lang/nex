---
title: Modules
summary: A module is a directory; selective imports, public-by-default visibility, the program's main, test functions and test modules, and the implicit prelude.
weight: 90
---

A nex program is a tree of source files. Each directory is a **module**, a file names what it uses
from other modules with `import`, and the prelude is in scope everywhere without one. The compiler
reads source only: there are no interface files to build first.

## 9.1 A module is a directory

All the `.nex` files in one directory belong to the same module, and a subdirectory is a submodule.
The module's name is its directory's path from the project root, with `/` written as `.`:

```text
src/
  linalg/
    dense/
      types.nex        ┐
      arith.nex        ├ module linalg.dense
      decompose.nex    ┘
    sparse/
      csr.nex          — module linalg.sparse
  main.nex             — the root module
```

The files of one module share one namespace: a declaration in any of them is visible in all of them,
with no import, whether it is public or `private` (§9.4). How a module's code is split across files
is a matter of reading convenience and changes nothing else.

**For a Fortran programmer**: a nex module plays the part of a Fortran `module`, but it is a
directory rather than one program unit in one file, so a large module needs no `submodule` to be
split across files. There is no separate `program` unit; the program starts at `main` (§9.5).

## 9.2 The `module` declaration

A file may name its module on its first line:

```nex
module linalg.dense

def add(a: [real; :, :], b: [real; :, :]) = a + b
```

The declaration is optional. When it is present it must agree with the file's directory, and a
mismatch is a compile error; when it is absent, the directory alone decides. Writing it is
recommended in a large tree, where it tells a reader which module a file is in without looking at
its path.

## 9.3 Imports

`import` brings names from another module into a file. The names are listed; `as` gives one a local
name:

```nex
import linalg.dense.{lu, solve}
import linalg.sparse.{CsrMatrix, matvec as spmv}
import linalg.dense as dense
```

The last line binds the module itself to a short name, through which its public names are reached
(`dense.lu(a)`).

- **An import lists its names.** `import linalg.dense` on its own, bringing in everything, is not
  allowed. Every name a file uses from elsewhere can be traced to the line that brought it in.
- **Imports come at the top of a file**, after the `module` declaration if there is one.
- **An import is per file**, not per module: each file imports what it uses.
- **There is no build order to write down.** The compiler works it out from the import graph.

| Fortran | nex |
|---|---|
| `use linalg_dense, only: lu, solve` | `import linalg.dense.{lu, solve}` |
| `use linalg_sparse, only: spmv => matvec` | `import linalg.sparse.{matvec as spmv}` |
| `use linalg_dense` (everything) | not allowed — list the names |

Note the order of a rename: Fortran writes the local name first (`local => remote`), nex writes the
module's name first (`remote as local`).

## 9.4 Visibility: `private`

Every top-level declaration — a function, a struct, an enum, a constant — is **public** by default:
any module that imports it can use it. `private` restricts a declaration to its own module:

```nex
module geometry

def distance(p: Point, q: Point) = sqrt(dist2(p, q))       // public

private def dist2(p: Point, q: Point) =                     // geometry only
  (p.x - q.x)^2 + (p.y - q.y)^2
```

A `private` declaration is visible in **every file of its module** — the whole directory — and in
none outside it. An `import` naming a `private` declaration is a compile error.

Fortran's default is also public, and its `private` attribute means the same thing at the level of
one `module` unit. nex has no `public` keyword, since it would only restate the default.

## 9.5 The program: `main`

A program is the module tree reached from one source file, and it starts at that file's `main`:

```nex
import stats.{mean, stddev}

def main() =
  val data = linspace(0.0, 10.0, 101)
  print(s"mean = ${mean(data)}, sd = ${stddev(data)}")
```

`main` is declared in one of two forms, `def main()` or `def main(args: [string])`, and returns
`void`; any other signature is a compile error. `args` holds the command-line arguments the user
gave, without the program's name, and is 1-based like every array: `args[1]` is the first.

```nex
def main(args: [string]) =
  if length(args) != 1
    eprint("usage: heat <steps>")
    stop 2
  print(s"running ${args[1]} steps")
```

The top level of a source file holds only declarations — `import`, `const`, module-level `val` and
`var`, `def`, `struct`, `enum`, `extern` — and no statements; the work starts in `main`.

The program ends when `main` returns, with exit status 0, or at a `stop` statement: `stop` ends it
with status 0 and `stop n` with status `n` ([Control flow](/spec/07-control-flow/)). `print` writes
to standard output and `eprint` to standard error. A trap anywhere ends the program at once, with the
trap's message on standard error and a failing exit status.

nex is always compiled. `nex run main.nex` compiles the program to a native binary and runs it;
there is no interpreter, so what `nex run` runs is the native code itself.

## 9.6 Tests and `nex test`

A function marked `@test` is a unit test. It takes no arguments and returns `void`. It **passes** by
returning and **fails** by trapping, and the prelude's assertions — `assert`, `assert_eq`,
`assert_approx`, `assert_traps` — trap with a message saying what was expected:

```nex
module stats

def mean(xs: [real]) = sum(xs) / length(xs)

private def centred(xs: [real]) = xs - mean(xs)

@test
def test_mean_of_a_constant() =
  assert_approx(mean(fill(100, 7.0)), 7.0, 1e-12)

@test
def test_centred_sums_to_zero() =
  assert_approx(sum(centred([1.0, 2.0, 6.0])), 0.0, 1e-12)
```

A test written in a module sees everything in that module, `private` declarations included, so an
internal helper can be tested without making it public.

`nex test` finds every `@test` function in the project, compiles them and runs each one. It prints
one line for each failure, with the failure's message, then a summary of how many passed and failed.
A test that traps fails on its own; the others still run. `nex test <substring>` runs only the tests
whose names contain the substring ([Command Line](/tooling/01-cli/)).

Tests are left out of every other build: the binary `nex run` makes contains no test code.

### 9.6.1 Test modules

A whole module can be test-only: `@test` before its `module` declaration marks it so. Everything in
it, tests and the helpers they share, exists only in test builds:

```nex
@test module stats.checks

import stats.{mean, variance}

def constant_sample(n: integer, c: real) = fill(n, c)

@test
def test_mean_recovers_constants() =
  for n, c in [(10, 0.0), (100, 3.25), (1000, -7.5)]
    assert_approx(mean(constant_sample(n, c)), c, 1e-12)

@test
def test_variance_of_a_constant_is_zero() =
  assert_approx(variance(constant_sample(50, 2.0)), 0.0, 1e-12)
```

A test module imports from other modules like any module does, and so sees only their public
names. A test that needs a `private` helper belongs in that helper's own module (§9.6). A test module
may span several files, each beginning `@test module stats.checks`.

## 9.7 The prelude

The **prelude** is the set of names every module has without importing anything: the numeric type
names (`real`, `int32`, `complex[real64]`, …), the constants `pi`, `e`, `inf`, `nan` and `i`, the
mathematical functions, the array constructors, shape functions and reductions, linear algebra,
printing and the assertions. It is described in [The prelude](/spec/12-prelude/).

A module's own declaration, or an imported name, may reuse a prelude name; inside that module the
nearer name wins. So may a local binding, which is why a loop variable named `i` shadows the
imaginary unit inside its loop ([Control flow](/spec/07-control-flow/)).

{{< note >}}
The prelude is ordinary nex source shipped with the compiler, which locates it through the
`--prelude-path` option or the `NEX_HOME` environment variable. How it is installed and found may
change.
{{< /note >}}

## 9.8 No interface files

nex has no counterpart of Fortran's `.mod` files. The compiler reads every module of a program from
source, in an order it derives from the imports, so there is no build order to maintain by hand, no
stale interface file to delete, and no dependence on which compiler version wrote one.
