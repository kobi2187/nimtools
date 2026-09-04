import compiler/[ast, renderer, idents, lineinfos]
import std/strutils

const
  RoutineKinds* = {nkProcDef, nkFuncDef, nkMethodDef, nkIteratorDef,
                   nkConverterDef, nkTemplateDef, nkMacroDef}
  BranchKinds* = {nkElifBranch, nkElifExpr, nkOfBranch, nkExceptBranch,
                  nkWhileStmt, nkForStmt}
  ShortCircuitOps* = ["and", "or"]

proc hasSons*(n: PNode): bool {.inline.} =
  n != nil and n.kind notin {nkCharLit..nkUInt64Lit, nkFloatLit..nkFloat128Lit,
                             nkStrLit..nkTripleStrLit, nkSym, nkIdent, nkEmpty}

proc isExported*(n: PNode): bool =
  ## Checks if a definition name has an export marker `*`.
  if n == nil or n.len == 0: return false
  var nameNode = n[0]
  if nameNode.kind == nkPragmaExpr and nameNode.len > 0:
    nameNode = nameNode[0]
  return nameNode.kind == nkPostfix and nameNode.len > 0 and nameNode[0].ident.s == "*"

proc routineName*(n: PNode): string =
  ## Extracts the declared name of a routine, stripped of `*` and pragmas.
  if n == nil or n.len == 0: return "<anon>"
  var nameNode = n[0]
  while nameNode.kind in {nkPostfix, nkPragmaExpr} and nameNode.len > 1:
    nameNode = (if nameNode.kind == nkPostfix: nameNode[1] else: nameNode[0])
  if nameNode.kind == nkIdent:
    return nameNode.ident.s
  elif nameNode.kind == nkAccQuoted and nameNode.len > 0 and nameNode[0].kind == nkIdent:
    return "`" & nameNode[0].ident.s & "`"
  else:
    return "<anon>"

proc typeDefName*(n: PNode): string =
  ## Extracts the declared name of a type definition.
  assert n.kind == nkTypeDef
  return routineName(n)

proc declarationPos*(n: PNode): tuple[line, col: int] =
  ## 1-based line and 0-based column of a definition's name, unwrapping `*` and
  ## pragma wrappers. The column matches the compiler convention that
  ## `rename-symbol --at:LINE:COL` consumes, so a query can feed a rename.
  if n == nil or n.len == 0: return (0, 0)
  var nameNode = n[0]
  while nameNode.kind in {nkPostfix, nkPragmaExpr} and nameNode.len > 1:
    nameNode = (if nameNode.kind == nkPostfix: nameNode[1] else: nameNode[0])
  (nameNode.info.line.int, nameNode.info.col.int)

proc nodeLineBounds*(n: PNode): tuple[startLine, endLine: int] =
  ## Computes the line span [startLine, endLine] of a node in the source file.
  ##
  ## nkEmpty nodes are excluded from the walk. An nkEmpty carries no source
  ## text of its own -- it is the parser's placeholder for "nothing here"
  ## (a missing type, a missing default value, a missing return type) -- but
  ## its `.info` position is NOT nil or (0,0); the parser sets it to wherever
  ## its cursor happened to land next. For an nkIdentDefs field with no default
  ## value, that is the position of the FOLLOWING declaration, not this one's.
  ## Counting it inflated a type's span into its neighboring typedef's territory,
  ## which made move-symbol extract and delete one line too many.
  if n == nil: return (0, 0)
  var lo = n.info.line.int
  var hi = lo
  proc walk(x: PNode) =
    if x == nil or x.kind == nkEmpty: return
    let l = x.info.line.int
    if l > hi: hi = l
    if l < lo and l > 0: lo = l
    if hasSons(x):
      for c in x: walk(c)
  walk(n)
  return (lo, hi)

proc routineKindName*(n: PNode): string =
  ## Human-readable keyword for a routine definition node.
  if n == nil: return "routine"
  case n.kind
  of nkProcDef: "proc"
  of nkFuncDef: "func"
  of nkMethodDef: "method"
  of nkIteratorDef: "iterator"
  of nkTemplateDef: "template"
  of nkMacroDef: "macro"
  of nkConverterDef: "converter"
  else: "routine"

