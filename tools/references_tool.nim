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

import std/[os, strutils, json, parseopt, algorithm, tables]
import ../shared/[scope_rename, exit_codes, suggest]
import project_graph

type
  FileReferences* = object
    file*: string
    declared*: tuple[line, col: int]  ## (-1, -1) when not the defining file
    uses*: seq[Reference]

  ProjectReferences* = object
    symbol*: string
    definedIn*: string
    files*: seq[FileReferences]
    engine*: string    ## "parser" (lexical, advisory) or "nimsuggest" (resolved)
    complete*: bool    ## false when the engine cannot see every use
    root*: string      ## project root the semantic query was run against

proc findProjectReferences*(filePath, symbol: string;
                            line = -1, col = -1): ProjectReferences =
  ## The defining file's own binding + uses, then unbound uses of `symbol` in
  ## every file that imports it. Empty `files` when the symbol is not declared
  ## in `filePath`. Cross-file discovery only runs for an exported symbol — a
  ## private one cannot be referenced from another module.
  result = ProjectReferences(symbol: symbol, definedIn: filePath,
                             engine: "parser", complete: false)
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

proc sourceLineAt(cache: var Table[string, seq[string]];
                  file: string; line: int): string =
  ## The stripped source line behind a semantic hit. nimsuggest reports only a
  ## position, and an agent reading the result wants the text.
  if file notin cache:
    cache[file] = if fileExists(file): readFile(file).splitLines else: @[]
  let lines = cache[file]
  if line >= 1 and line <= lines.len: lines[line - 1].strip else: ""

proc findSemanticReferences*(filePath, symbol, root: string;
                             line = -1, col = -1): tuple[
    refs: ProjectReferences, status: SuggestStatus, message: string] =
  ## Uses of `symbol` resolved by nimsuggest across every module reachable from
  ## `root`. Unlike the parser path this sees UFCS and qualified calls, tells
  ## overloads apart, and never reports a use it could not resolve — so a caller
  ## may act on the result instead of merely checking it.
  ##
  ## The parser is still used, for one thing only: turning a symbol *name* into
  ## the declaration *position* nimsuggest needs. `--at` skips even that.
  var refs = ProjectReferences(symbol: symbol, definedIn: filePath,
                               engine: "nimsuggest", complete: true, root: root)
  var declLine = line
  var declCol = col
  if declLine < 1:
    if not fileExists(filePath):
      return (refs, ssNoResult, "File not found: " & filePath)
    let local = findReferences(readFile(filePath), filePath, symbol)
    if local.len == 0:
      return (refs, ssNoResult,
              "Symbol '" & symbol & "' not declared in " & filePath)
    declLine = local[0].declaredLine
    declCol = local[0].declaredCol

  let reply = queryUses(root, filePath, declLine, declCol)
  if reply.status != ssOk:
    return (refs, reply.status, reply.message)

  var cache = initTable[string, seq[string]]()
  var byFile = initTable[string, seq[Reference]]()
  for u in reply.uses:
    byFile.mgetOrPut(u.file, @[]).add Reference(
      line: u.line, col: u.col, text: sourceLineAt(cache, u.file, u.line))

  proc byPosition(a, b: Reference): int =
    result = cmp(a.line, b.line)
    if result == 0: result = cmp(a.col, b.col)

  # Defining file first, then the rest in a stable order.
  refs.definedIn = reply.def.file
  var defUses = byFile.getOrDefault(reply.def.file)
  defUses.sort(byPosition)
  refs.files.add FileReferences(file: reply.def.file,
                                declared: (reply.def.line, reply.def.col),
                                uses: defUses)
  var others: seq[string] = @[]
  for f in byFile.keys:
    if f != reply.def.file: others.add f
  others.sort()
  for f in others:
    var uses = byFile[f]
    uses.sort(byPosition)
    refs.files.add FileReferences(file: f, declared: (-1, -1), uses: uses)
  (refs, ssOk, "")

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
  result &= $total & " use(s) across " & $fileCount & " file(s)\n"
  # The engine is part of the answer: "0 uses" from the parser means "none that
  # a lexical walk can see", which is not the same claim as "none".
  result &= (if r.complete:
               "resolved by nimsuggest (root " & r.root.bareName & ")"
             else:
               "parser, advisory: UFCS (x.f) and qualified (m.f) uses are not " &
               "reported -- pass --semantic for a resolved answer")

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
  ## `references <file> <symbol>` — uses of a binding declared in that file.
  var p = initOptParser(args)
  var file, symbol, at = ""
  var asJson, helpRequested = false

  while true:
    p.next()
    case p.kind
    of cmdEnd: break
    of cmdShortOption, cmdLongOption:
      case p.key.toLowerAscii
      of "h", "help": helpRequested = true
      of "j", "json": asJson = true
      of "at": at = p.val
      else:
        stderr.writeLine "Unknown option: --", p.key
        return ExitError
    of cmdArgument:
      if file == "": file = p.key
      elif symbol == "": symbol = p.key

  if helpRequested or file == "" or symbol == "":
    echo """\
nimtools references: Every use of one symbol in a file.

Usage:
  references [--at:LINE:COL] [--json] <file.nim> <symbol>

Lists the declaration and every use of `symbol` in that file, each as LINE:COL
with the stripped source line. --at disambiguates a shadowed binding by a
declaration or use position. For uses across importing modules, use
`project-references`.

Exit codes:
  0  found (a symbol with zero uses is a valid answer)
  1  symbol not found, parse failure, or missing file

Options:
  -j, --json           machine-readable output
      --at:LINE:COL    report one binding, selected by a declaration or use
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

proc projectMain*(args: seq[string]): int =
  ## `project-references <file> <symbol>` — uses across importing modules.
  var p = initOptParser(args)
  var file, symbol, root = ""
  var asJson, helpRequested, semantic = false

  while true:
    p.next()
    case p.kind
    of cmdEnd: break
    of cmdShortOption, cmdLongOption:
      case p.key.toLowerAscii
      of "h", "help": helpRequested = true
      of "j", "json": asJson = true
      of "s", "semantic": semantic = true
      of "root":
        root = p.val
        semantic = true
      else:
        stderr.writeLine "Unknown option: --", p.key
        return ExitError
    of cmdArgument:
      if file == "": file = p.key
      elif symbol == "": symbol = p.key

  if helpRequested or file == "" or symbol == "":
    echo """\
