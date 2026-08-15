## Effect surface and purity candidates — two Nim-specific reports that have no
## mainstream IDE equivalent.
##
## `raises` answers "what can this module throw at me", which a caller genuinely
## needs and cannot get without reading every proc.
##
## IMPORTANT LIMIT, and the reason every output says so: Nim *infers* effects
## during the compiler's sem pass. The parser only sees what was written down.
## A proc with no `{.raises.}` pragma is reported as UNDECLARED, never as safe —
## it may raise anything. Only `{.raises: [].}` means "provably raises nothing",
## because the compiler checked it. Conflating those two would be the exact kind
## of silent wrongness this project exists to avoid.
##
## `func-candidates` flags procs with no *visible* side effect. A heuristic, and
## it says so: it cannot see through a call to another proc, so a proc that only
## calls an impure helper still looks pure here.

import compiler/[ast, renderer]
import std/[os, strutils, json, parseopt, sequtils]
import ../shared/[compiler_env, ast_utils, exit_codes]

type
  RoutineEffects* = object
    name*, kind*, sig*: string
    line*: int
    declared*: bool          ## a {.raises.} pragma was written
    raises*: seq[string]     ## its contents; empty + declared = raises nothing
    otherPragmas*: seq[string]

  FuncCandidate* = object
    name*, sig*: string
    line*: int

proc pragmaNode(n: PNode): PNode =
  ## Pragma list of a routine definition, or nil. Index 4 in a routine node.
  if n == nil or n.len < 5: return nil
  let p = n[4]
  if p != nil and p.kind == nkPragma: p else: nil

proc effectsOf*(filePath: string): seq[RoutineEffects] =
  ## Declared effect surface of every routine in the file.
  let parsed = parseNimFile(filePath)
  if parsed.ast == nil: return @[]

  for n in collectRoutines(parsed.ast):
    var e = RoutineEffects(name: routineName(n), kind: routineKindName(n),
      sig: renderRoutineSignature(n), line: n.info.line.int,
      declared: false, raises: @[], otherPragmas: @[])

    let prag = pragmaNode(n)
    if prag != nil:
      for item in prag:
        if item.kind == nkExprColonExpr and item.len >= 2 and
           item[0].kind == nkIdent:
          let pname = item[0].ident.s
          if pname == "raises":
            e.declared = true
            if item[1].kind == nkBracket:
              for ex in item[1]:
                e.raises.add renderTree(ex).strip()
          else:
            if pname notin e.otherPragmas: e.otherPragmas.add pname
        elif item.kind == nkIdent:
          if item.ident.s notin e.otherPragmas:
            e.otherPragmas.add item.ident.s
    result.add e

proc hasVarParam(n: PNode): bool =
  ## True when any parameter is `var T` — the routine can mutate its caller's
  ## data, so it is not a func candidate.
  if n.len < 4 or n[3] == nil or n[3].kind != nkFormalParams: return false
  for i, p in n[3]:
    if i == 0 or p.kind != nkIdentDefs: continue
    if p.len >= 2 and p[^2] != nil and p[^2].kind == nkVarTy: return true
  false

const ImpureNames = ["echo", "write", "writeLine", "print", "readLine",
                     "readFile", "writeFile", "open", "close", "exec",
                     "execShellCmd", "getTime", "now", "rand", "quit",
                     "createDir", "removeFile", "copyFile", "moveFile"]

proc funcCandidates*(filePath: string): seq[FuncCandidate] =
  ## `proc`s with no visible side effect, which could likely be `func`.
  ##
  ## HEURISTIC. Flags a proc only when its body contains no call to a known
  ## impure routine, no assignment to anything declared outside it, and no `var`
  ## parameter. It cannot see through calls, so a proc whose only impurity is a
  ## call to an impure helper in the same file will still be flagged. Treat the
  ## output as candidates to review, not as a verified purity proof.
  let parsed = parseNimFile(filePath)
  if parsed.ast == nil: return @[]

  # Names declared at module level: assigning to one is a side effect.
  var globals: seq[string] = @[]
  proc collectGlobals(n: PNode) =
    if n == nil: return
    if n.kind in {nkVarSection, nkLetSection}:
      for defs in n:
        if defs.kind != nkIdentDefs: continue
        for i in 0 .. defs.len - 3:
          let nm = if defs[i].kind == nkIdent: defs[i].ident.s
                   elif defs[i].kind == nkPostfix and defs[i].len >= 2 and
                        defs[i][1].kind == nkIdent: defs[i][1].ident.s
                   else: ""
          if nm.len > 0: globals.add nm
    elif n.kind == nkStmtList:
      for c in n: collectGlobals(c)
  collectGlobals(parsed.ast)

  proc isImpure(n: PNode, localNames: var seq[string]): bool =
    if n == nil: return false
    case n.kind
    of nkCall, nkCommand:
      if n.len >= 1 and n[0].kind == nkIdent and n[0].ident.s in ImpureNames:
        return true
    of nkAsgn:
      # Assigning to a module-level name is a side effect; to a local, not.
      if n.len >= 1:
        let lhs = n[0]
        let nm = if lhs.kind == nkIdent: lhs.ident.s else: ""
        if nm.len > 0 and nm in globals and nm notin localNames: return true
        if lhs.kind == nkDotExpr: return true   # mutating a field of something
    of nkVarSection, nkLetSection:
      for defs in n:
        if defs.kind != nkIdentDefs: continue
        for i in 0 .. defs.len - 3:
          if defs[i].kind == nkIdent: localNames.add defs[i].ident.s
    else: discard
    if hasSons(n):
      for c in n:
        if isImpure(c, localNames): return true
    false

  for n in collectRoutines(parsed.ast):
    if n.kind != nkProcDef: continue          # already a func/template/etc
    if hasVarParam(n): continue
    let body = if n.len >= 7: n[6] else: nil
    if body == nil or body.kind == nkEmpty: continue
    var locals: seq[string] = @[]
    if isImpure(body, locals): continue
    result.add FuncCandidate(name: routineName(n),
      sig: renderRoutineSignature(n), line: n.info.line.int)

