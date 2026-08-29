## type-report: hover-equivalent type resolution, in three layers over one
## shared batched engine (shared/suggest.queryTypes).
##
## - `at`: caller-supplied file:line:col points, passed straight through. The
##   building block; covers what the curated layers below cannot (a specific
##   argument inside a call, a sub-expression not bound to a name).
## - `function`: locals of one proc.
## - `module`: every top-level declaration.

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

proc identDefName(n: PNode): tuple[name: string, line, col: int] =
  ## `n` is one name slot of an nkIdentDefs/nkConstDef -- either a bare
  ## nkIdent, or nkPostfix wrapping one when the binding is exported with `*`.
  ## Unlike declarationPos (which expects a routine/typedef container and reads
  ## its child[0]), this takes the name node itself.
  var nameNode = n
  if nameNode.kind == nkPostfix and nameNode.len > 1: nameNode = nameNode[1]
  let nm = if nameNode.kind == nkIdent: nameNode.ident.s else: "<anon>"
  (nm, nameNode.info.line.int, nameNode.info.col.int)

proc localBindingLocs(routineNode: PNode, file: string): seq[tuple[name: string, loc: SuggestLoc]] =
  ## Every var/let/const declared directly in the routine's body (not nested
  ## routines -- collectRoutines-style unconditional recursion would descend
  ## into those too, which is why this walk stops at a nested RoutineKinds
  ## node instead of recursing into it).
  var acc: seq[tuple[name: string, loc: SuggestLoc]] = @[]
  proc walk(n: PNode) =
    if n == nil: return
    if n.kind in RoutineKinds and n != routineNode: return  # don't cross into nested routines
    if n.kind in {nkVarSection, nkLetSection, nkConstSection}:
      for defs in n:
        if defs.kind notin {nkIdentDefs, nkConstDef}: continue
        for i in 0 .. defs.len - 3:
          let (nm, line, col) = identDefName(defs[i])
          acc.add (nm, SuggestLoc(file: file, line: line, col: col))
    if hasSons(n):
      for c in n: walk(c)
  if routineNode.len >= 7: walk(routineNode[6])  # body only, not params
  acc

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
        let (nm, l, c) = identDefName(defs[i])
        names.add nm
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

when isMainModule:
  quit(atMain(commandLineParams()))
