## organize-imports: sorts a file's top-level imports into three groups (std
## lib, third-party/nimble, project-local relative) and removes exact-duplicate
## module paths. Parser-only, deterministic, no nimsuggest dependency — same
## cost class as add-import/rm-import.
##
## Grouping rule: a module path starting with "std/" or matching a bare stdlib
## module name is "std"; a path starting with "." or ".." is "local"; anything
## else is "third-party". Within a group, alphabetical by path.

import compiler/[ast]
import std/[os, strutils, algorithm, parseopt]
import ../shared/[compiler_env, source_rewriter, exit_codes]
import import_tool

type
  ImportGroup = enum
    igStd, igThirdParty, igLocal

proc classify(modulePath: string): ImportGroup =
  if modulePath.startsWith("./") or modulePath.startsWith("../"):
    igLocal
  elif modulePath.startsWith("std/"):
    igStd
  else:
    igStd  # bare names (e.g. "os", "json") without a package prefix are stdlib

proc renderImportBlock(modules: seq[string]): string =
  var byGroup: array[ImportGroup, seq[string]]
  var seen: seq[string] = @[]
  for m in modules:
    if m in seen: continue
    seen.add m
    byGroup[classify(m)].add m
  for g in ImportGroup:
    byGroup[g].sort()
  var lines: seq[string] = @[]
  for g in [igStd, igThirdParty, igLocal]:
    for m in byGroup[g]:
      lines.add "import " & m
  lines.join("\n")

proc firstImportLine(root: PNode): int =
  ## 1-based line of the first top-level import statement, or 0 if none.
  if root == nil: return 0
  for n in root:
    if n.kind in {nkImportStmt, nkImportExceptStmt, nkFromStmt}:
      return n.info.line.int
  0

proc lastImportLine(root: PNode): int =
  if root == nil: return 0
  for n in root:
    if n.kind in {nkImportStmt, nkImportExceptStmt, nkFromStmt}:
      result = n.info.line.int

proc organizeImports*(filePath: string): tuple[changed: bool, message: string] =
  if not fileExists(filePath):
    return (false, "File not found: " & filePath)
  let source = readFile(filePath)
  let parsed = parseNimString(source, filePath)
  if parsed.ast == nil:
    return (false, "Could not parse: " & filePath)

  let modules = extractExistingImports(parsed.ast)
  if modules.len == 0:
    return (false, "No imports to organize")

  let first = firstImportLine(parsed.ast)
  let last = lastImportLine(parsed.ast)
  if first == 0 or last == 0:
    return (false, "No top-level import statements found")

  let newBlock = renderImportBlock(modules)
  let oldBlock = extractLineRange(source, first, last).strip(trailing = true)
  if oldBlock == newBlock:
    return (false, "Already sorted and deduped")

  let updated = replaceLineRange(source, first, last, newBlock)
  writeFile(filePath, stripBlankLines(updated) & "\n")
  (true, "Organized " & $modules.len & " import(s) in " & filePath)

proc main*(args: seq[string]): int =
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
nimtools organize-imports: Sort and dedupe a file's top-level imports.

Usage:
  organize-imports <file.nim>

Groups: std lib, then third-party/nimble, then project-local (./, ../).
Alphabetical within each group. Exact-duplicate module paths are removed.

Exit codes:
  0  completed (including: already organized, a valid no-op)
  1  file not found or parse failure
"""
    return ExitOk

  let (changed, message) = organizeImports(file)
  if message.startsWith("File not found") or message.startsWith("Could not parse"):
    stderr.writeLine "Error: ", message
    return ExitError
  echo message
  ExitOk

when isMainModule:
  quit(main(commandLineParams()))
