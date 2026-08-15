# Continuity Ledger — nimtools

**Project:** `/home/kl/prog/TEST/nimtools`
**Created:** 2026-08-15
**Type:** Brownfield onboarding (no prior ledger)
**Status:** Working prototype — builds and runs cleanly; 9 correctness bugs found in the
refactoring tools (6 reproduced, 2 code-read, 1 predicted), the worst of which (`move-symbol`)
emits non-compiling code.

---

## 1. What This Project Is

A Nim CLI toolkit that uses **Nim's own compiler as a library** (`import compiler/[ast, parser, ...]`)
for static analysis and deterministic refactoring. README frames the audience as
"developers and AI agents."

**Confirmed user intent (onboarding interview):**
- **Primary goal:** Fix correctness bugs — make refactoring tools trustworthy.
- **Audience:** AI-agent tooling (primary). Prioritize JSON output stability, deterministic
  behavior, and correct exit codes.
- **Artifacts:** Compiled binaries should be gitignored.

The "AI-agent tooling" framing raises the stakes on the bugs below: an agent cannot visually
sanity-check a diff, so a tool that silently emits non-compiling code is worse than one that refuses.

---

## 2. Architecture Map

```
nimtools.nim            (93 ln)  Umbrella CLI dispatcher — routes subcommands
├── tools/                       Library modules, each ALSO a standalone binary (isMainModule)
│   ├── find_import_tool.nim  (201) Symbol search across stdlib/nimble/project -> import path
│   ├── import_tool.nim       (179) add/remove imports; owns extractExistingImports
│   ├── move_tool.nim         (127) Move procs/types between files
│   ├── rename_tool.nim       (114) Token-level rename + nimsuggest path (incomplete)
│   └── inspect_tool.nim      (144) JSON model of a file (types/routines/cc)
└── shared/
    ├── compiler_env.nim       (44) Parser setup w/ silenced hooks + error capture  << cleanest module
    ├── ast_utils.nim         (186) AST helpers: names, exports, render, cyclomatic complexity
    ├── source_rewriter.nim   (108) Line-range edit, export marker, lexer-guided rename
    └── path_resolver.nim     (110) stdlib/nimble/project path -> idiomatic import path

cyc.nim                (227)  Cyclomatic complexity CLI — SELF-CONTAINED (duplicates ast_utils)
nimoutline.nim         (233)  Outline generator CLI — SELF-CONTAINED (duplicates ast_utils)
test_refactor_src.nim   (17)  Manual scratch fixture, no assertions
```

**Total: 1,783 lines / 13 files.**

### Key design decision (worth preserving)
`cyc.nim`'s header comment is an unusually good rationale document. It explains why AST-based
complexity beats regex, and defends the **dispatch-arm exemption** (an `of` arm with no internal
branch is a lookup-table entry, not a decision) and the **`--debt`/`--heavy` metrics** over a raw
count (a raw count *punishes* splitting a monster proc into three readable ones). Preserve this
reasoning through any refactor.

---

## 3. Tech Stack & Build

| Item | Value |
|---|---|
| Language | Nim **2.3.1** (devel), installed at `/home/kl/apps/Nim` |
| Key dependency | Nim compiler-as-library, resolved from the Nim install root |
| Build | Manual `nim c` per binary. **No `.nimble`, no `config.nims`, no Makefile** |
| Tests | **None** (`test_refactor_src.nim` is a manual fixture) |
| VCS | **Not a git repository** — `git log` fails |
| Verified | Fresh build of `nimtools.nim` succeeds (exit 0, 2 unused-import warnings) |

**Build command that works:**
```bash
nim c -d:release nimtools.nim
nim c -d:release cyc.nim
nim c -d:release nimoutline.nim
```

Checked-in generated artifacts: binaries `nimtools`, `cyc`, `nimoutline`,
`tools/{find_import,import,move,rename,inspect}_tool`, **plus `nimoutline.outline.txt`**
(generated output committed alongside the source).
Per user decision these should all be gitignored — and `cyc.nim`'s own header already asserts
"the binary is gitignored," so the tree contradicts its documentation.

### Reproducibility caveat (likely mechanism — not pinned)
`cyc.nim`'s header documents that building needs
`--path:$(dirname $(dirname $(readlink -f $(command -v nim))))`, yet a bare `nim c` succeeds here.

