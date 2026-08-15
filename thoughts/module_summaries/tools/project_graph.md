# tools/project_graph.nim

## Purpose
The local import graph — which module imports which — shared by every cross-file
tool (`project-references`, `rename-project`, and a future project-wide delete
guard). One role: answer "who can see this module's symbols".

## Public interface
- `bareName*(path: string): string` — `std/strutils` → `strutils`, `model.nim` → `model`
- `projectFiles*(root: string): seq[string]` — every .nim under `root`
- `importersOf*(moduleFile: string): seq[string]` — files importing it, transitively
- `symbolIsExported*(filePath, symbol: string): bool`

## Design notes
- Matching is by **bare module name**, so it is advisory: it does not resolve a
  name to one of two same-named modules, and it does not follow re-export chains
  beyond the local tree. Callers (`rename-project`) refuse on the ambiguity
  rather than guess.
- Split out of `references_tool` (2026-08-15): `references` is a query, the
  graph is infrastructure. `rename_tool` imports this, not `references_tool`.
