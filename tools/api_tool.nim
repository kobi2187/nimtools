## api-surface: what a module offers to the outside world.
##
## `extract` answers "show me this one symbol"; this answers "what can I call
## from outside this module" — the question an agent otherwise resolves by
## reading the whole file. Private symbols never appear; only a count of them,
## so the reader knows something is hidden without being shown it.
##
## Purely syntactic: an export marker is `*` in the parse tree and nothing else.
## No overload resolution, no UFCS ambiguity, no semantic pass — so unlike
## call-site analysis, this cannot be silently incomplete.
##
## One caveat worth knowing: exported TYPES are rendered whole, so an object's
## private fields appear in the rendered shape. That is deliberate — an agent
## reading a surface usually wants the full shape — but it means the type lines
## are "the type as declared", not strictly "the public API of the type".

import compiler/[ast]
import std/[os, strutils, json, parseopt, algorithm, sequtils]
import ../shared/[compiler_env, ast_utils, exit_codes]

type
  ApiSymbol* = object
    name*: string
    kind*: string     ## proc/func/template/macro/iterator/converter/method/type/const/let/var
    sig*: string      ## one-line signature or rendered type
    doc*: string      ## the symbol's own doc comment, "" when undocumented
    exported*: bool   ## false only when includePrivate surfaced it
    line*: int

  ModuleSurface* = object
    file*: string
    moduleDoc*: string       ## the module's header `##` block — its rationale
    symbols*: seq[ApiSymbol]
    reExports*: seq[string]  ## modules re-exported via `export`
    privateCount*: int       ## private symbols; in `symbols` only under includePrivate

type
  SurfaceChange* = object
    name*: string
    kind*: string
    before*, after*: string   ## the two signatures, for `changed`

  SurfaceDiff* = object
    added*: seq[ApiSymbol]
    removed*: seq[ApiSymbol]
    changed*: seq[SurfaceChange]
    addedReExports*, removedReExports*: seq[string]

proc isBreaking*(d: SurfaceDiff): bool =
  ## A change is breaking when existing callers can stop compiling: a symbol
  ## disappeared (or went private), its signature changed, or a re-export was
  ## withdrawn. Pure additions are not breaking.
  d.removed.len > 0 or d.changed.len > 0 or d.removedReExports.len > 0

proc isExportedName(n: PNode): bool =
  ## True when a declaration name node carries the `*` marker.
  ## nkPostfix holds the operator at [0] and the name at [1].
  if n == nil: return false
  case n.kind
  of nkPostfix:
    n.len >= 2 and n[0].kind == nkIdent and n[0].ident.s == "*"
  of nkPragmaExpr:
    n.len >= 1 and isExportedName(n[0])
  else:
    false

proc plainName(n: PNode): string =
  ## Declaration name with the export marker and any pragma wrapper removed.
  if n == nil: return ""
  case n.kind
  of nkIdent: n.ident.s
  of nkPostfix:
    if n.len >= 2: plainName(n[1]) else: ""
  of nkPragmaExpr:
    if n.len >= 1: plainName(n[0]) else: ""
  else: ""

proc collectSections(root: PNode,
                     includePrivate = false): tuple[symbols: seq[ApiSymbol],
                                                    reExports: seq[string],
                                                    privateCount: int] =
  ## const/let/var sections plus `export` statements. Each nkIdentDefs/
  ## nkConstDef may declare several names, and each name carries its own export
  ## marker, so they are checked individually rather than per-section.
  ## Routine bodies are not descended into: a `var`/`let` there is a local
  ## binding, not a module-level symbol.
  var symbols: seq[ApiSymbol] = @[]
  var reExports: seq[string] = @[]
  var privateCount = 0

  proc walk(n: PNode) =
    if n == nil: return
    if n.kind in {nkConstSection, nkLetSection, nkVarSection}:
      let kindStr = case n.kind
        of nkConstSection: "const"
        of nkLetSection: "let"
        else: "var"
      for defs in n:
        if defs.kind notin {nkIdentDefs, nkConstDef}: continue
        # names occupy every slot except the trailing type and default value
        for i in 0 .. defs.len - 3:
          let nameNode = defs[i]
          let nm = plainName(nameNode)
          if nm.len == 0: continue
          let exp = isExportedName(nameNode)
          if exp or includePrivate:
            var sig = kindStr & " " & nm & (if exp: "*" else: "")
            if defs.len >= 2 and defs[^2].kind != nkEmpty:
              sig &= ": " & renderTypeNode(defs[^2])
            # For a const the value IS the interesting part — a caller needs to
            # know `ExitRefused` is 2. Only shown for const: a let/var initial
            # value is mutable state, not part of the contract.
            if n.kind == nkConstSection and defs.len >= 1 and
               defs[^1].kind != nkEmpty:
              sig &= " = " & renderTypeNode(defs[^1])
            symbols.add ApiSymbol(name: nm, kind: kindStr, exported: exp,
              sig: sig, line: nameNode.info.line.int)
          if not exp: privateCount.inc
    elif n.kind == nkExportStmt:
      for c in n:
        let nm = plainName(c)
        if nm.len > 0 and nm notin reExports:
          reExports.add nm
    elif n.kind notin RoutineKinds and hasSons(n):
      for c in n: walk(c)

  walk(root)
  (symbols, reExports, privateCount)

