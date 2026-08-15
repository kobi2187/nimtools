# shared/scope_rename.nim

## Purpose
Rename a *binding* — one declaration plus the uses that actually resolve to it —
rather than every identifier in the file that happens to share the name. This is
what makes renaming a local, a parameter, or a loop variable correct.

## Public interface
- `RenameScopedStatus*` — enum: `srRenamed`, `srNotFound`, `srConflict`
- `RenameScopedResult*` — object: `status*`, `message*`, `source*` (rewritten
  text), `occurrences*: int`
- `renameScoped*(source, filename, oldName, newName: string; line, col: int):
  RenameScopedResult` — `line` 1-based, `col` 0-based (compiler convention)
- `Reference*` — object: `line*, col*: int`, `text*: string` (stripped source
  line at the use)
- `SymbolReferences*` — object: `name*: string`, `declaredLine*,
  declaredCol*: int`, `uses*: seq[Reference]`
- `findReferences*(source, filename, symbol: string; line = -1, col = -1):
  seq[SymbolReferences]` — all bindings of `symbol`; with `line`/`col`, only the
  one declared or used there
- `findUnboundUses*(source, filename, symbol: string): seq[Reference]` — every
  identifier named `symbol` that resolves to no local binding (imports,
  builtins). The raw material for cross-file reference discovery.
- `renameUnboundUses*(source, filename, oldName, newName: string): string` —
  rewrites only the unbound uses of `oldName`; the cross-file half of a rename
  (the defining file goes through `renameScoped`)

## Usage pattern
```nim
let r = renameScoped(readFile(p), p, "i", "idx", line = 2, col = 6)
if r.status == srRenamed: writeFile(p, r.source)
```
```bash
nimtools rename-symbol --at:2:6 file.nim i idx   # scoped
nimtools rename-symbol file.nim i idx            # token-level, whole file
```

## How it works
Walks the parse tree carrying a scope stack. Scope openers are structural, so no
semantic pass is needed:
- **routines** — the name binds in the *enclosing* scope; params and body get a
  new one, and params are declared before the body is walked
- **for loops** — the iterable is evaluated in the current scope, the loop
  variables bind in a new scope covering only the body. This is what stops an
  outer `i` from being captured by `for i in ...`
- **var/let/const** — type and default value are walked *before* the name is
  declared, so `var x = x` refers to the outer `x`
- **block / while** — plain nested scope
- **`a.b`** — only `a` is a name lookup; `b` is a field, never renamed

Every identifier records its own `line:col`, so a resolved use maps straight to
a rewrite span. Spans are applied right-to-left per line so earlier columns stay
valid. Strings and comments are never touched because they are not `nkIdent`
nodes — the exclusion is structural, not a heuristic.

## Circumstances
Written 2026-08-15 after the user pointed out that renaming should be real
refactoring — "a local in a function, a param and its callsite... but all of
that is done without string search replace". The existing token rename skipped
strings and comments but had no scope model, so it was string replace wearing a
lexer costume. Deliberately built without nimsuggest: lexical scope is fully
recoverable from the parse tree, needs no compilable project, no subprocess, and
works on files that do not compile.

## Known limits
- **One file, lexical scope only.** Cannot resolve overloads, follow a symbol
  across modules, or reason about types. Cross-file work lives in `rename_tool`
  (`rename-symbol --project`) and `references_tool` (`references --project`),
  which layer an import graph over this module's unbound-use collection.
- Refuses (`srConflict`) when the new name is already bound in the same scope,
  since the rename would silently change what surrounding code resolves to.
- `findUnboundUses` is advisory: qualified access (`util.fn`) is not reported
  (only the module side is walked), and an unbound use cannot be attributed to
  one of two same-named exporters by the parser alone.
