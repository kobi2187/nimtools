# Intent-level tools: change-signature, organize-imports, extract-variable, type-report

## Motivation

nimtools' current tools are correct low-level primitives (rename, move, delete,
references) but an agent performing a common refactor still has to sequence
several of them by hand, and some LSP-standard capabilities have no equivalent
at all. This spec closes the highest-value gaps identified against a standard
LSP feature set:

- **change-signature** — deferred in CLAUDE.md gap #7 until a semantic engine
  existed. `shared/suggest.nim` (nimsuggest driver) now exists, so this is
  buildable.
- **organize-imports** — `unused-imports` only reports; nothing normalizes
  import order/dedupes.
- **extract-variable** — no structural "pull this expression into a `let`"
  action exists; agents currently hand-edit for this.
- **type-report** — no hover/type-at-point equivalent. `suggest.nim`'s `def`
  query already returns a type column that is currently discarded.

All four share the semantic engine and its cost/safety conventions
(`--semantic` never silently downgrades to a lexical guess; a query costs
seconds because it compiles the project; refuse rather than corrupt, exit 2,
`--force` to override), which is why they are one spec.

## 1. `change-signature`

```
change-signature --at:L:C file.nim --add-param "name:type=default"
change-signature --at:L:C file.nim --remove-param name
change-signature --at:L:C file.nim --reorder a,c,b
```

One flag per invocation — not composable in a single call. Keeps each
operation's blast radius independently reasoned about and independently
tested; an agent chains calls for a compound change.

`--at:L:C` resolves the proc via `findSemanticReferences` (already exists in
`tools/references_tool.nim`), which supplies every call site project-wide via
`pickProjectRoot`. No new root-picking logic is needed.

### `--add-param`

Requires a default value (`name:type=default`) so every existing positional
call site remains valid without editing. Rewrites the declaration only; no
call sites change.

### `--remove-param`

For each call site, inspect the argument expression passed for that
parameter (positional or named):

- Bare literal or identifier → drop freely, no side effects possible.
- Anything else (call, operator, index, etc. — could have a side effect) →
  refuse (exit 2), listing every such call site with file:line:col and the
  argument text. `--force` drops anyway.

This mirrors `move-symbol`'s existing `findLeftBehindDeps` refusal precedent
and was checked against mainstream IDE behavior: JetBrains silently drops and
warns only in documentation; gopls explicitly preserves side effects when
removing an unused parameter. Refuse-by-default is the safer and
cheaper-to-implement middle ground — it does not attempt gopls's
hoist-to-statement rewrite, it makes the caller decide explicitly.

### `--reorder`

Rewrites the parameter order in the declaration. At each call site: named
arguments are already order-independent and are left untouched; positional
arguments are reordered to match the new declaration order.

### Cost

Same cost class as `references --semantic` — one nimsuggest compile per
invocation, on the order of seconds, using the existing `SuggestTimeoutSecs`
guard. No new latency class.

## 2. `organize-imports`

```
organize-imports file.nim
```

Deterministic, parser-only — no nimsuggest dependency. Sorts existing imports
into groups (std lib, then third-party/nimble, then project-local by relative
path) and removes exact-duplicate module paths. Built on
`extractExistingImports`/`source_rewriter`, the same machinery `add-import`
and `rm-import` already use.

Exit 0 always: a file whose imports are already sorted and deduped is a valid
no-op success, consistent with the rest of the toolkit's exit-code contract.

## 3. `extract-variable`

```
extract-variable --at:L:C1-C2 file.nim newName
```

Reads the expression spanning columns C1..C2 on line L, inserts
`let newName = <expr>` on the line immediately above the statement containing
it, and replaces only that selected span with `newName`.

Deliberately narrow for this pass: replaces only the one selected occurrence,
does not search for or replace textually-identical occurrences elsewhere in
the function, and does no semantic equivalence proof. Parser-level only (the
expression's source text is what moves, not its resolved type). **Flagged by
the user as needing refinement later** — likely candidates for a follow-up:
multi-occurrence replacement with a same-scope/no-intervening-mutation check,
smarter insertion-point selection inside expressions (ternary branches,
comprehensions), and choosing `let` vs `var` when the extracted expression's
target is subsequently reassigned.

## 4. `type-report`

Three layers over one shared batched engine — the point-list layer is the
building block; the other two are parser-driven curation on top of it.

```
type-report at file:L:C [file:L:C ...]     # arbitrary caller-picked points
type-report function --at:L:C file.nim     # locals + return type of the enclosing proc
type-report module file.nim                # every top-level decl's resolved type
```

### Shared engine addition

`shared/suggest.nim` gains:

```nim
proc queryTypes*(projectRoot: string; locs: seq[SuggestLoc]): seq[TypeResult]
```

Batches nimsuggest `def` queries into **one nimsuggest process for the whole
call**, piping N query lines through the same `--stdin` session rather than
spawning N processes — matching the performance discipline the rest of
`suggest.nim` already follows (the ~8s cost is nimsuggest's project compile,
paid once per invocation, not once per location). The `def` query's
already-parsed type column (currently discarded by `parseRow`) becomes the
result; `parseRow` needs to stop dropping it.

### `at` layer

Caller-supplied `file:line:col` locations passed straight to `queryTypes`, no
curation. Covers cases the other two layers don't (a specific argument inside
a call, a sub-expression not bound to a name).

### `function` layer

Parser walks the enclosing proc's body for local `var`/`let`/`const`
bindings — reusing the scope-walking machinery in `shared/scope_rename.nim` —
to build the location list, resolves the proc's own signature, then makes one
batched `queryTypes` call. Output: the proc's resolved signature, then one
line per local binding with its resolved type and declaration line.

### `module` layer

Parser walks top-level declarations via the existing
`collectRoutines`/`collectTypeDefs` traversal in `shared/ast_utils.nim` for
the location list, one batched `queryTypes` call. Output: one line per
exported and private top-level proc/const/let/var, name + resolved
signature/type — surfaces cases where the written type differs from what
nimsuggest infers (`auto`, generics, templates).

## Testing

Each new tool gets a `tests/test_*.nim` suite following the existing pattern
(`test_move.nim`, `test_suggest.nim`): fixtures written to the scratch dir,
real nimsuggest calls for the semantic tools (`change-signature`,
`type-report function`/`module`/`at`) — not mocked, consistent with how
`test_suggest.nim` already exercises the real binary. `organize-imports` and
`extract-variable` are parser-only and need no nimsuggest in their tests.

## Out of scope for this spec

- `extract-function`, `inline-variable` — each is materially larger scope
  (insertion-point selection, multi-statement bodies, scoping across the
  extracted boundary) and deserves its own design pass.
- Persistent/warm nimsuggest process (CLAUDE.md gap #9) — this spec's tools
  inherit the existing per-invocation cost; making nimsuggest long-lived is a
  separate, orthogonal performance project that would benefit every
  `--semantic` tool, not just these four.
