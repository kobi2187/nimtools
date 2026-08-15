# shared/ast_utils.nim

## Purpose
AST helpers over Nim's parser tree: find routines and types, name them, render
them, measure their complexity. Every tool that reads Nim source goes through
here; it exists so the walkers are written once rather than per tool.

## Public interface
- `RoutineKinds*`, `BranchKinds*`, `ShortCircuitOps*` — node-kind sets
- `hasSons*(n: PNode): bool` — false for leaf kinds; guards every recursion
- `isExported*(n: PNode): bool` — has an export marker `*`
- `routineName*(n: PNode): string` — declared name, stripped of `*` and pragmas
- `typeDefName*(n: PNode): string` — same for an `nkTypeDef`
- `routineKindName*(n: PNode): string` — "proc"/"func"/"iterator"/…
- `docComment*(n: PNode): string` — leading `##` block, or "" when absent
- `collectRoutines*(root: PNode): seq[PNode]` — every routine **including
  nested ones**; excludes bodiless forward declarations
- `collectTypeDefs*(root: PNode): seq[PNode]` — every `nkTypeDef`, same rule
- `nodeLineBounds*(n: PNode): tuple[startLine, endLine: int]` — source span
- `renderTypeNode*`, `renderTypeDefConcise*`, `renderRoutineSignature*` — one-line renders
- `countBranches*`, `isDispatchArm*`, `calcCyclomaticComplexity*` — McCabe

## Usage pattern
```nim
let parsed = parseNimFile(path)
for n in collectRoutines(parsed.ast):
  echo routineName(n), " cc=", calcCyclomaticComplexity(n),
       " doc=", docComment(n)
```

## Circumstances
The collect* procs were added 2026-08-15 to replace three near-identical
walkers in inspect_tool, move_tool and find_import_tool. All three put the
recursion in a trailing `elif`, so traversal stopped at every routine and
nested procs were invisible; `cyc.nim` recursed unconditionally and saw them,
which is why the two tools disagreed on routine counts. Recursion here is
unconditional: a node is recorded *and* descended into.

## Known limits
- Parser-level only: no symbol resolution, no cross-file knowledge.
- `renderTypeNode` is cc=42 and is the most complex proc in the tree; a drifted
  copy still lives in `nimoutline.nim`.
