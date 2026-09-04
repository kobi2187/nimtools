# nimtools

A command-line toolkit for reading, checking, and rewriting Nim code, built directly on
Nim's own compiler (parser + nimsuggest) instead of regexes or string matching. It's meant
to be driven by an AI coding agent as much as by a person — every command gives a clear
exit code (0 = done, 1 = error, 2 = refused) and either plain text or `--json` output, so
a script or an agent can act on the result without guessing.

## Build

```bash
nim c -d:release nimtools.nim      # the umbrella CLI
```

Each tool also builds and runs standalone (`nim c -d:release tools/move_tool.nim`), but
`nimtools <command> ...` is the normal way to use them.

## What it does

**Look at code**
- `outline` — one-line summary of every type and routine in a file, with line numbers.
- `inspect` — a full JSON model of a file: imports, types, routines, complexity.
- `extract` — print one symbol's signature (or full body) by name.
- `api-surface` — what a module exports, without opening it.
- `api-diff` — did this change break the public API?
- `cyc` — cyclomatic complexity per routine, for spotting code that's grown too tangled.
- `type-report` — the resolved type of an expression, a function's locals, or a whole
  module's declarations (uses the real compiler, not a guess).
- `syntax-check` — does this file still parse? Milliseconds, no compiling.

**Find things**
- `find-import` — "I need `X`, what do I import?" — searches stdlib, nimble packages,
  and the project itself.
- `references` / `project-references` — every place a symbol is used, in one file or
  across every file that imports it. Add `--semantic` for a fully accurate answer (slower,
  but correct even for method-call-style syntax the plain parser can't resolve).
- `unused-imports` / `missing-docs` / `raises` / `func-candidates` — small reports:
  dead imports, undocumented routines, what a proc can throw, procs that look pure.

**Change code**
- `rename-symbol` / `rename-scoped` / `rename-project` — rename something, from a
  simple whole-file text rename up to a project-wide rename of an exported symbol.
- `move-symbol` — move a proc or type to another file. Carries over the imports it
  needs, drops the ones it doesn't, and places it near where it's actually used instead
  of just dumping it at the end of the file.
- `delete-symbol` — remove a definition, but refuses if anything still uses it.
- `change-signature` — add, remove, or reorder a proc's parameters and automatically
  fix up every call site.
- `extract-variable` — pull a piece of an expression out into its own `let`.
- `organize-imports` / `add-import` / `rm-import` — keep a file's imports sorted,
  deduped, and correct.

## Why it refuses instead of guessing

A few commands can return exit code 2 instead of doing what you asked — that means the
tool understood the request but doing it would produce code that doesn't compile (e.g.
moving a proc without the type it depends on, or removing a parameter some call site
still needs). Pass `--force` to do it anyway. The idea is that a tool an agent runs
unattended should never silently write broken code.

## Tests

```bash
./tests/run.sh
```
