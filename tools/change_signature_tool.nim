## change-signature: add/remove/reorder a proc's parameters and fix up every
## call site project-wide, using the semantic reference engine
## (findSemanticReferences) to find every call regardless of UFCS or
## qualified-call form.
##
## One operation per invocation. Each is independently safe to reason about
## and independently testable; an agent chains calls for a compound change.
##
## --remove-param refuses (exit 2) when a call site's argument for that
## parameter is anything other than a bare literal or identifier -- such an
## argument could have a side effect that dropping it would silently lose.
## This mirrors move-symbol's findLeftBehindDeps precedent. --force overrides.

import compiler/[ast, renderer]
import std/[os, strutils, parseopt, sequtils, sets, tables]
import ../shared/[compiler_env, ast_utils, source_rewriter, exit_codes, suggest]
import references_tool, project_graph

type
  ChangeSigStatus* = enum
    csApplied
    csRefused
    csError

  ChangeSigResult* = object
    status*: ChangeSigStatus
    message*: string
    blockedSites*: seq[string]   ## file:line:col, populated only on csRefused

proc findEnclosingRoutineDecl(root: PNode, line, col: int): PNode =
  ## The routine whose declarationPos matches `line:col` -- --at names the
  ## proc's own name token, same convention as rename-scoped/rename-project.
  for n in collectRoutines(root):
    let (l, c) = declarationPos(n)
    if l == line and c == col: return n

proc formalParams(n: PNode): PNode =
  if n.len >= 4 and n[3] != nil and n[3].kind == nkFormalParams: n[3] else: nil

proc paramNames(formals: PNode): seq[string] =
  if formals == nil: return @[]
  for i in 1 ..< formals.len:
    let p = formals[i]
    if p.kind != nkIdentDefs: continue
    for j in 0 .. p.len - 3:
      result.add p[j].ident.s

proc isSimpleArg(n: PNode): bool =
  ## A bare literal or identifier -- cannot have a side effect. Anything else
  ## (call, operator, index, dot-access) is treated as possibly effectful.
  ## nkLiterals (compiler/ast.nim) = nkCharLit..nkTripleStrLit, which already
  ## spans int/uint/float/string/char kinds; nkNilLit and nkIdent added
  ## separately since nkLiterals does not include them.
  n.kind in ({nkNilLit, nkIdent} + nkLiterals)

proc callArgExpr(callSite: PNode, paramIndex: int, paramName: string): PNode =
  ## The argument node at `paramIndex` (0-based, excluding the callee), or the
  ## one named `paramName` if the call uses named-argument form. Nil if this
  ## call node does not look like a call at all.
  if callSite.kind != nkCall or callSite.len < 2: return nil
  var positional = 0
  for i in 1 ..< callSite.len:
    let a = callSite[i]
    if a.kind == nkExprEqExpr and a.len == 2 and a[0].kind == nkIdent:
      if a[0].ident.s == paramName: return a[1]
    else:
      if positional == paramIndex: return a
      positional.inc
  nil

proc findCallAt(n: PNode, line, col: int): PNode =
  ## An nkCall whose callee token sits at line:col. findSemanticReferences
  ## reports the callee's own position, not the whole call node's span.
  if n == nil: return nil
  if n.kind == nkCall and n.len >= 1:
    let (cl, cc) = declarationPos(n)
    # declarationPos unwraps nkPostfix/nkPragmaExpr on n[0]; a bare nkIdent
    # callee needs its own info directly.
    var calleeNode = n[0]
    let (rl, rc) = (calleeNode.info.line.int, calleeNode.info.col.int)
    if rl == line and rc == col: return n
  if hasSons(n):
    for c in n:
      let inner = findCallAt(c, line, col)
      if inner != nil: return inner

proc rewriteDecl(filePath: string, declNode: PNode,
                 newFormals: seq[tuple[name, typ, default: string]]): string =
  let (s, e) = nodeLineBounds(declNode)
  let original = extractLineRange(readFile(filePath), s, e)
  let openParen = original.find('(')
  let closeParen = original.rfind(')')
  if openParen < 0 or closeParen < 0:
    return original
  let newParamText = newFormals.mapIt(
    it.name & ": " & it.typ & (if it.default.len > 0: " = " & it.default else: "")
  ).join(", ")
  original[0 .. openParen] & newParamText & original[closeParen .. ^1]

