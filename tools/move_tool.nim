import compiler/[ast]
import std/[os, strutils, algorithm, parseopt]
import ../shared/[compiler_env, ast_utils, source_rewriter, path_resolver]
import import_tool

type
  FoundSymbol = object
    name: string
    node: PNode
    startLine: int
    endLine: int

proc findSymbolNodes(root: PNode, symbolNames: seq[string]): seq[FoundSymbol] =
  var targets = symbolNames
  
  proc walk(n: PNode, acc: var seq[FoundSymbol]) =
    if n == nil: return
    if n.kind == nkTypeDef:
      let name = typeDefName(n)
      if name in targets:
        let (s, e) = nodeLineBounds(n)
        acc.add FoundSymbol(name: name, node: n, startLine: s, endLine: e)
    elif n.kind in RoutineKinds:
      let name = routineName(n)
      if name in targets:
        let (s, e) = nodeLineBounds(n)
        acc.add FoundSymbol(name: name, node: n, startLine: s, endLine: e)
    elif hasSons(n):
      for c in n: walk(c, acc)
      
  walk(root, result)

proc moveSymbols*(sourceFile, destFile: string, symbolNames: seq[string]): bool =
  if not fileExists(sourceFile):
    stderr.writeLine "Error: Source file not found: ", sourceFile
    return false

  let sourceContent = readFile(sourceFile)
  let parsed = parseNimString(sourceContent, sourceFile)
  if parsed.ast == nil:
    stderr.writeLine "Error: Could not parse source file: ", sourceFile
    return false

  let foundSymbols = findSymbolNodes(parsed.ast, symbolNames)
  if foundSymbols.len == 0:
    stderr.writeLine "Error: None of the specified symbols were found in ", sourceFile
    return false

  # Sort backwards by startLine so removing them doesn't invalidate subsequent line offsets
  var sortedSymbols = foundSymbols
  sortedSymbols.sort(proc(a, b: FoundSymbol): int = cmp(b.startLine, a.startLine))

  var extractedBlocks: seq[string] = @[]
  var updatedSource = sourceContent

  for sym in sortedSymbols:
    let rawCode = extractLineRange(sourceContent, sym.startLine, sym.endLine)
    # Ensure exported with '*'
    let exportedCode = ensureSymbolExported(rawCode, sym.name)
    extractedBlocks.add exportedCode
    # Cut from source
    updatedSource = replaceLineRange(updatedSource, sym.startLine, sym.endLine, "")
    echo "Extracted '", sym.name, "' (lines ", sym.startLine, "..", sym.endLine, ")"

  # Write back updated source
  writeFile(sourceFile, updatedSource.strip(trailing = true) & "\n")
  echo "Removed extracted symbols from ", sourceFile

  # Reverse extractedBlocks back to original order
  extractedBlocks.reverse()
  let appendedCode = extractedBlocks.join("\n\n") & "\n"

  # Append to destination file
  if fileExists(destFile):
    let destContent = readFile(destFile)
    writeFile(destFile, destContent.strip(trailing = true) & "\n\n" & appendedCode)
    echo "Appended ", extractedBlocks.len, " symbol(s) to ", destFile
  else:
    writeFile(destFile, appendedCode)
    echo "Created destination file ", destFile, " with ", extractedBlocks.len, " symbol(s)"

  # Auto-wire import in source file
  let relImport = resolveProjectImportPath(destFile, sourceFile)
  discard addImportToFile(sourceFile, relImport)
  return true

proc main*() =
  var p = initOptParser()
  var sourceFile = ""
  var destFile = ""
  var symbols: seq[string] = @[]
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
        quit(1)
    of cmdArgument:
      if sourceFile == "": sourceFile = p.key
      elif destFile == "": destFile = p.key
      else: symbols.add p.key

  if helpRequested or sourceFile == "" or destFile == "" or symbols.len == 0:
    echo """
nimtools move-symbol: Move procs/types from one file to another, auto-exporting and wiring imports.

Usage:
  move-symbol <source.nim> <destination.nim> <symbol1> [symbol2 ...]

Examples:
  move-symbol src/app.nim src/utils.nim sanitizeInput formatSummary
"""
    quit(0)

  if moveSymbols(sourceFile, destFile, symbols):
    echo "Refactoring completed successfully."
  else:
    quit(1)

when isMainModule:
  main()
