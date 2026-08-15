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
│   ├── rename_tool.nim        token-level rename (semantic path refuses; not built yet)
│   ├── inspect_tool.nim       JSON model of a file
│   ├── extract_tool.nim       one symbol: signature first, --body opt-in
│   └── doc_tool.nim           routines missing doc comments
└── shared/
    ├── compiler_env.nim       parser setup with silenced hooks + structured error capture
    ├── ast_utils.nim          walkers, names, render, doc comments, complexity
    ├── source_rewriter.nim    line-range edit, export marker, lexer-guided rename
    ├── scope_rename.nim       scope-stack walker; renames one binding, not a name
    ├── path_resolver.nim      file path -> idiomatic import path
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

### Rename has two modes — pick deliberately

`nimtools rename-symbol --at:LINE:COL file.nim old new` is **scope-aware**: it resolves which
binding that position names and rewrites only the uses resolving to it. A local `i` stays local;
a shadowing `for i in ...` is a different binding and is left alone. Line is 1-based, column
0-based (compiler convention — `inspect` and `extract` report positions in exactly this form).

Without `--at` the rename is **token-level**: every matching identifier in the file, no scope
model. It skips strings and comments but will happily clobber an unrelated local of the same name.
Kept because it is the right tool for a file-wide mechanical rename.

Neither mode crosses files. `renameSemantic` (nimsuggest, project-wide) refuses rather than
pretending — see `tools/rename_tool.nim` for why the previous attempt was withdrawn.

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

## Self-audit

The toolkit measures itself; `--gate`/`--debt` are not enforced anywhere (no CI, no VCS).

```bash
./cyc *.nim tools/*.nim shared/*.nim     # baseline: debt 258, heavy 10, over-5 34/65
```

## Artifacts

Binaries are extensionless and sit next to their source, so `.gitignore` lists them by name
rather than by glob (a `tools/*` rule would need `!*.nim` counter-rules and could swallow future
source). Add new binaries and test executables to that list explicitly.
