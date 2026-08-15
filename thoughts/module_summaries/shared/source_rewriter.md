# shared/source_rewriter.nim

## Purpose
Text-level edits to Nim source that must not disturb anything they were not
asked to change: extract a line range, replace a line range, add an export
marker, rename identifier tokens.

## Public interface
- `detectLineEnding*(source: string): string` — "\r\n" or "\n", dominant ending
- `extractLineRange*(source: string, startLine, endLine: int): string`
- `replaceLineRange*(source: string, startLine, endLine: int, replacement: string): string`
- `ensureSymbolExported*(defCode: string, name: string): string` — inserts `*`
- `renameTokenStream*(source: string, oldName, newName: string): string` —
  lexer-guided rename; skips strings and comments

## Usage pattern
```nim
let src = readFile(path)
let block = extractLineRange(src, 10, 24)
writeFile(path, replaceLineRange(src, 10, 24, ""))
```

## Circumstances
`detectLineEnding` added 2026-08-15. Every proc here splits with `splitLines()`
and rejoins; `splitLines` discards `\r`, so joining with a bare `"\n"` silently
converted CRLF files to LF across the whole file, not just the edited region.
Verified with a hexdump before/after a rename. All three joins now restore the
detected ending.

## Known limits
`renameTokenStream` is token-level, **not semantic**. It correctly skips strings
and comments (verified), but has no scope model: it rewrites every identifier
in the file matching the name, so renaming a local `i` hits every `i`. It also
cannot follow a symbol into another file. Scope-aware rename needs a scope-stack
walker over the parse tree; cross-file rename needs nimsuggest.
