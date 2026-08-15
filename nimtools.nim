import std/[os, strutils, json]
import tools/[find_import_tool, import_tool, move_tool, rename_tool, inspect_tool]

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

For command-specific help, run:
  nimtools <command> --help
"""

proc main() =
  let args = commandLineParams()
  if args.len == 0 or args[0] in ["-h", "--help", "help"]:
    printHelp()
    quit(0)

  let cmd = args[0].toLowerAscii
  case cmd
  of "find-import", "find", "search":
    find_import_tool.main(if args.len > 1: args[1..^1] else: @[])
  of "add-import":
    var newArgs = @["add"]
    if args.len > 1: newArgs.add args[1..^1]
    # We can invoke directly
    if args.len >= 3:
      let targetFile = args[1]
      for m in args[2..^1]:
        discard addImportToFile(targetFile, m)
    else:
      echo "Usage: nimtools add-import <file.nim> <module1> [module2 ...]"
  of "rm-import", "remove-import":
    if args.len >= 3:
      let targetFile = args[1]
      for m in args[2..^1]:
        discard removeImportFromFile(targetFile, m)
    else:
      echo "Usage: nimtools rm-import <file.nim> <module1> [module2 ...]"
  of "move-symbol", "move-proc", "move-type", "move":
    if args.len >= 4:
      let src = args[1]
      let dest = args[2]
      let syms = args[3..^1]
      if moveSymbols(src, dest, syms):
        echo "Move operation completed successfully."
      else:
        quit(1)
    else:
      echo "Usage: nimtools move-symbol <source.nim> <destination.nim> <symbol1> [symbol2 ...]"
  of "rename-symbol", "rename":
    if args.len >= 4:
      let target = args[1]
      let oldName = args[2]
      let newName = args[3]
      if renameInFile(target, oldName, newName):
        echo "Rename complete."
      else:
        quit(1)
    else:
      echo "Usage: nimtools rename-symbol <file.nim> <oldName> <newName>"
  of "inspect", "json":
    if args.len >= 2:
      echo inspectFile(args[1]).pretty()
    else:
      echo "Usage: nimtools inspect <file.nim>"
  of "outline":
    # Delegate to nimoutline binary or logic
    let res = execShellCmd("./nimoutline " & args[1..^1].quoteShellCommand())
    quit(res)
  of "cyc", "complexity":
    # Delegate to cyc binary or logic
    let res = execShellCmd("./cyc " & args[1..^1].quoteShellCommand())
    quit(res)
  else:
    stderr.writeLine "Unknown command: ", cmd
    printHelp()
    quit(1)

when isMainModule:
  main()
