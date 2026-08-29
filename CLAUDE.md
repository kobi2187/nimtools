# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build

No `.nimble`, no `config.nims`, no Makefile. Build each binary manually:

```bash
nim c -d:release nimtools.nim      # umbrella CLI
nim c -d:release cyc.nim           # complexity auditor
nim c -d:release nimoutline.nim    # outline generator
nim c -d:release tools/inspect_tool.nim   # each tools/*.nim is also standalone
```

Everything imports **Nim's compiler as a library** (`import compiler/[ast, parser, ...]`).
A bare `nim c` works here only because Nim 2.3.1 is installed from a source checkout at
`/home/kl/apps/Nim`, whose install root is on the search path (`nim dump | grep apps/Nim`
confirms it) and which ships `compiler/` as a sibling of `lib/`. **On a distro or binary-only
Nim this build fails** — the portable form is:

```bash
nim c --path:$(dirname $(dirname $(readlink -f $(command -v nim)))) -d:release <file>.nim
```

## Tests

```bash
./tests/run.sh                          # all suites
nim c --hints:off -r tests/test_move.nim # one suite
```

`std/unittest`, no dependencies. Suites write fixtures to the scratch dir, never into the repo.
`test_refactor_src.nim` at the root is an older manual fixture with no assertions — the tools
mutate it in place if you run them against it.

Since every write tool rewrites files destructively, a fix without a test is not finished.

## Architecture

```
nimtools.nim        Umbrella CLI — dispatch() routes subcommands, returns exit codes
├── tools/          Each module is BOTH a library (exports procs) and a binary (isMainModule)
│   ├── find_import_tool.nim   symbol search across stdlib/nimble/project -> import path
│   ├── import_tool.nim        add/remove imports; owns extractExistingImports
│   ├── move_tool.nim          move procs/types; refuses unsafe moves
│   ├── delete_tool.nim        delete-symbol; refuses when still referenced in-file
│   ├── rename_tool.nim        rename-symbol / rename-scoped / rename-project
│   ├── references_tool.nim    references / project-references (single vs cross-file)
│   ├── project_graph.nim      import graph shared by the cross-file tools
│   ├── inspect_tool.nim       JSON model of a file
│   ├── extract_tool.nim       one symbol: signature first, --body opt-in
│   ├── api_tool.nim           api-surface / api-diff
│   ├── check_tool.nim         syntax-check: does it parse (0.8ms, no imports)
│   └── doc_tool.nim           routines missing doc comments
└── shared/
    ├── compiler_env.nim       parser setup with silenced hooks + structured error capture
    ├── ast_utils.nim          walkers, names, render, doc comments, complexity
    ├── source_rewriter.nim    line-range edit, export marker, lexer-guided rename
    ├── scope_rename.nim       scope-stack walker; renames one binding, not a name;
    │                          also findReferences (uses with line:col)
    ├── path_resolver.nim      file path -> idiomatic import path
    ├── suggest.nim            SEMANTIC engine: drives nimsuggest over --stdin
    └── exit_codes.nim         0 ok / 1 error / 2 refused

cyc.nim             SELF-CONTAINED complexity CLI  — still duplicates ast_utils
nimoutline.nim      outline CLI, built on shared/  — stdout by default, -o for a file
tests/              std/unittest suites; ./tests/run.sh
thoughts/module_summaries/   per-module contract + rationale; read before the source
```

Three things about this layout are non-obvious and matter:

**1. `cyc.nim` still does not use `shared/`.** It carries its own copies of `hasSons`,
`routineName`, `renderTypeNode`, `countBranches`, `isDispatchArm`, `RoutineKinds`, `BranchKinds`.
When editing AST logic, check both locations.

`nimoutline.nim` was converted to the shared modules — its copies had already drifted (no
`nkVarTy` case, unguarded `n[1]`/`n[2]` indexing) and its walker missed nested routines, so it
disagreed with `extract` about the same file. `cyc.nim` is the last holdout; its complexity
algorithm is logically equivalent to `ast_utils`, so the risk there is drift, not a live bug.

