# tools/rename_tool.nim

## Purpose
Rename identifiers, at three distinct precisions. Each is its own command — a
rename with a scope is a different operation from a whole-file token sweep, not
a flag on the same command.

## Public interface
- `RenameStatus*` / `RenameResult*` — token-level result (`rnRenamed`,
  `rnNoOp`, `rnError`)
- `renameInFile*(filePath, oldName, newName: string): RenameResult` — token
- `renameScopedInFile*(filePath, oldName, newName: string; line, col: int):
  RenameScopedResult` — one binding, one file
- `renameProjectScoped*(entryFile, oldName, newName: string; line, col: int):
  RenameScopedResult` — an exported symbol across its importers
- `tokenMain*` / `scopedMain*` / `projectMain*(args: seq[string]): int` — CLIs
- `renameSemantic*` — nimsuggest path; refuses (not implemented)

## Usage pattern
```bash
nimtools rename-symbol  file.nim old new           # token-level, whole file
nimtools rename-scoped  --at:LINE:COL file.nim old new
nimtools rename-project --at:LINE:COL file.nim old new
```

## Design notes
- `rename-symbol` is deliberately the dumbest: every matching identifier, no
  scope model. Kept because a file-wide mechanical rename is a real job — but it
  is the wrong tool for a local.
- `rename-scoped` runs the scope stack in `shared/scope_rename.nim`; it renames
  one *binding* (declaration + resolving uses), never a shadowing sibling.
- `rename-project` renames an **exported** symbol: `renameScoped` on the defining
  file, then `renameUnboundUses` on each importer from `project_graph`. Refuses
  (exit 2) when another local module also exports the name — ambiguity is a
  refusal, not a guess — and leaves a shadowing local in an importer alone.
- `renameSemantic` (nimsuggest, overloads + qualified access) is the one thing
  none of the above can do; it refuses rather than pretending.
