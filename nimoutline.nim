import compiler / [ast, parser, idents, options, renderer, lineinfos]
import std/[strutils, parseopt, os]

type
  OutlineItem = object
    line: int
    content: string

proc hasSons(n: PNode): bool =
  n != nil and n.kind notin {nkCharLit..nkUInt64Lit, nkFloatLit..nkFloat128Lit, nkStrLit..nkTripleStrLit, nkSym, nkIdent, nkEmpty}

proc renderTypeNode(n: PNode): string =
  if n == nil: return ""
  case n.kind
  of nkIdent:
    return n.ident.s
  of nkSym:
    return n.sym.name.s
  of nkPostfix:
    if n.len >= 2:
      return renderTypeNode(n[1]) & n[0].ident.s
    else:
      return renderTree(n)
  of nkPragmaExpr:
    if n.len >= 2:
      return renderTypeNode(n[0]) & " " & renderTree(n[1])
    else:
      return renderTree(n)
  of nkDistinctTy:
    return if n.len > 0: "distinct " & renderTypeNode(n[0]) else: "distinct"
  of nkRefTy:
    return if n.len > 0: "ref " & renderTypeNode(n[0]) else: "ref"
  of nkPtrTy:
    return if n.len > 0: "ptr " & renderTypeNode(n[0]) else: "ptr"
  of nkBracketExpr:
    var res = renderTypeNode(n[0]) & "["
    for i in 1 ..< n.len:
      if i > 1: res &= ", "
      res &= renderTypeNode(n[i])
    res &= "]"
    return res
  of nkObjectTy:
    var res = "object"
    if n[1].kind != nkEmpty:
      res &= " " & renderTree(n[1])
    if n[2].kind != nkEmpty:
      res &= " { " & renderTypeNode(n[2]) & " }"
    return res
  of nkRecList:
    var fields: seq[string] = @[]
    for child in n:
      fields.add(renderTypeNode(child))
    return fields.join(", ")
  of nkIdentDefs:
    if n.len >= 3:
      var names: seq[string] = @[]
      for i in 0 .. n.len - 3:
        names.add(renderTree(n[i]))
      let typStr = renderTypeNode(n[n.len - 2])
      let defVal = n[n.len - 1]
      var res = names.join(", ") & ": " & typStr
      if defVal.kind != nkEmpty:
        res &= " = " & renderTree(defVal)
      return res
    else:
      return renderTree(n)
  of nkEnumTy:
    var vals: seq[string] = @[]
    for i in 1 ..< n.len:
      vals.add(renderTree(n[i]))
    return "enum { " & vals.join(", ") & " }"
  of nkTupleTy:
    var fields: seq[string] = @[]
    for child in n:
      fields.add(renderTypeNode(child))
    return "tuple { " & fields.join(", ") & " }"
  of nkProcTy:
    var res = "proc"
    if n[0].kind != nkEmpty:
      res &= renderTree(n[0])
    if n[1].kind != nkEmpty:
      res &= " " & renderTree(n[1])
    return res
  of nkRecCase:
    var res = "case " & renderTypeNode(n[0])
    for i in 1 ..< n.len:
      let branch = n[i]
      if branch.kind == nkOfBranch:
        var vals: seq[string] = @[]
        for j in 0 .. branch.len - 2:
          vals.add(renderTree(branch[j]))
        res &= " of " & vals.join(", ") & ": (" & renderTypeNode(branch[branch.len - 1]) & ")"
      elif branch.kind == nkElse:
        res &= " else: (" & renderTypeNode(branch[0]) & ")"
    return res
  else:
    return renderTree(n).replace("\n", " ").replace("  ", " ").strip()

proc renderTypeDefConcise(n: PNode): string =
  assert n.kind == nkTypeDef
  let nameStr = renderTree(n[0])
  let genericsStr = if n[1].kind != nkEmpty: renderTree(n[1]) else: ""
  let bodyStr = renderTypeNode(n[2])
  result = "type " & nameStr & genericsStr & " = " & bodyStr