proc currentFormals(formals: PNode): seq[tuple[name, typ, default: string]] =
  if formals == nil: return @[]
  for i in 1 ..< formals.len:
    let p = formals[i]
    if p.kind != nkIdentDefs: continue
    let typText = if p[^2].kind != nkEmpty: renderTree(p[^2]).strip() else: ""
    let defText = if p[^1].kind != nkEmpty: renderTree(p[^1]).strip() else: ""
    for j in 0 .. p.len - 3:
      result.add (p[j].ident.s, typText, defText)

proc addParam*(filePath, root: string; line, col: int;
              name, typ, default: string): ChangeSigResult =
  let parsed = parseNimFile(filePath)
  if parsed.ast == nil:
    return ChangeSigResult(status: csError, message: "Could not parse: " & filePath)
  let declNode = findEnclosingRoutineDecl(parsed.ast, line, col)
  if declNode == nil:
    return ChangeSigResult(status: csError,
      message: "No routine declared at " & filePath & ":" & $line & ":" & $col)

  var formals = currentFormals(formalParams(declNode))
  formals.add (name, typ, default)
  let newDecl = rewriteDecl(filePath, declNode, formals)
  let (s, e) = nodeLineBounds(declNode)
  writeFile(filePath, replaceLineRange(readFile(filePath), s, e, newDecl))
  ChangeSigResult(status: csApplied,
    message: "Added parameter '" & name & "' to the declaration in " & filePath)

proc removeParam*(filePath, root: string; line, col: int; name: string;
                  force = false): ChangeSigResult =
  let parsed = parseNimFile(filePath)
  if parsed.ast == nil:
    return ChangeSigResult(status: csError, message: "Could not parse: " & filePath)
  let declNode = findEnclosingRoutineDecl(parsed.ast, line, col)
  if declNode == nil:
    return ChangeSigResult(status: csError,
      message: "No routine declared at " & filePath & ":" & $line & ":" & $col)

  let formals = formalParams(declNode)
  let names = paramNames(formals)
  let paramIndex = names.find(name)
  if paramIndex < 0:
    return ChangeSigResult(status: csError,
      message: "No parameter named '" & name & "' in the declaration")

  let symbolName = routineName(declNode)
  let (sr, status, sMessage) = findSemanticReferences(filePath, symbolName, root, line, col)
  if status != ssOk:
    return ChangeSigResult(status: csError, message: sMessage)

  if not force:
    var blocked: seq[string] = @[]
    for f in sr.files:
      for u in f.uses:
        let callParsed = parseNimFile(f.file)
        if callParsed.ast == nil: continue
        let callNode = findCallAt(callParsed.ast, u.line, u.col)
        if callNode == nil: continue
        let argNode = callArgExpr(callNode, paramIndex, name)
        if argNode != nil and not isSimpleArg(argNode):
          blocked.add f.file & ":" & $u.line & ":" & $u.col &
                      "  (" & renderTree(argNode).strip() & ")"
    if blocked.len > 0:
      return ChangeSigResult(status: csRefused, blockedSites: blocked,
        message: "Refusing to remove '" & name & "': " & $blocked.len &
                 " call site(s) pass a non-trivial expression for it, which " &
                 "could have a side effect. Pass --force to remove anyway.")

  # Rewrite the declaration.
  var newFormals: seq[tuple[name, typ, default: string]] = @[]
  for f in currentFormals(formals):
    if f.name != name: newFormals.add f
  let newDecl = rewriteDecl(filePath, declNode, newFormals)
  let (s, e) = nodeLineBounds(declNode)
  writeFile(filePath, replaceLineRange(readFile(filePath), s, e, newDecl))

  # Rewrite call sites: drop the argument at paramIndex (or the named form).
  for f in sr.files:
    if f.uses.len == 0: continue
    var text = readFile(f.file)
    var edits: seq[tuple[line: int, newText: string]] = @[]
    let callParsed = parseNimFile(f.file)
    if callParsed.ast == nil: continue
    for u in f.uses:
      let callNode = findCallAt(callParsed.ast, u.line, u.col)
      if callNode == nil: continue
      var newArgs: seq[PNode] = @[]
      var positional = 0
      for i in 1 ..< callNode.len:
        let a = callNode[i]
        let isNamedTarget = a.kind == nkExprEqExpr and a.len == 2 and
                            a[0].kind == nkIdent and a[0].ident.s == name
        let isPositionalTarget = a.kind != nkExprEqExpr and positional == paramIndex
        if not isNamedTarget and not isPositionalTarget: newArgs.add a
        if a.kind != nkExprEqExpr: positional.inc
      let (cs, ce) = nodeLineBounds(callNode)
      let calleeText = renderTree(callNode[0]).strip()
      let argsText = newArgs.mapIt(renderTree(it).strip()).join(", ")
      edits.add (cs, calleeText & "(" & argsText & ")")
    for e in edits:
      text = replaceLineRange(text, e.line, e.line, e.newText)
    writeFile(f.file, text)

  ChangeSigResult(status: csApplied,
    message: "Removed parameter '" & name & "' from " & filePath &
             " and " & $sr.files.len & " call site file(s)")

