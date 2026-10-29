# Porting nex to sysl

The reference is the Scala 3 implementation at [edadma/nex](https://github.com/edadma/nex) (local
clone `~/dev/nex`, never modified by this port). Its `docs/content/spec/` is the language
specification and its tests are the acceptance criteria. This port exists to be a **stressor for
sysl**: a real compiler for a real numerical language, written in sysl, so every gap it meets is
reported to sysl first (org rule 9) rather than routed around here.

## The reference, phase by phase

Line counts are `wc -l` of `shared/src/main/scala/io/github/edadma/nex/` (comments included).
Main sources total about 27,000 lines; tests about 15,100.

| phase | files | lines |
|---|---|---|
| lexer + parser | `NexLexer` 369, `NexParser` 899, `NexAST` 379, `NexLiterate` 87 | 1,734 |
| elaborator + inference | `NexElaborator` 1,187, `NexElabInference` 921, `NexElabInferGenerics` 317, `NexElabInferPatterns` 266, `NexElabInferPrelude` 596, `NexElabLowering` 287, `NexElabState` 303, `NexTypedAST` 573 | 4,450 |
| lifetime (auto-clone, spec §8.3) | `NexLifetime` | 344 |
| monomorphize | `NexMonomorphize` | 965 |
| interpreter | `NexInterpreter` 317, `NexInterpEval` 965, `NexInterpArrays` 520, `NexInterpPrelude` 483 | 2,285 |
| fusion | `NexFusion` | 413 |
| LLVM backend | `NexLLVMCodegen` 1,156, `NexLLVMState` 1,051, `NexLLVMArrays` 1,218, `NexLLVMArrayPrelude` 879, `NexLLVMMatrixPrelude` 440, `NexLLVMControl` 627, `NexLLVMEnums` 501, `NexLLVMLambdas` 528, `NexLLVMPrelude` 457, `NexLLVMPrint` 415, `NexLLVMValueToString` 494, `NexLLVMAsserts` 368 | 8,134 |
| runtime preamble (LLVM IR text in Scala strings) | `NexLLVMPreamble` | 2,134 |
| MLIR backend | `NexMLIRCodegen` 1,552, `NexMLIRArrays` 1,267, `NexMLIRScalarControl` 1,223, `NexMLIRLambdas` 602, `NexMLIREnums` 438, `NexMLIRHOFs` 431, `NexMLIRStrings` 310 | 5,823 |
| prelude | `prelude/scalar.nex` 176, `NexIntrinsics` 51 | 227 |
| modules + sysroot | `NexModuleLoader` 162, `NexSysroot` 64 | 226 |
| CLI + platform | `Cli` 406, `platform` 54 | 460 |

The tests, by the phase they accept (`in {` cases per file):

| phase | test files (cases) |
|---|---|
| lexer + parser | `NexLexerTests` (45), `NexParserTests` (87), `NexParserPass2Tests` (66), `NexParserTupleTests` (28), `NexLiterateTests` (11) |
| elaborator | `NexElaboratorStage1Tests` (88), `Stage2` (129), `Stage3` (38) |
| interpreter | `NexProgramCorpus` (425 programs, through `NexCorpusInterpreterTests`), `NexInterpreterTests` (40: traps and elaboration errors, interpreter-only) |
| fusion | `NexFusionTests` (41) |
| LLVM | `NexLLVMBasics` (20), `ControlFlow` (14), `Loops` (10), `Strings` (6), `Aggregates` (27), `Lambdas` (13), `Arrays` (48), `Prelude` (56); and the corpus again, compiled and compared byte for byte with the interpreter |
| modules, prelude, runner | `NexModuleLoaderTests` (20), `NexSysrootTests` (3), `NexPreludeIntegrationTests` (4), `NexTestRunnerTests` (7) |

## The oracle

`testdata/corpus/` holds the reference's `NexProgramCorpus`: 425 programs as `NNN-<name>.nex`, each
beside `NNN-<name>.out`, the exact bytes it must print, with `index.tsv` giving each file's category,
name and whether the reference's MLIR backend covers it (348 do). The numbers keep the reference's
order, so a failure names the same case in both implementations.

**The expected outputs are stored in the reference, not computed**, so no run of the Scala
interpreter was needed. They were extracted by compiling `NexProgramCorpus.scala` itself, unchanged,
in a scratch sbt project with a dumper beside it, so every escape, `stripMargin` and `"true\n" * 15`
is evaluated by Scala rather than re-implemented. `testdata/` is the directory a sysl package's walk
leaves out by convention, so nothing in it is compiled.

When the reference's corpus grows, the same dumper is re-run; the source and expected output of a
case are never edited here by hand.

## Milestones

Each is one bounded item for one agent, ending in a green `sysl test .` on its branch. Every one
after M1 carries the earlier ones' tests unchanged.

1. **M1 — lexer and parser.** `nex tokens` and `nex parse`, the off-side rule and bracket-aware
   blocks through `sh.sysl.parsing`'s `Layout`, juxtaposition, literate sources. *Accepts*: every
   corpus program parses; the lexer and parser tests' cases ported as sysl tests (positive cases by
   a printed-tree comparison, negative cases by their diagnostic).
