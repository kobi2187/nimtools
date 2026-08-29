## extract-variable: pulls the expression at one column span into a `let`
## declared on the line above the statement that contains it, and replaces
## only that selected span with the new name.
##
## Deliberately narrow: exact-span replacement only, no search for other
## occurrences of the same expression, no semantic equivalence proof (the
## expression's source TEXT is what moves, its type is never queried). Flagged
## in the design spec as needing refinement later -- candidates for a follow-up
## are multi-occurrence replacement with a same-scope/no-intervening-mutation
## check, smarter insertion inside expressions (ternary branches, comprehensions),
## and choosing `let` vs `var` when the target is later reassigned.

import std/[os, strutils, parseopt]
import ../shared/[compiler_env, source_rewriter, exit_codes]

proc leadingIndent(line: string): string =
  for c in line:
    if c == ' ' or c == '\t': result.add c
    else: break

proc extractVariable*(filePath: string; line, colStart, colEnd: int;
                      newName: string): tuple[ok: bool, message: string] =
  if not fileExists(filePath):
    return (false, "File not found: " & filePath)

  let source = readFile(filePath)
  let parsed = parseNimString(source, filePath)
  # The parser is error-recovering: parsed.ast is non-nil even on malformed
  # input (it emits a partial tree from whatever it could recover), so a nil
  # check alone misses this. parsed.errors is populated whenever the compiler
  # hooks saw a Severity.Error, which is what actually means "did not parse".
  if parsed.ast == nil or parsed.errors.len > 0:
    return (false, "Could not parse: " & filePath & " -- " & parsed.errors.join("; "))

  let lines = source.splitLines
  if line < 1 or line > lines.len:
    return (false, "Line " & $line & " is out of range (file has " & $lines.len & " lines)")
  let srcLine = lines[line - 1]
  if colStart < 0 or colEnd > srcLine.len or colStart >= colEnd:
    return (false, "Column span " & $colStart & ".." & $colEnd &
            " is out of range for line " & $line & " (length " & $srcLine.len & ")")

  let expr = srcLine[colStart ..< colEnd]
  let indent = leadingIndent(srcLine)
  let newLine = srcLine[0 ..< colStart] & newName & srcLine[colEnd .. ^1]
  let letDecl = indent & "let " & newName & " = " & expr

  let replacement = letDecl & "\n" & newLine
  let updated = replaceLineRange(source, line, line, replacement)
  writeFile(filePath, updated)
  (true, "Extracted '" & expr & "' into '" & newName & "' at " & filePath & ":" & $line)

proc main*(args: seq[string]): int =
  var p = initOptParser(args)
  var file, at, newName = ""
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
      elif newName == "": newName = p.key
      else:
        stderr.writeLine "Unexpected argument: ", p.key
        return ExitError

  if helpRequested or file == "" or at == "" or newName == "":
    echo """
nimtools extract-variable: Pull an expression into a `let` above its statement.

Usage:
  extract-variable --at:LINE:COLSTART-COLEND <file.nim> <newName>

Line is 1-based, columns are 0-based, COLEND is exclusive. Replaces ONLY the
selected span -- other identical occurrences elsewhere in the file are left
untouched. Parser-level: the expression's source text moves, its type is
never queried.

Exit codes:
  0  extracted
  1  bad --at, file not found, parse failure, or column span out of range
"""
    return ExitOk

  let parts = at.split(':')
  if parts.len != 2:
    stderr.writeLine "Error: malformed --at (want LINE:COLSTART-COLEND): ", at
    return ExitError
  let line = try: parseInt(parts[0]) except ValueError: -1
  let colParts = parts[1].split('-')
  if line < 1 or colParts.len != 2:
    stderr.writeLine "Error: malformed --at (want LINE:COLSTART-COLEND): ", at
    return ExitError
  let colStart = try: parseInt(colParts[0]) except ValueError: -1
  let colEnd = try: parseInt(colParts[1]) except ValueError: -1
  if colStart < 0 or colEnd <= colStart:
    stderr.writeLine "Error: malformed column span in --at: ", at
    return ExitError

  let (ok, message) = extractVariable(file, line, colStart, colEnd, newName)
  if not ok:
    stderr.writeLine "Error: ", message
    return ExitError
  echo message
  ExitOk

when isMainModule:
  quit(main(commandLineParams()))
