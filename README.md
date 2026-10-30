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

## Layout

The repository is a sysl workspace of four projects:

- **the library `nex`** at the root (`sh/sysl/nex/`, module `sh.sysl.nex`): the front end both
  engines share — lexer, parser, elaborator and its checks, typed IR, units of measure, the module
  loader. `load` and `load_source` in `nex.sysl` take a source to a typed program or its
  diagnostics. A sysl program depends on it as `github.com/sysl-lang/nex`.
- **`compiler/`**, the `nex` command: the MLIR emitter, the driver that lowers and links a program,
  and `nex test`'s runner.
- **`runtime/`**, the archive every compiled program links.
- **`examples/embed/`**, a sysl program hosting a nex script (below).

```
sysl build compiler -o nex
sysl build-c runtime -o libnex_rt.a
sysl test .
```

`nex` finds `libnex_rt.a` beside itself, or at `NEX_RUNTIME`. Compiling needs LLVM's `mlir-opt`,
`mlir-translate` and `clang`, found at `NEX_LLVM_HOME` or else Homebrew's `opt/llvm`; without them
the toolchain tests skip.

## Embedding

A sysl program runs nex scripts on the library's interpreter, with no toolchain (DESIGN §16): it
loads a script, calls its functions by name with values, reads and writes its module-level
bindings, and gives it functions and types of its own. A diagnostic, a trap and a value all come
back as values; nothing is printed but what the script prints, and that goes to the host's `write`.

```sysl
import nex.sh.sysl.nex.*

var host = new_host()
val solid = host.give_type("Solid", (id) -> kernel.release(id))

host.give("box", (args) -> Ok(solid.handle(kernel.make_box(args))))

load_script(text, "model.nex", host) match
    Ok(script) -> script.call("build", given) match
        Ok(volume) -> ...
        Err(e) -> eprints(e.text())
    Err(ds) -> for d in ds
        eprints(d.text)
```

```nex
@host struct Solid
@host extern def box(w: real<mm>, h: real<mm>, d: real<mm>): Solid

def build(width: real<in>, count: integer) = ...
```

A host function is handed its arguments in the units its declaration names, an array as one typed
buffer, and a host type's object is reference counted, its `release` called when nex and the host
have both let go. A step budget and `cancel()` stop a runaway script, and a sandboxed script may
not `stop`. `examples/embed/` is a whole host; `sysl build examples/embed -o embed` builds it.

## Licence

ISC, as the reference implementation is — see [LICENSE](LICENSE).