**2. `nimtools outline` / `nimtools cyc` shell out** rather than importing, via `delegate()`,
which resolves the helper next to the running executable (`getAppDir()`). Do not reintroduce a
relative `./nimoutline` — it only resolves when the cwd happens to be the project root, and fails
with exit 127 everywhere else.

**3. Traversal is centralised — do not hand-roll a walker.** `collectRoutines` /
`collectTypeDefs` in `shared/ast_utils.nim` recurse unconditionally (record a node *and* descend
into it), so nested routines are found and bodiless forward declarations are skipped.

The bug this replaced is easy to reintroduce: putting recursion in a trailing `elif` after the
record branches makes traversal stop at every routine.

```nim
elif hasSons(n): for c in n: walk(c)    # WRONG: unreachable for routines
```

`find_import_tool.nim` still has a private walker with this shape. `cyc.nim` and `nimoutline.nim`
have their own correct-but-separate traversals.

## Design decisions worth preserving

`cyc.nim`'s header comment is a rationale document, not decoration. It defends:
- **AST over regex** — a regex counts branch keywords inside string literals (overcount) and
  collapses a 20-arm `case` to 1 (undercount). Both were observed.
- **The dispatch-arm exemption** — an `of` arm whose body contains no branch of its own is a
  lookup-table entry, not a decision. The exemption is *measured* by recursing into the arm, so
  an arm doing real work still counts.
- **`--debt`/`--heavy` over a raw count** — a raw over-threshold count *punishes* splitting one
  monster proc into three readable ones.

Keep this reasoning through any refactor of the complexity code.

## The agent contract

The audience is AI-agent tooling, so **the exit code and the output shape are the API**. An agent
cannot eyeball a diff, which drives three rules:

**Exit codes** (`shared/exit_codes.nim`): `0` completed — *including a no-op, which is success*;
`1` error (missing file, parse failure, symbol not found); `2` refused — understood the request
and declined because carrying it out would emit broken code.

**Refuse rather than corrupt.** `move-symbol` analyses whether the moved code references symbols
that would stay behind, and declines with the names listed. Analysis is parser-level, so it is
conservative in the safe direction: it may refuse a movable symbol, but will not emit undeclared
references. `--force` overrides.

**Emit resolvable identifiers.** `inspect` reports imports as `std/os`, not the parser's rendered
`"std / [os, json]"`. The spaced form was the cause of both the dirty JSON and the duplicate-import
bug — nothing could match against it.

### Three checking speeds — know which question each answers

There is no "check this module but skip its imports" semantic mode, and there
cannot be: without `strutils`'s symbol table, `s.strip` is indistinguishable from
a typo. Loading imports is what makes type checking possible. What `nim check`
already does is the cheap half — it sems dependencies for their symbols and
never codegens them.

| tool | cost here | catches |
|---|---|---|
| `nimtools syntax-check` | **0.8 ms/file** (24 files in 7 ms) | syntax only |
| `nim check <file>` | ~1.4 s | full types, loads imports |
| persistent nimsuggest `chk` | 8.3 s warmup, then 0.35 s | full types |

`syntax-check` exists for the two jobs `nim check` cannot do: gating the
destructive write tools (`move-symbol`, `rename-project`, `delete-symbol` rewrite
files in place — "does it still parse" is the first question after, and at 0.8 ms
an agent can ask after every write), and answering on a module mid-refactor whose
imports do not resolve yet.

It states its own scope in every reply (`syntax only: type errors need
nim check`) for the same reason the reference engines do — a verdict that gets
read as "compiles" is worse than no verdict.

The parse errors it reports were always being computed; `compiler_env` captured
them and every caller discarded them. `ParseResult.diagnostics` now carries them
structured (line, col, message) beside the legacy prose `errors`.

### Two engines, and the answer says which one replied

Parser (lexical) and nimsuggest (semantic) are both first-class; neither replaces the other.

**Parser** — no compile, milliseconds, correct for *shape*: `outline`, `api-surface`, `cyc`,
`doc`, `inspect`, `extract`. Shape questions do not need identity, and should not pay a compile.