nimtools project-references: Every use of a symbol across its importers.

Usage:
  project-references [--semantic [--root:FILE]] [--json] <file.nim> <symbol>

Default (parser) lists uses of `symbol` in the defining file and in every
module that imports it, matching identifiers lexically. That is ADVISORY and
under-reports: a UFCS call (x.fn) or a qualified one (util.fn) is invisible to
it, so "0 use(s)" does not mean the symbol is unused. Output always names the
engine that answered.

--semantic resolves the symbol with nimsuggest instead: UFCS and qualified
uses are found, overloads are told apart, and the answer is complete for every
module reachable from the project root. It compiles the project, so it costs
seconds. The root is auto-picked as a module that transitively imports
`file.nim` and is itself imported by nothing; --root overrides that.

Exit codes:
  0  found (a symbol with zero uses is a valid answer)
  1  symbol not found, parse failure, missing file, or nimsuggest unavailable

Options:
  -j, --json        machine-readable output
  -s, --semantic    resolve with nimsuggest instead of the lexical parser
      --root:FILE   project root to open nimsuggest with (implies --semantic)
"""
    return ExitOk

  if not fileExists(file):
    stderr.writeLine "Error: File not found: ", file
    return ExitError

  var r: ProjectReferences
  if semantic:
    if root == "": root = pickProjectRoot(file)
    elif not fileExists(root):
      stderr.writeLine "Error: Root file not found: ", root
      return ExitError
    let (sr, status, message) = findSemanticReferences(file, symbol, root)
    # No silent downgrade to the parser: a caller asked for a resolved answer,
    # and a lexical guess wearing that label is exactly the failure this path
    # exists to remove.
    if status != ssOk:
      stderr.writeLine "Error: ", message
      return ExitError
    r = sr
  else:
    r = findProjectReferences(file, symbol)
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
    var payload = %*{"symbol": r.symbol, "definedIn": r.definedIn,
                     "engine": r.engine, "complete": r.complete,
                     "files": jFiles}
    if r.root.len > 0: payload["root"] = %r.root
    echo $payload.pretty()
  else:
    echo renderProject(r)
  ExitOk

when isMainModule:
  quit(main(commandLineParams()))