proc surfaceOf*(filePath: string, includePrivate = false): ModuleSurface =
  ## The exported surface of one module.
  ##
  ## `includePrivate` also lists private symbols, marking each with `exported`.
  ## An executable exports nothing, so without it a CLI module reports an empty
  ## surface and a private count — correct, but useless for the file whose whole
  ## content is those private procs.
  result = ModuleSurface(file: filePath, symbols: @[], reExports: @[],
                         privateCount: 0)
  let parsed = parseNimFile(filePath)
  if parsed.ast == nil: return

  # The module's own doc block: leading nkCommentStmt children of the root,
  # before any declaration. A doc attached to a routine belongs to that routine,
  # so only the run at the very top counts.
  if parsed.ast.kind == nkStmtList:
    for c in parsed.ast:
      if c.kind == nkCommentStmt:
        if result.moduleDoc.len > 0: result.moduleDoc &= "\n"
        result.moduleDoc &= c.comment.strip()
      else:
        break
  elif parsed.ast.comment.len > 0:
    result.moduleDoc = parsed.ast.comment.strip()

  for n in collectTypeDefs(parsed.ast):
    let exp = isExported(n)
    if exp or includePrivate:
      result.symbols.add ApiSymbol(name: typeDefName(n), kind: "type",
        sig: renderTypeDefConcise(n), doc: docComment(n), exported: exp,
        line: n.info.line.int)
    if not exp: result.privateCount.inc

  for n in collectRoutines(parsed.ast):
    let exp = isExported(n)
    if exp or includePrivate:
      result.symbols.add ApiSymbol(name: routineName(n), kind: routineKindName(n),
        sig: renderRoutineSignature(n), doc: docComment(n), exported: exp,
        line: n.info.line.int)
    if not exp: result.privateCount.inc

  let sections = collectSections(parsed.ast, includePrivate)
  result.symbols.add sections.symbols
  result.reExports = sections.reExports
  result.privateCount += sections.privateCount
  result.symbols.sort(proc(a, b: ApiSymbol): int = cmp(a.line, b.line))

proc surfaceOfPaths*(paths: seq[string],
                     includePrivate = false): seq[ModuleSurface] =
  ## Surfaces for every .nim file in `paths`; directories are walked.
  var files: seq[string] = @[]
  for p in paths:
    if dirExists(p):
      for f in walkDirRec(p):
        if f.endsWith(".nim") and not f.contains("nimcache"): files.add f
    elif fileExists(p):
      files.add p
  files.sort()
  for f in files: result.add surfaceOf(f, includePrivate)