**Semantic** (`shared/suggest.nim`) — needed for *identity*. `x.foo` is a field access or a UFCS
call to `foo(x)` depending on the type of `x`, and the parser cannot tell. This is not a rounding
error: `project-references tools/project_graph.nim bareName` reported **0 uses** for a proc with
**10**, every one of them written UFCS-style. An agent trusting that deletes live code.

`suggest.nim` drives the `nimsuggest` that ships with Nim rather than reimplementing sem. Over
`--stdin` the protocol is one line out, tab-separated rows back, so `osproc.execCmdEx` (which
takes stdin text directly) is the entire driver — no pipes, no supervision.

The rule that makes the split safe: **an incomplete engine must never answer as if complete.**
`project-references` names its engine in text output and carries `"engine"` / `"complete"` in
JSON. `--semantic` never silently falls back to the parser — if nimsuggest is missing or times
out it exits `1` with the reason, because a lexical guess wearing a semantic label is precisely
the failure the path exists to remove.

nimsuggest sees only modules reachable from its root, so `pickProjectRoot` (in `project_graph`)
picks a top module that imports the target. Note `importersOf` searches only a module's own
directory — `projectRootDir` climbs past that deliberately, since inheriting the blind spot would
under-report the importers the semantic path was added to find.

### Rename is three commands — pick deliberately

`rename-symbol file.nim old new` is **token-level**: every matching identifier in the file, no
scope model. It skips strings and comments but will happily clobber an unrelated local of the
same name. The right tool for a file-wide mechanical rename.

`rename-scoped --at:LINE:COL file.nim old new` is **scope-aware**: it resolves which binding
that position names and rewrites only the uses resolving to it. A local `i` stays local; a
shadowing `for i in ...` is a different binding and is left alone.

`rename-project --at:LINE:COL file.nim old new` renames an **exported** symbol across every
module that imports its file, refusing (exit 2) when another local module also exports the
name. Line is 1-based, column 0-based (compiler convention — `inspect` and `extract` report
positions in exactly this form).

None of these is `renameSemantic` (nimsuggest, full project graph + overloads) — that refuses
rather than pretending. See `tools/rename_tool.nim`.

Historical defect analysis with reproductions is in
`thoughts/ledgers/CONTINUITY_CLAUDE-nimtools.md` — the B1/B2/B4/B5/B6/B9 entries are fixed and
covered by tests; read it for the reasoning, not the current state.

## Known gaps (found by dogfooding, 2026-08-15)

Writing a module summary using only the tools — no file reads — surfaced these:

1. ~~No module-level doc access~~ — **fixed**: `api-surface --docs` now shows the
   module's header `##` block and each symbol's summary line. Use it as the
   first call when learning an unfamiliar module; it usually replaces the read.
2. **`unused-imports` is advisory only.** 10/15 agreement with `nim check` on
   this project. Prefer `nim check` when the project compiles.
3. **`raises` reports UNDECLARED for nearly everything** on codebases that don't
   annotate effects — correct, but low signal. Worth pairing with `nim check`'s
   inferred effects if that ever matters.
4. ~~`api-surface` is blind to executables~~ — **fixed**: `--all` lists private
   symbols (marked `-`, `exported = false`), including private const/let/var.
   `collectSections` no longer descends into routine bodies, so a proc's local
   `var`/`let` is neither listed nor counted (previously inflated `cyc.nim` to
   "33 private" when only 13 were module symbols).

## Known gaps (second dogfooding pass, 2026-08-15)

Driving a full refactor loop (create → rename → move → find → delete) in
`playground/` with the tools alone surfaced a different layer of gaps — the
write side, where an agent does most of its work. Two are now closed, two stand.

5. ~~`references` is single-file~~ — **fixed, then fixed properly**:
   `project-references` follows the import graph and reports an imported
   symbol's *unbound* uses. That parser path silently under-reports — it misses
   UFCS (`x.fn`) and qualified (`util.fn`) uses entirely, and cannot tell two
   same-named exporters apart. `--semantic` resolves with nimsuggest instead and
   is complete for every module reachable from the root. Both label themselves;
   parser mode still says `"complete": false`. Single-file `references` has no
   `--semantic` yet and carries the same blind spot.