Confirmed facts: there is **no** project `nim.cfg`/`config.nims`, **no** `~/.config/nim/`, and Nim
is installed from a **source checkout at `/home/kl/apps/Nim` which ships a `compiler/` directory**
as a sibling of `lib/`. The likely explanation is that `import compiler/ast` resolves off the
install root. **Caveat:** grepping the install's `config/nim.cfg` for `compiler` returned only
comment lines — no explicit `path=` entry was located, so the exact resolution mechanism is
inferred rather than proven. Verify with `nim dump 2>&1 | grep '^/home/kl/apps/Nim$'` before
relying on it (use `grep 'apps/Nim$'` — anchoring the full path may miss a differently-formatted entry).

**This will break on a binary-only / distro Nim install that omits the compiler sources.**
The documented `--path` flag is not redundant — it is what makes the build portable. Worth
capturing in a `config.nims` or `.nimble` so the dependency is explicit rather than incidental.

---

## 4. BUGS FOUND (nine defects, evidence level stated per entry)

Ordered by severity for the agent-tooling use case. **Evidence is not uniform — read the tag:**

- **[REPRODUCED]** B1, B2, B4, B5, B6, B9 — observed by running the built binaries against
  scratch fixtures in `/tmp`. Actual output recorded inline.
- **[CODE-READ]** B3, B7 — found by reading source. B3 is unreachable from the CLI, so it
  *cannot* be reproduced through the tools.
- **[PREDICTED]** B8 — the crash is inferred from Nim's `case` semantics, **not observed**.
  The one probe attempted did not exercise the code path (see B8).

Don't treat the [CODE-READ]/[PREDICTED] entries as carrying the same weight as the reproduced ones.

### B1 — `move-symbol` emits non-compiling code (CRITICAL) — [REPRODUCED]
No dependency analysis. Moving a proc does not move or import the types it references,
and does not add a back-import to the destination.

Reproduced: moving `calculateAgeNextYear(p: Person)` from `test_refactor_src.nim` to `helpers.nim`
produced a `helpers.nim` that fails `nim check`:
```
helpers.nim(1, 31) Error: undeclared identifier: 'Person'
helpers.nim(2, 13) Error: undeclared field: 'age'
```
Also: caller in the source file still calls the moved symbol, and the tool adds
`import ./helpers` to the *source* but never `import ./source` to the *destination*.
Leaves a stray blank line where the symbol was excised.

**Note:** dest gets the export marker (`calculateAgeNextYear*`) correctly — that part works.

### B2 — `add-import` is not idempotent (HIGH) — [REPRODUCED, root-caused]
Running `add-import src.nim std/json` twice yields two identical import lines.

**Root cause found.** `extractExistingImports` (`tools/import_tool.nim:9`) falls through to
`renderTree(c).strip()` for `nkInfix` nodes. `renderTree` renders `std/json` as
**`std / json` — with surrounding spaces**. Verified directly:
```
kind=nkInfix renderTree=[std / strutils]
kind=nkInfix renderTree=[std / [os, json]]
```
So the guard `if moduleName in existing` compares `"std/json"` against `"std / json"` and never
matches. The same spacing bug means grouped imports (`std/[os, json]`) are never decomposed into
individual module names, so membership tests against grouped imports always fail too.

Fix direction: normalize by stripping whitespace from the rendered infix, and expand
`nkBracketExpr` inside `nkInfix` into one entry per module.

### B3 — `renameSemantic` renames the empty string (HIGH) — [CODE-READ]
`tools/rename_tool.nim:19`. On the no-usages path it calls:
```nim
return renameInFile(targetFile, "", newName)   # oldName = ""
```
Passing an empty `oldName` into the rename path is nonsense. Also in the same proc:
- Parses nimsuggest rows matching `parts[0] == "def"` while the query issued is `use` — likely
  the wrong row filter, so `usages` is usually empty and the broken fallback is the *normal* path.
- Reads `parts[4]` as the file path; nimsuggest's column order should be re-verified.
- Renames using `targetFile.extractFilename` as the identifier — a filename, not a symbol.
- `while p.running: readLine()` can block; the 50-line "safety cutoff" is arbitrary.