proc diffSurfaces*(before, after: ModuleSurface): SurfaceDiff =
  ## Compares two exported surfaces. Symbols are matched on name AND kind: a
  ## `proc foo` replaced by a `template foo` is not the same API element to a
  ## caller, so it reports as removed+added rather than unchanged.
  ##
  ## Overloads share a name; when a name has several entries their signatures
  ## are compared as a set, so reordering them is not reported as a change.
  proc key(s: ApiSymbol): string = s.kind & " " & s.name

  proc sigsFor(surface: ModuleSurface, k: string): seq[string] =
    for s in surface.symbols:
      if key(s) == k: result.add s.sig

  var seenKeys: seq[string] = @[]
  for s in before.symbols:
    let k = key(s)
    if k in seenKeys: continue
    seenKeys.add k

    let afterSigs = sigsFor(after, k)
    if afterSigs.len == 0:
      result.removed.add s
      continue
    let beforeSigs = sigsFor(before, k)
    # Compare as sets so overload order does not register as a change.
    for sig in beforeSigs:
      if sig notin afterSigs:
        result.changed.add SurfaceChange(name: s.name, kind: s.kind,
          before: sig, after: afterSigs.join(" | "))
        break

  for s in after.symbols:
    let k = key(s)
    if sigsFor(before, k).len == 0 and not result.added.anyIt(key(it) == k):
      result.added.add s

  for r in before.reExports:
    if r notin after.reExports: result.removedReExports.add r
  for r in after.reExports:
    if r notin before.reExports: result.addedReExports.add r

proc toJson(s: ModuleSurface): JsonNode =
  var syms = newJArray()
  for sym in s.symbols:
    syms.add %*{"name": sym.name, "kind": sym.kind, "sig": sym.sig,
                "doc": sym.doc, "line": sym.line}
  %*{"file": s.file, "moduleDoc": s.moduleDoc, "symbols": syms,
     "reExports": s.reExports, "privateCount": s.privateCount}

proc render(s: ModuleSurface, withDocs = false): string =
  result = s.file & "\n"
  if withDocs and s.moduleDoc.len > 0:
    for line in s.moduleDoc.splitLines():
      result &= "  ## " & line & "\n"
    result &= "\n"
  if s.symbols.len == 0 and s.reExports.len == 0:
    result &= "  (nothing exported)\n"
  for r in s.reExports:
    result &= "  export " & r & "   (re-export)\n"
  for sym in s.symbols:
    # A leading `-` marks a private symbol, which only appears under --all.
    result &= (if sym.exported: "  " else: "  - ") & sym.sig & "\n"
    if withDocs and sym.doc.len > 0:
      # First line only: the summary is what a caller needs to choose a symbol;
      # `extract` gives the full doc when they have chosen one.
      result &= "      " & sym.doc.splitLines()[0] & "\n"
  var exportedShown = 0
  for sym in s.symbols:
    if sym.exported: exportedShown.inc
  let privateShown = s.symbols.len - exportedShown
  result &= "  " & $exportedShown & " exported"
  if privateShown > 0:
    result &= ", " & $privateShown & " private (shown)"
  elif s.privateCount > 0:
    result &= ", " & $s.privateCount & " private (hidden)"
  result &= "\n"

proc renderDiff(before, after: string, d: SurfaceDiff): string =
  result = before & "  ->  " & after & "\n"
  for s in d.removed:
    result &= "  - " & s.sig & "\n"
  for c in d.changed:
    result &= "  ~ " & c.before & "\n      now: " & c.after & "\n"
  for s in d.added:
    result &= "  + " & s.sig & "\n"
  for r in d.removedReExports:
    result &= "  - export " & r & "\n"
  for r in d.addedReExports:
    result &= "  + export " & r & "\n"
  if not d.isBreaking and d.added.len == 0 and d.addedReExports.len == 0:
    result &= "  (no change to the exported surface)\n"
  elif d.isBreaking:
    result &= "  BREAKING: " & $d.removed.len & " removed, " &
              $d.changed.len & " changed\n"
  else:
    result &= "  compatible: " & $d.added.len & " added\n"

