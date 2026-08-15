## extract: hand an agent exactly one symbol, and nothing else.
##
## The point is token economy. An agent that needs `renderTypeNode` should not
## read the 400-line file it lives in, and should not grep for it either —
## grep finds the name in call sites, comments and strings, and cannot tell you
## where the definition ends. This walks the parse tree, so the boundaries are
## the real ones.
##
## Signature-first by default: the agent gets the shape, the doc, and the cost
## (line span + complexity), then decides whether the body is worth the tokens.
## `--body` fetches the source. That default is the whole feature — always
## returning the body would just be a slower way to read the file.

import compiler/[ast]
import std/[os, strutils, json, parseopt]
import ../shared/[compiler_env, ast_utils, source_rewriter, exit_codes]

type
  Extracted* = object
    name*: string
    kind*: string       ## proc/func/type/...
    exported*: bool
    line*, endLine*: int
    sig*: string
    doc*: string
    cc*: int
    body*: string       ## populated only when requested

proc findSymbol*(filePath, symbol: string, withBody = false): seq[Extracted] =
  ## Returns every definition of `symbol` in `filePath`. More than one result
  ## means overloads (or a type and a proc sharing a name) — the caller is told
  ## about all of them rather than being handed an arbitrary first match, since
  ## an agent cannot notice it received the wrong overload.
  let parsed = parseNimFile(filePath)
  if parsed.ast == nil: return @[]
  let source = if withBody and fileExists(filePath): readFile(filePath) else: ""

  for n in collectRoutines(parsed.ast):
    if routineName(n) != symbol: continue
    let (lo, hi) = nodeLineBounds(n)
    result.add Extracted(
      name: symbol, kind: routineKindName(n), exported: isExported(n),
      line: n.info.line.int, endLine: hi,
      sig: renderRoutineSignature(n), doc: docComment(n),
      cc: calcCyclomaticComplexity(n),
      body: if withBody: extractLineRange(source, lo, hi) else: "")

  for n in collectTypeDefs(parsed.ast):
    if typeDefName(n) != symbol: continue
    let (lo, hi) = nodeLineBounds(n)
    result.add Extracted(
      name: symbol, kind: "type", exported: isExported(n),
      line: n.info.line.int, endLine: hi,
      sig: renderTypeDefConcise(n), doc: docComment(n), cc: 0,
      body: if withBody: extractLineRange(source, lo, hi) else: "")

proc toJson*(e: Extracted, filePath: string): JsonNode =
  ## Machine-readable form. `body` is present only when it was requested.
  result = %*{
    "name": e.name, "kind": e.kind, "exported": e.exported,
    "file": filePath, "line": e.line, "endLine": e.endLine,
    "sig": e.sig, "doc": e.doc, "cc": e.cc
  }
  if e.body.len > 0: result["body"] = %e.body

proc render(e: Extracted, filePath: string, withBody: bool): string =
  result = e.sig & "\n"
  if e.doc.len > 0:
    for line in e.doc.splitLines(): result &= "  ## " & line & "\n"
  let span = e.endLine - e.line + 1
  result &= "  " & filePath & ":" & $e.line & "-" & $e.endLine &
            "  (" & $span & " ln"
  if e.cc > 0: result &= ", cc=" & $e.cc
  result &= ")\n"
  if withBody:
    result &= "\n" & e.body & "\n"
  else:
    result &= "\n  --body to fetch source\n"

proc main*(args: seq[string]): int =
  ## CLI entry. Returns an exit code rather than quitting, so the umbrella
  ## dispatcher stays in control of the process.
  var p = initOptParser(args)
  var targetFile, symbol = ""
  var withBody, asJson, helpRequested = false

  while true:
    p.next()
    case p.kind
    of cmdEnd: break
    of cmdShortOption, cmdLongOption:
      case p.key.toLowerAscii
      of "h", "help": helpRequested = true
      of "b", "body": withBody = true
      of "j", "json": asJson = true
      else:
        stderr.writeLine "Unknown option: --", p.key
        return ExitError
    of cmdArgument:
      if targetFile == "": targetFile = p.key
      elif symbol == "": symbol = p.key

  if helpRequested or targetFile == "" or symbol == "":
    echo """
nimtools extract: Print one symbol without reading the whole file.

Usage:
  extract [--body] [--json] <file.nim> <symbol>

Options:
  -b, --body   include the full source of the symbol
  -j, --json   machine-readable output
"""
    return ExitOk

  if not fileExists(targetFile):
    stderr.writeLine "Error: File not found: ", targetFile
    return ExitError

  let found = findSymbol(targetFile, symbol, withBody)
  if found.len == 0:
    stderr.writeLine "Error: Symbol '", symbol, "' not found in ", targetFile
    return ExitError

  if asJson:
    var arr = newJArray()
    for e in found: arr.add e.toJson(targetFile)
    echo (if found.len == 1: arr[0] else: arr).pretty()
  else:
    if found.len > 1:
      echo found.len, " definitions of '", symbol, "':\n"
    for e in found:
      echo render(e, targetFile, withBody)
  return ExitOk

when isMainModule:
  quit(main(commandLineParams()))