2. **M2 — elaborator, monomorphic.** Name resolution, the type lattice (integer, real, complex,
   bool, string, arrays of rank 1 and 2, tuples, structs, enums), inference, patterns, lowering,
   `nex elaborate`. *Accepts*: `NexElaboratorStage1Tests` and the non-generic `Stage2` cases; every
   corpus program without generics elaborates.
3. **M3 — generics, monomorphization, lifetime.** Generic functions, structs and enums, constraints,
   `NexMonomorphize`, the auto-clone pass. *Accepts*: the rest of `Stage2` and `Stage3`; every
   corpus program elaborates.
4. **M4 — interpreter.** `nex run`, the value model, arrays and views, the prelude, traps.
   *Accepts*: **the corpus, 425 of 425, byte for byte**, and `NexInterpreterTests`' trap and
   error cases.
5. **M5 — modules, sysroot, `nex test`.** The module loader, the source prelude located by
   `--prelude-path` / `NEX_HOME`, `@test` discovery. *Accepts*: `NexModuleLoaderTests`,
   `NexSysrootTests`, `NexPreludeIntegrationTests`, `NexTestRunnerTests`.
6. **M6 — LLVM backend, scalars.** IR emission, the runtime preamble, scalar arithmetic, control
   flow, functions, strings and printing, `nex compile` through `clang -O1`. *Accepts*: the
   `Basics`, `ControlFlow`, `Loops`, `Strings` tests; every scalar corpus program's binary prints
   what the interpreter prints, byte for byte.
7. **M7 — LLVM aggregates, enums, closures.** *Accepts*: `Aggregates`, `Lambdas`, the enum and
   closure corpus categories at parity.
8. **M8 — LLVM arrays.** Arrays with ARC, slicing and views, the array and matrix prelude, complex.
   *Accepts*: `Arrays`, `Prelude`; every array corpus program at parity.
9. **M9 — fusion.** `NexFusion` and its fused-loop lowering. *Accepts*: `NexFusionTests`; **the
   whole corpus at AOT/interpreter parity, 425 of 425**; `examples/fft` compiles and runs.

**The runtime preamble is LLVM IR, not Scala**, held in Scala strings. It moves across as `.ll`
files read with `embed`, so it is copied rather than re-written, and a diff against the reference's
text stays possible.

## MLIR: deferred, and probably not ported

- **It is a second backend for the same output**, and the LLVM one already covers the whole language;
  MLIR covers 348 of the 425 corpus programs and its own documentation calls it experimental.
- **It needs a toolchain this machine does not have** (`mlir-opt`, `mlir-translate`), which a
  stressor would then make every contributor install.
- **What it would stress in sysl is what the LLVM backend already stresses**: text emission of an IR
  from a typed tree. 5,800 lines for no new pressure on the language.

Reconsider after M9, if the reference's MLIR path has by then taken over from its LLVM one.

## What the port uses from sysl

- **`sysl-lang/parsing`** (0.13.2): `Scanner`, `Span`/`Source`, the literal readers (escapes,
  `read_interpolated_named` for `s"$x ${y}"`), `Diagnostic`/`Report` for caret-pointing errors,
  `pratt` for operator precedence, `Layout` for the off-side rule with blocks inside brackets and
  continuation lines, and `tangle_literate` for literate sources.
- **The standard library**: `sysl.math.complex.Complex[real]`; `sysl.container.Map`; `sysl.fs` to
  read sources; `sysl.process.capture` to run `clang`; `sysl.fmt.format_real` and
  `sysl.fmt.shortest` for printing reals.

## Probed, and what sysl may lack

Probed with sysl 0.7.9 (each a short program; all built and ran):

- A recursive enum held through `&` (`Add(l: &Expr, r: &Expr)`), matched and evaluated, with a
  `Map[string, real]` environment — works.
- `Complex(3.0, 4.0) * Complex(1.0, -1.0)` and `.abs()` — works (`7 1 7.0710678118654755`).
- `capture("clang", ["--version"])` — works.

**No blocking gap found.** One question for the user, not yet a gap:

- **Printing a real as nex does needs its shortest digits and decimal exponent**, because nex's
  spelling is Java's `Double.toString` (`1.0E20`, `1.0E-5`, `3.0`), not `%g`'s. sysl computes
  exactly those (Ryu, in `shortest_real`), but the only public answer is text in `%g`'s spelling:
  `sysl.fmt.shortest(1e20)` is `1e+20`. Reaching the digits directly is refused:

  ```
  error: 'sysl.shortest_real' is private to module 'sysl'
  ```

  The longhand is to re-read `shortest`'s text for its digits and exponent, which is also what the
  reference's own AOT runtime does (it searches `%.<p>g` precisions and post-processes). A public
  `shortest_digits(x) -> (digits, exponent)` would remove that. To be settled before M4.

**A parity risk that is nex's, not sysl's**: the interpreter formats `f"…"` specifiers with Java's
`String.format` (rounding half-up; `%g` keeps trailing zeros), while `sysl.fmt.format_real` is C's
(rounding half-to-even of the exact value; `%g` strips them). The reference's AOT runtime uses C's
`snprintf`, so the two references may already disagree. The corpus cannot settle it: its six `f"…"`
programs use only `%d` and `%f`. The spec's §2 / §10 wording on specifiers decides, and a case per
conversion belongs in the reference's corpus before M4 relies on it.
