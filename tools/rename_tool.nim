import std/[os, strutils, parseopt, osproc, streams]
import ../shared/[source_rewriter, compiler_env, exit_codes, scope_rename]
import project_graph
export scope_rename

proc renameScopedInFile*(filePath, oldName, newName: string;
                         line, col: int): RenameScopedResult =
  ## Scope-aware rename of one binding in one file. Unlike the token rename
  ## below, this resolves which declaration the position refers to and rewrites
  ## only the uses that bind to it — a local `i` stays local.
  if not fileExists(filePath):
    return RenameScopedResult(status: srNotFound,
      message: "File not found: " & filePath)
  let source = readFile(filePath)
  result = renameScoped(source, filePath, oldName, newName, line, col)
  if result.status == srRenamed:
    writeFile(filePath, result.source)

type
  RenameStatus* = enum
    rnRenamed   ## at least one occurrence was rewritten
    rnNoOp      ## file was fine as-is; nothing matched
    rnError     ## bad input: missing file, empty name

  RenameResult* = object
    status*: RenameStatus
    message*: string

proc renameInFile*(filePath, oldName, newName: string): RenameResult =
  ## Renames identifier tokens in a single file, skipping strings and comments.
  ##
  ## SCOPE LIMIT: this is token-level, not semantic. It has no scope model, so
  ## it renames every matching identifier in the file — a local named `i` hits
  ## every `i`. It also cannot follow a symbol into another file. For scoped or
  ## cross-file renames, semantic mode (nimsuggest) is required.
  if oldName.len == 0 or newName.len == 0:
    return RenameResult(status: rnError, message: "Both oldName and newName must be non-empty")
  if not fileExists(filePath):
    return RenameResult(status: rnError, message: "File not found: " & filePath)

  let content = readFile(filePath)
  let updated = renameTokenStream(content, oldName, newName)
  if updated != content:
    writeFile(filePath, updated)
    RenameResult(status: rnRenamed,
      message: "Renamed '" & oldName & "' -> '" & newName & "' in " & filePath)
  else:
    RenameResult(status: rnNoOp,
      message: "No occurrences of '" & oldName & "' in " & filePath & " (nothing to do)")

proc renameProjectScoped*(entryFile, oldName, newName: string;
                          line, col: int): RenameScopedResult =
  ## Cross-file, scope-aware rename of an exported symbol. Rewrites the
  ## definition and its uses in the defining file via `renameScoped`, then
  ## rewrites unbound uses in every module that imports it. Refuses (srConflict)
  ## when another local module also exports the name, because a use in an
  ## importer would then be ambiguous and the parser cannot tell which module it
  ## refers to.
  if not fileExists(entryFile):
    return RenameScopedResult(status: srNotFound,
      message: "File not found: " & entryFile)

  if not symbolIsExported(entryFile, oldName):
    return RenameScopedResult(status: srNotFound, message:
      "'" & oldName & "' is not an exported symbol in " & entryFile &
      "; a cross-file rename needs an exported definition")

  for f in projectFiles(entryFile.parentDir):
    if f == entryFile: continue
    if symbolIsExported(f, oldName):
      return RenameScopedResult(status: srConflict, message:
        "Refusing cross-file rename: '" & oldName & "' is also exported by " &
        f & ", so a use in an importer is ambiguous")

  let source = readFile(entryFile)
  let local = renameScoped(source, entryFile, oldName, newName, line, col)
  if local.status != srRenamed: return local
  writeFile(entryFile, local.source)

  var filesChanged = 1
  for f in importersOf(entryFile):
    let src = readFile(f)
    let updated = renameUnboundUses(src, f, oldName, newName)
    if updated != src:
      writeFile(f, updated)
      filesChanged.inc

  RenameScopedResult(status: srRenamed, occurrences: filesChanged, message:
    "Renamed '" & oldName & "' -> '" & newName & "' across " & $filesChanged &
    " file(s)")

proc renameSemantic*(projectFile, targetFile: string, line, col: int,
                     newName: string): RenameResult =
  ## Project-wide, scope-aware rename via nimsuggest.
  ##
  ## NOT IMPLEMENTED YET. The previous attempt here was wrong in four ways
  ## (queried `use` but filtered rows for `def`; fell back to renaming the
  ## empty string; used a *filename* as the identifier to rename; could block
  ## forever on readLine), so it refuses rather than silently corrupting files.
  ##
  ## Doing this properly needs a real nimsuggest driver: non-blocking framed
  ## I/O with a timeout, correct row parsing, and mapping returned positions
  ## back to token spans per file. Tracked as the next piece of work.
  RenameResult(status: rnError, message:
    "Semantic (project-wide, scope-aware) rename is not implemented yet. " &
    "Use `rename-symbol <file> <old> <new>` for single-file token rename, " &
    "which cannot scope locals or cross files.")

