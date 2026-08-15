## references: every use of one binding, so an agent sees the blast radius
## before rename / move / delete. `find-import` answers "where is this defined";
## this answers "where is it *used*".
##
## Two scopes:
## - single-file (default): built on the scope model in scope_rename, so a
##   shadowed local is disambiguated by position, not by name alone.
## - --project: also follows the import graph and reports uses of the symbol in
##   every module that imports its defining module. An imported name has no
##   local binding, so it appears as an *unbound* use there.
##
## Advisory limits: qualified access (`util.sanitize`) is not reported — only
## the module side is walked. Unbound uses are candidates, not a proof of
## resolution: if two modules export the same name the parser cannot tell which
## one a use refers to. Read-only, so a false candidate costs nothing.

import std/[os, strutils, json, parseopt, tables, sets, algorithm]
import ../shared/[scope_rename, exit_codes, compiler_env, ast_utils]
import import_tool

type
  FileReferences* = object
    file*: string
    declared*: tuple[line, col: int]  ## (-1, -1) when not the defining file
    uses*: seq[Reference]

  ProjectReferences* = object
    symbol*: string
    definedIn*: string
    files*: seq[FileReferences]

proc bareName(path: string): string =
  ## Last path segment: `std/strutils` -> `strutils`, `model.nim` -> `model`.
  path.rsplit({'/', '\\'}, 1)[^1].replace(".nim", "")

proc projectFiles*(root: string): seq[string] =
  ## Every .nim file under `root`, excluding nimcache.
  for f in walkDirRec(root):
    if f.endsWith(".nim") and "nimcache" notin f:
      result.add f
  result.sort()

proc importersOf*(moduleFile: string): seq[string] =
  ## .nim files under moduleFile's directory that import it, directly or
  ## transitively, matched by bare module name. moduleFile itself is excluded.
  let root = moduleFile.parentDir
  let target = moduleFile.bareName
  let files = projectFiles(root)
  var byName: Table[string, string]
  for f in files: byName[f.bareName] = f

  var seen: HashSet[string]
  seen.incl moduleFile
  var queue: seq[string] = @[]

  # Direct importers first.
  for f in files:
    if f in seen: continue
    let parsed = parseNimFile(f)
    if parsed.ast == nil: continue
    for imp in extractExistingImports(parsed.ast):
      if imp.bareName == target:
        queue.add f; seen.incl f
        break

  # Then transitively: a file importing an already-seen file also sees `target`.
  var i = 0
  while i < queue.len:
    let seenBare = queue[i].bareName
    i.inc
    for f in files:
      if f in seen: continue
      let parsed = parseNimFile(f)
      if parsed.ast == nil: continue
      for imp in extractExistingImports(parsed.ast):
        if imp.bareName == seenBare:
          queue.add f; seen.incl f
          break
  result = queue

proc symbolIsExported*(filePath, symbol: string): bool =
  let parsed = parseNimFile(filePath)
  if parsed.ast == nil: return false
  for n in collectRoutines(parsed.ast):
    if routineName(n) == symbol and isExported(n): return true
  for n in collectTypeDefs(parsed.ast):
    if typeDefName(n) == symbol and isExported(n): return true
  false

proc findProjectReferences*(filePath, symbol: string;
                            line = -1, col = -1): ProjectReferences =
  ## The defining file's own binding + uses, then unbound uses of `symbol` in
  ## every file that imports it. Empty `files` when the symbol is not declared
  ## in `filePath`. Cross-file discovery only runs for an exported symbol — a
  ## private one cannot be referenced from another module.
  result = ProjectReferences(symbol: symbol, definedIn: filePath)
  if not fileExists(filePath): return

  let local = findReferences(readFile(filePath), filePath, symbol, line, col)
  if local.len == 0: return

  var def = FileReferences(file: filePath, declared: (-1, -1), uses: @[])
  for l in local:
    if def.declared == (-1, -1):
      def.declared = (l.declaredLine, l.declaredCol)
    for u in l.uses: def.uses.add u
  result.files.add def

  if not symbolIsExported(filePath, symbol): return

  for f in importersOf(filePath):
    let uses = findUnboundUses(readFile(f), f, symbol)
    if uses.len > 0:
      result.files.add FileReferences(file: f, declared: (-1, -1), uses: uses)

proc renderProject(r: ProjectReferences): string =
  var total = 0
  for f in r.files: total += f.uses.len
  result = r.symbol & "  defined " & r.definedIn
  let defFile = r.files[0]
  if defFile.declared.line > 0:
    result &= ":" & $defFile.declared.line & ":" & $defFile.declared.col
  result &= "\n"
  var fileCount = 0
  for f in r.files:
    if f.uses.len == 0 and f.file == r.definedIn: continue
    fileCount.inc
    for u in f.uses:
      result &= "  " & f.file.bareName & ":" & $u.line & ":" & $u.col & "  " &
                u.text & "\n"
  result &= $total & " use(s) across " & $fileCount & " file(s)"

