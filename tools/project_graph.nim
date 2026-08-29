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

proc projectRootDir*(file: string): string =
  ## Topmost ancestor directory still holding .nim files. `importersOf` searches
  ## only a module's own directory, which is why it cannot see `nimtools.nim`
  ## importing `tools/references_tool` — a root picker inheriting that blind spot
  ## would under-report exactly what the semantic path exists to fix.
  result = file.parentDir
  while true:
    let parent = result.parentDir
    if parent.len == 0 or parent == result: break
    var hasNim = false
    for f in walkDir(parent):
      if f.kind == pcFile and f.path.endsWith(".nim"): hasNim = true; break
    if not hasNim: break
    result = parent

proc pickProjectRoot*(moduleFile: string): string =
  ## The widest root to open nimsuggest with: a module that reaches `moduleFile`
  ## through imports and that nothing else imports. nimsuggest sees only modules
  ## reachable from its root, so opening it on `moduleFile` itself would cover
  ## that file's imports and miss every one of its *importers*. Falls back to the
  ## file itself when nothing imports it.
  let target = moduleFile.bareName
  let files = projectFiles(projectRootDir(moduleFile))

  # One parse pass: bare name -> the imports it declares.
  var imports = initTable[string, seq[string]]()
  var byName = initTable[string, string]()
  var imported: HashSet[string]
  for f in files:
    let parsed = parseNimFile(f)
    if parsed.ast == nil: continue
    var names: seq[string] = @[]
    for imp in extractExistingImports(parsed.ast): names.add imp.bareName
    imports[f.bareName] = names
    byName[f.bareName] = f
    for n in names: imported.incl n

  proc reaches(start: string): bool =
    ## Does `start` pull in `target`, directly or transitively?
    var seen = [start].toHashSet
    var queue = @[start]
    var i = 0
    while i < queue.len:
      let cur = queue[i]; i.inc
      for imp in imports.getOrDefault(cur):
        if imp == target: return true
        if imp notin seen and imp in imports:
          seen.incl imp; queue.add imp
    false

  var tops: seq[string] = @[]
  for name in imports.keys:
    if name != target and name notin imported: tops.add name
  tops.sort()
  for name in tops:
    if reaches(name): return byName[name]
  moduleFile

proc symbolIsExported*(filePath, symbol: string): bool =
  ## True when `filePath` declares an exported routine or type named `symbol`.
  let parsed = parseNimFile(filePath)
  if parsed.ast == nil: return false
  for n in collectRoutines(parsed.ast):
    if routineName(n) == symbol and isExported(n): return true
  for n in collectTypeDefs(parsed.ast):
    if typeDefName(n) == symbol and isExported(n): return true
  false
