# tools/move_tool.nim

## Purpose
Move procs and types between files, exporting them and wiring the import.
Refuses when the move would produce code that does not compile.

## Public interface
- `MoveStatus*` — enum: `mvMoved`, `mvRefused`, `mvError`
- `MoveResult*` — object: `status*`, `message*: string`, `deps*: seq[string]`
- `findLeftBehindDeps*(root: PNode, moved: seq[FoundSymbol]): seq[string]` —
  names the moved code references that would stay in the source file
- `moveSymbols*(sourceFile, destFile: string, symbolNames: seq[string],
   force = false): MoveResult`
- `main*()` — CLI entry

## Usage pattern
```nim
let r = moveSymbols("src/app.nim", "src/utils.nim", @["sanitizeInput"])
case r.status
of mvMoved:   echo r.message
of mvRefused: echo "would break: ", r.deps.join(", ")
of mvError:   quit(1)
```
```bash
nimtools move-symbol src/app.nim src/utils.nim sanitizeInput   # exit 2 if unsafe
nimtools move-symbol --force ...                               # move anyway
```

## Circumstances
Rewritten 2026-08-15. The tool previously did no dependency analysis at all:
moving `calculateAgeNextYear(p: Person)` left `Person` behind and added no
back-import, so the destination failed `nim check` — reproduced against a real
fixture. For the AI-agent audience this is the worst failure mode in the
toolkit, since an agent cannot eyeball the diff.

## Design notes
- Refusal happens **before any file is written**, so a declined move leaves the
  tree untouched.
- Analysis is parser-level, so it is conservative in the safe direction: it may
  refuse a symbol that was actually movable (a name that merely *looks* used),
  but it will not emit undeclared references.
- Refusal is a distinct exit code (2), not an error — the tool understood the
  request and declined.
