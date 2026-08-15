# tools/delete_tool.nim

## Purpose
Remove a proc/type definition — `move-symbol` without a destination. Its own
role rather than a flag on move: the refusal is the mirror image of move's
(`findLeftBehindDeps`), but the operation and its result type are distinct.

## Public interface
- `DeleteStatus*` — enum: `delDeleted`, `delRefused`, `delError`
- `DeleteResult*` — object: `status*`, `message*: string`
- `deleteSymbols*(filePath: string, symbolNames: seq[string], force = false):
  DeleteResult`
- `deleteMain*(args: seq[string]): int` — CLI entry for `nimtools delete-symbol`

## Usage pattern
```bash
nimtools delete-symbol file.nim helper      # exit 2 if `helper` is still called
nimtools delete-symbol --force file.nim helper
```

## Circumstances
Split out of `move_tool` (2026-08-15) when the toolkit settled on one role per
tool. The delete refusal reuses the scope model (`findReferences`): a symbol is
unsafe to remove when it has any in-file use, because that would leave an
undeclared identifier. `--force` overrides, matching move's contract.

## Design notes
- Refusal happens **before any file is written**; exit 2, not 1 — the tool
  understood the request and declined.
- **Single-file only.** It refuses on in-file references, not project-wide ones.
  `project-references` supplies the cross-file blast radius an agent can check
  first; a project-wide delete guard is the natural next step.