proc renderEffects(filePath: string, es: seq[RoutineEffects],
                   exportedOnly: bool): string =
  result = filePath & "\n"
  var shown = 0
  for e in es:
    if exportedOnly and not e.sig.contains("*"): continue
    shown.inc
    if e.declared:
      if e.raises.len == 0:
        result &= "  raises nothing   " & e.sig & "\n"
      else:
        result &= "  raises " & e.raises.join(", ") & "   " & e.sig & "\n"
    else:
      result &= "  UNDECLARED       " & e.sig & "\n"
  if shown == 0: result &= "  (no routines)\n"
  result &= "  UNDECLARED means no {.raises.} pragma — the parser cannot infer\n" &
            "  effects, so those may raise anything.\n"

proc main*(args: seq[string]): int =
  ## CLI entry for `raises`. Returns an exit code rather than quitting.
  var p = initOptParser(args)
  var files: seq[string] = @[]
  var asJson, helpRequested, exportedOnly = false

  while true:
    p.next()
    case p.kind
    of cmdEnd: break
    of cmdShortOption, cmdLongOption:
      case p.key.toLowerAscii
      of "h", "help": helpRequested = true
      of "j", "json": asJson = true
      of "e", "exported": exportedOnly = true
      else:
        stderr.writeLine "Unknown option: --", p.key
        return ExitError
    of cmdArgument: files.add p.key

  if helpRequested or files.len == 0:
    echo """
nimtools raises: Declared exception surface.

Usage:
  raises [--exported] [--json] FILE...

Reports the {.raises.} pragma of each routine. DECLARED ONLY — Nim infers
effects during compilation, which the parser cannot see. A routine with no
pragma is reported UNDECLARED, never as safe.

Options:
  -e, --exported   only exported routines
  -j, --json       machine-readable output
"""
    return ExitOk

  for f in files:
    if not fileExists(f):
      stderr.writeLine "Error: File not found: ", f
      return ExitError

  if asJson:
    var arr = newJArray()
    for f in files:
      for e in effectsOf(f):
        if exportedOnly and not e.sig.contains("*"): continue
        arr.add %*{"file": f, "name": e.name, "kind": e.kind, "line": e.line,
                   "sig": e.sig, "declared": e.declared, "raises": e.raises,
                   "otherPragmas": e.otherPragmas}
    echo arr.pretty()
  else:
    for i, f in files:
      if i > 0: echo ""
      stdout.write renderEffects(f, effectsOf(f), exportedOnly)
  return ExitOk

proc funcMain*(args: seq[string]): int =
  ## CLI entry for `func-candidates`.
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
    of cmdArgument: files.add p.key

  if helpRequested or files.len == 0:
    echo """
nimtools func-candidates: procs that show no side effect and could be func.

Usage:
  func-candidates [--json] FILE...

HEURISTIC — cannot see through calls, so a proc whose only impurity is calling
an impure helper is still flagged. Review before changing anything.

Options:
  -j, --json   machine-readable output
"""
    return ExitOk

  var all: seq[tuple[file: string, c: FuncCandidate]] = @[]
  for f in files:
    if not fileExists(f):
      stderr.writeLine "Error: File not found: ", f
      return ExitError
    for c in funcCandidates(f): all.add (f, c)

  if asJson:
    var arr = newJArray()
    for (f, c) in all:
      arr.add %*{"file": f, "name": c.name, "sig": c.sig, "line": c.line}
    echo arr.pretty()
  else:
    if all.len == 0:
      echo "No func candidates found."
    else:
      echo all.len, " proc(s) with no visible side effect:"
      for (f, c) in all:
        echo "  ", f, ":", c.line, "  ", c.sig
  return ExitOk

when isMainModule:
  quit(main(commandLineParams()))