proc main() =
  var p = initOptParser()
  var inputFile = ""
  var outputFile = ""
  var helpRequested = false

  while true:
    p.next()
    case p.kind
    of cmdEnd: break
    of cmdShortOption, cmdLongOption:
      case p.key
      of "h", "help":
        helpRequested = true
      of "o", "out":
        outputFile = p.val
      else:
        stderr.writeLine "Error: Unknown option: " & p.key
        quit(1)
    of cmdArgument:
      if inputFile == "":
        inputFile = p.key
      elif outputFile == "":
        outputFile = p.key
      else:
        stderr.writeLine "Error: Unexpected argument: " & p.key
        quit(1)

  if helpRequested or inputFile == "":
    echo """
nimoutline - Nim source code summary generator

Usage:
  nimoutline <input_file.nim> [options]

Options:
  -o, --out:<file>   Specify the output text file path.
                     If not specified, defaults to <input_file>.outline.txt
  -h, --help         Show this help message.
"""
    quit(0)

  if not fileExists(inputFile):
    stderr.writeLine "Error: File does not exist: " & inputFile
    quit(1)

  let content = try:
    readFile(inputFile)
  except CatchableError as e:
    stderr.writeLine "Error: Could not read file: " & e.msg
    quit(1)

  let cache = newIdentCache()
  let config = newConfigRef()

  # Set compiler settings to prevent exit and capture messages
  config.ideCmd = ideSug
  config.errorMax = 1000
  config.writelnHook = proc(output: string) {.closure, gcsafe.} = discard

  var errors: seq[string] = @[]
  config.structuredErrorHook = proc(conf: ConfigRef; info: TLineInfo; msg: string; severity: Severity) {.closure, gcsafe.} =
    {.cast(gcsafe).}:
      if severity == Severity.Error:
        errors.add("Line " & $info.line & ", col " & $info.col & ": " & msg)

  let root = parseString(content, cache, config, inputFile)

  if errors.len > 0:
    stderr.writeLine "Error: Syntax errors in " & inputFile & ":"
    for err in errors:
      stderr.writeLine "  " & err
    quit(1)

  var
    types: seq[OutlineItem] = @[]
    routines: seq[OutlineItem] = @[]

  proc walk(n: PNode) =
    if n == nil: return
    if n.kind == nkTypeDef:
      types.add OutlineItem(line: n.info.line.int, content: renderTypeDefConcise(n))
    elif n.kind in routineDefs:
      routines.add OutlineItem(line: n.info.line.int, content: renderTree(n, {renderNoBody, renderNoComments}))
    elif hasSons(n):
      for i in 0 ..< n.len:
        walk(n[i])

  walk(root)

  # Generate outline text
  var outputLines: seq[string] = @[]
  outputLines.add "Outline of " & inputFile
  outputLines.add "Generated by nimoutline"
  outputLines.add ""
  outputLines.add "================================================================================"
  outputLines.add "TYPES"
  outputLines.add "================================================================================"
  if types.len == 0:
    outputLines.add "(no types defined)"
  else:
    for t in types:
      outputLines.add "Line " & align($t.line, 4) & ": " & t.content

  outputLines.add ""
  outputLines.add "================================================================================"
  outputLines.add "ROUTINES"
  outputLines.add "================================================================================"
  if routines.len == 0:
    outputLines.add "(no routines defined)"
  else:
    for r in routines:
      outputLines.add "Line " & align($r.line, 4) & ": " & r.content

  let outputText = outputLines.join("\n") & "\n"

  if outputFile == "":
    outputFile = inputFile.changeFileExt("outline.txt")

  try:
    writeFile(outputFile, outputText)
    echo "Outline successfully written to: ", outputFile
  except CatchableError as e:
    stderr.writeLine "Error: Could not write outline to: " & outputFile & " (" & e.msg & ")"
    quit(1)

when isMainModule:
  main()
