## Scope-aware rename within a single file.
##
## Token rename (`source_rewriter.renameTokenStream`) rewrites every identifier
## in the file matching a name. That is wrong for anything local: rename `i` and
## you hit every `i` in every proc. This module renames a *binding* — one
## declaration and the uses that actually resolve to it.
##
## It works off the parser AST, so no compilation and no nimsuggest is needed.
## The parse tree carries enough for lexical scoping: procs, blocks, for-loops
## and their bodies are nodes, declarations sit in known positions, and every
## identifier records its own line:col so a resolved use maps straight to a
## rewrite span.
##
## LIMIT: lexical scope only, one file. It cannot resolve overloads, follow a
## symbol across modules, or reason about types — renaming an exported symbol
## used elsewhere still needs the caller to update the other files. Cross-file
## rename needs semantic information (nimsuggest).

import compiler/[ast]
import std/[strutils, algorithm]
import compiler_env

type
  RenameScopedStatus* = enum
    srRenamed    ## the binding and its uses were rewritten
    srNotFound   ## no binding declared at the given position
    srConflict   ## the new name already exists in that scope

  RenameScopedResult* = object
    status*: RenameScopedStatus
    message*: string
    source*: string      ## rewritten text (only meaningful on srRenamed)
    occurrences*: int    ## declaration + uses rewritten

  Pos = tuple[line, col: int]

  Binding = ref object
    name: string
    declared: Pos
    uses: seq[Pos]
    scope: Scope       ## the scope this binding was declared in

  Scope = ref object
    parent: Scope
    bindings: seq[Binding]

proc lookup(s: Scope, name: string): Binding =
  ## Innermost binding of `name` visible from `s`, or nil.
  var cur = s
  while cur != nil:
    for i in countdown(cur.bindings.high, 0):
      if cur.bindings[i].name == name: return cur.bindings[i]
    cur = cur.parent
  nil

proc declaredHere(s: Scope, name: string): bool =
  for b in s.bindings:
    if b.name == name: return true
  false

proc pos(n: PNode): Pos = (n.info.line.int, n.info.col.int)

proc identName(n: PNode): string =
  ## Name of a declaration target, unwrapping `*` and pragma wrappers.
  if n == nil: return ""
  case n.kind
  of nkIdent: n.ident.s
  of nkPostfix:
    if n.len >= 2: identName(n[1]) else: ""
  of nkPragmaExpr:
    if n.len >= 1: identName(n[0]) else: ""
  else: ""

proc declNode(n: PNode): PNode =
  ## The nkIdent actually carrying the source position of a declaration name.
  if n == nil: return nil
  case n.kind
  of nkIdent: n
  of nkPostfix:
    if n.len >= 2: declNode(n[1]) else: nil
  of nkPragmaExpr:
    if n.len >= 1: declNode(n[0]) else: nil
  else: nil

proc collectBindings(root: PNode): seq[Binding] =
  ## Walks the tree maintaining a scope stack, recording every binding with the
  ## uses that resolve to it. A use is an nkIdent that is not itself a
  ## declaration target and whose name resolves in the enclosing scope chain.
  var all: seq[Binding] = @[]

  proc declare(scope: Scope, nameNode: PNode) =
    let nm = identName(nameNode)
    let dn = declNode(nameNode)
    if nm.len == 0 or dn == nil: return
    let b = Binding(name: nm, declared: pos(dn), uses: @[], scope: scope)
    scope.bindings.add b
    all.add b

  proc use(scope: Scope, n: PNode) =
    let b = scope.lookup(n.ident.s)
    if b != nil: b.uses.add pos(n)

  proc walk(n: PNode, scope: Scope) {.gcsafe.}

  proc walkBody(n: PNode, scope: Scope) =
    ## Walks a node in a fresh child scope.
    if n != nil: walk(n, Scope(parent: scope, bindings: @[]))

  proc walkSection(n: PNode, scope: Scope) =
    ## var/let/const: each nkIdentDefs declares names[0..^3]; the type and the
    ## default value are ordinary expressions in the CURRENT scope, and must be
    ## walked BEFORE declaring, so `var x = x` refers to the outer x.
    for defs in n:
      if defs.kind notin {nkIdentDefs, nkConstDef}: continue
      if defs.len >= 2: walk(defs[^2], scope)   # type
      if defs.len >= 1: walk(defs[^1], scope)   # default value
      for i in 0 .. defs.len - 3:
        declare(scope, defs[i])

  proc walkRoutine(n: PNode, scope: Scope) =
    ## The routine name binds in the ENCLOSING scope; params and body get a new
    ## one. Params must be declared before the body is walked.
    if n.len >= 1: declare(scope, n[0])
    let inner = Scope(parent: scope, bindings: @[])
    if n.len >= 3 and n[2] != nil: walk(n[2], inner)      # generic params
    if n.len >= 4 and n[3] != nil and n[3].kind == nkFormalParams:
      for i, p in n[3]:
        if i == 0: continue                                # return type
        if p.kind != nkIdentDefs: continue
        if p.len >= 2: walk(p[^2], inner)                  # param type
        if p.len >= 1: walk(p[^1], inner)                  # default value
        for j in 0 .. p.len - 3:
          declare(inner, p[j])
    if n.len >= 7: walk(n[6], inner)                       # body

  proc walkFor(n: PNode, scope: Scope) =
    ## `for a, b in expr:` — the iterable is evaluated in the current scope,
    ## the loop variables bind in a NEW scope covering only the body. This is
    ## what stops an outer `i` from being captured by `for i in ...`.
    if n.len >= 2: walk(n[^2], scope)                      # iterable
    let inner = Scope(parent: scope, bindings: @[])
    for i in 0 .. n.len - 3:
      declare(inner, n[i])
    if n.len >= 1: walk(n[^1], inner)                      # body

  proc walk(n: PNode, scope: Scope) =
    if n == nil: return
    case n.kind
    of nkIdent:
      use(scope, n)
    of nkSym, nkEmpty, nkStrLit..nkTripleStrLit, nkCharLit..nkUInt64Lit,
       nkFloatLit..nkFloat128Lit, nkCommentStmt:
      discard
    of nkVarSection, nkLetSection, nkConstSection:
      walkSection(n, scope)
    of nkProcDef, nkFuncDef, nkMethodDef, nkIteratorDef, nkConverterDef,
       nkTemplateDef, nkMacroDef:
      walkRoutine(n, scope)
    of nkForStmt:
      walkFor(n, scope)
    of nkBlockStmt, nkBlockExpr, nkWhileStmt:
      walkBody(n, scope)
    of nkDotExpr:
      # `a.b` — only the left side is a name lookup; `b` is a field.
      if n.len >= 1: walk(n[0], scope)
    else:
      for c in n: walk(c, scope)

  walk(root, Scope(parent: nil, bindings: @[]))
  all

