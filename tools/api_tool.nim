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
import std/[os, strutils, json, parseopt, algorithm]
import ../shared/[compiler_env, ast_utils, exit_codes]

type
  ApiSymbol* = object
    name*: string
    kind*: string     ## proc/func/template/macro/iterator/converter/method/type/const/let/var
    sig*: string      ## one-line signature or rendered type
    line*: int

  ModuleSurface* = object
    file*: string
    symbols*: seq[ApiSymbol]
    reExports*: seq[string]  ## modules re-exported via `export`
    privateCount*: int       ## symbols deliberately not shown

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

proc collectSections(root: PNode): tuple[symbols: seq[ApiSymbol],
                                         reExports: seq[string],
                                         privateCount: int] =
  ## const/let/var sections plus `export` statements. Each nkIdentDefs/
  ## nkConstDef may declare several names, and each name carries its own export
  ## marker, so they are checked individually rather than per-section.
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
          if isExportedName(nameNode):
            var sig = kindStr & " " & nm & "*"
            if defs.len >= 2 and defs[^2].kind != nkEmpty:
              sig &= ": " & renderTypeNode(defs[^2])
            # For a const the value IS the interesting part — a caller needs to
            # know `ExitRefused` is 2. Only shown for const: a let/var initial
            # value is mutable state, not part of the contract.
            if n.kind == nkConstSection and defs.len >= 1 and
               defs[^1].kind != nkEmpty:
              sig &= " = " & renderTypeNode(defs[^1])
            symbols.add ApiSymbol(name: nm, kind: kindStr,
              sig: sig, line: nameNode.info.line.int)
          else:
            privateCount.inc
    elif n.kind == nkExportStmt:
      for c in n:
        let nm = plainName(c)
        if nm.len > 0 and nm notin reExports:
          reExports.add nm
    elif hasSons(n):
      for c in n: walk(c)

  walk(root)
  (symbols, reExports, privateCount)

proc surfaceOf*(filePath: string): ModuleSurface =
  ## The exported surface of one module.
  result = ModuleSurface(file: filePath, symbols: @[], reExports: @[],
                         privateCount: 0)
  let parsed = parseNimFile(filePath)
  if parsed.ast == nil: return

  for n in collectTypeDefs(parsed.ast):
    if isExported(n):
      result.symbols.add ApiSymbol(name: typeDefName(n), kind: "type",
        sig: renderTypeDefConcise(n), line: n.info.line.int)
    else:
      result.privateCount.inc

  for n in collectRoutines(parsed.ast):
    if isExported(n):
      result.symbols.add ApiSymbol(name: routineName(n), kind: routineKindName(n),
        sig: renderRoutineSignature(n), line: n.info.line.int)
    else:
      result.privateCount.inc

  let sections = collectSections(parsed.ast)
  result.symbols.add sections.symbols
  result.reExports = sections.reExports
  result.privateCount += sections.privateCount
  result.symbols.sort(proc(a, b: ApiSymbol): int = cmp(a.line, b.line))

proc surfaceOfPaths*(paths: seq[string]): seq[ModuleSurface] =
  ## Surfaces for every .nim file in `paths`; directories are walked.
  var files: seq[string] = @[]
  for p in paths:
    if dirExists(p):
      for f in walkDirRec(p):
        if f.endsWith(".nim") and not f.contains("nimcache"): files.add f
    elif fileExists(p):
      files.add p
  files.sort()
  for f in files: result.add surfaceOf(f)

proc toJson(s: ModuleSurface): JsonNode =
  var syms = newJArray()
  for sym in s.symbols:
    syms.add %*{"name": sym.name, "kind": sym.kind, "sig": sym.sig, "line": sym.line}
  %*{"file": s.file, "symbols": syms, "reExports": s.reExports,
     "privateCount": s.privateCount}

proc render(s: ModuleSurface): string =
  result = s.file & "\n"
  if s.symbols.len == 0 and s.reExports.len == 0:
    result &= "  (nothing exported)\n"
  for r in s.reExports:
    result &= "  export " & r & "   (re-export)\n"
  for sym in s.symbols:
    result &= "  " & sym.sig & "\n"
  result &= "  " & $s.symbols.len & " exported"
  if s.privateCount > 0:
    result &= ", " & $s.privateCount & " private (hidden)"
  result &= "\n"

proc main*(args: seq[string]): int =
  ## CLI entry. Returns an exit code rather than quitting, so the umbrella
  ## dispatcher stays in control of the process.
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

  if helpRequested or paths.len == 0:
    echo """
nimtools api-surface: What a module exports, without reading it.

Usage:
  api-surface [--json] FILE|DIR...

Lists exported routines, types, consts, lets, vars and re-exports, grouped by
module. Private symbols are never listed — only counted. Exported types are
rendered as declared, so their private fields do appear in the type line.

Options:
  -j, --json   machine-readable output
"""
    return ExitOk

  for path in paths:
    if not fileExists(path) and not dirExists(path):
      stderr.writeLine "Error: No such file or directory: ", path
      return ExitError

  let surfaces = surfaceOfPaths(paths)
  if asJson:
    var arr = newJArray()
    for s in surfaces: arr.add s.toJson()
    echo arr.pretty()
  else:
    for i, s in surfaces:
      if i > 0: echo ""
      stdout.write render(s)
  return ExitOk

when isMainModule:
  quit(main(commandLineParams()))
