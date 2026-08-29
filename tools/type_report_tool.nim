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

when isMainModule:
  quit(atMain(commandLineParams()))