6. ~~No cross-file rename~~ — **fixed**: `rename-project --at:LINE:COL` renames
   the definition and its uses in the defining file, then rewrites unbound uses
   in each importer. Refuses (exit 2) when another local module also exports
   the name (ambiguous), and leaves a shadowing local alone.
7. ~~No edit-symbol / change-signature — and deliberately so.~~ — **fixed**:
   `change-signature --at:LINE:COL` adds/removes/reorders a parameter and
   fixes up every call site via `findSemanticReferences`. `--remove-param`
   refuses when a call site's argument could have a side effect (mirrors
   `move-symbol`'s `findLeftBehindDeps`); `--force` overrides. One operation
   per invocation.
8. **`delete-symbol` is single-file** — it refuses only on in-file references,
   not project-wide. `project-references --semantic` now supplies a *complete*
   blast radius, which is what a project-wide delete guard needs: guarding on
   the parser path would refuse on incomplete data and, worse, permit on it.

## Known gaps (third pass, 2026-08-16)

9. **Semantic mode costs ~8s** on this project (nimsuggest compiles it), vs
   ~20ms for the parser. One-shot process per invocation; a persistent
   nimsuggest is the upgrade path if that ever hurts.
10. **`rename-project` is still parser-only** and inherits the UFCS blind spot,
    so it can rewrite a definition and leave UFCS call sites untouched. Routing
    it through `findSemanticReferences` is the next step and needs no new
    machinery.
11. **`importersOf` searches only a module's own directory**, so parser-mode
    cross-file answers miss importers living in a parent or sibling directory
    (`nimtools.nim` importing `tools/references_tool` is invisible to it).
    `pickProjectRoot` works around this with `projectRootDir`; `importersOf`
    itself is unfixed.
12. **`inspect` reports exit 0 and clean JSON on a file that does not parse.**
    It emits a *partial* model from whatever the parser recovered — a file with
    a missing `:` still listed its `proc`. The diagnostics now exist
    (`ParseResult.diagnostics`); `inspect` still discards them. Same class as
    the reference-engine over-claim, and now a small fix. Not yet done.

## Known gaps (fourth pass, 2026-08-29)

Closed via `docs/superpowers/specs/2026-08-29-intent-level-tools-design.md`:
`change-signature`, `organize-imports`, `type-report` (at/function/module
layers), `extract-variable`. `type-report` exposes the type column
`shared/suggest.nim`'s `parseRow` already parsed from every nimsuggest `def`
reply but had been discarding.

13. **`extract-variable` replaces only the exact selected span** — no search
    for textually-identical occurrences elsewhere in the function, no
    same-scope/no-intervening-mutation check, no `let` vs `var` choice when
    the target is later reassigned. Deliberately narrow for this pass;
    flagged in the design spec as needing refinement.
14. **`extract-function` and `inline-variable` are not built.** Each needs
    insertion-point selection and scoping analysis materially larger than
    `extract-variable`'s exact-span replacement; deferred to its own design
    pass rather than folded into this one.
15. **nimsuggest is still one process per invocation**, so `change-signature`
    and every `type-report` layer pay the same ~8s project-compile cost
    `references --semantic` already does (gap #9). A persistent nimsuggest
    would benefit all of these at once — still the upgrade path, still not
    built.

## Self-audit

The toolkit measures itself; `--gate`/`--debt` are not enforced anywhere (no CI, no VCS).

```bash
./cyc *.nim tools/*.nim shared/*.nim     # baseline: debt 258, heavy 10, over-5 34/65
```

## Artifacts

Binaries are extensionless and sit next to their source, so `.gitignore` lists them by name
rather than by glob (a `tools/*` rule would need `!*.nim` counter-rules and could swallow future
source). Add new binaries and test executables to that list explicitly.