This whole proc appears unreachable from the CLI (no flag wires to it) — confirm before investing.

### B4 — Silent CRLF normalization (MEDIUM, data-loss class) — [REPRODUCED]
Every rewrite path goes through `splitLines()` / `join("\n")`, which discards `\r`.
Verified: a CRLF file rewritten by `rename-symbol` came back LF-only:
```
before: 70 72 6f 63 ... 3d 0d 0a   (\r\n)
after:  70 72 6f 63 ... 3d 0a      (\n)
```
Affects `source_rewriter.nim` (`extractLineRange`, `replaceLineRange`, `renameTokenStream`)
and `import_tool.nim`. Silently reformats the whole file beyond the requested edit.

### B5 — `outline` / `cyc` delegation breaks outside project root (MEDIUM) — [REPRODUCED]
`nimtools.nim` shells out with hardcoded relative paths:
```nim
execShellCmd("./nimoutline " & ...)
execShellCmd("./cyc " & ...)
```
From any other cwd: `sh: 1: ./nimoutline: not found`, exit **127**.
Fix direction: import the logic (best — kills the duplication in §5), or at minimum resolve
relative to `getAppDir()`.

### B6 — `rename` returns exit 1 for a successful no-op (LOW, agent-hostile) — [REPRODUCED]
Renaming an absent symbol prints "No identifier occurrences" and exits **1**. For an agent
driving these tools, "nothing needed changing" is not a failure. Distinguish
*no-op* from *error* in exit codes.

### B7 — Bare `except:` swallows everything (LOW) — [CODE-READ]
`find_import_tool.nim:35,194` and `rename_tool.nim:46,47` use bare `except:` / `except: 0`,
hiding real errors (permissions, decode failures) as empty results.

### B8 — `inspect_tool.nim` has an incomplete `case` (LOW) — [PREDICTED, not observed]
`main()` at line ~116 has `case p.key` with only `of "h", "help"` and no `else`.

A probe with `--bogus` did not crash, but that proved nothing: `nimtools.nim`'s
`of "inspect", "json":` branch calls `inspectFile(args[1])` **directly and never invokes
`inspect_tool.main()`**, so the suspect `case` was never executed. A string `case` with no `else`
raises at runtime on no match, so the **standalone `tools/inspect_tool` binary would crash** on an
unknown option — it does not silently ignore it.

### B9 — `inspect` / `move-symbol` / `find-import` are blind to nested routines (MEDIUM) — [REPRODUCED]
The walkers in `inspect_tool.nim:35`, `move_tool.nim:16`, and `find_import_tool.nim:49` all use the
same `elif` chain:
```nim
if n.kind == nkTypeDef:      ...        # records, does NOT recurse
elif n.kind in RoutineKinds: ...        # records, does NOT recurse
elif hasSons(n): for c in n: walk(c)    # only reached for non-routine nodes
```
Because the recursion lives in the final `elif`, traversal **stops at every routine**, so procs
(and types) declared *inside* a routine body are never seen. `cyc.nim`'s `collect` recurses
unconditionally and does find them.

Verified divergence on routine counts:
| file | `cyc` | `inspect` |
|---|---|---|
| `nimoutline.nim` | **5** | **4** |
| `tools/move_tool.nim` | **4** | **3** |
| `shared/ast_utils.nim` | 13 | 13 |

Impact: `move-symbol` cannot find a nested symbol, `find-import` misses it, and `inspect`
under-reports the complexity summary.

**Subtle trap for whoever fixes this:** the `ast_utils.nim` row agrees at 13 **by coincidence,
not correctness** — the two tools count different sets that happen to be the same size. `inspect`
counts the forward declaration `proc countBranches*(n: PNode): int` but misses the nested `walk`
inside `nodeLineBounds`; `cyc` skips the bodiless forward declaration but finds `walk`. Do not use
a matching total as evidence of agreement.

---

## 5. Structural Debt: Triplicated AST Logic

`cyc.nim` and `nimoutline.nim` are fully self-contained and **duplicate `shared/ast_utils.nim`**:
`hasSons`, `routineName`, `renderTypeNode`, `renderTypeDefConcise`, `countBranches`,
`isDispatchArm`, `isShortCircuit`, `RoutineKinds`, `BranchKinds`, `ShortCircuit`.

