import std/[os, strutils, json]
import tools/[find_import_tool, import_tool, move_tool, rename_tool, inspect_tool,
              extract_tool, doc_tool]
import shared/exit_codes

proc printHelp() =
  echo """
nimtools: Deterministic AST-grade Nim toolkit for developers and AI agents.

Usage:
  nimtools <command> [arguments...]

Available Commands:
  outline        Generate concise one-line types & routine signatures from a file
  cyc            Audit McCabe cyclomatic complexity on real AST
  find-import    Discover missing symbols and their module paths across stdlib/Nimble/project
  add-import     Deterministically insert an import into a file
  rm-import      Deterministically remove an import from a file
  move-symbol    Migrate procs/types between files with auto-export & import wiring
  rename-symbol  Lexer-safe identifier renaming (ignoring strings & comments)
  inspect        Emit comprehensive JSON model of a file (AST, symbols, complexity)
  extract        Print one symbol's signature + doc (--body for full source)
  missing-docs   List exported routines that have no doc comment

Exit codes:
  0  completed (changed something, or correctly did nothing)
  1  error (missing file, parse failure, symbol not found)
  2  refused (would emit non-compiling code; --force to override)

For command-specific help, run:
  nimtools <command> --help
"""

proc usage(msg: string): int =
  ## Prints a usage line and yields the error exit code.
  stderr.writeLine msg
  ExitError

proc delegate(binary: string, args: seq[string]): int =
  ## Runs a sibling binary resolved next to THIS executable, not the cwd.
  ## A relative "./name" only works when the cwd happens to be the project
  ## root, which silently breaks every other working directory.
  let exe = getAppDir() / binary
  if not fileExists(exe):
    return usage("Error: helper binary not found: " & exe &
                 " (build it with: nim c -d:release " & binary & ".nim)")
  execShellCmd(exe.quoteShell & " " & args.quoteShellCommand())

proc dispatch(args: seq[string]): int =
  let cmd = args[0].toLowerAscii
  let rest = if args.len > 1: args[1..^1] else: @[]
  case cmd
  of "find-import", "find", "search":
    find_import_tool.main(rest)
    ExitOk
  of "add-import":
    if rest.len < 2: return usage("Usage: nimtools add-import <file.nim> <module1> [module2 ...]")
    for m in rest[1..^1]:
      if not addImportToFile(rest[0], m): return ExitError
    ExitOk
  of "rm-import", "remove-import":
    if rest.len < 2: return usage("Usage: nimtools rm-import <file.nim> <module1> [module2 ...]")
    for m in rest[1..^1]:
      if not removeImportFromFile(rest[0], m): return ExitError
    ExitOk
  of "move-symbol", "move-proc", "move-type", "move":
    var force = false
    var pos: seq[string] = @[]
    for a in rest:
      if a in ["--force", "-f"]: force = true else: pos.add a
    if pos.len < 3:
      return usage("Usage: nimtools move-symbol [--force] <source.nim> <destination.nim> <symbol1> [...]")
    let r = moveSymbols(pos[0], pos[1], pos[2..^1], force = force)
    case r.status
    of mvMoved:   echo r.message; ExitOk
    of mvRefused: stderr.writeLine r.message; ExitRefused
    of mvError:   usage("Error: " & r.message)
  of "rename-symbol", "rename":
    # --at:LINE:COL selects scope-aware mode: rename the binding at that
    # position and only the uses that resolve to it. Without it the rename is
    # token-level and hits every matching identifier in the file.
    var at = ""
    var pos: seq[string] = @[]
    for a in rest:
      if a.startsWith("--at:"): at = a[5..^1] else: pos.add a
    if pos.len < 3:
      return usage("Usage: nimtools rename-symbol [--at:LINE:COL] <file.nim> <oldName> <newName>")

    if at.len > 0:
      let parts = at.split(':')
      if parts.len != 2:
        return usage("Error: --at expects LINE:COL, got '" & at & "'")
      let line = try: parseInt(parts[0]) except ValueError: -1
      let col = try: parseInt(parts[1]) except ValueError: -1
      if line < 1 or col < 0:
        return usage("Error: --at expects a 1-based line and 0-based column, got '" & at & "'")
      let r = renameScopedInFile(pos[0], pos[1], pos[2], line, col)
      case r.status
      of srRenamed:  echo r.message; ExitOk
      of srConflict: stderr.writeLine r.message; ExitRefused
      of srNotFound: usage("Error: " & r.message)
    else:
      let r = renameInFile(pos[0], pos[1], pos[2])
      case r.status
      of rnRenamed: echo r.message; ExitOk
      of rnNoOp:    echo r.message; ExitOk   # nothing to change is not a failure
      of rnError:   usage("Error: " & r.message)
  of "inspect", "json":
    if rest.len < 1: return usage("Usage: nimtools inspect <file.nim>")
    let report = inspectFile(rest[0])
    echo report.pretty()
    if report.hasKey("error"): ExitError else: ExitOk
  of "extract", "show":
    extract_tool.main(rest)
  of "missing-docs", "undocumented":
    doc_tool.main(rest)
  of "outline":
    delegate("nimoutline", rest)
  of "cyc", "complexity":
    delegate("cyc", rest)
  else:
    stderr.writeLine "Unknown command: ", cmd
    printHelp()
    ExitError

proc main() =
  let args = commandLineParams()
  if args.len == 0 or args[0] in ["-h", "--help", "help"]:
    printHelp()
    quit(ExitOk)
  quit(dispatch(args))

when isMainModule:
  main()