proc diffMain*(args: seq[string]): int =
  ## `api-diff BEFORE AFTER` — compares two files, or two directories pairwise
  ## by matching relative paths.
  var p = initOptParser(args)
  var paths: seq[string] = @[]
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
    of cmdArgument: paths.add p.key

  if helpRequested or paths.len != 2:
    echo """
nimtools api-diff: Did the exported surface change?

Usage:
  api-diff [--json] BEFORE AFTER

BEFORE and AFTER are both files, or both directories (compared pairwise by
relative path). Reports added, removed and changed exports.

Exit codes:
  0  compatible (no change, or additions only)
  2  breaking   (an export was removed, changed, or a re-export withdrawn)

Options:
  -j, --json   machine-readable output
"""
    return ExitOk

  for path in paths:
    if not fileExists(path) and not dirExists(path):
      stderr.writeLine "Error: No such file or directory: ", path
      return ExitError

  # Pair modules up: for directories, match on the path relative to each root.
  var pairs: seq[tuple[label: string, before, after: ModuleSurface]] = @[]
  if dirExists(paths[0]) and dirExists(paths[1]):
    var rels: seq[string] = @[]
    for f in surfaceOfPaths(@[paths[0]]):
      rels.add relativePath(f.file, paths[0])
    for f in surfaceOfPaths(@[paths[1]]):
      let r = relativePath(f.file, paths[1])
      if r notin rels: rels.add r
    rels.sort()
    for r in rels:
      let bPath = paths[0] / r
      let aPath = paths[1] / r
      let b = if fileExists(bPath): surfaceOf(bPath) else: ModuleSurface(file: bPath)
      let a = if fileExists(aPath): surfaceOf(aPath) else: ModuleSurface(file: aPath)
      pairs.add (r, b, a)
  else:
    pairs.add (paths[1], surfaceOf(paths[0]), surfaceOf(paths[1]))

  var breaking = false
  if asJson:
    var arr = newJArray()
    for (label, b, a) in pairs:
      let d = diffSurfaces(b, a)
      if d.isBreaking: breaking = true
      if d.added.len == 0 and d.removed.len == 0 and d.changed.len == 0 and
         d.addedReExports.len == 0 and d.removedReExports.len == 0: continue
      var changed = newJArray()
      for c in d.changed:
        changed.add %*{"name": c.name, "kind": c.kind,
                       "before": c.before, "after": c.after}
      arr.add %*{
        "module": label, "breaking": d.isBreaking,
        "added": d.added.mapIt(it.sig),
        "removed": d.removed.mapIt(it.sig),
        "changed": changed,
        "addedReExports": d.addedReExports,
        "removedReExports": d.removedReExports}
    echo arr.pretty()
  else:
    var printed = 0
    for (label, b, a) in pairs:
      let d = diffSurfaces(b, a)
      if d.isBreaking: breaking = true
      if d.added.len == 0 and d.removed.len == 0 and d.changed.len == 0 and
         d.addedReExports.len == 0 and d.removedReExports.len == 0: continue
      if printed > 0: echo ""
      stdout.write renderDiff(b.file, label, d)
      printed.inc
    if printed == 0:
      echo "No change to the exported surface."
  if breaking: ExitRefused else: ExitOk

proc main*(args: seq[string]): int =
  ## CLI entry. Returns an exit code rather than quitting, so the umbrella
  ## dispatcher stays in control of the process.
  var p = initOptParser(args)
  var paths: seq[string] = @[]
  var asJson, helpRequested, withDocs, includePrivate = false

  while true:
    p.next()
    case p.kind
    of cmdEnd: break
    of cmdShortOption, cmdLongOption:
      case p.key.toLowerAscii
      of "h", "help": helpRequested = true
      of "j", "json": asJson = true
      of "d", "docs": withDocs = true
      of "a", "all": includePrivate = true
      else:
        stderr.writeLine "Unknown option: --", p.key
        return ExitError
    of cmdArgument: paths.add p.key

  if helpRequested or paths.len == 0:
    echo """
nimtools api-surface: What a module exports, without reading it.

Usage:
  api-surface [--all] [--docs] [--json] FILE|DIR...

Lists exported routines, types, consts, lets, vars and re-exports, grouped by
module. Private symbols are never listed — only counted. Exported types are
rendered as declared, so their private fields do appear in the type line.

Options:
  -a, --all    include private symbols, marked `-`. Needed for executables,
               which export nothing and otherwise show an empty surface.
  -d, --docs   include the module's header doc and each symbol's summary line
  -j, --json   machine-readable output
"""
    return ExitOk

  for path in paths:
    if not fileExists(path) and not dirExists(path):
      stderr.writeLine "Error: No such file or directory: ", path
      return ExitError

  let surfaces = surfaceOfPaths(paths, includePrivate)
  if asJson:
    var arr = newJArray()
    for s in surfaces: arr.add s.toJson()
    echo arr.pretty()
  else:
    for i, s in surfaces:
      if i > 0: echo ""
      stdout.write render(s, withDocs)
  return ExitOk

when isMainModule:
  quit(main(commandLineParams()))
