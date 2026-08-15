## project graph: which local module imports which. The shared role under
## `references --project` and `rename-symbol --project` — and any future
## `delete-symbol --project` guard. It is read-only and advisory: matching is by
## bare module name, so it does not resolve a name to one of two same-named
## modules, and it makes no claim about re-export chains beyond the local tree.

import compiler/[ast]
import std/[os, strutils, tables, sets, algorithm]
import ../shared/[compiler_env, ast_utils]
import import_tool

proc bareName*(path: string): string =
  ## Last path segment: `std/strutils` -> `strutils`, `model.nim` -> `model`.
  path.rsplit({'/', '\\'}, 1)[^1].replace(".nim", "")

proc projectFiles*(root: string): seq[string] =
  ## Every .nim file under `root`, excluding nimcache.
  for f in walkDirRec(root):
    if f.endsWith(".nim") and "nimcache" notin f:
      result.add f
  result.sort()

proc importersOf*(moduleFile: string): seq[string] =
  ## .nim files under moduleFile's directory that import it, directly or
  ## transitively, matched by bare module name. moduleFile itself is excluded.
  let root = moduleFile.parentDir
  let target = moduleFile.bareName
  let files = projectFiles(root)

  var seen: HashSet[string]
  seen.incl moduleFile
  var queue: seq[string] = @[]

  # Direct importers first.
  for f in files:
    if f in seen: continue
    let parsed = parseNimFile(f)
    if parsed.ast == nil: continue
    for imp in extractExistingImports(parsed.ast):
      if imp.bareName == target:
        queue.add f; seen.incl f
        break

  # Then transitively: a file importing an already-seen file also sees `target`.
  var i = 0
  while i < queue.len:
    let seenBare = queue[i].bareName
    i.inc
    for f in files:
      if f in seen: continue
      let parsed = parseNimFile(f)
      if parsed.ast == nil: continue
      for imp in extractExistingImports(parsed.ast):
        if imp.bareName == seenBare:
          queue.add f; seen.incl f
          break
  result = queue

proc symbolIsExported*(filePath, symbol: string): bool =
  ## True when `filePath` declares an exported routine or type named `symbol`.
  let parsed = parseNimFile(filePath)
  if parsed.ast == nil: return false
  for n in collectRoutines(parsed.ast):
    if routineName(n) == symbol and isExported(n): return true
  for n in collectTypeDefs(parsed.ast):
    if typeDefName(n) == symbol and isExported(n): return true
  false
