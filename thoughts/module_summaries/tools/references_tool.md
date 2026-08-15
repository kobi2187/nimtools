# tools/references_tool.nim

## Purpose
Answer "where is this symbol *used*" without reading the file. `find-import`
answers "where is this defined" (to resolve an import); this answers the
complement — the blast radius an agent needs before rename / move / delete.

## Public interface
- `main*(args: seq[string]): int` — CLI entry for `nimtools references`
- `ProjectReferences*`, `FileReferences*` — cross-file result shapes
- `findProjectReferences*(filePath, symbol: string; line = -1, col = -1)` —
  the defining file's binding + uses, then unbound uses in every importer
- `projectFiles*(root: string)` — every .nim under `root` (reused by rename)
- `importersOf*(moduleFile: string)` — files importing it, transitively
- `symbolIsExported*(filePath, symbol: string): bool`

## Usage pattern
```bash
nimtools references file.nim greet                 # declaration + every use
nimtools references --at:2:6 file.nim x            # one binding, disambiguated
nimtools references --project file.nim sanitize    # + every importing module
nimtools references --json file.nim greet
```

Output is `LINE:COL` plus the stripped source line for each use, using the same
1-based line / 0-based column convention as `inspect`, `extract` and
`rename-symbol --at`. Exit `0` when found (a symbol with zero uses is a valid
answer); `1` when the name has no binding in the file.

## Circumstances
Written 2026-08-15 from dogfooding a rename: renaming `describe`→`summarize` in
one module broke a caller in another, and the only way to find the dangling call
site was grep. The scope model in `scope_rename.collectBindings` already computed
every binding's uses — it was just never exposed. This command is that exposure.

## Design notes
- Built on `findReferences` in `scope_rename`, so a shadowed local is
  disambiguated by position (`--at`), not by name alone. Multiple bindings of
  the same name are all reported when no position is given.
- `text` carries the stripped source line, so the agent sees context per use
  without paying for the whole file.
- `--project` adds the import graph on top: an imported name has no local
  binding, so `scope_rename.findUnboundUses` sees it. Cross-file discovery only
  runs for an *exported* symbol — a private one cannot be referenced elsewhere.
- **Advisory, read-only**: qualified access (`util.fn`) is not reported (only
  the module side is walked), and an unbound use cannot be attributed to one of
  two same-named exporters by the parser alone. A false candidate costs nothing
  because the tool never edits; `rename-symbol --project` refuses on exactly
  that ambiguity instead.
