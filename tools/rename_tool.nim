import std/[os, strutils, parseopt, osproc, streams]
import ../shared/[source_rewriter, compiler_env, exit_codes]

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

proc main*() =
  var p = initOptParser()
  var targetFile = ""
  var oldName = ""
  var newName = ""
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
      if targetFile == "": targetFile = p.key
      elif oldName == "": oldName = p.key
      elif newName == "": newName = p.key
      else:
        stderr.writeLine "Unexpected argument: ", p.key
        quit(1)

  if helpRequested or targetFile == "" or oldName == "" or newName == "":
    echo """
nimtools rename-symbol: Lexer-safe identifier renaming (skipping comments and strings).

Usage:
  rename-symbol <file.nim> <oldName> <newName>

Examples:
  rename-symbol src/main.nim oldHelperName newHelperName
"""
    quit(0)

  let r = renameInFile(targetFile, oldName, newName)
  case r.status
  of rnRenamed, rnNoOp: echo r.message
  of rnError:
    stderr.writeLine "Error: ", r.message
    quit(ExitError)

when isMainModule:
  main()
