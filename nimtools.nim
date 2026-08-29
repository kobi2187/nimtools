import std/[os, strutils, json]
import tools/[find_import_tool, import_tool, move_tool, delete_tool, rename_tool,
              inspect_tool, extract_tool, doc_tool, api_tool, effects_tool,
              references_tool, check_tool, organize_imports_tool, type_report_tool,
              extract_variable_tool]
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
  references     Every use of a symbol in one file (line:col), scope model
  project-references  Every use of a symbol across its importing modules
  add-import     Deterministically insert an import into a file
  rm-import      Deterministically remove an import from a file
  organize-imports  Sort and dedupe a file's imports (std, third-party, local)
  move-symbol    Migrate procs/types between files with auto-export & import wiring
  delete-symbol  Remove a proc/type definition (refuses if still referenced)
  rename-symbol  Whole-file token rename (skips strings & comments)
  rename-scoped  Rename one binding + its uses (--at:LINE:COL)
  rename-project Rename an exported symbol across its importers (--at:LINE:COL)
  syntax-check   Does the file still parse? (~0.8ms, syntax only, no imports)
  inspect        Emit comprehensive JSON model of a file (AST, symbols, complexity)
  extract        Print one symbol's signature + doc (--body for full source)
  missing-docs   List exported routines that have no doc comment
  api-surface    What a module exports, without reading it
  api-diff       Compare two exported surfaces; exit 2 if breaking
  unused-imports Imports whose symbols are never referenced (reports only)
  raises         Declared exception surface (declared pragmas only)
  func-candidates  procs with no visible side effect (heuristic)
  type-report   Resolve type(s) at point(s); at/function/module layers
  extract-variable  Pull an expression into a let above its statement

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
  of "references", "refs", "find-references":
    references_tool.main(rest)
  of "project-references", "project-refs", "find-project-references":
    references_tool.projectMain(rest)
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
  of "organize-imports", "sort-imports":
    organize_imports_tool.main(rest)
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
  of "delete-symbol", "delete":
    delete_tool.deleteMain(rest)
  of "rename-symbol", "rename":
    rename_tool.tokenMain(rest)
  of "rename-scoped", "scope-rename":
    rename_tool.scopedMain(rest)
  of "rename-project", "project-rename":
    rename_tool.projectMain(rest)
  of "inspect", "json":
    if rest.len < 1: return usage("Usage: nimtools inspect <file.nim>")
    let report = inspectFile(rest[0])
    echo report.pretty()
    if report.hasKey("error"): ExitError else: ExitOk
  of "syntax-check", "check-syntax", "parse-check":
    check_tool.main(rest)
  of "extract", "show":
    extract_tool.main(rest)
  of "missing-docs", "undocumented":
    doc_tool.main(rest)
  of "api-surface", "api", "surface":
    api_tool.main(rest)
  of "api-diff", "diff-api":
    api_tool.diffMain(rest)
  of "unused-imports":
    import_tool.unusedMain(rest)
  of "raises", "effects":
    effects_tool.main(rest)
  of "func-candidates", "funcs":
    effects_tool.funcMain(rest)
  of "type-report", "types":
    if rest.len < 1: return usage("Usage: nimtools type-report <at|function|module> ...")
    case rest[0]
    of "at": type_report_tool.atMain(rest[1..^1])
    of "function": type_report_tool.functionMain(rest[1..^1])
    of "module": type_report_tool.moduleMain(rest[1..^1])
    else: usage("Unknown type-report layer: " & rest[0] & " (want: at, function, module)")
  of "extract-variable", "extract-var":
    extract_variable_tool.main(rest)
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
