# tools/doc_tool.nim

## Purpose
List routines with no doc comment. Exported ones by default, since those are
the API surface a caller reads without opening the file.

## Public interface
- `UndocRoutine*` — object: `name, kind, sig, file: string`, `line, cc: int`
- `findUndocumented*(filePath: string, includePrivate = false): seq[UndocRoutine]`
- `main*(args: seq[string]): int` — CLI entry, returns an exit code

## Usage pattern
```nim
for u in findUndocumented("shared/ast_utils.nim"):
  echo u.file, ":", u.line, "  ", u.kind, " ", u.name
```
```bash
nimtools missing-docs shared/*.nim          # exported only
nimtools missing-docs --all --json src/*.nim
```

## Circumstances
Written 2026-08-15 alongside `extract`, from the user's list of wanted tools
("find procs with missing documentation comments"). It is a filter over
`collectRoutines` + `docComment` rather than a new traversal, so it inherits
nested-routine visibility and forward-declaration skipping for free — this is
the payoff for having centralised the walker.

## Design notes
- Private routines excluded by default; `--all` includes them.
- Reports `cc` so an undocumented *and* complex routine is easy to prioritise.
