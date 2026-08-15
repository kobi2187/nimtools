import compiler/[ast]
import std/[os, strutils, algorithm, parseopt]
import ../shared/[compiler_env, ast_utils, source_rewriter, path_resolver]
import import_tool

type
  MoveStatus* = enum
    mvMoved      ## symbols were moved
    mvRefused    ## refused: moving would break the destination
    mvError      ## bad input: missing file, parse failure, symbol not found

  MoveResult* = object
    status*: MoveStatus
    message*: string
    deps*: seq[string]   ## on mvRefused: names that would be left behind

proc collectIdents(n: PNode, acc: var seq[string]) =
  ## Gathers every identifier appearing anywhere under `n`.
  if n == nil: return
  if n.kind == nkIdent:
    acc.add n.ident.s
  elif hasSons(n):
    for c in n: collectIdents(c, acc)

proc findLeftBehindDeps*(root: PNode, moved: seq[FoundSymbol]): seq[string] =
  ## Returns names defined in the source file that the moved code references
  ## but which are NOT themselves being moved. These are exactly the symbols
  ## that would become undeclared identifiers in the destination file.
  var movedNames: seq[string] = @[]
  for m in moved: movedNames.add m.name

  var staying: seq[string] = @[]
  for n in collectTypeDefs(root):
    let nm = typeDefName(n)
    if nm notin movedNames: staying.add nm
  for n in collectRoutines(root):
    let nm = routineName(n)
    if nm notin movedNames: staying.add nm

  var used: seq[string] = @[]
  for m in moved: collectIdents(m.node, used)

  for name in staying:
    if name in used and name notin result:
      result.add name

proc moveSymbols*(sourceFile, destFile: string, symbolNames: seq[string],
                  force = false): MoveResult =
  if not fileExists(sourceFile):
    return MoveResult(status: mvError, message: "Source file not found: " & sourceFile)

  let sourceContent = readFile(sourceFile)
  let parsed = parseNimString(sourceContent, sourceFile)
  if parsed.ast == nil:
    return MoveResult(status: mvError, message: "Could not parse source file: " & sourceFile)

  let foundSymbols = findSymbolNodes(parsed.ast, symbolNames)
  if foundSymbols.len == 0:
    return MoveResult(status: mvError,
      message: "None of the specified symbols were found in " & sourceFile)

  # Refuse before writing anything if the move would break the destination.
  if not force:
    let missing = findLeftBehindDeps(parsed.ast, foundSymbols)
    if missing.len > 0:
      return MoveResult(status: mvRefused, deps: missing, message:
        "Refusing to move: the moved code references " & missing.join(", ") &
        ", which would stay in " & sourceFile & " and become undeclared in " &
        destFile & ". Move them together, or pass --force to move anyway.")

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
  writeFile(sourceFile, stripBlankLines(updatedSource) & "\n")
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

  # Wire the import in the source file ONLY when code that stayed behind still
  # references a moved symbol. Adding it unconditionally leaves a dead import
  # (and an `unused-imports` warning) when the move took the module's only proc.
  var movedNames: seq[string] = @[]
  for s in foundSymbols: movedNames.add s.name
  var remainingIdents: seq[string] = @[]
  let remainingAst = parseNimString(stripBlankLines(updatedSource), sourceFile).ast
  if remainingAst != nil: collectIdents(remainingAst, remainingIdents)
  var needsImport = false
  for nm in movedNames:
    if nm in remainingIdents: needsImport = true
  if needsImport:
    let relImport = resolveProjectImportPath(destFile, sourceFile)
    discard addImportToFile(sourceFile, relImport)
  return MoveResult(status: mvMoved,
    message: "Moved " & $foundSymbols.len & " symbol(s) to " & destFile)

proc main*() =
  var p = initOptParser()
  var sourceFile = ""
  var destFile = ""
  var symbols: seq[string] = @[]
  var helpRequested = false
  var forceMove = false

  while true:
    p.next()
    case p.kind
    of cmdEnd: break
    of cmdShortOption, cmdLongOption:
      case p.key.toLowerAscii
      of "h", "help": helpRequested = true
      of "f", "force": forceMove = true
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
  move-symbol [--force] <source.nim> <destination.nim> <symbol1> [symbol2 ...]

Refuses (exit 2) when the moved code references symbols that would stay behind.
  --force, -f   move anyway, even if the destination will not compile

Examples:
  move-symbol src/app.nim src/utils.nim sanitizeInput formatSummary
"""
    quit(0)

  let r = moveSymbols(sourceFile, destFile, symbols, force = forceMove)
  case r.status
  of mvMoved:
    echo r.message
  of mvRefused:
    stderr.writeLine r.message
    quit(2)
  of mvError:
    stderr.writeLine "Error: ", r.message
    quit(1)

when isMainModule:
  main()
