# nex

A modern, AOT-compiled, array-first numerical programming language: Fortran's heritage — built-in
complex numbers and matrices, IEEE 754 throughout, AOT performance — with modern syntax: Scala
3-style indentation, expression-oriented, math-flavoured juxtaposition (`2pi`, `4a*c`,
`3sin(2pi*t)`), and array expressions that compile to fused loops with no intermediate temporaries.

```nex
def normalize(v: [real]) =
  val mag = sqrt(sum(v * v))
  if mag == 0.0 then v
  else v / mag
```

**This is the sysl implementation of nex**, written from scratch with an MLIR backend. The reference
implementation is the Scala 3 one at [edadma/nex](https://github.com/edadma/nex), whose
`docs/content/spec/` is the language specification; where this one and the reference disagree, the
reference is right until the specification says otherwise. The architecture and milestones are in
[PLAN.md](PLAN.md).

## Status

The port has started: what exists is the command's skeleton and the oracle. `testdata/corpus/`
holds the reference's program corpus — 425 programs, each beside the exact output it must print —
and six more for units of measure, and every milestone of the port is measured against it.

```
sysl build .
sysl test .
```

Compiling needs LLVM's `mlir-opt`, `mlir-translate` and `clang`, found at `NEX_LLVM_HOME` or else
Homebrew's `opt/llvm`; without them the toolchain tests skip.

## Licence

ISC, as the reference implementation is — see [LICENSE](LICENSE).