proc renderLocal(filePath, symbol: string, refs: seq[SymbolReferences]): string =
  var total = 0
  for r in refs: total += r.uses.len
  for i, r in refs:
    if i > 0: result &= "\n"
    let head = if refs.len > 1: symbol & " (binding " & $(i + 1) & ") declared " &
               filePath & ":" & $r.declaredLine & ":" & $r.declaredCol
               else: symbol & " declared " & filePath & ":" & $r.declaredLine &
               ":" & $r.declaredCol
    result &= head & "\n"
    for u in r.uses:
      result &= "  " & $u.line & ":" & $u.col & "  " & u.text & "\n"
  result &= $total & " use(s)"

proc main*(args: seq[string]): int =
  ## CLI entry. Returns an exit code rather than quitting, so the umbrella
  ## dispatcher stays in control of the process.
  var p = initOptParser(args)
  var file, symbol, at = ""
  var asJson, project, helpRequested = false

  while true:
    p.next()
    case p.kind
    of cmdEnd: break
    of cmdShortOption, cmdLongOption:
      case p.key.toLowerAscii
      of "h", "help": helpRequested = true
      of "j", "json": asJson = true
      of "at": at = p.val
      of "project", "all-files": project = true
      else:
        stderr.writeLine "Unknown option: --", p.key
        return ExitError
    of cmdArgument:
      if file == "": file = p.key
      elif symbol == "": symbol = p.key

  if helpRequested or file == "" or symbol == "":
    echo """\
nimtools references: Every use of one symbol, without reading the file.

Usage:
  references [--project] [--at:LINE:COL] [--json] <file.nim> <symbol>

Single-file (default): lists the declaration and every use of `symbol` in that
file, each as LINE:COL with the stripped source line. --at disambiguates a
shadowed binding by a declaration or use position.

--project: also follows the import graph and lists uses in every module that
imports the defining module. An imported name is reported as an unbound use, so
the result is advisory: qualified access (util.sanitize) is not reported, and
the parser cannot tell two modules exporting the same name apart.

Line is 1-based, column 0-based, matching `inspect`, `extract` and
`rename-symbol --at`.

Exit codes:
  0  found (a symbol with zero uses is a valid answer)
  1  symbol not found, parse failure, or missing file

Options:
  -j, --json           machine-readable output
      --at:LINE:COL    report one binding, selected by a declaration or use
      --project        cross-file: follow importers of the defining module
"""
    return ExitOk

  if not fileExists(file):
    stderr.writeLine "Error: File not found: ", file
    return ExitError

  var line = -1
  var col = -1
  if at.len > 0:
    let parts = at.split(':')
    if parts.len != 2:
      stderr.writeLine "Error: --at expects LINE:COL, got '", at, "'"
      return ExitError
    line = try: parseInt(parts[0]) except ValueError: -1
    col = try: parseInt(parts[1]) except ValueError: -1
    if line < 1 or col < 0:
      stderr.writeLine "Error: --at expects a 1-based line and 0-based column"
      return ExitError

  if project:
    let r = findProjectReferences(file, symbol, line, col)
    if r.files.len == 0:
      stderr.writeLine "Error: Symbol '", symbol, "' not found in ", file
      return ExitError
    if asJson:
      var jFiles = newJArray()
      for f in r.files:
        var jUses = newJArray()
        for u in f.uses:
          jUses.add %*{"line": u.line, "col": u.col, "text": u.text}
        var obj = %*{"file": f.file, "uses": jUses}
        if f.declared.line > 0:
          obj["declared"] = %*{"line": f.declared.line, "col": f.declared.col}
        jFiles.add obj
      echo $(%*{"symbol": r.symbol, "definedIn": r.definedIn,
                "files": jFiles}).pretty()
    else:
      echo renderProject(r)
    return ExitOk

  let refs = findReferences(readFile(file), file, symbol, line, col)
  if refs.len == 0:
    stderr.writeLine "Error: Symbol '", symbol, "' not found in ", file
    return ExitError

  if asJson:
    var jBindings = newJArray()
    for r in refs:
      var jUses = newJArray()
      for u in r.uses:
        jUses.add %*{"line": u.line, "col": u.col, "text": u.text}
      jBindings.add %*{"declared": {"line": r.declaredLine, "col": r.declaredCol},
                       "uses": jUses}
    echo $(%*{"file": file, "symbol": symbol, "bindings": jBindings}).pretty()
  else:
    echo renderLocal(file, symbol, refs)
  ExitOk

when isMainModule:
  quit(main(commandLineParams()))