proc docComment*(n: PNode): string =
  ## Returns the doc comment attached to a routine, or "" when it has none.
  ## A routine's doc is the leading `##` block of its body; the parser attaches
  ## it either to the definition node itself or as the first body statement.
  if n == nil: return ""
  if n.comment.len > 0: return n.comment.strip()
  let body = if n.len >= 7: n[6] else: nil
  if body == nil or body.kind == nkEmpty: return ""
  if body.comment.len > 0: return body.comment.strip()
  if body.kind == nkStmtList and body.len > 0:
    let first = body[0]
    if first.kind == nkCommentStmt: return first.comment.strip()
    if first.comment.len > 0: return first.comment.strip()
  return ""

proc collectRoutines*(root: PNode): seq[PNode] =
  ## Returns every routine definition in `root`, including routines nested
  ## inside other routines. Recursion is unconditional: a routine is recorded
  ## AND descended into, so nested definitions are never skipped.
  ## Bodiless forward declarations are excluded — they are not definitions.
  proc walk(n: PNode, acc: var seq[PNode]) =
    if n == nil: return
    if n.kind in RoutineKinds:
      let hasBody = n.len >= 7 and n[6] != nil and n[6].kind != nkEmpty
      if hasBody: acc.add n
    if hasSons(n):
      for c in n: walk(c, acc)
  walk(root, result)

proc collectTypeDefs*(root: PNode): seq[PNode] =
  ## Returns every `nkTypeDef` in `root`, including types declared inside
  ## routine bodies. Same unconditional-recursion rule as `collectRoutines`.
  proc walk(n: PNode, acc: var seq[PNode]) =
    if n == nil: return
    if n.kind == nkTypeDef: acc.add n
    if hasSons(n):
      for c in n: walk(c, acc)
  walk(root, result)

type
  FoundSymbol* = object
    name*: string
    node*: PNode
    startLine*: int
    endLine*: int

proc findSymbolNodes*(root: PNode, symbolNames: seq[string]): seq[FoundSymbol] =
  ## Every type or routine definition whose name is in `symbolNames`, with its
  ## 1-based line span. Shared by move and delete; `node` is kept for callers
  ## that need the AST, `startLine`/`endLine` for line-range edits.
  for n in collectTypeDefs(root):
    let name = typeDefName(n)
    if name in symbolNames:
      let (s, e) = nodeLineBounds(n)
      result.add FoundSymbol(name: name, node: n, startLine: s, endLine: e)
  for n in collectRoutines(root):
    let name = routineName(n)
    if name in symbolNames:
      let (s, e) = nodeLineBounds(n)
      result.add FoundSymbol(name: name, node: n, startLine: s, endLine: e)

