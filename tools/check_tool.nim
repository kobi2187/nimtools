## syntax-check: is this file still parseable, and where isn't it.
##
## Deliberately NOT a type checker, and it cannot become one. Semantic analysis
## needs the symbol tables of every import — without `strutils` loaded, `s.strip`
## is indistinguishable from a typo — so "check one module, skip its imports" has
## no semantic answer. `nim check` already does the cheap half of that: it sems
## dependencies for their symbols and never generates code for them. Use it when
## you want types. It costs ~1.4s on this project.
##
## What IS separable is the syntax layer, and it is ~1750x cheaper: 0.8ms per
## file against 1.4s, because the parser never leaves the file. That buys two
## things `nim check` cannot:
##
## - a gate for the destructive write tools. `move-symbol` / `rename-project` /
##   `delete-symbol` rewrite files in place; "did that still parse" is the first
##   question afterwards, and at 0.8ms an agent can ask it after every write.
## - an answer on files `nim check` refuses outright — a module mid-refactor
##   whose imports do not resolve yet still gives a useful syntax verdict.
##
## The parse errors were already being computed by `compiler_env` and thrown
## away by every caller, which is why `inspect` reports clean JSON and exit 0 on
## a file that does not parse. This surfaces them.

import std/[os, strutils, json, parseopt]  # os: commandLineParams, isMainModule
import ../shared/[compiler_env, exit_codes]

type
  FileCheck* = object
    file*: string
    ok*: bool
    errors*: seq[ParseError]

proc checkFile*(path: string): FileCheck =
  ## Parse `path` and report what failed. A file that parses with no diagnostics
  ## is ok; anything else is not, including an empty AST.
  let parsed = parseNimFile(path)
  FileCheck(file: path, ok: parsed.ast != nil and parsed.diagnostics.len == 0,
            errors: parsed.diagnostics)

proc render(checks: seq[FileCheck]): string =
  var bad = 0
  for c in checks:
    if c.ok: continue
    bad.inc
    for e in c.errors:
      result &= c.file & ":" & $e.line & ":" & $e.col & ": " & e.message & "\n"
  if bad == 0:
    result &= $checks.len & " file(s) parse"
  else:
    result &= $bad & " of " & $checks.len & " file(s) failed to parse"
  # Syntax is all this proves. Saying so keeps the verdict from being read as
  # "compiles" — the same over-claim the parser reference path used to make.
  result &= "\nsyntax only: type errors need `nim check`"

proc main*(args: seq[string]): int =
  var p = initOptParser(args)
  var files: seq[string] = @[]
  var asJson, helpRequested = false

  while true:
    p.next()
    case p.kind
    of cmdEnd: break
    of cmdShortOption, cmdLongOption:
      case p.key.toLowerAscii
      of "h", "help": helpRequested = true
      of "j", "json": asJson = true
      else:
        stderr.writeLine "Unknown option: --", p.key
        return ExitError
    of cmdArgument:
      files.add p.key

  if helpRequested or files.len == 0:
    echo """\
nimtools syntax-check: Does this file still parse, and where doesn't it.

Usage:
  syntax-check [--json] <file.nim>...

Parses each file and reports every syntax error as file:line:col. ~0.8ms per
file, because it never looks at imports.

SYNTAX ONLY. It cannot report type errors, undeclared identifiers, or bad
argument types: those need the symbol tables of every import, which is what
`nim check` loads (~1.4s here). This is the fast gate to run after a write
tool rewrites a file, not a replacement for `nim check`.

Exit codes:
  0  every file parses
  1  a file failed to parse, or is missing

Options:
  -j, --json   machine-readable output
"""
    return ExitOk

  var checks: seq[FileCheck] = @[]
  for f in files:
    checks.add checkFile(f)

  if asJson:
    var jFiles = newJArray()
    var allOk = true
    for c in checks:
      if not c.ok: allOk = false
      var jErrors = newJArray()
      for e in c.errors:
        jErrors.add %*{"line": e.line, "col": e.col, "message": e.message}
      jFiles.add %*{"file": c.file, "ok": c.ok, "errors": jErrors}
    echo $(%*{"ok": allOk, "checked": checks.len,
              "scope": "syntax", "files": jFiles}).pretty()
  else:
    echo render(checks)

  for c in checks:
    if not c.ok: return ExitError
  ExitOk

when isMainModule:
  quit(main(commandLineParams()))
