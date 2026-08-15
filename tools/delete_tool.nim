## delete-symbol: remove a proc/type definition — `move-symbol` without a
## destination. Its own role, not a flag on move. Refuses when a deleted symbol
## is still referenced elsewhere in the file (checked with the scope model), so
## it cannot emit an undeclared identifier. `--force` overrides.

import compiler/[ast]
import std/[os, strutils, algorithm, parseopt]
import ../shared/[compiler_env, ast_utils, source_rewriter, scope_rename, exit_codes]

type
  DeleteStatus* = enum
    delDeleted    ## the definitions were removed
    delRefused    ## refused: a deleted symbol is still referenced in-file
    delError      ## bad input: missing file, parse failure, symbol not found

  DeleteResult* = object
    status*: DeleteStatus
    message*: string

proc deleteSymbols*(filePath: string, symbolNames: seq[string],
                    force = false): DeleteResult =
  if not fileExists(filePath):
    return DeleteResult(status: delError, message: "File not found: " & filePath)

  let source = readFile(filePath)
  let parsed = parseNimString(source, filePath)
  if parsed.ast == nil:
    return DeleteResult(status: delError, message: "Could not parse: " & filePath)

  let found = findSymbolNodes(parsed.ast, symbolNames)
  if found.len == 0:
    return DeleteResult(status: delError,
      message: "None of the specified symbols were found in " & filePath)

  # Refuse before writing if any deleted symbol is still used in the file.
  if not force:
    var stillUsed: seq[string] = @[]
    for sym in found:
      for r in findReferences(source, filePath, sym.name):
        if r.uses.len > 0:
          stillUsed.add sym.name & " (" & $r.uses.len & " use(s))"
    if stillUsed.len > 0:
      return DeleteResult(status: delRefused, message:
        "Refusing to delete: still referenced in " & filePath & ": " &
        stillUsed.join(", ") & ". Pass --force to delete anyway.")

  var sorted = found
  sorted.sort(proc(a, b: FoundSymbol): int = cmp(b.startLine, a.startLine))
  var updated = source
  for sym in sorted:
    updated = replaceLineRange(updated, sym.startLine, sym.endLine, "")

  writeFile(filePath, stripBlankLines(updated))
  DeleteResult(status: delDeleted,
    message: "Deleted " & $found.len & " symbol(s) from " & filePath)

proc deleteMain*(args: seq[string]): int =
  ## CLI entry for `nimtools delete-symbol`.
  var p = initOptParser(args)
  var file = ""
  var symbols: seq[string] = @[]
  var force, helpRequested = false

  while true:
    p.next()
    case p.kind
    of cmdEnd: break
    of cmdShortOption, cmdLongOption:
      case p.key.toLowerAscii
      of "h", "help": helpRequested = true
      of "f", "force": force = true
      else:
        stderr.writeLine "Unknown option: --", p.key
        return ExitError
    of cmdArgument:
      if file == "": file = p.key
      else: symbols.add p.key

  if helpRequested or file == "" or symbols.len == 0:
    echo """\
nimtools delete-symbol: Remove a proc/type definition from a file.

Usage:
  delete-symbol [--force] <file.nim> <symbol1> [symbol2 ...]

Refuses (exit 2) when a deleted symbol is still referenced elsewhere in the
file, since that would emit undeclared identifiers. In-file only — a
project-wide guard is not yet written; check `references --project` first.

  --force, -f   delete anyway, even if the file will not compile
"""
    return ExitOk

  let r = deleteSymbols(file, symbols, force = force)
  case r.status
  of delDeleted: echo r.message; ExitOk
  of delRefused: stderr.writeLine r.message; ExitRefused
  of delError:   stderr.writeLine "Error: ", r.message; ExitError

when isMainModule:
  quit(deleteMain(commandLineParams()))
