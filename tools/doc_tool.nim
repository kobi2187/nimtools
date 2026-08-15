## missing-docs: exported routines with no doc comment.
##
## Exported symbols are the API surface — those are the ones a caller reads
## without opening the file, so those are the ones worth documenting. Private
## helpers are excluded by default (`--all` includes them).
##
## This is a filter over the same walker `inspect` and `extract` use, so it
## sees nested routines and skips bodiless forward declarations for free.

import std/[os, strutils, json, parseopt]
import ../shared/[compiler_env, ast_utils, exit_codes]

type
  UndocRoutine* = object
    name*, kind*, sig*, file*: string
    line*, cc*: int

proc findUndocumented*(filePath: string, includePrivate = false): seq[UndocRoutine] =
  ## Routines in `filePath` with no doc comment. Exported only unless
  ## `includePrivate`. Returns an empty seq when the file cannot be parsed.
  let parsed = parseNimFile(filePath)
  if parsed.ast == nil: return @[]
  for n in collectRoutines(parsed.ast):
    if not includePrivate and not isExported(n): continue
    if docComment(n).len > 0: continue
    result.add UndocRoutine(
      name: routineName(n), kind: routineKindName(n),
      sig: renderRoutineSignature(n), file: filePath,
      line: n.info.line.int, cc: calcCyclomaticComplexity(n))

proc main*(args: seq[string]): int =
  ## CLI entry. Returns an exit code rather than quitting, so the umbrella
  ## dispatcher stays in control of the process.
  var p = initOptParser(args)
  var files: seq[string] = @[]
  var includePrivate, asJson, helpRequested = false

  while true:
    p.next()
    case p.kind
    of cmdEnd: break
    of cmdShortOption, cmdLongOption:
      case p.key.toLowerAscii
      of "h", "help": helpRequested = true
      of "a", "all": includePrivate = true
      of "j", "json": asJson = true
      else:
        stderr.writeLine "Unknown option: --", p.key
        return ExitError
    of cmdArgument: files.add p.key

  if helpRequested or files.len == 0:
    echo """
nimtools missing-docs: List routines that have no doc comment.

Usage:
  missing-docs [--all] [--json] FILE...

Options:
  -a, --all    include private routines (default: exported only)
  -j, --json   machine-readable output
"""
    return ExitOk

  var all: seq[UndocRoutine] = @[]
  for f in files:
    if not fileExists(f):
      stderr.writeLine "Error: File not found: ", f
      return ExitError
    all.add findUndocumented(f, includePrivate)

  if asJson:
    var arr = newJArray()
    for u in all:
      arr.add %*{"name": u.name, "kind": u.kind, "sig": u.sig,
                 "file": u.file, "line": u.line, "cc": u.cc}
    echo arr.pretty()
  else:
    if all.len == 0:
      echo "All ", (if includePrivate: "" else: "exported "), "routines documented."
    else:
      echo all.len, " undocumented ",
           (if includePrivate: "" else: "exported "), "routine(s):"
      for u in all:
        echo "  ", u.file, ":", u.line, "  ", u.kind, " ", u.name
  return ExitOk

when isMainModule:
  quit(main(commandLineParams()))
