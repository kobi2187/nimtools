# nimtools

Static analysis and refactoring toolkit for Nim, built on Nim's own compiler as a library.
Targets AI agents as the primary caller: every tool returns structured exit codes (`0` ok,
`1` error, `2` refused) and machine-parseable output, not just human-readable text.

## Build

No `.nimble`, no config. Build each binary manually:

```bash
nim c -d:release nimtools.nim      # umbrella CLI
nim c -d:release cyc.nim           # complexity auditor
nim c -d:release nimoutline.nim    # outline generator
nim c -d:release tools/inspect_tool.nim   # each tools/*.nim is also standalone
```

See `CLAUDE.md` for the portable build form (needed off this machine's Nim source checkout).

## Tools

Run via the umbrella CLI (`nimtools <command> ...`) or each `tools/*.nim` standalone.

| Command | Purpose |
|---|---|
| `outline` | One-line type/routine signatures with line numbers |
| `cyc` | McCabe cyclomatic complexity, AST-based (not regex) |
| `inspect` | JSON model of a file: imports, types, routines |
| `extract` | Pull one symbol's signature or full body by name |
| `api-surface` / `api-diff` | Exported (or `--all`) symbols, module + per-symbol docs |
| `find-import` | Symbol search across stdlib/nimble/project → import path |
| `import` | Add/remove imports |
| `move-symbol` | Move a proc/type between files; refuses unsafe moves |
| `delete-symbol` | Delete a symbol; refuses if still referenced in-file |
| `rename-symbol` | Token-level rename in one file |
| `rename-scoped` | Scope-aware rename of one binding (`--at:LINE:COL`) |
| `rename-project` | Cross-file rename of an exported symbol |
| `references` / `project-references` | Find uses; `--semantic` for a complete answer via nimsuggest |
| `syntax-check` | Does it parse — 0.8ms/file, no imports loaded |
| `change-signature` | Add/remove/reorder a proc's params; fixes up every call site |
| `organize-imports` | Sort and dedupe a file's imports |
| `extract-variable` | Pull a selected expression into a `let` above its statement |
| `type-report` | Resolved type at a point / of a function's locals / of a whole module |
| `doc` | Routines missing doc comments |

## Design

- **Parser vs semantic, and the answer says which one replied.** Parser tools (`outline`,
  `api-surface`, `cyc`, `inspect`, `extract`) are fast and correct for *shape*. `references
  --semantic` drives `nimsuggest` for *identity* (UFCS/qualified calls the parser can't resolve)
  and never silently falls back — if nimsuggest is unavailable it exits `1`, not a wrong answer.
- **Refuse rather than corrupt.** Write tools analyze whether an edit is safe before applying it
  and decline (exit `2`) rather than emit broken code. `--force` overrides.
- **Exit codes are the API.** `0` includes a no-op success; `1` is error; `2` is a deliberate
  refusal — an agent branches on these, not on stdout text.

Full architecture, rationale, and known gaps: see `CLAUDE.md`.

## Tests

```bash
./tests/run.sh                          # all suites
nim c --hints:off -r tests/test_move.nim # one suite
```

`std/unittest`, no external dependencies.

## Self-audit

```bash
./cyc *.nim tools/*.nim shared/*.nim     # baseline: debt 258, heavy 10, over-5 34/65
```