proc reorderParams*(filePath, root: string; line, col: int;
                    newOrder: seq[string]): ChangeSigResult =
  let parsed = parseNimFile(filePath)
  if parsed.ast == nil:
    return ChangeSigResult(status: csError, message: "Could not parse: " & filePath)
  let declNode = findEnclosingRoutineDecl(parsed.ast, line, col)
  if declNode == nil:
    return ChangeSigResult(status: csError,
      message: "No routine declared at " & filePath & ":" & $line & ":" & $col)

  let formals = currentFormals(formalParams(declNode))
  let oldOrder = formals.mapIt(it.name)
  if newOrder.len != oldOrder.len or newOrder.toHashSet != oldOrder.toHashSet:
    return ChangeSigResult(status: csError,
      message: "--reorder must name exactly the existing parameters, got: " &
               newOrder.join(","))

  var byName = initTable[string, tuple[name, typ, default: string]]()
  for f in formals: byName[f.name] = f
  var reordered: seq[tuple[name, typ, default: string]] = @[]
  for n in newOrder: reordered.add byName[n]

  let symbolName = routineName(declNode)
  let (sr, status, sMessage) = findSemanticReferences(filePath, symbolName, root, line, col)
  if status != ssOk:
    return ChangeSigResult(status: csError, message: sMessage)

  let newDecl = rewriteDecl(filePath, declNode, reordered)
  let (s, e) = nodeLineBounds(declNode)
  writeFile(filePath, replaceLineRange(readFile(filePath), s, e, newDecl))

  var newIndexOf = initTable[string, int]()
  for i, n in newOrder: newIndexOf[n] = i

  for f in sr.files:
    if f.uses.len == 0: continue
    var text = readFile(f.file)
    let callParsed = parseNimFile(f.file)
    if callParsed.ast == nil: continue
    var edits: seq[tuple[line: int, newText: string]] = @[]
    for u in f.uses:
      let callNode = findCallAt(callParsed.ast, u.line, u.col)
      if callNode == nil: continue
      var isNamedCall = false
      for i in 1 ..< callNode.len:
        if callNode[i].kind == nkExprEqExpr: isNamedCall = true
      if isNamedCall: continue  # named args are already order-independent
      var positionalArgs: seq[PNode] = @[]
      for i in 1 ..< callNode.len: positionalArgs.add callNode[i]
      if positionalArgs.len != oldOrder.len: continue  # partial call, skip
      var reorderedArgs = newSeq[PNode](positionalArgs.len)
      for oldIdx, argNode in positionalArgs:
        let pname = oldOrder[oldIdx]
        reorderedArgs[newIndexOf[pname]] = argNode
      let (cs, ce) = nodeLineBounds(callNode)
      let calleeText = renderTree(callNode[0]).strip()
      let argsText = reorderedArgs.mapIt(renderTree(it).strip()).join(", ")
      edits.add (cs, calleeText & "(" & argsText & ")")
    for e in edits:
      text = replaceLineRange(text, e.line, e.line, e.newText)
    writeFile(f.file, text)

  ChangeSigResult(status: csApplied,
    message: "Reordered parameters of " & filePath &
             " and updated " & $sr.files.len & " call site file(s)")

