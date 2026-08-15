# tools/cc.nim — cyclomatic complexity, measured on the real AST.
#
# WHY NOT A REGEX. tools/complexity.py counts `if|elif|while|and|or|except` as
# text. That is wrong in both directions, and both were observed here:
#
#   OVERCOUNTS  the words inside STRING LITERALS. A three-arm case in
#               compiler/diagnostics.nim scored 8 — every match was inside
#               quotes, including an `if n > 0:` in an explanation. Splitting
#               such a proc cannot lower its score, so the gate was asking for
#               a refactor that did not exist.
#
#   UNDERCOUNTS `case` arms, which are the branches Nim code actually uses.
#               A 20-arm case over an enum counted as 1.
#
# Both disappear when the measurement is the parse tree. The Nim compiler is
# available as a library, so this parses the file for real and walks it.
#
# THE METRIC. McCabe: complexity = decision points + 1. A decision point is
# anything that adds an edge to the control-flow graph:
#
#   if / elif        each condition
#   case             each `of` arm that CONTAINS A DECISION (see below)
#   while / for      the loop test
#   and / or         short-circuit — a second path around the right operand
#   except           each handler
#
# NOT counted: `else` (the edge already exists), `try`/`finally` (no branch of
# their own), anything inside a nested routine — that gets its own score — and
# PURE DISPATCH ARMS.
#
# DISPATCH ARMS. An `of` arm whose body has no branch of its own is a lookup
# table entry written in control-flow syntax: `of exkUnary: yield e.operand`.
# The arms are data, and a reader scans them instead of tracing them. Charging
# one apiece made a 21-kind AST dispatch outscore genuinely knotty code, which
# taxed the exact shape this tree wants — see ast.children and clearIds, where
# the alternative is the same 21 arms copy-pasted per traversal.
#
# The exemption is EARNED, not assumed: it is measured by recursing into the
# arm, so anything that loops, tests, or short-circuits still counts. A `case`
# doing real work per arm scores exactly as before.
#
# BUILD ONCE (the binary is gitignored; this imports Nim's compiler sources,
# so it needs the install root on the path):
#
#   nim c --path:$(dirname $(dirname $(readlink -f $(command -v nim)))) \
#       -o:tools/cc tools/cc.nim
#
# Usage: cc [--gate N] [--budget N] FILE...
import compiler/[ast, idents, options, parser, lineinfos, llstream]
import std/[os, strutils, algorithm, sequtils]

const
  BranchKinds = {nkElifBranch, nkElifExpr, nkOfBranch, nkExceptBranch,
                 nkWhileStmt, nkForStmt}
    ## Nodes that each add one path. `nkElifBranch` covers the `if` itself:
    ## Nim represents `if c:` as an nkIfStmt whose first child is an
    ## elif-branch, so a plain if scores 1 and `if/elif/else` scores 2.
  RoutineKinds = {nkProcDef, nkFuncDef, nkMethodDef, nkIteratorDef,
                  nkConverterDef, nkTemplateDef, nkMacroDef}
  ShortCircuit = ["and", "or"]
    ## `a and b` only evaluates b sometimes, which is a branch. Written as an
    ## infix call in the tree, so it is matched by name.

proc isShortCircuit(n: PNode): bool =
  ## `a and b` / `a or b` — an infix call to one of the two operators.
  if n.kind notin {nkInfix, nkCall}: return false
  if n.len == 0 or n[0].kind != nkIdent: return false
  n[0].ident.s in ShortCircuit

proc countBranches(n: PNode): int

proc isDispatchArm(n: PNode): bool =
  ## An `of` arm that only DELIVERS a value — no decision of its own.
  ##
  ## A `case` mapping each kind to a straight action is a lookup table written
  ## in control-flow syntax; the arms are data, not decisions, and a reader
  ## scans them rather than tracing them. Charging one per arm made a 21-kind
  ## AST dispatch score higher than genuinely knotty code, which taxed exactly
  ## the shape this tree wants (see ast.children, clearIds).
  ##
  ## "No decision of its own" is measured, not guessed: the arm's body must
  ## contain zero branch points. An arm that loops, tests, or short-circuits
  ## is doing work and is still counted.
  if n.kind != nkOfBranch or n.len == 0: return false
  countBranches(n[^1]) == 0

proc countBranches(n: PNode): int =
  ## Decision points beneath `n`, NOT descending into a nested routine — that
  ## has its own complexity and is reported separately.
  if n == nil: return 0
  if n.kind in BranchKinds and not isDispatchArm(n): result += 1
  if isShortCircuit(n): result += 1
  for c in n:
    if c.kind in RoutineKinds: continue
    result += countBranches(c)

proc routineName(n: PNode): string =
  ## The declared name, with any `*` export marker and pragma stripped.
  if n.len == 0: return "<anon>"
  var nameNode = n[0]
  while nameNode.kind in {nkPostfix, nkPragmaExpr} and nameNode.len > 1:
    nameNode = (if nameNode.kind == nkPostfix: nameNode[1] else: nameNode[0])
  if nameNode.kind == nkIdent: nameNode.ident.s
  elif nameNode.kind == nkAccQuoted and nameNode.len > 0 and
       nameNode[0].kind == nkIdent: "`" & nameNode[0].ident.s & "`"
  else: "<anon>"