proc findBindingAt(bindings: seq[Binding], name: string, line, col: int): Binding =
  ## The binding declared at line:col, or whichever binding covers a use there.
  for b in bindings:
    if b.name != name: continue
    if b.declared == (line, col): return b
  for b in bindings:
    if b.name != name: continue
    for u in b.uses:
      if u == (line, col): return b
  nil

proc rewrite(source: string, spans: seq[Pos], oldName, newName: string): string =
  ## Replaces `oldName` at each line:col with `newName`, applying each line's
  ## spans right-to-left so earlier columns stay valid.
  var lines = source.splitLines()
  var byLine: seq[seq[int]] = newSeq[seq[int]](lines.len + 2)
  for (l, c) in spans:
    if l >= 1 and l <= lines.len: byLine[l].add c

  for lineNo in 1 .. lines.len:
    if byLine[lineNo].len == 0: continue
    var cols = byLine[lineNo]
    cols.sort(proc(a, b: int): int = cmp(b, a))
    var text = lines[lineNo - 1]
    for c in cols:
      if c >= 0 and c + oldName.len <= text.len and
         text.substr(c, c + oldName.len - 1) == oldName:
        text = text.substr(0, c - 1) & newName & text.substr(c + oldName.len)
    lines[lineNo - 1] = text

  lines.join(if source.contains("\r\n"): "\r\n" else: "\n")

proc renameScoped*(source, filename, oldName, newName: string;
                   line, col: int): RenameScopedResult =
  ## Renames the binding of `oldName` declared (or used) at `line`:`col`,
  ## together with every use that resolves to it. Other bindings sharing the
  ## name — in sibling procs, or shadowing it — are left alone.
  ##
  ## `line` is 1-based, `col` 0-based, matching the compiler's own positions.
  if oldName.len == 0 or newName.len == 0:
    return RenameScopedResult(status: srNotFound,
      message: "Both oldName and newName must be non-empty")

  let parsed = parseNimString(source, filename)
  if parsed.ast == nil:
    return RenameScopedResult(status: srNotFound,
      message: "Could not parse " & filename)

  let bindings = collectBindings(parsed.ast)
  let target = findBindingAt(bindings, oldName, line, col)
  if target == nil:
    return RenameScopedResult(status: srNotFound, message:
      "No binding named '" & oldName & "' is declared or used at " &
      filename & ":" & $line & ":" & $col)

  # A rename that collides with a name already bound in the SAME scope would
  # silently change which declaration the surrounding code resolves to.
  for b in bindings:
    if b.name == newName and b.scope == target.scope:
      return RenameScopedResult(status: srConflict, message:
        "'" & newName & "' is already declared at " & filename & ":" &
        $b.declared.line & ":" & $b.declared.col & " — renaming would shadow it")

  var spans = @[target.declared] & target.uses
  let updated = rewrite(source, spans, oldName, newName)
  RenameScopedResult(status: srRenamed, source: updated,
    occurrences: spans.len, message:
      "Renamed '" & oldName & "' -> '" & newName & "' (" & $spans.len &
      " occurrence(s), scope-local)")