**The copies have already drifted** — this is not a hypothetical risk:
- `ast_utils.renderTypeNode` handles `nkVarTy`; `nimoutline`'s copy does **not**.
- Same-named proc, different complexity: **cc=42** (ast_utils) vs **cc=36** (nimoutline).
- `nimoutline` indexes `n[1]`/`n[2]` unguarded where `ast_utils` checks `n.len` first
  (e.g. `nkObjectTy`: `if n.len > 1 and n[1].kind != nkEmpty` vs bare `if n[1].kind != nkEmpty`).

**Scope of the drift — measured, not assumed.** The *complexity* algorithms
(`countBranches`/`isDispatchArm`/`isShortCircuit`) in `cyc.nim` and `ast_utils.nim` are logically
equivalent, and per-routine cc values were verified identical wherever both tools see the same
routine (`renderTypeNode` 42/42, `main` 18/18, `routineName` 10/10). The proven drift is in the
**rendering** path (`renderTypeNode`), plus the **traversal** difference recorded as B9 above.
So the two tools disagree on *which routines exist*, not on how to score a given one.

The duplication is still the root risk: three copies with no shared test mean the *next* divergence
lands silently, exactly as `nkVarTy` already did.

Fixing B5 by importing rather than shelling out would collapse this duplication as a side effect.

---

## 6. Complexity Self-Audit (dogfooded)

`./cyc *.nim tools/*.nim shared/*.nim`:

```
65 routines in 13 files
  complexity > 5: 34        (52% of all routines)
  total debt:     258       (sum of overage above 5)
  heavy (cc>=15): 10
```

Worst offenders:
| cc | lines | location | notes |
|---|---|---|---|
| 42 | 89 | `ast_utils.nim:56` `renderTypeNode` | giant `case`; drifted twin of below |
| 36 | 86 | `nimoutline.nim:12` `renderTypeNode` | duplicate copy |
| 20 | 66 | `nimtools.nim:25` `main` | dispatcher w/ inline arg parsing |
| 19 | 26 | `path_resolver.nim:85` `getCandidateNimFiles` | 3 near-identical walk loops |
| 18 | 83 | `cyc.nim:143` `main` | |
| 18 | 125 | `nimoutline.nim:106` `main` | |
| 18 | 60 | `import_tool.nim:27` `addImportToFile` | site of B2 |
| 17 | 95 | `find_import_tool.nim:104` `main` | |

The tool's own `--gate`/`--debt` thresholds are **not enforced anywhere** (no CI, no git).
The project does not yet hold itself to the standard it sells.

---

## 7. Behavior That Is Verified Working

Don't regress these:
- ✅ `rename-symbol` **correctly skips strings and comments** — the headline claim holds.
  Verified: `target` inside `"the word target in a string"`, a `##` doc comment, and a `#` comment
  were all left untouched while the definition and call site were renamed. The lexer-guided
  approach in `renameTokenStream` is sound.
- ✅ `cyc` produces sensible AST-based complexity and is the **more complete traverser** of the two
  (it finds nested routines; see B9). The dispatch-arm exemption is implemented as documented,
  though it was not isolated in a dedicated fixture.
- ✅ `nimoutline` generates correct type/routine outlines with line numbers.
- ✅ `nimtools inspect` emits well-formed, parseable JSON (imports, types, routines, complexity
  summary). ⚠️ **Well-formed ≠ accurate** — see B9: `routines` / `complexity.totalRoutines` are
  wrong in *both* directions — they **omit nested procs** *and* **count bodiless forward
  declarations**.
- ✅ `rm-import` removes **standalone** `import std/x` lines. ⚠️ The grouped (`std/[...]`)
  decomposition branch in `removeImportFromFile` is **untested** — no fixture exercised it.
  Note it does **raw string manipulation** (`strip().startsWith("import std/[")`, `find('[')`,
  `split(',')`) and never calls `extractExistingImports`/`renderTree`, so **B2's root cause does
  not apply to it** — fixing B2 will not fix or validate this branch. Separately, B2's broken
  dedupe does mean `add-import` can append a duplicate *into* an existing group.
