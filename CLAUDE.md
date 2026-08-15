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

**There are none.** `test_refactor_src.nim` is a scratch fixture with no assertions, and the
refactoring tools *mutate it in place* when run against it. Every tool rewrites files
destructively, and the repo is **not a git repository** — there is no undo. Copy fixtures to a
scratch dir before exercising any rewrite path.

Verification substitute currently in use: run a tool, then `nim check` the output file.

## Architecture

```
nimtools.nim        Umbrella CLI — dispatches subcommands
├── tools/          Each module is BOTH a library (exports procs) and a binary (isMainModule)
│   ├── find_import_tool.nim   symbol search across stdlib/nimble/project -> import path
│   ├── import_tool.nim        add/remove imports; owns extractExistingImports
│   ├── move_tool.nim          move procs/types between files
│   ├── rename_tool.nim        token-level rename (+ an unwired nimsuggest path)
│   └── inspect_tool.nim       JSON model of a file
└── shared/
    ├── compiler_env.nim       parser setup with silenced hooks + structured error capture
    ├── ast_utils.nim          AST helpers: names, exports, render, cyclomatic complexity
    ├── source_rewriter.nim    line-range edit, export marker, lexer-guided rename
    └── path_resolver.nim      file path -> idiomatic import path

cyc.nim             SELF-CONTAINED complexity CLI  — duplicates ast_utils
nimoutline.nim      SELF-CONTAINED outline CLI     — duplicates ast_utils
```

Three things about this layout are non-obvious and matter:

**1. `cyc.nim` and `nimoutline.nim` do not use `shared/`.** They carry their own copies of
`hasSons`, `routineName`, `renderTypeNode`, `renderTypeDefConcise`, `countBranches`,
`isDispatchArm`, `RoutineKinds`, `BranchKinds`. The copies have **already drifted** — e.g.
`ast_utils.renderTypeNode` handles `nkVarTy` and guards `n.len` before indexing; `nimoutline`'s
copy does neither. When editing AST logic, check all three locations.

**2. `nimtools outline` / `nimtools cyc` shell out**, they do not import:

```nim
execShellCmd("./nimoutline " & ...)   # nimtools.nim
```

Hardcoded relative paths, so both subcommands fail with exit 127 outside the project root.
Replacing these with direct imports would also collapse the duplication in (1).

**3. Two different AST traversal shapes coexist, and they disagree.** `inspect_tool`,
`move_tool`, and `find_import_tool` all use:

```nim
if n.kind == nkTypeDef:      ...        # records, does NOT recurse
elif n.kind in RoutineKinds: ...        # records, does NOT recurse
elif hasSons(n): for c in n: walk(c)    # recursion only in the final elif
```

Recursion living in the last `elif` means traversal **stops at every routine**, so nested procs
are never seen. `cyc.nim`'s `collect` recurses unconditionally and does find them. The two tools
therefore report different routine sets for the same file. Do not use matching *totals* as
evidence of agreement — they coincide on some files while counting different sets (`inspect`
counts bodiless forward declarations and misses nested procs; `cyc` does the opposite).

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

## Known correctness state

Full defect analysis with reproductions lives in
`thoughts/ledgers/CONTINUITY_CLAUDE-nimtools.md`. Read it before touching the refactoring tools.
Headlines:

- `move-symbol` **emits non-compiling code** — no dependency analysis, so moving a proc leaves
  its types behind and adds no back-import.
- `add-import` is **not idempotent** — `renderTree` renders `std/json` as `std / json` (with
  spaces), so the dedupe guard never matches.
- Every rewrite path goes through `splitLines()` / `join("\n")`, which **silently strips CRLF**.
- `rename-symbol` is **single-file only** by design, and correctly skips strings and comments.

Audience is AI-agent tooling, so exit codes and JSON shape are part of the contract: distinguish
no-op from error (`rename` currently exits 1 on a successful no-op), and note that `inspect`
emits well-formed but **inaccurate** JSON due to the traversal issue above.

## Self-audit

The toolkit measures itself; `--gate`/`--debt` are not enforced anywhere (no CI, no VCS).

```bash
./cyc *.nim tools/*.nim shared/*.nim     # baseline: debt 258, heavy 10, over-5 34/65
```

## Artifacts

Compiled binaries (`nimtools`, `cyc`, `nimoutline`, `tools/*_tool`) and generated output
(`nimoutline.outline.txt`) are checked into the tree, contradicting `cyc.nim`'s own header claim
that "the binary is gitignored." Per user decision these should be gitignored once VCS exists.