proc bodyLines(n: PNode): int =
  ## Lines the routine spans, from its own line to the deepest line under it.
  var lo = n.info.line.int
  var hi = lo
  proc walk(x: PNode) =
    if x == nil: return
    let l = x.info.line.int
    if l > hi: hi = l
    if l < lo and l > 0: lo = l
    for c in x: walk(c)
  walk(n)
  hi - lo + 1

type Measured = tuple[cc, lines, line: int, name, file: string]

proc collect(n: PNode, file: string, acc: var seq[Measured]) =
  ## Every routine in the tree, including nested ones — each scored on its own
  ## body, so an inner proc's branches are not charged to its parent.
  if n == nil: return
  if n.kind in RoutineKinds:
    let body = if n.len >= 7: n[6] else: nil
    if body != nil and body.kind != nkEmpty:
      acc.add((countBranches(body) + 1, bodyLines(n), n.info.line.int,
               routineName(n), file))
  for c in n: collect(c, file, acc)

proc measure(path: string, acc: var seq[Measured]) =
  let cache = newIdentCache()
  let conf = newConfigRef()
  conf.errorMax = high(int)
  try:
    collect(parseString(readFile(path), cache, conf, path), path, acc)
  except CatchableError as e:
    stderr.writeLine "cc: could not parse ", path, ": ", e.msg

proc main() =
  var gate, budget, debt, heavy = -1
  var files: seq[string]
  var i = 1
  while i <= paramCount():
    case paramStr(i)
    of "--gate": inc i; gate = parseInt(paramStr(i))
    of "--budget": inc i; budget = parseInt(paramStr(i))
    of "--debt": inc i; debt = parseInt(paramStr(i))
    of "--heavy": inc i; heavy = parseInt(paramStr(i))
    else: files.add(paramStr(i))
    inc i
  if files.len == 0:
    echo "usage: cc [--gate N] [--budget N] [--debt N] [--heavy N] FILE..."
    quit(1)

  var all: seq[Measured]
  for f in files: measure(f, all)
  all.sort(proc (a, b: Measured): int = cmp(b.cc, a.cc))

  let over = all.filterIt(it.cc > 5)
  echo all.len, " routines in ", files.len, " files"
  echo "  complexity > 5: ", over.len
  for m in over:
    echo "  cc=", m.cc, "\t", m.lines, "ln  ",
         m.file.extractFilename, ":", m.line, "  ", m.name

  var failed = false
  if gate >= 0:
    let worst = all.filterIt(it.cc > gate)
    if worst.len > 0:
      echo "\nFAIL: ", worst.len, " routine(s) over the ceiling of ", gate
      failed = true
    else:
      echo "\nceiling ", gate, ": ok (worst is ",
           (if all.len > 0: all[0].cc else: 0), ")"
  if budget >= 0:
    if over.len > budget:
      echo "FAIL: ", over.len, " routines over complexity 5, budget is ", budget
      failed = true
    else:
      echo "budget ", budget, ": ok (", over.len, " over complexity 5)"
      if over.len < budget:
        echo "  -> tighten --budget to ", over.len

  # --debt / --heavy: the metrics that actually track "small, readable procs".
  #
  # WHY THE COUNT ALONE IS THE WRONG GATE. `--budget` counts ROUTINES over 5
  # and weights them all the same, so a cc=6 helper (one guard plus a short
  # case) is the same unit of debt as a cc=53 monster. Two consequences, both
  # observed in this tree:
  #
  #   * it fires on good code. 64 procs sit at exactly cc=6, one over the
  #     line, and almost all are fine.
  #   * it PUNISHES the fix. Splitting genType (cc=53, worst in the tree) into
  #     three readable procs raised the count by two, because three procs over
  #     5 score worse than one at 53. The gate rewarded leaving it alone.
  #
  # DEBT sums how far each routine is over 5, so splitting a monster always
  # helps (53 becomes 8+7+6: debt 48 -> 6) and a new cc=6 helper costs 1.
  # HEAVY counts only routines at or over its threshold — the ones where
  # complexity genuinely hurts reading. Together they say "the tail is
  # shrinking" without taxing every small helper.
  let totalDebt = over.foldl(a + b.cc - 5, 0)
  if debt >= 0:
    if totalDebt > debt:
      echo "FAIL: complexity debt ", totalDebt, " (sum over 5), limit is ", debt
      failed = true
    else:
      echo "debt ", debt, ": ok (", totalDebt, ")"
      if totalDebt < debt: echo "  -> tighten --debt to ", totalDebt
  if heavy >= 0:
    # The threshold is where a `case` stops being dispatch and starts being a
    # proc doing several jobs. 15 is this tree's p90.
    const HeavyAt = 15
    let heavies = all.filterIt(it.cc >= HeavyAt)
    if heavies.len > heavy:
      echo "FAIL: ", heavies.len, " routines at cc>=", HeavyAt, ", limit is ", heavy
      failed = true
    else:
      echo "heavy ", heavy, ": ok (", heavies.len, " at cc>=", HeavyAt, ")"
      if heavies.len < heavy: echo "  -> tighten --heavy to ", heavies.len
  quit(if failed: 1 else: 0)

main()