proc renderTypeNode*(n: PNode): string =
  ## Formats any type AST node into a concise, single-line representation.
  if n == nil: return ""
  case n.kind
  of nkIdent:
    return n.ident.s
  of nkSym:
    return n.sym.name.s
  of nkPostfix:
    if n.len >= 2:
      return renderTypeNode(n[1]) & n[0].ident.s
    else:
      return renderTree(n)
  of nkPragmaExpr:
    if n.len >= 2:
      return renderTypeNode(n[0]) & " " & renderTree(n[1])
    else:
      return renderTree(n)
  of nkDistinctTy:
    return if n.len > 0: "distinct " & renderTypeNode(n[0]) else: "distinct"
  of nkRefTy:
    return if n.len > 0: "ref " & renderTypeNode(n[0]) else: "ref"
  of nkPtrTy:
    return if n.len > 0: "ptr " & renderTypeNode(n[0]) else: "ptr"
  of nkVarTy:
    return if n.len > 0: "var " & renderTypeNode(n[0]) else: "var"
  of nkBracketExpr:
    var res = renderTypeNode(n[0]) & "["
    for i in 1 ..< n.len:
      if i > 1: res &= ", "
      res &= renderTypeNode(n[i])
    res &= "]"
    return res
  of nkObjectTy:
    var res = "object"
    if n.len > 1 and n[1].kind != nkEmpty:
      res &= " " & renderTree(n[1])
    if n.len > 2 and n[2].kind != nkEmpty:
      res &= " { " & renderTypeNode(n[2]) & " }"
    return res
  of nkRecList:
    var fields: seq[string] = @[]
    for child in n:
      fields.add(renderTypeNode(child))
    return fields.join(", ")
  of nkIdentDefs:
    if n.len >= 3:
      var names: seq[string] = @[]
      for i in 0 .. n.len - 3:
        names.add(renderTree(n[i]))
      let typStr = renderTypeNode(n[n.len - 2])
      let defVal = n[n.len - 1]
      var res = names.join(", ") & ": " & typStr
      if defVal.kind != nkEmpty:
        res &= " = " & renderTree(defVal)
      return res
    else:
      return renderTree(n)
  of nkEnumTy:
    var vals: seq[string] = @[]
    for i in 1 ..< n.len:
      vals.add(renderTree(n[i]))
    return "enum { " & vals.join(", ") & " }"
  of nkTupleTy:
    var fields: seq[string] = @[]
    for child in n:
      fields.add(renderTypeNode(child))
    return "tuple { " & fields.join(", ") & " }"
  of nkProcTy:
    var res = "proc"
    if n.len > 0 and n[0].kind != nkEmpty:
      res &= renderTree(n[0])
    if n.len > 1 and n[1].kind != nkEmpty:
      res &= " " & renderTree(n[1])
    return res
  of nkRecCase:
    var res = "case " & renderTypeNode(n[0])
    for i in 1 ..< n.len:
      let branch = n[i]
      if branch.kind == nkOfBranch:
        var vals: seq[string] = @[]
        for j in 0 .. branch.len - 2:
          vals.add(renderTree(branch[j]))
        res &= " of " & vals.join(", ") & ": (" & renderTypeNode(branch[branch.len - 1]) & ")"
      elif branch.kind == nkElse:
        res &= " else: (" & renderTypeNode(branch[0]) & ")"
    return res
  else:
    return renderTree(n).replace("\n", " ").replace("  ", " ").strip()

proc renderTypeDefConcise*(n: PNode): string =
  ## Formats a nkTypeDef into `type Name* = ...` single line.
  assert n.kind == nkTypeDef
  let nameStr = renderTree(n[0])
  let genericsStr = if n[1].kind != nkEmpty: renderTree(n[1]) else: ""
  let bodyStr = renderTypeNode(n[2])
  result = "type " & nameStr & genericsStr & " = " & bodyStr

proc renderRoutineSignature*(n: PNode): string =
  ## Formats a routine definition into its one-line signature.
  assert n.kind in RoutineKinds
  return renderTree(n, {renderNoBody, renderNoComments}).strip()

# --- Cyclomatic Complexity Helpers ---

proc isShortCircuit(n: PNode): bool =
  if n.kind notin {nkInfix, nkCall}: return false
  if n.len == 0 or n[0].kind != nkIdent: return false
  return n[0].ident.s in ShortCircuitOps

proc countBranches*(n: PNode): int

proc isDispatchArm*(n: PNode): bool =
  if n.kind != nkOfBranch or n.len == 0: return false
  return countBranches(n[^1]) == 0

proc countBranches*(n: PNode): int =
  if n == nil: return 0
  if n.kind in BranchKinds and not isDispatchArm(n): result += 1
  if isShortCircuit(n): result += 1
  if hasSons(n):
    for c in n:
      if c.kind in RoutineKinds: continue
      result += countBranches(c)

proc calcCyclomaticComplexity*(n: PNode): int =
  if n == nil or n.kind notin RoutineKinds: return 1
  let body = if n.len >= 7: n[6] else: nil
  if body != nil and body.kind != nkEmpty:
    return countBranches(body) + 1
  return 1
