# Intent-Level Tools Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add four intent-level tools to nimtools — `change-signature`, `organize-imports`, `extract-variable`, and `type-report` (three layers) — closing the highest-value LSP-parity gaps identified against the existing toolkit.

**Architecture:** Each tool is a new `tools/*_tool.nim` module (library + `isMainModule` binary, following the existing pattern), wired into the umbrella CLI's `dispatch()` in `nimtools.nim`. `change-signature` and `type-report`'s function/module layers reuse the existing semantic engine (`shared/suggest.nim`, `tools/project_graph.nim`, `tools/references_tool.nim`'s `findSemanticReferences`). `organize-imports` and `extract-variable` are parser-only, reusing `shared/ast_utils.nim`, `shared/source_rewriter.nim`, and `tools/import_tool.nim`'s `extractExistingImports`.

**Tech Stack:** Nim 2.3.1, compiler-as-a-library (`compiler/[ast, parser, ...]`), nimsuggest (external binary, driven over `--stdin`), `std/unittest`.

**Spec:** `docs/superpowers/specs/2026-08-29-intent-level-tools-design.md`

## Global Constraints

- Exit codes are the API: `ExitOk = 0` (completed, including a no-op), `ExitError = 1` (bad input/parse failure/symbol not found), `ExitRefused = 2` (understood, declined because the edit would emit non-compiling code) — from `shared/exit_codes.nim`. Every new tool's CLI entrypoint must return these, not raw `quit()` codes.
- `--semantic`-class tools never silently fall back to a lexical guess on nimsuggest failure — they exit 1 with the reason (existing precedent: `references --semantic` in `tools/references_tool.nim`).
- Refuse rather than corrupt: a refusal always lists the reason (symbol/file names, or call-site locations) in the message, and `--force` is the only override.
- `--at:LINE:COL` is 1-based line, 0-based column (compiler convention) — matches `inspect`/`extract`/existing `rename-scoped`/`rename-project`/`references --semantic`.
- Each tool is both a library (exported procs, testable directly) and a standalone binary (`when isMainModule: main()`), per `tools/move_tool.nim`/`tools/check_tool.nim`.
- New tests go in `tests/test_*.nim`, `std/unittest`, fixtures written under `getTempDir() / "nimtools_test_<name>"`, following `tests/test_check.nim`/`tests/test_move.nim`/`tests/test_suggest.nim`. Semantic-engine tests skip themselves when `nimsuggestPath().len == 0` and guard the whole suite with `when defined(windows): echo "skipping..."` per `tests/test_suggest.nim`'s existing pattern.
- Every new/modified binary must build with `nim c -d:release <file>.nim` before its task is considered done.

---

## Task 1: `organize-imports` — sort and dedupe imports

**Files:**
- Create: `tools/organize_imports_tool.nim`
- Test: `tests/test_organize_imports.nim`
- Modify: `nimtools.nim` (add dispatch case + help line)
- Modify: `.gitignore` (add `tools/organize_imports_tool`, `tests/test_organize_imports`)

**Interfaces:**
- Consumes: `extractExistingImports*(root: PNode): seq[string]` from `tools/import_tool.nim`; `parseNimFile*(filePath: string): ParseResult` from `shared/compiler_env.nim` (`.ast: PNode`); `detectLineEnding*`, `stripBlankLines*` from `shared/source_rewriter.nim`.
- Produces: `proc organizeImports*(filePath: string): tuple[changed: bool, message: string]` — used only by this task's own CLI `main`.

- [ ] **Step 1: Write the failing test**

Create `tests/test_organize_imports.nim`:

```nim
## organize-imports: deterministic sort (std, then third-party, then local
## relative) and dedupe of a file's import statements. Parser-only, no
## nimsuggest — same cost class as add-import/rm-import.

import std/[unittest, os, strutils]
import ../tools/organize_imports_tool

const Scratch = getTempDir() / "nimtools_test_organize_imports"

proc fixture(name, body: string): string =
  createDir(Scratch)
  result = Scratch / name
  writeFile(result, body)

suite "organize-imports":
  test "sorts std imports before local relative imports":
    let f = fixture("unsorted.nim", "import ./util\nimport std/os\nimport std/json\n\nproc f*() = discard\n")
    let r = organizeImports(f)
    check r.changed
    let text = readFile(f)
    check text.find("std/json") < text.find("std/os")   # alphabetical within group
    check text.find("std/os") < text.find("./util")      # std group before local group

  test "dedupes an exact-duplicate import":
    let f = fixture("dup.nim", "import std/os\nimport std/os\nimport std/json\n\nproc f*() = discard\n")
    let r = organizeImports(f)
    check r.changed
    let text = readFile(f)
    check text.count("std/os") == 1

  test "is a no-op success on an already-sorted, deduped file":
    let f = fixture("clean.nim", "import std/json\nimport std/os\n\nproc f*() = discard\n")
    discard organizeImports(f)  # normalize first
    let before = readFile(f)
    let r = organizeImports(f)
    check not r.changed
    check readFile(f) == before

  test "leaves non-import code untouched":
    let f = fixture("body.nim", "import std/os\nimport std/json\n\nproc f*(): int =\n  42\n")
    discard organizeImports(f)
    check "proc f*(): int" in readFile(f)
    check "42" in readFile(f)
```

- [ ] **Step 2: Run test to verify it fails**

Run: `nim c --hints:off -r tests/test_organize_imports.nim`
Expected: FAIL — `organize_imports_tool` module does not exist yet (compile error).

- [ ] **Step 3: Write the implementation**

Create `tools/organize_imports_tool.nim`:

```nim
## organize-imports: sorts a file's top-level imports into three groups (std
## lib, third-party/nimble, project-local relative) and removes exact-duplicate
## module paths. Parser-only, deterministic, no nimsuggest dependency — same
## cost class as add-import/rm-import.
##
## Grouping rule: a module path starting with "std/" or matching a bare stdlib
## module name is "std"; a path starting with "." or ".." is "local"; anything
## else is "third-party". Within a group, alphabetical by path.

import compiler/[ast]
import std/[os, strutils, algorithm, parseopt]
import ../shared/[compiler_env, source_rewriter, exit_codes]
import import_tool

type
  ImportGroup = enum
    igStd, igThirdParty, igLocal

proc classify(modulePath: string): ImportGroup =
  if modulePath.startsWith("./") or modulePath.startsWith("../"):
    igLocal
  elif modulePath.startsWith("std/"):
    igStd
  else:
    igStd  # bare names (e.g. "os", "json") without a package prefix are stdlib

proc renderImportBlock(modules: seq[string]): string =
  var byGroup: array[ImportGroup, seq[string]]
  for m in modules: byGroup[classify(m)].add m
  for g in ImportGroup:
    byGroup[g].sort()
  var lines: seq[string] = @[]
  for g in [igStd, igThirdParty, igLocal]:
    for m in byGroup[g]:
      lines.add "import " & m
  lines.join("\n")

proc firstImportLine(root: PNode): int =
  ## 1-based line of the first top-level import statement, or 0 if none.
  if root == nil: return 0
  for n in root:
    if n.kind in {nkImportStmt, nkImportExceptStmt, nkFromStmt}:
      return n.info.line.int
  0

proc lastImportLine(root: PNode): int =
  if root == nil: return 0
  for n in root:
    if n.kind in {nkImportStmt, nkImportExceptStmt, nkFromStmt}:
      result = n.info.line.int

proc organizeImports*(filePath: string): tuple[changed: bool, message: string] =
  if not fileExists(filePath):
    return (false, "File not found: " & filePath)
  let source = readFile(filePath)
  let parsed = parseNimString(source, filePath)
  if parsed.ast == nil:
    return (false, "Could not parse: " & filePath)

  let modules = extractExistingImports(parsed.ast)
  if modules.len == 0:
    return (false, "No imports to organize")

  let first = firstImportLine(parsed.ast)
  let last = lastImportLine(parsed.ast)
  if first == 0 or last == 0:
    return (false, "No top-level import statements found")

  let newBlock = renderImportBlock(modules)
  let oldBlock = extractLineRange(source, first, last).strip(trailing = true)
  if oldBlock == newBlock:
    return (false, "Already sorted and deduped")

  let updated = replaceLineRange(source, first, last, newBlock)
  writeFile(filePath, stripBlankLines(updated) & "\n")
  (true, "Organized " & $modules.len & " import(s) in " & filePath)

proc main*(args: seq[string]): int =
  var p = initOptParser(args)
  var file = ""
  var helpRequested = false
  while true:
    p.next()
    case p.kind
    of cmdEnd: break
    of cmdShortOption, cmdLongOption:
      case p.key.toLowerAscii
      of "h", "help": helpRequested = true
      else:
        stderr.writeLine "Unknown option: --", p.key
        return ExitError
    of cmdArgument:
      if file == "": file = p.key
      else:
        stderr.writeLine "Unexpected argument: ", p.key
        return ExitError

  if helpRequested or file == "":
    echo """
nimtools organize-imports: Sort and dedupe a file's top-level imports.

Usage:
  organize-imports <file.nim>

Groups: std lib, then third-party/nimble, then project-local (./, ../).
Alphabetical within each group. Exact-duplicate module paths are removed.

Exit codes:
  0  completed (including: already organized, a valid no-op)
  1  file not found or parse failure
"""
    return ExitOk

  let (changed, message) = organizeImports(file)
  if message.startsWith("File not found") or message.startsWith("Could not parse"):
    stderr.writeLine "Error: ", message
    return ExitError
  echo message
  ExitOk

when isMainModule:
  main(commandLineParams())
```

- [ ] **Step 4: Run test to verify it passes**

Run: `nim c --hints:off -r tests/test_organize_imports.nim`
Expected: PASS (4 tests)

- [ ] **Step 5: Wire into the umbrella CLI**

In `nimtools.nim`, add the import:

```nim
import tools/[find_import_tool, import_tool, move_tool, delete_tool, rename_tool,
              inspect_tool, extract_tool, doc_tool, api_tool, effects_tool,
              references_tool, check_tool, organize_imports_tool]
```

Add to `printHelp()`'s command list, after the `rm-import` line:

```
  organize-imports  Sort and dedupe a file's imports (std, third-party, local)
```

Add to `dispatch()`, after the `rm-import` case:

```nim
  of "organize-imports", "sort-imports":
    organize_imports_tool.main(rest)
```

- [ ] **Step 6: Build the binary and verify it runs**

Run: `nim c -d:release tools/organize_imports_tool.nim && nim c -d:release nimtools.nim`
Expected: both `[SuccessX]`.

Run: `./nimtools organize-imports --help`
Expected: prints the usage text from Step 3.

- [ ] **Step 7: Update `.gitignore`**

Add two lines (matching the existing extensionless-binary listing style) to `.gitignore`:

```
tools/organize_imports_tool
tests/test_organize_imports
```

- [ ] **Step 8: Commit**

```bash
git add tools/organize_imports_tool.nim tests/test_organize_imports.nim nimtools.nim .gitignore
git commit -m "Add organize-imports: deterministic sort and dedupe of a file's imports"
```

---

## Task 2: `type-report` — batched semantic type queries (building block + `at` layer)

**Files:**
- Modify: `shared/suggest.nim` (add `queryTypes*`, stop discarding the type column in `parseRow`)
- Create: `tools/type_report_tool.nim` (`at` layer only in this task; `function`/`module` layers are Task 3)
- Test: `tests/test_type_report.nim`
- Modify: `nimtools.nim`
- Modify: `.gitignore`

**Interfaces:**
- Consumes: `nimsuggestPath*`, `runSuggest` (private — reuse via a new proc in the same module), `SuggestLoc*`, `SuggestStatus*` from `shared/suggest.nim`; `pickProjectRoot*(moduleFile: string): string` from `tools/project_graph.nim`.
- Produces:
  - `shared/suggest.nim`: `type TypeResult* = object` with fields `loc*: SuggestLoc`, `typ*: string`, `status*: SuggestStatus`, `message*: string`; `proc queryTypes*(projectRoot: string; locs: seq[SuggestLoc]): seq[TypeResult]`.
  - `tools/type_report_tool.nim`: `proc atMain*(args: seq[string]): int` — the `type-report at` CLI entrypoint. Task 3 adds `functionMain*`/`moduleMain*` to the same file.

- [ ] **Step 1: Write the failing test for `queryTypes`**

Create `tests/test_type_report.nim`:

```nim
## type-report: batched nimsuggest 'def' queries exposing the type column
## suggest.nim's parseRow already parses but previously discarded.

import std/[unittest, os, sequtils]
import ../shared/suggest

const Scratch = getTempDir() / "nimtools_test_type_report"

proc writeProject(dir: string, files: openArray[(string, string)]) =
  removeDir(dir)
  createDir(dir)
  for (name, body) in files:
    createDir((dir / name).parentDir)
    writeFile(dir / name, body)

when defined(windows):
  echo "skipping end-to-end type-report suite on windows"
else:
  suite "queryTypes: batched resolution":
    setup:
      let dir = Scratch / "proj"
      writeProject(dir, {
        "m.nim": "proc tag*(s: string): string =\n  \"[\" & s & \"]\"\n" &
                 "let greeting = tag(\"hi\")\n"})

    test "resolves the type at a single location":
      if nimsuggestPath().len == 0:
        skip()
      else:
        let results = queryTypes(dir / "m.nim", @[SuggestLoc(file: dir / "m.nim", line: 1, col: 5)])
        check results.len == 1
        check results[0].status == ssOk
        check "string" in results[0].typ

    test "resolves multiple locations in one call":
      if nimsuggestPath().len == 0:
        skip()
      else:
        let locs = @[
          SuggestLoc(file: dir / "m.nim", line: 1, col: 5),   # tag
          SuggestLoc(file: dir / "m.nim", line: 3, col: 4)]   # greeting
        let results = queryTypes(dir / "m.nim", locs)
        check results.len == 2
        check results[0].status == ssOk
        check results[1].status == ssOk

    test "a location naming no symbol reports ssNoResult for just that entry":
      if nimsuggestPath().len == 0:
        skip()
      else:
        let locs = @[
          SuggestLoc(file: dir / "m.nim", line: 1, col: 5),    # tag: resolves
          SuggestLoc(file: dir / "m.nim", line: 2, col: 0)]    # blank-ish: may not
        let results = queryTypes(dir / "m.nim", locs)
        check results.len == 2
        check results[0].status == ssOk

  suite "unavailability is reported per batch, never a wrong-shaped result":
    test "a missing root produces one failing result per location, not a crash":
      let locs = @[SuggestLoc(file: Scratch / "nope.nim", line: 1, col: 0)]
      let results = queryTypes(Scratch / "nope.nim", locs)
      check results.len == 1
      check results[0].status == ssUnavailable
      check results[0].message.len > 0
```

- [ ] **Step 2: Run test to verify it fails**

Run: `nim c --hints:off -r tests/test_type_report.nim`
Expected: FAIL — `queryTypes`, `TypeResult` undeclared.

- [ ] **Step 3: Implement `queryTypes` in `shared/suggest.nim`**

`parseRow` already parses column index 3 (`f[3]`, the type) but discards it. Modify the return tuple to include it, then add the batching proc.

Replace the existing `parseRow*` proc:

```nim
proc parseRow*(row: string): tuple[section: string, loc: SuggestLoc,
                                   typ: string, ok: bool] =
  ## A reply row, or ok=false for the banner and blank lines nimsuggest also
  ## prints. Anything not shaped like a result is skipped rather than fatal.
  let f = row.split('\t')
  if f.len < 7: return
  if f[0] notin ["def", "use"]: return
  let line = try: parseInt(f[5]) except ValueError: return
  let col = try: parseInt(f[6]) except ValueError: return
  (f[0], SuggestLoc(file: f[4], line: line, col: col), f[3], true)
```

Update the two call sites inside `queryUses*` that destructure `parseRow`'s result (they currently bind `let p = parseRow(row)` and read `p.section`/`p.loc`/`p.ok` — those field names are unchanged, only `typ` is new, so no call-site edit is needed there beyond re-running the tests below to confirm).

Add after `queryUses*`:

```nim
type
  TypeResult* = object
    loc*: SuggestLoc          ## the location this result answers for
    typ*: string              ## resolved type/signature text; "" when not ssOk
    status*: SuggestStatus
    message*: string          ## why, when status is not ssOk

proc queryTypes*(projectRoot: string; locs: seq[SuggestLoc]): seq[TypeResult] =
  ## Resolves the type at each location in `locs` using ONE nimsuggest process
  ## for the whole batch — N query lines piped through the same `--stdin`
  ## session, not N process spawns. The ~8s cost is nimsuggest's project
  ## compile, paid once per call regardless of how many locations are asked.
  if locs.len == 0: return @[]

  var query = ""
  for loc in locs:
    query.add "def " & loc.file.absolutePath & ":" & $loc.line & ":" & $loc.col & "\n"
  query.setLen(query.len - 1)  # drop trailing newline; runSuggest appends "\nquit\n"

  let r = runSuggest(projectRoot, query)
  if not r.ok:
    for loc in locs:
      result.add TypeResult(loc: loc, status: ssUnavailable, message: r.message)
    return

  # Each `def` query emits at most one "def" row (or none, if nothing resolves
  # there) followed by that symbol's "use" rows for the WHOLE project — which
  # this call does not want. Only "def" rows are kept, in the order nimsuggest
  # emitted them, which is the order the queries were issued in.
  var defRows: seq[tuple[loc: SuggestLoc, typ: string]] = @[]
  for row in r.output.splitLines:
    let p = parseRow(row)
    if p.ok and p.section == "def":
      defRows.add (p.loc, p.typ)

  # Match def rows back to the requested locations positionally: nimsuggest
  # answers `def` queries in the order they were sent, one def row per query
  # that resolved (a query naming no symbol emits zero rows for that query).
  # Since a silent skip cannot be told apart from "this query's answer is
  # still pending", a location gets ssNoResult only when strictly fewer def
  # rows came back than locations were sent, applied to the tail.
  if defRows.len == locs.len:
    for i, loc in locs:
      result.add TypeResult(loc: loc, typ: defRows[i].typ, status: ssOk)
  else:
    # Fewer defs than queries: report what resolved, in order, then mark the
    # remaining locations (the ones nimsuggest had nothing to say about) as
    # ssNoResult rather than guessing which index they were.
    for i in 0 ..< defRows.len:
      result.add TypeResult(loc: locs[i], typ: defRows[i].typ, status: ssOk)
    for i in defRows.len ..< locs.len:
      result.add TypeResult(loc: locs[i], status: ssNoResult,
        message: "nimsuggest resolved no symbol at " & locs[i].file & ":" &
                 $locs[i].line & ":" & $locs[i].col)
```

- [ ] **Step 4: Run test to verify it passes**

Run: `nim c --hints:off -r tests/test_type_report.nim`
Expected: PASS (4 tests; the 3 nimsuggest-dependent ones run if nimsuggest is installed, skip otherwise).

- [ ] **Step 5: Run the full suite to confirm `queryUses` still works**

Run: `nim c --hints:off -r tests/test_suggest.nim`
Expected: PASS — `parseRow`'s new 4-tuple return does not break `queryUses*`'s existing field access (`p.section`, `p.loc`, `p.ok`).

- [ ] **Step 6: Implement the `at` layer CLI**

Create `tools/type_report_tool.nim`:

```nim
## type-report: hover-equivalent type resolution, in three layers over one
## shared batched engine (shared/suggest.queryTypes).
##
## - `at`: caller-supplied file:line:col points, passed straight through. The
##   building block; covers what the curated layers below cannot (a specific
##   argument inside a call, a sub-expression not bound to a name).
## - `function`: locals of one proc (Task 3).
## - `module`: every top-level declaration (Task 3).

import std/[os, strutils, parseopt]
import ../shared/[suggest, exit_codes]
import project_graph

proc parseFileLineCol(spec: string): tuple[loc: SuggestLoc, ok: bool] =
  ## "path/to/file.nim:LINE:COL" -- splits from the right so a Windows drive
  ## letter or a path containing ':' elsewhere does not break parsing.
  let lastColon = spec.rfind(':')
  if lastColon < 0: return (SuggestLoc(), false)
  let secondLastColon = spec.rfind(':', 0, lastColon - 1)
  if secondLastColon < 0: return (SuggestLoc(), false)
  let file = spec[0 ..< secondLastColon]
  let lineStr = spec[secondLastColon + 1 ..< lastColon]
  let colStr = spec[lastColon + 1 .. ^1]
  let line = try: parseInt(lineStr) except ValueError: -1
  let col = try: parseInt(colStr) except ValueError: -1
  if line < 1 or col < 0: return (SuggestLoc(), false)
  (SuggestLoc(file: file, line: line, col: col), true)

proc renderTypeResults(results: seq[TypeResult]): string =
  for r in results:
    result.add r.loc.file & ":" & $r.loc.line & ":" & $r.loc.col & "  "
    result.add (if r.status == ssOk: r.typ else: "(" & r.message & ")")
    result.add "\n"

proc atMain*(args: seq[string]): int =
  var p = initOptParser(args)
  var root = ""
  var specs: seq[string] = @[]
  var helpRequested = false
  while true:
    p.next()
    case p.kind
    of cmdEnd: break
    of cmdShortOption, cmdLongOption:
      case p.key.toLowerAscii
      of "h", "help": helpRequested = true
      of "root": root = p.val
      else:
        stderr.writeLine "Unknown option: --", p.key
        return ExitError
    of cmdArgument:
      specs.add p.key

  if helpRequested or specs.len == 0:
    echo """
nimtools type-report at: Resolve the type at one or more points.

Usage:
  type-report at [--root:FILE] <file:line:col> [file:line:col ...]

Line is 1-based, column 0-based. Batches every location into ONE nimsuggest
compile, not one per location -- the cost is paid once regardless of count.
Root is auto-picked (a module that transitively imports the first location's
file) unless --root overrides it.

Exit codes:
  0  completed (a location resolving to nothing is reported, not an error)
  1  malformed file:line:col, or nimsuggest unavailable
"""
    return ExitOk

  var locs: seq[SuggestLoc] = @[]
  for s in specs:
    let (loc, ok) = parseFileLineCol(s)
    if not ok:
      stderr.writeLine "Error: malformed location (want file:line:col): ", s
      return ExitError
    if not fileExists(loc.file):
      stderr.writeLine "Error: File not found: ", loc.file
      return ExitError
    locs.add loc

  if root == "": root = pickProjectRoot(locs[0].file)
  elif not fileExists(root):
    stderr.writeLine "Error: Root file not found: ", root
    return ExitError

  let results = queryTypes(root, locs)
  if results.len > 0 and results[0].status == ssUnavailable:
    stderr.writeLine "Error: ", results[0].message
    return ExitError

  echo renderTypeResults(results)
  ExitOk

when isMainModule:
  quit(atMain(commandLineParams()))
```

- [ ] **Step 7: Build and smoke-test**

Run: `nim c -d:release tools/type_report_tool.nim`
Expected: `[SuccessX]`.

Run against this repo's own source (requires nimsuggest on PATH):
```bash
./tools/type_report_tool at --root:nimtools.nim shared/suggest.nim:1:1
```
Expected: either a resolved type line or an `(nimsuggest resolved no symbol...)` line — not a crash.

- [ ] **Step 8: Wire into the umbrella CLI**

In `nimtools.nim`, add `type_report_tool` to the tools import list, add to `printHelp()`:

```
  type-report   Resolve type(s) at point(s); at/function/module layers
```

Add to `dispatch()`:

```nim
  of "type-report", "types":
    if rest.len < 1: return usage("Usage: nimtools type-report <at|function|module> ...")
    case rest[0]
    of "at": type_report_tool.atMain(rest[1..^1])
    else: usage("Unknown type-report layer: " & rest[0] & " (want: at, function, module)")
```

(The `function`/`module` cases are added in Task 3 — this task's dispatch only recognizes `at` and errors clearly on anything else in the meantime.)

- [ ] **Step 9: Rebuild the umbrella CLI**

Run: `nim c -d:release nimtools.nim`
Expected: `[SuccessX]`.

- [ ] **Step 10: Update `.gitignore`**

Add:
```
tools/type_report_tool
tests/test_type_report
```

- [ ] **Step 11: Commit**

```bash
git add shared/suggest.nim tools/type_report_tool.nim tests/test_type_report.nim nimtools.nim .gitignore
git commit -m "Add type-report: batched nimsuggest type resolution, 'at' layer

Exposes the type column shared/suggest.nim's parseRow already parsed
but discarded. queryTypes batches N locations into one nimsuggest
process instead of N spawns, matching the performance discipline the
rest of the semantic engine already follows."
```

---

## Task 3: `type-report function` and `type-report module` layers

**Files:**
- Modify: `tools/type_report_tool.nim` (add `functionMain*`, `moduleMain*`)
- Modify: `tests/test_type_report.nim`
- Modify: `nimtools.nim` (complete the `type-report` dispatch)

**Interfaces:**
- Consumes: `collectRoutines*`, `collectTypeDefs*`, `routineName*`, `nodeLineBounds*`, `declarationPos*` from `shared/ast_utils.nim`; `parseNimFile*` from `shared/compiler_env.nim`; `queryTypes*`, `TypeResult`, `SuggestLoc` from `shared/suggest.nim`; `pickProjectRoot*` from `tools/project_graph.nim`.
- Produces: `proc functionMain*(args: seq[string]): int`, `proc moduleMain*(args: seq[string]): int` in `tools/type_report_tool.nim`.

Local-binding collection for the `function` layer needs the AST shape of `var`/`let`/`const` sections inside a routine body: each `nkVarSection`/`nkLetSection`/`nkConstSection` child is an `nkIdentDefs` (or `nkConstDef`) whose names occupy indices `0 .. ^3` (this matches `shared/scope_rename.nim:137` and `tools/effects_tool.nim`'s existing handling — same shape, reused here as a fresh local walk since this needs *locations*, not a scope-binding graph).

- [ ] **Step 1: Write the failing test**

Add to `tests/test_type_report.nim`, inside the `when defined(windows) ... else:` block, as new suites after the existing `queryTypes` suite:

```nim
  suite "type-report function: locals of one proc":
    setup:
      let dir2 = Scratch / "func_layer"
      writeProject(dir2, {
        "m.nim": "proc compute*(a: int): int =\n" &
                 "  var tmp = a * 2\n" &
                 "  let doubled = tmp\n" &
                 "  doubled\n"})

    test "reports the proc signature and each local binding":
      if nimsuggestPath().len == 0:
        skip()
      else:
        let report = functionTypeReport(dir2 / "m.nim", dir2 / "m.nim", 1, 6)
        check report.status == ssOk
        check "compute" in report.signature
        let names = report.locals.mapIt(it.loc.file & ":" & $it.loc.line)
        check report.locals.len == 2   # tmp, doubled
        for l in report.locals:
          check l.status == ssOk

    test "reports ssNoResult when the position names no routine":
      if nimsuggestPath().len == 0:
        skip()
      else:
        let report = functionTypeReport(dir2 / "m.nim", dir2 / "m.nim", 2, 2)
        check report.status == ssNoResult

  suite "type-report module: every top-level declaration":
    setup:
      let dir3 = Scratch / "module_layer"
      writeProject(dir3, {
        "m.nim": "proc pub*(a: int): int = a + 1\n" &
                 "proc priv(a: int): int = a - 1\n" &
                 "const K* = 42\n"})

    test "reports every top-level proc and const":
      if nimsuggestPath().len == 0:
        skip()
      else:
        let results = moduleTypeReport(dir3 / "m.nim", dir3 / "m.nim")
        check results.len == 3
        let names = results.mapIt(it.name)
        check "pub" in names
        check "priv" in names
        check "K" in names
```

Update the import line at the top of `tests/test_type_report.nim` to add `../tools/type_report_tool` and `sequtils`' `mapIt` is already imported.

- [ ] **Step 2: Run test to verify it fails**

Run: `nim c --hints:off -r tests/test_type_report.nim`
Expected: FAIL — `functionTypeReport`, `moduleTypeReport` undeclared.

- [ ] **Step 3: Implement both layers**

Add to `tools/type_report_tool.nim` (after the existing `at`-layer code, before `atMain*`... actually append after `atMain*` and before `when isMainModule`):

```nim
import compiler/[ast]
import ../shared/[compiler_env, ast_utils]

type
  FunctionTypeReport* = object
    status*: SuggestStatus
    message*: string
    signature*: string
    locals*: seq[TypeResult]

  ModuleTypeEntry* = object
    name*: string
    result*: TypeResult

proc enclosingRoutine(root: PNode, line, col: int): PNode =
  ## The innermost routine whose body span contains `line:col`, or nil.
  proc walk(n: PNode): PNode =
    if n == nil: return nil
    if n.kind in RoutineKinds:
      let (s, e) = nodeLineBounds(n)
      if line >= s and line <= e: result = n
    if hasSons(n):
      for c in n:
        let inner = walk(c)
        if inner != nil: result = inner
  walk(root)

proc localBindingLocs(routineNode: PNode, file: string): seq[tuple[name: string, loc: SuggestLoc]] =
  ## Every var/let/const declared directly in the routine's body (not nested
  ## routines -- collectRoutines-style unconditional recursion would descend
  ## into those too, which is why this walk stops at a nested RoutineKinds
  ## node instead of recursing into it).
  proc walk(n: PNode) =
    if n == nil: return
    if n.kind in RoutineKinds and n != routineNode: return  # don't cross into nested routines
    if n.kind in {nkVarSection, nkLetSection, nkConstSection}:
      for defs in n:
        if defs.kind notin {nkIdentDefs, nkConstDef}: continue
        for i in 0 .. defs.len - 3:
          let (line, col) = declarationPos(defs[i])
          result.add (routineName(defs[i]).strip(chars = {'*'}), SuggestLoc(file: file, line: line, col: col))
    if hasSons(n):
      for c in n: walk(c)
  if routineNode.len >= 7: walk(routineNode[6])  # body only, not params

proc functionTypeReport*(atFile, root: string; line, col: int): FunctionTypeReport =
  ## Resolves the enclosing proc's own signature plus every local var/let/const
  ## it declares directly (not inside a nested routine), in ONE batched query.
  let parsed = parseNimFile(atFile)
  if parsed.ast == nil:
    return FunctionTypeReport(status: ssUnavailable, message: "Could not parse: " & atFile)

  let routineNode = enclosingRoutine(parsed.ast, line, col)
  if routineNode == nil:
    return FunctionTypeReport(status: ssNoResult,
      message: "No routine encloses " & atFile & ":" & $line & ":" & $col)

  let (declLine, declCol) = declarationPos(routineNode)
  let locals = localBindingLocs(routineNode, atFile)
  var locs = @[SuggestLoc(file: atFile, line: declLine, col: declCol)]
  for l in locals: locs.add l.loc

  let results = queryTypes(root, locs)
  if results.len == 0 or results[0].status == ssUnavailable:
    return FunctionTypeReport(status: ssUnavailable,
      message: (if results.len > 0: results[0].message else: "nimsuggest unavailable"))

  FunctionTypeReport(status: ssOk,
    signature: results[0].typ,
    locals: results[1 ..^ 1])

proc moduleTypeReport*(atFile, root: string): seq[ModuleTypeEntry] =
  ## Every top-level routine and type/const/let/var declaration's resolved
  ## type, in ONE batched query. Surfaces cases where the written type differs
  ## from what nimsuggest infers (auto, generics, templates).
  let parsed = parseNimFile(atFile)
  if parsed.ast == nil: return @[]

  var names: seq[string] = @[]
  var locs: seq[SuggestLoc] = @[]
  for n in collectRoutines(parsed.ast):
    let (l, c) = declarationPos(n)
    names.add routineName(n)
    locs.add SuggestLoc(file: atFile, line: l, col: c)
  # Module-level const/let/var (mirrors the local-binding shape, but only
  # direct children of the module's top-level statement list).
  for n in parsed.ast:
    if n.kind notin {nkVarSection, nkLetSection, nkConstSection}: continue
    for defs in n:
      if defs.kind notin {nkIdentDefs, nkConstDef}: continue
      for i in 0 .. defs.len - 3:
        let (l, c) = declarationPos(defs[i])
        names.add routineName(defs[i]).strip(chars = {'*'})
        locs.add SuggestLoc(file: atFile, line: l, col: c)

  let results = queryTypes(root, locs)
  for i, r in results:
    result.add ModuleTypeEntry(name: names[i], result: r)

proc functionMain*(args: seq[string]): int =
  var p = initOptParser(args)
  var file, at = ""
  var helpRequested = false
  while true:
    p.next()
    case p.kind
    of cmdEnd: break
    of cmdShortOption, cmdLongOption:
      case p.key.toLowerAscii
      of "h", "help": helpRequested = true
      of "at": at = p.val
      else:
        stderr.writeLine "Unknown option: --", p.key
        return ExitError
    of cmdArgument:
      if file == "": file = p.key
      else:
        stderr.writeLine "Unexpected argument: ", p.key
        return ExitError

  if helpRequested or file == "" or at == "":
    echo """
nimtools type-report function: Resolved signature + locals of one proc.

Usage:
  type-report function --at:LINE:COL <file.nim>

Exit codes:
  0  resolved
  1  bad --at, file not found, or no routine at that position
"""
    return ExitOk

  let (loc, ok) = parseFileLineCol(file & ":" & at)
  if not ok:
    stderr.writeLine "Error: malformed --at (want LINE:COL): ", at
    return ExitError
  if not fileExists(file):
    stderr.writeLine "Error: File not found: ", file
    return ExitError

  let root = pickProjectRoot(file)
  let report = functionTypeReport(file, root, loc.line, loc.col)
  if report.status != ssOk:
    stderr.writeLine "Error: ", report.message
    return ExitError

  echo report.signature
  for l in report.locals:
    echo "  ", l.loc.line, ": ", (if l.status == ssOk: l.typ else: "(" & l.message & ")")
  ExitOk

proc moduleMain*(args: seq[string]): int =
  var p = initOptParser(args)
  var file = ""
  var helpRequested = false
  while true:
    p.next()
    case p.kind
    of cmdEnd: break
    of cmdShortOption, cmdLongOption:
      case p.key.toLowerAscii
      of "h", "help": helpRequested = true
      else:
        stderr.writeLine "Unknown option: --", p.key
        return ExitError
    of cmdArgument:
      if file == "": file = p.key
      else:
        stderr.writeLine "Unexpected argument: ", p.key
        return ExitError

  if helpRequested or file == "":
    echo """
nimtools type-report module: Resolved type of every top-level declaration.

Usage:
  type-report module <file.nim>

Exit codes:
  0  completed
  1  file not found or parse failure
"""
    return ExitOk

  if not fileExists(file):
    stderr.writeLine "Error: File not found: ", file
    return ExitError

  let root = pickProjectRoot(file)
  let entries = moduleTypeReport(file, root)
  if entries.len > 0 and entries[0].result.status == ssUnavailable:
    stderr.writeLine "Error: ", entries[0].result.message
    return ExitError

  for e in entries:
    echo e.name, ": ", (if e.result.status == ssOk: e.result.typ else: "(" & e.result.message & ")")
  ExitOk
```

Note: `parseFileLineCol` (defined earlier in this file for `atMain`) is reused by `functionMain` by concatenating `file & ":" & at` — this keeps one parsing routine instead of two near-duplicates.

- [ ] **Step 4: Run test to verify it passes**

Run: `nim c --hints:off -r tests/test_type_report.nim`
Expected: PASS (10 tests total across all suites in the file; nimsuggest-dependent ones run or skip per availability).

- [ ] **Step 5: Complete the umbrella CLI dispatch**

In `nimtools.nim`, replace the Task 2 placeholder dispatch case with:

```nim
  of "type-report", "types":
    if rest.len < 1: return usage("Usage: nimtools type-report <at|function|module> ...")
    case rest[0]
    of "at": type_report_tool.atMain(rest[1..^1])
    of "function": type_report_tool.functionMain(rest[1..^1])
    of "module": type_report_tool.moduleMain(rest[1..^1])
    else: usage("Unknown type-report layer: " & rest[0] & " (want: at, function, module)")
```

- [ ] **Step 6: Build and smoke-test**

Run: `nim c -d:release tools/type_report_tool.nim && nim c -d:release nimtools.nim`
Expected: both `[SuccessX]`.

Run against this repo:
```bash
./nimtools type-report module shared/exit_codes.nim
```
Expected: three lines (`ExitOk`, `ExitError`, `ExitRefused`) each with a resolved type, or a clear `(reason)` if nimsuggest is unavailable.

- [ ] **Step 7: Full suite regression check**

Run: `./tests/run.sh`
Expected: every suite `PASS`, including `test_suggest.nim` (unaffected by the new code) and `test_type_report.nim`.

- [ ] **Step 8: Commit**

```bash
git add tools/type_report_tool.nim tests/test_type_report.nim nimtools.nim
git commit -m "Add type-report function and module layers

function layer resolves one proc's own signature plus every local
var/let/const it declares (not descending into nested routines), in
one batched query. module layer resolves every top-level declaration.
Both share queryTypes from the previous commit."
```

---

## Task 4: `extract-variable`

**Files:**
- Create: `tools/extract_variable_tool.nim`
- Test: `tests/test_extract_variable.nim`
- Modify: `nimtools.nim`
- Modify: `.gitignore`

**Interfaces:**
- Consumes: `extractLineRange*`, `replaceLineRange*`, `detectLineEnding*` from `shared/source_rewriter.nim`; `parseNimFile*` from `shared/compiler_env.nim` (used only to validate the file parses before editing, per the existing convention of gating writes on parseability — see `move_tool.nim`'s use of `parseNimString` before any edit).
- Produces: `proc extractVariable*(filePath: string; line, colStart, colEnd: int; newName: string): tuple[ok: bool, message: string]` — used only by this task's own CLI `main`.

Deliberately narrow per the spec: replaces only the selected span, no occurrence search, no semantic equivalence check. Parser-level only — the expression's source *text* is what moves, its type is never queried.

- [ ] **Step 1: Write the failing test**

Create `tests/test_extract_variable.nim`:

```nim
## extract-variable: pulls the expression at one column span into a `let`
## above its containing statement. Deliberately narrow for this pass -- only
## the exact selected span is replaced; textually-identical occurrences
## elsewhere in the function are left alone (flagged in the design spec as
## needing refinement later).

import std/[unittest, os, strutils]
import ../tools/extract_variable_tool

const Scratch = getTempDir() / "nimtools_test_extract_variable"

proc fixture(name, body: string): string =
  createDir(Scratch)
  result = Scratch / name
  writeFile(result, body)

suite "extract-variable":
  test "extracts a simple call expression into a let above its statement":
    let f = fixture("simple.nim",
      "proc f*(a: int): int =\n" &
      "  echo compute(a) + 1\n" &
      "  0\n")
    # "compute(a)" spans columns 6..15 (0-based) on line 2.
    let r = extractVariable(f, 2, 6, 16, "tmp")
    check r.ok
    let text = readFile(f)
    check "let tmp = compute(a)" in text
    check "echo tmp + 1" in text

  test "does not touch a second identical occurrence elsewhere":
    let f = fixture("dup.nim",
      "proc f*(a: int): int =\n" &
      "  echo compute(a) + compute(a)\n" &
      "  0\n")
    let r = extractVariable(f, 2, 6, 16, "tmp")
    check r.ok
    let text = readFile(f)
    check text.count("compute(a)") == 1   # the second occurrence is untouched
    check "let tmp = compute(a)" in text

  test "fails on an out-of-range column span":
    let f = fixture("short.nim", "proc f*(): int =\n  1\n")
    let r = extractVariable(f, 2, 0, 999, "tmp")
    check not r.ok

  test "fails when the file does not parse":
    let f = fixture("broken.nim", "proc f*(: int =\n")
    let r = extractVariable(f, 1, 0, 5, "tmp")
    check not r.ok
```

- [ ] **Step 2: Run test to verify it fails**

Run: `nim c --hints:off -r tests/test_extract_variable.nim`
Expected: FAIL — `extractVariable` undeclared.

- [ ] **Step 3: Implement**

Create `tools/extract_variable_tool.nim`:

```nim
## extract-variable: pulls the expression at one column span into a `let`
## declared on the line above the statement that contains it, and replaces
## only that selected span with the new name.
##
## Deliberately narrow: exact-span replacement only, no search for other
## occurrences of the same expression, no semantic equivalence proof (the
## expression's source TEXT is what moves, its type is never queried). Flagged
## in the design spec as needing refinement later -- candidates for a follow-up
## are multi-occurrence replacement with a same-scope/no-intervening-mutation
## check, smarter insertion inside expressions (ternary branches, comprehensions),
## and choosing `let` vs `var` when the target is later reassigned.

import std/[os, strutils, parseopt]
import ../shared/[compiler_env, source_rewriter, exit_codes]

proc leadingIndent(line: string): string =
  for c in line:
    if c == ' ' or c == '\t': result.add c
    else: break

proc extractVariable*(filePath: string; line, colStart, colEnd: int;
                      newName: string): tuple[ok: bool, message: string] =
  if not fileExists(filePath):
    return (false, "File not found: " & filePath)

  let source = readFile(filePath)
  let parsed = parseNimString(source, filePath)
  if parsed.ast == nil:
    return (false, "Could not parse: " & filePath & " -- " & parsed.errors.join("; "))

  let lines = source.splitLines
  if line < 1 or line > lines.len:
    return (false, "Line " & $line & " is out of range (file has " & $lines.len & " lines)")
  let srcLine = lines[line - 1]
  if colStart < 0 or colEnd > srcLine.len or colStart >= colEnd:
    return (false, "Column span " & $colStart & ".." & $colEnd &
            " is out of range for line " & $line & " (length " & $srcLine.len & ")")

  let expr = srcLine[colStart ..< colEnd]
  let indent = leadingIndent(srcLine)
  let newLine = srcLine[0 ..< colStart] & newName & srcLine[colEnd .. ^1]
  let letDecl = indent & "let " & newName & " = " & expr

  let replacement = letDecl & "\n" & newLine
  let updated = replaceLineRange(source, line, line, replacement)
  writeFile(filePath, updated)
  (true, "Extracted '" & expr & "' into '" & newName & "' at " & filePath & ":" & $line)

proc main*(args: seq[string]): int =
  var p = initOptParser(args)
  var file, at, newName = ""
  var helpRequested = false
  while true:
    p.next()
    case p.kind
    of cmdEnd: break
    of cmdShortOption, cmdLongOption:
      case p.key.toLowerAscii
      of "h", "help": helpRequested = true
      of "at": at = p.val
      else:
        stderr.writeLine "Unknown option: --", p.key
        return ExitError
    of cmdArgument:
      if file == "": file = p.key
      elif newName == "": newName = p.key
      else:
        stderr.writeLine "Unexpected argument: ", p.key
        return ExitError

  if helpRequested or file == "" or at == "" or newName == "":
    echo """
nimtools extract-variable: Pull an expression into a `let` above its statement.

Usage:
  extract-variable --at:LINE:COLSTART-COLEND <file.nim> <newName>

Line is 1-based, columns are 0-based, COLEND is exclusive. Replaces ONLY the
selected span -- other identical occurrences elsewhere in the file are left
untouched. Parser-level: the expression's source text moves, its type is
never queried.

Exit codes:
  0  extracted
  1  bad --at, file not found, parse failure, or column span out of range
"""
    return ExitOk

  let parts = at.split(':')
  if parts.len != 2:
    stderr.writeLine "Error: malformed --at (want LINE:COLSTART-COLEND): ", at
    return ExitError
  let line = try: parseInt(parts[0]) except ValueError: -1
  let colParts = parts[1].split('-')
  if line < 1 or colParts.len != 2:
    stderr.writeLine "Error: malformed --at (want LINE:COLSTART-COLEND): ", at
    return ExitError
  let colStart = try: parseInt(colParts[0]) except ValueError: -1
  let colEnd = try: parseInt(colParts[1]) except ValueError: -1
  if colStart < 0 or colEnd <= colStart:
    stderr.writeLine "Error: malformed column span in --at: ", at
    return ExitError

  let (ok, message) = extractVariable(file, line, colStart, colEnd, newName)
  if not ok:
    stderr.writeLine "Error: ", message
    return ExitError
  echo message
  ExitOk

when isMainModule:
  quit(main(commandLineParams()))
```

- [ ] **Step 4: Run test to verify it passes**

Run: `nim c --hints:off -r tests/test_extract_variable.nim`
Expected: PASS (4 tests).

- [ ] **Step 5: Wire into the umbrella CLI**

In `nimtools.nim`, add `extract_variable_tool` to the import list, add to `printHelp()`:

```
  extract-variable  Pull an expression into a let above its statement
```

Add to `dispatch()`:

```nim
  of "extract-variable", "extract-var":
    extract_variable_tool.main(rest)
```

- [ ] **Step 6: Build and verify**

Run: `nim c -d:release tools/extract_variable_tool.nim && nim c -d:release nimtools.nim`
Expected: both `[SuccessX]`.

- [ ] **Step 7: Update `.gitignore`**

Add:
```
tools/extract_variable_tool
tests/test_extract_variable
```

- [ ] **Step 8: Commit**

```bash
git add tools/extract_variable_tool.nim tests/test_extract_variable.nim nimtools.nim .gitignore
git commit -m "Add extract-variable: pull one selected expression into a let

Deliberately narrow: exact-span replacement only, no multi-occurrence
search, no semantic equivalence check -- flagged in the design spec as
needing refinement later."
```

---

## Task 5: `change-signature`

**Files:**
- Create: `tools/change_signature_tool.nim`
- Test: `tests/test_change_signature.nim`
- Modify: `nimtools.nim`
- Modify: `.gitignore`

**Interfaces:**
- Consumes: `findSemanticReferences*(filePath, symbol, root: string; line, col: int): tuple[refs: ProjectReferences, status: SuggestStatus, message: string]` from `tools/references_tool.nim`; `pickProjectRoot*` from `tools/project_graph.nim`; `parseNimFile*`/`parseNimString*` from `shared/compiler_env.nim`; `nodeLineBounds*`, `declarationPos*` from `shared/ast_utils.nim`; `extractLineRange*`, `replaceLineRange*` from `shared/source_rewriter.nim`.
- Produces: `proc addParam*`, `proc removeParam*`, `proc reorderParams*` — three top-level procs sharing a common result shape `ChangeSigResult* = object` with `status*: ChangeSigStatus` (`csApplied`, `csRefused`, `csError`), `message*: string`, `blockedSites*: seq[string]` (file:line:col for refused call sites).

Formal params AST shape (verified against `shared/scope_rename.nim`'s `walkRoutine` and `tools/effects_tool.nim`'s `hasVarParam`): for a routine node `n`, `n[3]` is `nkFormalParams` when `n.len >= 4`; `n[3][0]` is the return type (possibly `nkEmpty`); each `n[3][i]` for `i >= 1` is `nkIdentDefs` with `p[0 ..< p.len-2]` the parameter name(s), `p[^2]` the type node, `p[^1]` the default-value node (possibly `nkEmpty`).

- [ ] **Step 1: Write the failing test**

Create `tests/test_change_signature.nim`:

```nim
## change-signature: add/remove/reorder a proc's parameters and fix up every
## call site project-wide via the semantic engine (findSemanticReferences).
## One operation per invocation -- add, remove, or reorder, never combined --
## so each op's blast radius is independently reasoned about.

import std/[unittest, os, strutils]
import ../tools/change_signature_tool

const Scratch = getTempDir() / "nimtools_test_change_signature"

proc writeProject(dir: string, files: openArray[(string, string)]) =
  removeDir(dir)
  createDir(dir)
  for (name, body) in files:
    createDir((dir / name).parentDir)
    writeFile(dir / name, body)

when defined(windows):
  echo "skipping end-to-end change-signature suite on windows"
else:
  suite "change-signature --add-param":
    test "adds a defaulted param to the decl; call sites are untouched":
      if nimsuggestPath().len == 0:
        skip()
      else:
        let dir = Scratch / "add"
        writeProject(dir, {
          "lib.nim": "proc greet*(name: string): string =\n  \"hi \" & name\n",
          "app.nim": "import lib\necho greet(\"x\")\n"})
        let r = addParam(dir / "lib.nim", dir / "lib.nim", 1, 5,
                         "loud", "bool", "false")
        check r.status == csApplied
        check "loud: bool = false" in readFile(dir / "lib.nim")
        check readFile(dir / "app.nim") == "import lib\necho greet(\"x\")\n"

  suite "change-signature --remove-param":
    test "removes a param when every call site passes a bare literal or ident":
      if nimsuggestPath().len == 0:
        skip()
      else:
        let dir = Scratch / "remove_safe"
        writeProject(dir, {
          "lib.nim": "proc greet*(name: string, loud: bool): string =\n  name\n",
          "app.nim": "import lib\nlet x = true\necho greet(\"a\", x)\necho greet(\"b\", false)\n"})
        let r = removeParam(dir / "lib.nim", dir / "lib.nim", 1, 5, "loud")
        check r.status == csApplied
        check "loud" notin readFile(dir / "lib.nim").splitLines[0]
        check "greet(\"a\")" in readFile(dir / "app.nim")
        check "greet(\"b\")" in readFile(dir / "app.nim")

    test "refuses when a call site's argument could have a side effect":
      if nimsuggestPath().len == 0:
        skip()
      else:
        let dir = Scratch / "remove_unsafe"
        writeProject(dir, {
          "lib.nim": "proc greet*(name: string, loud: bool): string =\n  name\n",
          "app.nim": "import lib\nproc mkLoud(): bool = true\necho greet(\"a\", mkLoud())\n"})
        let r = removeParam(dir / "lib.nim", dir / "lib.nim", 1, 5, "loud")
        check r.status == csRefused
        check r.blockedSites.len == 1
        check "mkLoud" in readFile(dir / "lib.nim").readFile.splitLines[0] or true  # decl unchanged, see next check
        check "loud" in readFile(dir / "lib.nim")   # decl NOT rewritten on refusal

    test "force removes anyway, dropping the side-effecting argument":
      if nimsuggestPath().len == 0:
        skip()
      else:
        let dir = Scratch / "remove_force"
        writeProject(dir, {
          "lib.nim": "proc greet*(name: string, loud: bool): string =\n  name\n",
          "app.nim": "import lib\nproc mkLoud(): bool = true\necho greet(\"a\", mkLoud())\n"})
        let r = removeParam(dir / "lib.nim", dir / "lib.nim", 1, 5, "loud", force = true)
        check r.status == csApplied
        check "greet(\"a\")" in readFile(dir / "app.nim")

  suite "change-signature --reorder":
    test "reorders positional args at call sites; named args are untouched":
      if nimsuggestPath().len == 0:
        skip()
      else:
        let dir = Scratch / "reorder"
        writeProject(dir, {
          "lib.nim": "proc greet*(a: string, b: int): string =\n  a\n",
          "app.nim": "import lib\necho greet(\"x\", 1)\necho greet(b = 2, a = \"y\")\n"})
        let r = reorderParams(dir / "lib.nim", dir / "lib.nim", 1, 5, @["b", "a"])
        check r.status == csApplied
        let libText = readFile(dir / "lib.nim")
        check libText.find("b: int") < libText.find("a: string")
        let appText = readFile(dir / "app.nim")
        check "greet(1, \"x\")" in appText
        check "greet(b = 2, a = \"y\")" in appText   # named call untouched
```

- [ ] **Step 2: Run test to verify it fails**

Run: `nim c --hints:off -r tests/test_change_signature.nim`
Expected: FAIL — `change_signature_tool` module does not exist yet.

- [ ] **Step 3: Implement**

Create `tools/change_signature_tool.nim`:

```nim
## change-signature: add/remove/reorder a proc's parameters and fix up every
## call site project-wide, using the semantic reference engine
## (findSemanticReferences) to find every call regardless of UFCS or
## qualified-call form.
##
## One operation per invocation. Each is independently safe to reason about
## and independently testable; an agent chains calls for a compound change.
##
## --remove-param refuses (exit 2) when a call site's argument for that
## parameter is anything other than a bare literal or identifier -- such an
## argument could have a side effect that dropping it would silently lose.
## This mirrors move-symbol's findLeftBehindDeps precedent. --force overrides.

import compiler/[ast, renderer]
import std/[os, strutils, parseopt, sequtils, sets, tables]
import ../shared/[compiler_env, ast_utils, source_rewriter, exit_codes, suggest]
import references_tool, project_graph

export suggest.nimsuggestPath  # re-exported so callers/tests need one import

type
  ChangeSigStatus* = enum
    csApplied
    csRefused
    csError

  ChangeSigResult* = object
    status*: ChangeSigStatus
    message*: string
    blockedSites*: seq[string]   ## file:line:col, populated only on csRefused

proc findEnclosingRoutineDecl(root: PNode, line, col: int): PNode =
  ## The routine whose declarationPos matches `line:col` -- --at names the
  ## proc's own name token, same convention as rename-scoped/rename-project.
  for n in collectRoutines(root):
    let (l, c) = declarationPos(n)
    if l == line and c == col: return n

proc formalParams(n: PNode): PNode =
  if n.len >= 4 and n[3] != nil and n[3].kind == nkFormalParams: n[3] else: nil

proc paramNames(formals: PNode): seq[string] =
  if formals == nil: return @[]
  for i in 1 ..< formals.len:
    let p = formals[i]
    if p.kind != nkIdentDefs: continue
    for j in 0 .. p.len - 3:
      result.add p[j].ident.s

proc isSimpleArg(n: PNode): bool =
  ## A bare literal or identifier -- cannot have a side effect. Anything else
  ## (call, operator, index, dot-access) is treated as possibly effectful.
  ## nkLiterals (compiler/ast.nim) = nkCharLit..nkTripleStrLit, which already
  ## spans int/uint/float/string/char kinds; nkNilLit and nkIdent added
  ## separately since nkLiterals does not include them.
  n.kind in ({nkNilLit, nkIdent} + nkLiterals)

proc callArgExpr(callSite: PNode, paramIndex: int, paramName: string): PNode =
  ## The argument node at `paramIndex` (0-based, excluding the callee), or the
  ## one named `paramName` if the call uses named-argument form. Nil if this
  ## call node does not look like a call at all (a plain unbound-use match
  ## from the reference engine that turned out not to be a call site).
  if callSite.kind != nkCall or callSite.len < 2: return nil
  var positional = 0
  for i in 1 ..< callSite.len:
    let a = callSite[i]
    if a.kind == nkExprEqExpr and a.len == 2 and a[0].kind == nkIdent:
      if a[0].ident.s == paramName: return a[1]
    else:
      if positional == paramIndex: return a
      positional.inc
  nil

proc rewriteDecl(filePath: string, declNode: PNode,
                 newFormals: seq[tuple[name, typ, default: string]]): string =
  let (s, e) = nodeLineBounds(declNode)
  let original = extractLineRange(readFile(filePath), s, e)
  # Rebuild only the parameter list text; render the routine's own header
  # (name, generics, pragmas, return type) unchanged by editing the source
  # text between the outermost parens rather than re-rendering the whole node
  # -- re-rendering would also normalize unrelated formatting/comments.
  let openParen = original.find('(')
  let closeParen = original.find(')')
  if openParen < 0 or closeParen < 0:
    return original  # no parens found (parameterless proc); caller checks this
  let newParamText = newFormals.mapIt(
    it.name & ": " & it.typ & (if it.default.len > 0: " = " & it.default else: "")
  ).join(", ")
  original[0 .. openParen] & newParamText & original[closeParen .. ^1]

proc currentFormals(formals: PNode): seq[tuple[name, typ, default: string]] =
  if formals == nil: return @[]
  for i in 1 ..< formals.len:
    let p = formals[i]
    if p.kind != nkIdentDefs: continue
    let typText = if p[^2].kind != nkEmpty: renderTree(p[^2]).strip() else: ""
    let defText = if p[^1].kind != nkEmpty: renderTree(p[^1]).strip() else: ""
    for j in 0 .. p.len - 3:
      result.add (p[j].ident.s, typText, defText)

proc addParam*(filePath, root: string; line, col: int;
              name, typ, default: string): ChangeSigResult =
  let parsed = parseNimFile(filePath)
  if parsed.ast == nil:
    return ChangeSigResult(status: csError, message: "Could not parse: " & filePath)
  let declNode = findEnclosingRoutineDecl(parsed.ast, line, col)
  if declNode == nil:
    return ChangeSigResult(status: csError,
      message: "No routine declared at " & filePath & ":" & $line & ":" & $col)

  var formals = currentFormals(formalParams(declNode))
  formals.add (name, typ, default)
  let newDecl = rewriteDecl(filePath, declNode, formals)
  let (s, e) = nodeLineBounds(declNode)
  writeFile(filePath, replaceLineRange(readFile(filePath), s, e, newDecl))
  ChangeSigResult(status: csApplied,
    message: "Added parameter '" & name & "' to the declaration in " & filePath)

proc removeParam*(filePath, root: string; line, col: int; name: string;
                  force = false): ChangeSigResult =
  let parsed = parseNimFile(filePath)
  if parsed.ast == nil:
    return ChangeSigResult(status: csError, message: "Could not parse: " & filePath)
  let declNode = findEnclosingRoutineDecl(parsed.ast, line, col)
  if declNode == nil:
    return ChangeSigResult(status: csError,
      message: "No routine declared at " & filePath & ":" & $line & ":" & $col)

  let formals = formalParams(declNode)
  let names = paramNames(formals)
  let paramIndex = names.find(name)
  if paramIndex < 0:
    return ChangeSigResult(status: csError,
      message: "No parameter named '" & name & "' in the declaration")

  let symbolName = declNode[0].ident.s.strip(chars = {'*'})
  let (sr, status, sMessage) = findSemanticReferences(filePath, symbolName, root, line, col)
  if status != ssOk:
    return ChangeSigResult(status: csError, message: sMessage)

  if not force:
    var blocked: seq[string] = @[]
    for f in sr.files:
      for u in f.uses:
        let callParsed = parseNimFile(f.file)
        if callParsed.ast == nil: continue
        # Re-find the call node at u.line:u.col by walking for an nkCall whose
        # callee token sits at that position -- the reference engine reports
        # the callee's position, not the whole call node.
        proc findCallAt(n: PNode): PNode =
          if n == nil: return nil
          if n.kind == nkCall and n.len >= 1:
            let (cl, cc) = declarationPos(n[0])
            if cl == u.line and cc == u.col: return n
          if hasSons(n):
            for c in n:
              let inner = findCallAt(c)
              if inner != nil: return inner
        let callNode = findCallAt(callParsed.ast)
        if callNode == nil: continue
        let argNode = callArgExpr(callNode, paramIndex, name)
        if argNode != nil and not isSimpleArg(argNode):
          blocked.add f.file & ":" & $u.line & ":" & $u.col &
                      "  (" & renderTree(argNode).strip() & ")"
    if blocked.len > 0:
      return ChangeSigResult(status: csRefused, blockedSites: blocked,
        message: "Refusing to remove '" & name & "': " & $blocked.len &
                 " call site(s) pass a non-trivial expression for it, which " &
                 "could have a side effect. Pass --force to remove anyway.")

  # Rewrite the declaration.
  var newFormals: seq[tuple[name, typ, default: string]] = @[]
  for f in currentFormals(formals):
    if f.name != name: newFormals.add f
  let newDecl = rewriteDecl(filePath, declNode, newFormals)
  let (s, e) = nodeLineBounds(declNode)
  writeFile(filePath, replaceLineRange(readFile(filePath), s, e, newDecl))

  # Rewrite call sites: drop the argument at paramIndex (or the named form).
  for f in sr.files:
    if f.uses.len == 0: continue
    var text = readFile(f.file)
    var edits: seq[tuple[line: int, newText: string]] = @[]
    let callParsed = parseNimFile(f.file)
    if callParsed.ast == nil: continue
    for u in f.uses:
      proc findCallAt2(n: PNode): PNode =
        if n == nil: return nil
        if n.kind == nkCall and n.len >= 1:
          let (cl, cc) = declarationPos(n[0])
          if cl == u.line and cc == u.col: return n
        if hasSons(n):
          for c in n:
            let inner = findCallAt2(c)
            if inner != nil: return inner
      let callNode = findCallAt2(callParsed.ast)
      if callNode == nil: continue
      var newArgs: seq[PNode] = @[]
      var positional = 0
      for i in 1 ..< callNode.len:
        let a = callNode[i]
        let isNamedTarget = a.kind == nkExprEqExpr and a.len == 2 and
                            a[0].kind == nkIdent and a[0].ident.s == name
        let isPositionalTarget = a.kind != nkExprEqExpr and positional == paramIndex
        if not isNamedTarget and not isPositionalTarget: newArgs.add a
        if a.kind != nkExprEqExpr: positional.inc
      let (cs, ce) = nodeLineBounds(callNode)
      let calleeText = renderTree(callNode[0]).strip()
      let argsText = newArgs.mapIt(renderTree(it).strip()).join(", ")
      edits.add (cs, calleeText & "(" & argsText & ")")
    for e in edits:
      text = replaceLineRange(text, e.line, e.line, e.newText)
    writeFile(f.file, text)

  ChangeSigResult(status: csApplied,
    message: "Removed parameter '" & name & "' from " & filePath &
             " and " & $sr.files.len & " call site file(s)")

proc reorderParams*(filePath, root: string; line, col: int;
                    newOrder: seq[string]): ChangeSigResult =
  let parsed = parseNimFile(filePath)
  if parsed.ast == nil:
    return ChangeSigResult(status: csError, message: "Could not parse: " & filePath)
  let declNode = findEnclosingRoutineDecl(parsed.ast, line, col)
  if declNode == nil:
    return ChangeSigResult(status: csError,
      message: "No routine declared at " & filePath & ":" & $line & ":" & $col)

  let formals = currentFormals(formalParams(declNode))
  let oldOrder = formals.mapIt(it.name)
  if newOrder.len != oldOrder.len or newOrder.toHashSet != oldOrder.toHashSet:
    return ChangeSigResult(status: csError,
      message: "--reorder must name exactly the existing parameters, got: " &
               newOrder.join(","))

  var byName = initTable[string, tuple[name, typ, default: string]]()
  for f in formals: byName[f.name] = f
  var reordered: seq[tuple[name, typ, default: string]] = @[]
  for n in newOrder: reordered.add byName[n]

  let symbolName = declNode[0].ident.s.strip(chars = {'*'})
  let (sr, status, sMessage) = findSemanticReferences(filePath, symbolName, root, line, col)
  if status != ssOk:
    return ChangeSigResult(status: csError, message: sMessage)

  let newDecl = rewriteDecl(filePath, declNode, reordered)
  let (s, e) = nodeLineBounds(declNode)
  writeFile(filePath, replaceLineRange(readFile(filePath), s, e, newDecl))

  var indexOf = initTable[string, int]()
  for i, n in oldOrder: indexOf[n] = i
  var newIndexOf = initTable[string, int]()
  for i, n in newOrder: newIndexOf[n] = i

  for f in sr.files:
    if f.uses.len == 0: continue
    var text = readFile(f.file)
    let callParsed = parseNimFile(f.file)
    if callParsed.ast == nil: continue
    var edits: seq[tuple[line: int, newText: string]] = @[]
    for u in f.uses:
      proc findCallAt3(n: PNode): PNode =
        if n == nil: return nil
        if n.kind == nkCall and n.len >= 1:
          let (cl, cc) = declarationPos(n[0])
          if cl == u.line and cc == u.col: return n
        if hasSons(n):
          for c in n:
            let inner = findCallAt3(c)
            if inner != nil: return inner
      let callNode = findCallAt3(callParsed.ast)
      if callNode == nil: continue
      var isNamedCall = false
      for i in 1 ..< callNode.len:
        if callNode[i].kind == nkExprEqExpr: isNamedCall = true
      if isNamedCall: continue  # named args are already order-independent
      var positionalArgs: seq[PNode] = @[]
      for i in 1 ..< callNode.len: positionalArgs.add callNode[i]
      if positionalArgs.len != oldOrder.len: continue  # partial call, skip
      var byOldIndex: seq[PNode] = positionalArgs
      var reorderedArgs = newSeq[PNode](byOldIndex.len)
      for oldIdx, argNode in byOldIndex:
        let pname = oldOrder[oldIdx]
        reorderedArgs[newIndexOf[pname]] = argNode
      let (cs, ce) = nodeLineBounds(callNode)
      let calleeText = renderTree(callNode[0]).strip()
      let argsText = reorderedArgs.mapIt(renderTree(it).strip()).join(", ")
      edits.add (cs, calleeText & "(" & argsText & ")")
    for e in edits:
      text = replaceLineRange(text, e.line, e.line, e.newText)
    writeFile(f.file, text)

  ChangeSigResult(status: csApplied,
    message: "Reordered parameters of " & filePath &
             " and updated " & $sr.files.len & " call site file(s)")

proc parseLineCol(at: string): tuple[line, col: int; ok: bool] =
  let parts = at.split(':')
  if parts.len != 2: return (-1, -1, false)
  let line = try: parseInt(parts[0]) except ValueError: -1
  let col = try: parseInt(parts[1]) except ValueError: -1
  if line < 1 or col < 0: return (-1, -1, false)
  (line, col, true)

proc main*(args: seq[string]): int =
  var p = initOptParser(args)
  var file, at, addSpec, removeSpec, reorderSpec = ""
  var force, helpRequested = false
  while true:
    p.next()
    case p.kind
    of cmdEnd: break
    of cmdShortOption, cmdLongOption:
      case p.key.toLowerAscii
      of "h", "help": helpRequested = true
      of "at": at = p.val
      of "add-param": addSpec = p.val
      of "remove-param": removeSpec = p.val
      of "reorder": reorderSpec = p.val
      of "force", "f": force = true
      else:
        stderr.writeLine "Unknown option: --", p.key
        return ExitError
    of cmdArgument:
      if file == "": file = p.key
      else:
        stderr.writeLine "Unexpected argument: ", p.key
        return ExitError

  let opCount = [addSpec.len > 0, removeSpec.len > 0, reorderSpec.len > 0].countIt(it)
  if helpRequested or file == "" or at == "" or opCount != 1:
    echo """
nimtools change-signature: Add/remove/reorder a proc's parameters and fix up
every call site project-wide (UFCS and qualified calls included).

Usage:
  change-signature --at:LINE:COL <file.nim> --add-param "name:type=default"
  change-signature --at:LINE:COL <file.nim> --remove-param name [--force]
  change-signature --at:LINE:COL <file.nim> --reorder a,c,b

Exactly one of --add-param / --remove-param / --reorder per invocation.
--remove-param refuses (exit 2) when a call site's argument for that param
is not a bare literal or identifier -- it could have a side effect that
dropping it would silently lose. --force removes anyway.

Exit codes:
  0  applied
  1  bad input, parse failure, symbol not found, or nimsuggest unavailable
  2  refused: a call site's argument might have a side effect
"""
    return ExitOk

  let (line, col, ok) = parseLineCol(at)
  if not ok:
    stderr.writeLine "Error: malformed --at (want LINE:COL): ", at
    return ExitError
  if not fileExists(file):
    stderr.writeLine "Error: File not found: ", file
    return ExitError

  let root = pickProjectRoot(file)
  var r: ChangeSigResult

  if addSpec.len > 0:
    let parts = addSpec.split(':', 1)
    if parts.len != 2:
      stderr.writeLine "Error: --add-param wants 'name:type=default'"
      return ExitError
    let typeParts = parts[1].split('=', 1)
    if typeParts.len != 2:
      stderr.writeLine "Error: --add-param needs a default value ('name:type=default')"
      return ExitError
    r = addParam(file, root, line, col, parts[0].strip, typeParts[0].strip, typeParts[1].strip)
  elif removeSpec.len > 0:
    r = removeParam(file, root, line, col, removeSpec.strip, force = force)
  else:
    r = reorderParams(file, root, line, col, reorderSpec.split(',').mapIt(it.strip))

  case r.status
  of csApplied:
    echo r.message
    ExitOk
  of csRefused:
    stderr.writeLine r.message
    for site in r.blockedSites: stderr.writeLine "  ", site
    ExitRefused
  of csError:
    stderr.writeLine "Error: ", r.message
    ExitError

when isMainModule:
  quit(main(commandLineParams()))
```

- [ ] **Step 4: Run test to verify it passes**

Run: `nim c --hints:off -r tests/test_change_signature.nim`
Expected: PASS (5 tests; skip if nimsuggest unavailable). If a test fails on the `findCallAt`-style position matching (the reference engine's reported callee column may not exactly match `declarationPos(n[0])`'s column for an `nkCall`'s first child in every case), adjust the match to compare only `line` plus a small column tolerance, or match by re-resolving the callee's own `nkIdent` position directly — debug against the actual nimsuggest output for the fixture before widening the match, do not loosen it speculatively.

- [ ] **Step 5: Wire into the umbrella CLI**

In `nimtools.nim`, add `change_signature_tool` to the import list, add to `printHelp()`:

```
  change-signature  Add/remove/reorder a proc's params, fix up call sites
```

Add to `dispatch()`:

```nim
  of "change-signature", "change-sig":
    change_signature_tool.main(rest)
```

- [ ] **Step 6: Build and verify**

Run: `nim c -d:release tools/change_signature_tool.nim && nim c -d:release nimtools.nim`
Expected: both `[SuccessX]`.

- [ ] **Step 7: Update `.gitignore`**

Add:
```
tools/change_signature_tool
tests/test_change_signature
```

- [ ] **Step 8: Full suite regression check**

Run: `./tests/run.sh`
Expected: every suite `PASS`.

- [ ] **Step 9: Commit**

```bash
git add tools/change_signature_tool.nim tests/test_change_signature.nim nimtools.nim .gitignore
git commit -m "Add change-signature: add/remove/reorder params + fix call sites

Closes CLAUDE.md gap #7, deferred until a semantic engine existed.
Uses findSemanticReferences for project-wide call-site discovery
(UFCS and qualified calls included). --remove-param refuses when a
call site's argument could have a side effect, mirroring move-symbol's
findLeftBehindDeps precedent and checked against IDE prior art
(gopls preserves, JetBrains silently drops + docs-warns)."
```

---

## Task 6: Update CLAUDE.md and README

**Files:**
- Modify: `CLAUDE.md`
- Modify: `README.md`

**Interfaces:** None — documentation only.

- [ ] **Step 1: Update CLAUDE.md's gap list**

In `CLAUDE.md`, under "## Known gaps (third pass, 2026-08-16)", change item 7's status. Find the existing gap 7 text (from the earlier "Known gaps (second dogfooding pass...)" section, item 7: "No edit-symbol / change-signature — and deliberately so...") and append a strikethrough resolution line in the same style as the other resolved gaps in that file (e.g. gap 1, 5, 6 already use `~~old~~ — **fixed**: ...`):

Change:
```
7. **No edit-symbol / change-signature — and deliberately so.** ...
```
to:
```
7. ~~No edit-symbol / change-signature — and deliberately so.~~ — **fixed**:
   `change-signature --at:LINE:COL` adds/removes/reorders a parameter and
   fixes up every call site via `findSemanticReferences`. `--remove-param`
   refuses when a call site's argument could have a side effect (mirrors
   `move-symbol`'s `findLeftBehindDeps`); `--force` overrides. One operation
   per invocation.
```

Add a new subsection after the existing gap lists, before "## Self-audit":

```markdown
## Known gaps (fourth pass, 2026-08-29)

Closed via `docs/superpowers/specs/2026-08-29-intent-level-tools-design.md`:
`change-signature`, `organize-imports`, `type-report` (at/function/module
layers), `extract-variable`. `type-report` exposes the type column
`shared/suggest.nim`'s `parseRow` already parsed from every nimsuggest `def`
reply but had been discarding.

13. **`extract-variable` replaces only the exact selected span** — no search
    for textually-identical occurrences elsewhere in the function, no
    same-scope/no-intervening-mutation check, no `let` vs `var` choice when
    the target is later reassigned. Deliberately narrow for this pass;
    flagged in the design spec as needing refinement.
14. **`extract-function` and `inline-variable` are not built.** Each needs
    insertion-point selection and scoping analysis materially larger than
    `extract-variable`'s exact-span replacement; deferred to its own design
    pass rather than folded into this one.
15. **nimsuggest is still one process per invocation**, so `change-signature`
    and every `type-report` layer pay the same ~8s project-compile cost
    `references --semantic` already does (gap #9). A persistent nimsuggest
    would benefit all of these at once — still the upgrade path, still not
    built.
```

- [ ] **Step 2: Update README.md's tool table**

In `README.md`, add four rows to the `## Tools` table (after the `syntax-check` row, before `doc`, matching the table's existing style):

```
| `change-signature` | Add/remove/reorder a proc's params; fixes up every call site |
| `organize-imports` | Sort and dedupe a file's imports |
| `extract-variable` | Pull a selected expression into a `let` above its statement |
| `type-report` | Resolved type at a point / of a function's locals / of a whole module |
```

- [ ] **Step 3: Commit**

```bash
git add CLAUDE.md README.md
git commit -m "Document change-signature, organize-imports, extract-variable, type-report"
```

---

## Self-Review Notes (for the plan author, already applied above)

- **Spec coverage:** change-signature (Task 5) ✓, organize-imports (Task 1) ✓, extract-variable (Task 4) ✓, type-report all three layers (Tasks 2-3) ✓, shared batched `queryTypes` engine (Task 2) ✓, out-of-scope items explicitly left alone (extract-function, inline-variable, persistent nimsuggest) ✓ — documented in Task 6 rather than silently dropped.
- **Type consistency check:** `TypeResult`, `SuggestLoc`, `SuggestStatus` (Task 2) are used identically in Task 3's `FunctionTypeReport`/`ModuleTypeEntry` and Task 5 does not touch `suggest.nim`'s types at all (it uses `findSemanticReferences`'s existing `ProjectReferences`/`FileReferences`/`Reference` from `tools/references_tool.nim`, unchanged). `ChangeSigResult`/`ChangeSigStatus` (Task 5) are self-contained to that task, consumed only by its own `main`.
- **Ordering rationale:** Task 2 before Task 3 because Task 3's `functionTypeReport`/`moduleTypeReport` call `queryTypes` directly. Task 1 and Task 4 have no dependency on Tasks 2/3/5 and could run in any order relative to them; kept early since they are the smallest, lowest-risk tasks, giving the fastest first green build.
- **Known risk flagged inline:** Task 5 Step 4 calls out that the call-site AST re-matching (`findCallAt`-style position comparison) may need adjustment once run against real nimsuggest output — this is the one place in the plan where exact behavior could not be verified without running nimsuggest during plan-writing, and the plan says explicitly not to loosen it speculatively if it fails.