- ✅ `move-symbol` correctly adds the export marker `*` to moved symbols.
- ✅ `compiler_env.nim` cleanly silences compiler output and captures structured errors —
  good foundation, reuse it everywhere (note `cyc.nim` and `nimoutline.nim` re-roll this too).

### Known scope limit (by design, not a bug)
`rename-symbol` is **single-file only** — a call site in another file is left stale (verified:
`b.nim` still called `target()` after `a.nim` was renamed). Reasonable as a documented primitive,
but for agent use it must be *loudly* documented or paired with a project-wide mode, since an
agent will assume a rename is complete.

---

## 8. Recommended Priority (aligned to stated goal: fix correctness bugs)

1. **Add a test harness first.** There are zero tests and every fix below rewrites files in place.
   Fixing refactoring tools without a safety net risks silent regressions. Suggested shape:
   `tests/` with fixture dirs, run tool, assert exact output text **and** `nim check` passes.
   A **cross-tool consistency test** (`cyc` vs `inspect` on the same file) would have caught B9 —
   but it must compare **routine name sets**, not totals: a count-equality check passes on
   `ast_utils.nim` (13/13) for the coincidental reason described in B9.
2. **B1 `move-symbol`** — biggest trust gap. Minimum viable: detect identifiers in the moved
   block that resolve to symbols left behind, then either refuse with a clear message or add
   the back-import. Refusing loudly is acceptable and far better than emitting broken code.
3. **B2 `add-import` idempotency** — root cause known and narrow; cheap high-value fix.
4. **B4 CRLF preservation** — detect dominant line ending, restore on write. Touches one module.
5. **B9 nested-routine blindness** — one-line-ish fix (move recursion out of the `elif` chain into
   an unconditional walk) in three files. Directly undermines `move-symbol`/`find-import`, so it
   pairs naturally with #2. Beware the coincidental-agreement trap noted in B9.
6. **B6 exit-code semantics** — define no-op(0) vs changed(0) vs error(1) across all tools;
   document for agent consumers.
7. **B3 `renameSemantic`** — decide *delete or finish*. If unreachable, deleting removes 51 lines
   and cc=15 at zero cost.
8. **B5 + §5 together** — replace `execShellCmd` with direct imports; collapses the triplicated
   AST logic and fixes cwd-dependence in one move.
9. **B7/B8** — cheap hardening.

**Deferred by user decision (not now):** deduplication-for-its-own-sake, `.nimble`/CI packaging,
complexity-debt reduction. Note that **#8** delivers the dedup benefit as a byproduct of a
correctness fix, so it need not be a separate effort.

---

## 9. Open Questions

- **`git init`?** No VCS at all. Every fix here rewrites files in place with no undo. Strongly
  recommend initializing before any edits.
- **`test_refactor_src.nim`** is a scratch fixture that the tools mutate when run. Promote to
  `tests/fixtures/` so runs don't dirty the tree?
- **Is `renameSemantic` wanted?** Nothing wires it to the CLI. Finish or delete?
- **Should `move-symbol` refuse or auto-fix** on unresolved dependencies? Refusing is safer for
  agents; auto-fixing is more useful. Recommend refuse-by-default + `--force`.
- **Is `tools/*` being a dual library+binary intentional?** Doubles build artifacts; may be
  deliberate for standalone use.
- **`--gate`/`--debt` values for self-enforcement?** Current baseline: debt 258, heavy 10,
  budget 34. Ratchet down from there if self-gating is desired later.

---

## 10. Onboarding Environment Notes

- `thoughts/` and `.claude/` did **not** exist; `thoughts/ledgers/` created for this ledger.
- `init-project.sh` not found anywhere on the system.
- `rp-cli` (RepoPrompt) **not installed** — fell back to bash/find/read + dogfooding the project's
  own `cyc`/`inspect` binaries for metrics. This worked well and is repeatable.
- No `.claude/agents/onboard.md` present, so the skill's documented agent-delegation path was
  unavailable; onboarding was performed directly.
- Scratch dirs used for behavioral tests: `/tmp/ntscratch`, `/tmp/ntb`, `/tmp/ntc`, `/tmp/ntd`, `/tmp/nte`.
  Safe to delete. **No files in the project were modified** during onboarding.
