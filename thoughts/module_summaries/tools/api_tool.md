# tools/api_tool.nim

## Purpose
Answer "what can I call from outside this module" without reading the module.
`extract` does this per symbol; this does it per module, which is the question
an agent otherwise resolves by reading a whole file.

## Public interface
- `ApiSymbol*` — object: `name, kind, sig: string`, `line: int`
- `ModuleSurface*` — object: `file*`, `symbols*: seq[ApiSymbol]`,
  `reExports*: seq[string]`, `privateCount*: int`
- `surfaceOf*(filePath: string): ModuleSurface` — one module
- `surfaceOfPaths*(paths: seq[string]): seq[ModuleSurface]` — files and/or dirs
- `main*(args: seq[string]): int` — CLI entry

## Usage pattern
```nim
let s = surfaceOf("shared/exit_codes.nim")
for sym in s.symbols: echo sym.sig
```
```bash
nimtools api-surface shared/                 # grouped per module
nimtools api-surface --json shared/foo.nim   # machine-readable
```

Output is grouped per module, because that matches how imports work — an agent
reading the surface needs to know which module to import a symbol from.

## Circumstances
Written 2026-08-15, chosen as the highest-value item for an AI-agent consumer
after a survey of IDE refactoring catalogs. The survey's finding that shaped
this: agents do not need mechanised *edits* (a model edits text fluently), they
need *queries* that replace whole-file reads. Transformation refactorings
(change-signature, inline) were ruled out at parser level because Nim's UFCS
makes `p.greet` structurally identical to a field access, so call-site analysis
cannot be complete without semantic info.

This tool has no such weakness: an export marker is `*` in the parse tree and
nothing else, so the answer cannot be silently incomplete.

## Design notes
- Private symbols are never listed, only counted — the reader knows something is
  hidden without paying tokens for it.
- `const` shows its value (the value *is* the contract); `let`/`var` do not,
  since an initial value is mutable state rather than part of the interface.
- Exported types are rendered as declared, so an object's private fields appear
  in the type line. Deliberate — a caller usually wants the full shape — but it
  means type lines are "as declared", not strictly "the public API of the type".
- `export` statements are recorded as re-exports.

## Known limits
Syntactic only. A symbol made available through a macro or template that
generates code is invisible here, as it is to every other parser-level tool in
this project.
