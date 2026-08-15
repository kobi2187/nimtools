import compiler/[ast]
import std/[os, json, parseopt]
import ../shared/[compiler_env, ast_utils]
import import_tool

type
  InspectTypeInfo = object
    name: string
    exported: bool
    line: int
    repr: string

  InspectRoutineInfo = object
    name: string
    kind: string
    exported: bool
    line: int
    sig: string
    cc: int
    lines: int

proc inspectFile*(filePath: string): JsonNode =
  if not fileExists(filePath):
    return %*{"error": "File not found: " & filePath}

  let parsed = parseNimFile(filePath)
  if parsed.ast == nil:
    return %*{"error": "Could not parse file", "errors": parsed.errors}

  let imports = extractExistingImports(parsed.ast)
  
  var types: seq[InspectTypeInfo] = @[]
  var routines: seq[InspectRoutineInfo] = @[]

  proc walk(n: PNode) =
    if n == nil: return
    if n.kind == nkTypeDef:
      let name = typeDefName(n)
      types.add InspectTypeInfo(
        name: name,
        exported: isExported(n),
        line: n.info.line.int,
        repr: renderTypeDefConcise(n)
      )
    elif n.kind in RoutineKinds:
      let name = routineName(n)
      let kindStr = case n.kind
        of nkProcDef: "proc"
        of nkFuncDef: "func"
        of nkMethodDef: "method"
        of nkIteratorDef: "iterator"
        of nkTemplateDef: "template"
        of nkMacroDef: "macro"
        of nkConverterDef: "converter"
        else: "routine"
      let (lo, hi) = nodeLineBounds(n)
      let spanLines = if hi >= lo and lo > 0: hi - lo + 1 else: 1
      routines.add InspectRoutineInfo(
        name: name,
        kind: kindStr,
        exported: isExported(n),
        line: n.info.line.int,
        sig: renderRoutineSignature(n),
        cc: calcCyclomaticComplexity(n),
        lines: spanLines
      )
    elif hasSons(n):
      for c in n: walk(c)

  walk(parsed.ast)

  # Complexity summary
  var maxCc = 0
  var over5 = 0
  var debt = 0
  for r in routines:
    if r.cc > maxCc: maxCc = r.cc
    if r.cc > 5:
      over5.inc
      debt += (r.cc - 5)

  var jTypes = newJArray()
  for t in types:
    jTypes.add %*{
      "name": t.name,
      "exported": t.exported,
      "line": t.line,
      "repr": t.repr
    }

  var jRoutines = newJArray()
  for r in routines:
    jRoutines.add %*{
      "name": r.name,
      "kind": r.kind,
      "exported": r.exported,
      "line": r.line,
      "sig": r.sig,
      "cc": r.cc,
      "lines": r.lines
    }

  result = %*{
    "file": filePath,
    "imports": imports,
    "types": jTypes,
    "routines": jRoutines,
    "complexity": {
      "totalRoutines": routines.len,
      "over5": over5,
      "maxCc": maxCc,
      "debt": debt
    }
  }

proc main*() =
  var p = initOptParser()
  var targetFile = ""
  var helpRequested = false

  while true:
    p.next()
    case p.kind
    of cmdEnd: break
    of cmdShortOption, cmdLongOption:
      case p.key
      of "h", "help": helpRequested = true
    of cmdArgument:
      if targetFile == "": targetFile = p.key

  if helpRequested or targetFile == "":
    echo """
nimtools inspect: Machine-readable JSON summary of types, procs, imports, and AST complexity.

Usage:
  inspect <file.nim>
"""
    quit(0)

  let report = inspectFile(targetFile)
  echo report.pretty()

when isMainModule:
  main()
