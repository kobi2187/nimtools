# tools/effects_tool.nim

## Purpose
Two Nim-specific reports with no mainstream IDE equivalent: the declared
exception surface (`raises`), and procs that show no side effect and could
likely be `func` (`func-candidates`).

## Public interface
- `RoutineEffects*` — object: `name*, kind*, sig*: string`, `line*: int`,
  `declared*: bool`, `raises*: seq[string]`, `otherPragmas*: seq[string]`
- `FuncCandidate*` — object: `name*, sig*: string`, `line*: int`
- `effectsOf*(filePath: string): seq[RoutineEffects]`
- `funcCandidates*(filePath: string): seq[FuncCandidate]`
- `main*(args: seq[string]): int` — CLI entry for `raises`
- `funcMain*(args: seq[string]): int` — CLI entry for `func-candidates`

## Usage pattern
```bash
nimtools raises --exported shared/*.nim
nimtools func-candidates --json tools/api_tool.nim
```

## Circumstances
Written 2026-08-15, the last two of four Nim-specific reports chosen after an
IDE-catalog survey ruled out transformation refactorings at parser level (UFCS
makes `p.greet` structurally identical to a field access, so call sites cannot
be resolved completely without semantic info).

## The limit that shapes the design
Nim *infers* effects during the compiler's sem pass. The parser sees only what
was written. So a routine with no `{.raises.}` pragma is reported **UNDECLARED**,
never as safe — only `{.raises: [].}` means "provably raises nothing", because
the compiler checked it. Conflating those two would be exactly the silent
wrongness this project exists to avoid.

`func-candidates` is a heuristic and says so: it flags a proc with no `var`
parameter, no assignment to a module-level name, and no call to a known-impure
routine. It cannot see through calls, so a proc whose only impurity is calling
an impure helper in the same file is still flagged. Candidates to review, not a
purity proof.

## Dogfooding note (2026-08-15)
Writing this summary from tool output alone — no file reads — worked for the
interface section: `api-surface` gave the full signature list in one call. It
did NOT cover the *rationale*, which lives in the module's header doc comment.
`api-surface` shows signatures; `extract` shows a symbol's doc; nothing surfaces
the module-level `##` block. See the gap list in CLAUDE.md.