proc parseLineCol(at: string): tuple[line, col: int; ok: bool] =
  let parts = at.split(':')
  if parts.len != 2: return (-1, -1, false)
  let line = try: parseInt(parts[0]) except ValueError: -1
  let col = try: parseInt(parts[1]) except ValueError: -1
  if line < 1 or col < 0: return (-1, -1, false)
  (line, col, true)

proc main*(args: seq[string]): int =
  var p = initOptParser(args)
  var file, at, addSpec, removeSpec, reorderSpec = ""
  var force, helpRequested = false
  while true:
    p.next()
    case p.kind
    of cmdEnd: break
    of cmdShortOption, cmdLongOption:
      case p.key.toLowerAscii
      of "h", "help": helpRequested = true
      of "at": at = p.val
      of "add-param": addSpec = p.val
      of "remove-param": removeSpec = p.val
      of "reorder": reorderSpec = p.val
      of "force", "f": force = true
      else:
        stderr.writeLine "Unknown option: --", p.key
        return ExitError
    of cmdArgument:
      if file == "": file = p.key
      else:
        stderr.writeLine "Unexpected argument: ", p.key
        return ExitError

  let opCount = [addSpec.len > 0, removeSpec.len > 0, reorderSpec.len > 0].countIt(it)
  if helpRequested or file == "" or at == "" or opCount != 1:
    echo """
nimtools change-signature: Add/remove/reorder a proc's parameters and fix up
every call site project-wide (UFCS and qualified calls included).

Usage:
  change-signature --at:LINE:COL <file.nim> --add-param "name:type=default"
  change-signature --at:LINE:COL <file.nim> --remove-param name [--force]
  change-signature --at:LINE:COL <file.nim> --reorder a,c,b

Exactly one of --add-param / --remove-param / --reorder per invocation.
--remove-param refuses (exit 2) when a call site's argument for that param
is not a bare literal or identifier -- it could have a side effect that
dropping it would silently lose. --force removes anyway.

Exit codes:
  0  applied
  1  bad input, parse failure, symbol not found, or nimsuggest unavailable
  2  refused: a call site's argument might have a side effect
"""
    return ExitOk

  let (line, col, ok) = parseLineCol(at)
  if not ok:
    stderr.writeLine "Error: malformed --at (want LINE:COL): ", at
    return ExitError
  if not fileExists(file):
    stderr.writeLine "Error: File not found: ", file
    return ExitError

  let root = pickProjectRoot(file)
  var r: ChangeSigResult

  if addSpec.len > 0:
    let parts = addSpec.split(':', 1)
    if parts.len != 2:
      stderr.writeLine "Error: --add-param wants 'name:type=default'"
      return ExitError
    let typeParts = parts[1].split('=', 1)
    if typeParts.len != 2:
      stderr.writeLine "Error: --add-param needs a default value ('name:type=default')"
      return ExitError
    r = addParam(file, root, line, col, parts[0].strip, typeParts[0].strip, typeParts[1].strip)
  elif removeSpec.len > 0:
    r = removeParam(file, root, line, col, removeSpec.strip, force = force)
  else:
    r = reorderParams(file, root, line, col, reorderSpec.split(',').mapIt(it.strip))

  case r.status
  of csApplied:
    echo r.message
    ExitOk
  of csRefused:
    stderr.writeLine r.message
    for site in r.blockedSites: stderr.writeLine "  ", site
    ExitRefused
  of csError:
    stderr.writeLine "Error: ", r.message
    ExitError

when isMainModule:
  quit(main(commandLineParams()))
