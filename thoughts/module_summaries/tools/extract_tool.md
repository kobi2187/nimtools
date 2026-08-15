# tools/extract_tool.nim

## Purpose
Return exactly one symbol from a file so an agent does not have to read the
whole file — or grep for it, which finds call sites and comments and cannot
tell where a definition ends.

## Public interface
- `Extracted*` — object: `name, kind, sig, doc, body: string`, `exported: bool`,
  `line, endLine, cc: int`
- `findSymbol*(filePath, symbol: string, withBody = false): seq[Extracted]` —
  every definition of `symbol`; a seq because overloads are legal
- `toJson*(e: Extracted, filePath: string): JsonNode`
- `main*(args: seq[string]): int` — CLI entry, returns an exit code

## Usage pattern
```nim
for e in findSymbol("shared/ast_utils.nim", "renderTypeNode"):
  echo e.sig, "  cc=", e.cc      # signature only
let full = findSymbol(path, "renderTypeNode", withBody = true)[0].body
```
```bash
nimtools extract shared/ast_utils.nim renderTypeNode        # sig + doc + cost
nimtools extract --body --json shared/ast_utils.nim collectRoutines
```

## Circumstances
Written 2026-08-15. The user's framing: the toolkit exists so an agent reads
only what is relevant instead of grepping or shipping whole files. Output shape
was chosen deliberately — signature-first with `--body` opt-in, rather than
always returning the source, because always returning the body is just a slower
way to read the file.

## Design notes
- Returns **all** overloads. An agent cannot notice it received the wrong one,
  so an arbitrary first match would be a silent correctness bug.
- Types and routines both resolve; `kind` distinguishes them.
- Sees nested routines, because it uses `collectRoutines`.
