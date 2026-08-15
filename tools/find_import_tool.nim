import compiler/[ast]
import std/[os, strutils, json, sequtils, parseopt]
import ../shared/[compiler_env, ast_utils, path_resolver]

type
  MatchResult* = object
    symbol*: string
    kind*: string
    signature*: string
    module*: string
    packageName*: string
    filePath*: string
    line*: int
    scope*: string

proc matchesFilters(node: PNode, sig: string, kindStr: string,
                   filterKind, paramPattern, returnPattern: string): bool =
  if filterKind.len > 0 and filterKind.toLowerAscii != "all":
    if kindStr.toLowerAscii != filterKind.toLowerAscii:
      return false
  if paramPattern.len > 0:
    if not sig.toLowerAscii.contains(paramPattern.toLowerAscii):
      return false
  if returnPattern.len > 0:
    # Look for return colon part
    let colonIdx = sig.find(':')
    if colonIdx < 0: return false
    let retPart = sig.substr(colonIdx)
    if not retPart.toLowerAscii.contains(returnPattern.toLowerAscii):
      return false
  return true

proc searchSymbolsInFile*(modInfo: ModuleInfo, query: string,
                          filterKind = "all", paramPattern = "", returnPattern = ""): seq[MatchResult] =
  let content = try: readFile(modInfo.filePath) except: return @[]
  
  # Stage 1: Fast text prune
  if not content.contains(query):
    # Try case-insensitive prune if exact didn't match
    if not content.toLowerAscii.contains(query.toLowerAscii):
      return @[]
      
  # Stage 2: AST verification
  let parsed = parseNimString(content, modInfo.filePath)
  if parsed.ast == nil: return @[]
  
  let queryLower = query.toLowerAscii
  
  proc walk(n: PNode, acc: var seq[MatchResult]) =
    if n == nil: return
    
    if n.kind == nkTypeDef:
      let name = typeDefName(n)
      if (name == query or name.toLowerAscii == queryLower) and isExported(n):
        let sig = renderTypeDefConcise(n)
        if matchesFilters(n, sig, "type", filterKind, paramPattern, returnPattern):
          acc.add MatchResult(
            symbol: name,
            kind: "type",
            signature: sig,
            module: modInfo.importPath,
            packageName: modInfo.packageName,
            filePath: modInfo.filePath,
            line: n.info.line.int,
            scope: $modInfo.scope
          )
    elif n.kind in RoutineKinds:
      let name = routineName(n)
      if (name == query or name.toLowerAscii == queryLower) and isExported(n):
        let kindStr = case n.kind
          of nkProcDef: "proc"
          of nkFuncDef: "func"
          of nkMethodDef: "method"
          of nkIteratorDef: "iterator"
          of nkTemplateDef: "template"
          of nkMacroDef: "macro"
          of nkConverterDef: "converter"
          else: "routine"
        let sig = renderRoutineSignature(n)
        if matchesFilters(n, sig, kindStr, filterKind, paramPattern, returnPattern):
          acc.add MatchResult(
            symbol: name,
            kind: kindStr,
            signature: sig,
            module: modInfo.importPath,
            packageName: modInfo.packageName,
            filePath: modInfo.filePath,
            line: n.info.line.int,
            scope: $modInfo.scope
          )
    elif hasSons(n):
      for c in n: walk(c, acc)
      
  walk(parsed.ast, result)


proc findImport*(query: string, scopes: set[ModuleScope] = {scopeStdlib, scopeNimble, scopeProject},
                 filterKind = "all", paramPattern = "", returnPattern = ""): seq[MatchResult] =
  let candidateFiles = getCandidateNimFiles(scopes)
  for modInfo in candidateFiles:
    let matches = searchSymbolsInFile(modInfo, query, filterKind, paramPattern, returnPattern)
    result.add matches

proc main*(args: seq[string] = @[]) =
  var p = if args.len > 0: initOptParser(args) else: initOptParser()
  var query = ""
  var scopeStr = "all"
  var kindStr = "all"
  var paramFilter = ""
  var returnFilter = ""
  var jsonOutput = false
  var addToFile = ""
  var helpRequested = false

  while true:
    p.next()
    case p.kind
    of cmdEnd: break
    of cmdShortOption, cmdLongOption:
      case p.key.toLowerAscii
      of "h", "help": helpRequested = true
      of "s", "scope": scopeStr = p.val
      of "k", "kind": kindStr = p.val
      of "p", "params": paramFilter = p.val
      of "r", "returns": returnFilter = p.val
      of "j", "json": jsonOutput = true
      of "a", "add": addToFile = p.val
      else:
        stderr.writeLine "Unknown option: --", p.key
        quit(1)
    of cmdArgument:
      if query == "": query = p.key
      else:
        stderr.writeLine "Unexpected argument: ", p.key
        quit(1)

  if helpRequested or query == "":
    echo """
nimtools find-import: Search for function/type definitions and match import modules.

Usage:
  find-import <symbolName> [options]

Options:
  -s, --scope:<val>     Search scope: all, stdlib, nimble, project (default: all)
  -k, --kind:<val>      Filter symbol kind: all, proc, func, type, template, macro
  -p, --params:<val>    Filter signature by parameter type substring
  -r, --returns:<val>   Filter signature by return type substring
  -j, --json            Output matches as JSON for AI agents
  -a, --add:<file.nim>  Auto-insert 'import <module>' into target file
  -h, --help            Show this help message
"""
    quit(0)

  var scopes: set[ModuleScope] = {}
  case scopeStr.toLowerAscii
  of "stdlib": scopes = {scopeStdlib}
  of "nimble": scopes = {scopeNimble}
  of "project": scopes = {scopeProject}
  else: scopes = {scopeStdlib, scopeNimble, scopeProject}

  let matches = findImport(query, scopes, kindStr, paramFilter, returnFilter)

  if jsonOutput:
    var jArr = newJArray()
    for m in matches:
      jArr.add %*{
        "symbol": m.symbol,
        "kind": m.kind,
        "signature": m.signature,
        "module": m.module,
        "package": m.packageName,
        "file": m.filePath,
        "line": m.line,
        "scope": m.scope
      }
    echo $(%*{"query": query, "count": matches.len, "matches": jArr})
  else:
    if matches.len == 0:
      echo "No matches found for '", query, "'"
    else:
      echo "Found ", matches.len, " match(es) for '", query, "':\n"
      for i, m in matches:
        let origin = if m.packageName == "stdlib": "std" elif m.packageName == "local": "local" else: "pkg: " & m.packageName
        echo "[", i + 1, "] import ", m.module, "  (", origin, ")"
        echo "    ", m.signature
        echo "    --> ", m.filePath.extractFilename, ":", m.line
        echo ""

  if addToFile.len > 0 and matches.len > 0:
    let bestMatch = matches[0]
    echo "Adding 'import ", bestMatch.module, "' to ", addToFile, "..."
    # Auto-add import logic can be wired directly
    let targetContent = try: readFile(addToFile) except: ""
    let importLine = "import " & bestMatch.module
    if not targetContent.contains(importLine):
      writeFile(addToFile, importLine & "\n" & targetContent)
      echo "Successfully updated ", addToFile

when isMainModule:
  main()