proc parseLineCol(at: string): tuple[line, col: int; ok: bool] =
  ## Validates a `LINE:COL` string (1-based line, 0-based column).
  let parts = at.split(':')
  if parts.len != 2: return (-1, -1, false)
  let line = try: parseInt(parts[0]) except ValueError: -1
  let col = try: parseInt(parts[1]) except ValueError: -1
  if line < 1 or col < 0: return (-1, -1, false)
  (line, col, true)

proc tokenMain*(args: seq[string]): int =
  ## `rename-symbol <file> <old> <new>` — token-level, whole file.
  var p = initOptParser(args)
  var file, oldName, newName = ""
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
      elif oldName == "": oldName = p.key
      elif newName == "": newName = p.key
      else:
        stderr.writeLine "Unexpected argument: ", p.key
        return ExitError

  if helpRequested or file == "" or oldName == "" or newName == "":
    echo """\
nimtools rename-symbol: Lexer-safe whole-file identifier rename.

Usage:
  rename-symbol <file.nim> <oldName> <newName>

Rewrites every matching identifier token, skipping strings and comments. It has
no scope model — a local `i` hits every `i`. For one binding only, use
`rename-scoped`; for an exported symbol across modules, `rename-project`.
"""
    return ExitOk

  let r = renameInFile(file, oldName, newName)
  case r.status
  of rnRenamed, rnNoOp: echo r.message; ExitOk
  of rnError: stderr.writeLine "Error: ", r.message; ExitError

proc scopedMain*(args: seq[string]): int =
  ## `rename-scoped --at:LINE:COL <file> <old> <new>` — one binding, one file.
  var p = initOptParser(args)
  var file, oldName, newName, at = ""
  var helpRequested = false
  while true:
    p.next()
    case p.kind
    of cmdEnd: break
    of cmdShortOption, cmdLongOption:
      case p.key.toLowerAscii
      of "h", "help": helpRequested = true
      of "at": at = p.val
      else:
        stderr.writeLine "Unknown option: --", p.key
        return ExitError
    of cmdArgument:
      if file == "": file = p.key
      elif oldName == "": oldName = p.key
      elif newName == "": newName = p.key
      else:
        stderr.writeLine "Unexpected argument: ", p.key
        return ExitError

  if helpRequested or file == "" or oldName == "" or newName == "":
    echo """\
nimtools rename-scoped: Rename one binding and the uses that resolve to it.

Usage:
  rename-scoped --at:LINE:COL <file.nim> <oldName> <newName>

The position picks which declaration the rename targets, so a local `i` stays
local and a shadowing `for i in ...` is a different binding. Line is 1-based,
column 0-based — `inspect` and `extract` report the same form.
"""
    return ExitOk

  if at.len == 0:
    stderr.writeLine "Error: rename-scoped needs --at:LINE:COL to pick the binding"
    return ExitError
  let (line, col, ok) = parseLineCol(at)
  if not ok:
    stderr.writeLine "Error: --at expects a 1-based line and 0-based column, got '", at, "'"
    return ExitError

  let r = renameScopedInFile(file, oldName, newName, line, col)
  case r.status
  of srRenamed:  echo r.message; ExitOk
  of srConflict: stderr.writeLine r.message; ExitRefused
  of srNotFound: stderr.writeLine "Error: ", r.message; ExitError

proc projectMain*(args: seq[string]): int =
  ## `rename-project --at:LINE:COL <file> <old> <new>` — an exported symbol,
  ## across every module that imports its file.
  var p = initOptParser(args)
  var file, oldName, newName, at = ""
  var helpRequested = false
  while true:
    p.next()
    case p.kind
    of cmdEnd: break
    of cmdShortOption, cmdLongOption:
      case p.key.toLowerAscii
      of "h", "help": helpRequested = true
      of "at": at = p.val
      else:
        stderr.writeLine "Unknown option: --", p.key
        return ExitError
    of cmdArgument:
      if file == "": file = p.key
      elif oldName == "": oldName = p.key
      elif newName == "": newName = p.key
      else:
        stderr.writeLine "Unexpected argument: ", p.key
        return ExitError

  if helpRequested or file == "" or oldName == "" or newName == "":
    echo """\
nimtools rename-project: Rename an exported symbol across its importers.

Usage:
  rename-project --at:LINE:COL <file.nim> <oldName> <newName>

Renames the definition and its uses in `file`, then rewrites unbound uses in
every module that imports it. Refuses (exit 2) when another local module also
exports the name — a use in an importer would then be ambiguous.
"""
    return ExitOk

  if at.len == 0:
    stderr.writeLine "Error: rename-project needs --at:LINE:COL to pick the binding"
    return ExitError
  let (line, col, ok) = parseLineCol(at)
  if not ok:
    stderr.writeLine "Error: --at expects a 1-based line and 0-based column, got '", at, "'"
    return ExitError

  let r = renameProjectScoped(file, oldName, newName, line, col)
  case r.status
  of srRenamed:  echo r.message; ExitOk
  of srConflict: stderr.writeLine r.message; ExitRefused
  of srNotFound: stderr.writeLine "Error: ", r.message; ExitError

when isMainModule:
  quit(tokenMain(commandLineParams()))
