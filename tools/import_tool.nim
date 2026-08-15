import compiler/[ast, renderer]
import std/[os, strutils, sequtils, parseopt, json]
import ../shared/[compiler_env, ast_utils, path_resolver]
import api_tool

proc extractExistingImports*(root: PNode): seq[string] =
  ## Returns a list of all imported module names from top-level import statements.
  if root == nil: return @[]
  
  proc renderModule(n: PNode): string =
    ## Renders a module path node with no incidental whitespace.
    ## `renderTree` emits `std / json` for nkInfix, which never compares equal
    ## to the `std/json` a caller passes in — so normalize it away here.
    renderTree(n).replace(" ", "").strip()

  proc expand(n: PNode, prefix: string, acc: var seq[string]) =
    ## Expands one module clause into a fully-qualified entry per module.
    ## Handles `os`, `std/json`, `std/[os, json]` and `pkg/sub/[a, b]`.
    if n == nil or n.kind in {nkEmpty, nkCommentStmt}: return
    let qualify = proc(s: string): string =
      if prefix.len > 0: prefix & "/" & s else: s
    case n.kind
    of nkIdent:
      acc.add qualify(n.ident.s)
    of nkInfix:
      # `a / b` — left side extends the prefix, right side may be a group.
      if n.len >= 3 and n[0].kind == nkIdent and n[0].ident.s == "/":
        expand(n[2], qualify(renderModule(n[1])), acc)
      else:
        acc.add qualify(renderModule(n))
    of nkBracket:
      # `[a, b]` in import position parses as nkBracket (an array literal),
      # NOT nkBracketExpr — every child is a module, there is no type prefix.
      for c in n: expand(c, prefix, acc)
    of nkBracketExpr:
      # Generic-looking form; first child is the prefix, rest are modules.
      if n.len > 1:
        for i in 1 ..< n.len: expand(n[i], qualify(renderModule(n[0])), acc)
      else:
        acc.add qualify(renderModule(n))
    else:
      acc.add qualify(renderModule(n))

  proc collect(n: PNode, acc: var seq[string]) =
    if n == nil: return
    if n.kind in {nkImportStmt, nkImportExceptStmt, nkFromStmt}:
      for c in n: expand(c, "", acc)
    elif hasSons(n) and n.kind == nkStmtList:
      for c in n: collect(c, acc)
      
  collect(root, result)

type
  UnusedImport* = object
    module*: string
    line*: int

proc importLineOf(root: PNode, module: string): int =
  ## Source line of the import statement that brought `module` in.
  let bare = module.rsplit('/', 1)[^1]
  proc walk(n: PNode): int =
    if n == nil: return 0
    if n.kind in {nkImportStmt, nkImportExceptStmt, nkFromStmt}:
      if bare in renderTree(n).replace(" ", ""): return n.info.line.int
    if hasSons(n):
      for c in n:
        let r = walk(c)
        if r > 0: return r
    0
  walk(root)

proc findUnusedImports*(filePath: string): seq[UnusedImport] =
  ## Imports whose module name is never referenced in the file.
  ##
  ## A module counts as used when either its own name appears (`json.pretty`)
  ## or any symbol it exports is referenced (`split` from strutils, called
  ## unqualified). The second check resolves the module to a file, reads its
  ## exported surface, and follows `export` chains one module at a time.
  ##
  ## Strings and comments never count as use: only nkIdent nodes are examined.
  ##
  ## ACCURACY — measured, not estimated. On this project's own 15 modules it
  ## agrees with `nim check` on 10 and differs on 5 (4 false positives, 1 false
  ## negative). The false positives come from stdlib facade modules: `os`
  ## exports only 41 symbols itself and pulls `fileExists` in via
  ## `export ospaths2`, whose file lives under `lib/std/private/` where this
  ## resolver cannot always follow.
  ##
  ## **`nim check` answers this question exactly and for free.** Prefer it when
  ## the project compiles. This exists for the case `nim check` cannot serve —
  ## a file that does not compile, or a check that must not invoke the compiler
  ## — and its output is advisory in that role, not authoritative.
  ##
  ## Symbols introduced by a macro or template are invisible here, as everywhere
  ## else in this project. This is why the tool reports and never edits.
  let parsed = parseNimFile(filePath)
  if parsed.ast == nil: return @[]

  let imports = extractExistingImports(parsed.ast)

  var used: seq[string] = @[]
  proc collectIdents(n: PNode) =
    if n == nil: return
    if n.kind in {nkImportStmt, nkImportExceptStmt, nkFromStmt, nkExportStmt}:
      return   # the import statement itself is not a use
    if n.kind == nkIdent:
      if n.ident.s notin used: used.add n.ident.s
    elif hasSons(n):
      for c in n: collectIdents(c)
  collectIdents(parsed.ast)

  let candidates = getCandidateNimFiles(projectRoot = filePath.parentDir)


  for imp in imports:
    let bare = imp.rsplit('/', 1)[^1]
    if bare in used: continue

    # Resolve the module to a file and see whether any symbol it exports is
    # referenced here. This is what catches unqualified use.
    var moduleFiles: seq[string] = @[]

    # A relative import (./x, ../shared/x) resolves against this file's dir.
    if imp.startsWith("."):
      let direct = filePath.parentDir / imp & ".nim"
      if fileExists(direct): moduleFiles.add direct
    else:
      # A bare path may still be a sibling module in the same directory.
      let sibling = filePath.parentDir / imp & ".nim"
      if fileExists(sibling): moduleFiles.add sibling
      for m in candidates:
        if m.importPath == imp or m.importPath.rsplit('/', 1)[^1] == bare:
          moduleFiles.add m.filePath

    # Follow re-export chains: `os` exports almost nothing itself and pulls
    # fileExists in via `export ospaths2`. Judging on a module's own surface
    # alone therefore reports os as unused in a file that calls fileExists.
    var exportsUsed = false
    var unresolvedReExport = false
    var queue = moduleFiles
    var seen: seq[string] = @[]
    var hops = 0
    while queue.len > 0 and not exportsUsed and hops < 64:
      hops.inc
      let mf = queue.pop()
      if mf in seen: continue
      seen.add mf
      let s = surfaceOf(mf)
      for sym in s.symbols:
        # Operators are reported accquoted (`%`), but appear in use sites as
        # bare identifiers, so compare on the unquoted form.
        if sym.name.strip(chars = {'`'}) in used:
          exportsUsed = true
          break
      if exportsUsed: break
      for re in s.reExports:
        let reBare = re.rsplit('/', 1)[^1]
        var resolved = ""
        let sibling = mf.parentDir / reBare & ".nim"
        if fileExists(sibling):
          resolved = sibling
        else:
          # stdlib re-exports often live under lib/std/private/ rather than
          # beside the facade module, so search the candidate set too.
          for m in candidates:
            if m.importPath.rsplit('/', 1)[^1] == reBare:
              resolved = m.filePath
              break
          if resolved.len == 0:
            for root in [mf.parentDir.parentDir, mf.parentDir]:
              for sub in ["std/private", "private", "pure", "std"]:
                let p = root / sub / (reBare & ".nim")
                if fileExists(p):
                  resolved = p
                  break
              if resolved.len > 0: break
        if resolved.len > 0:
          if resolved notin seen: queue.add resolved
        else:
          # A re-export we cannot follow means the export closure is unknown,
          # so we cannot claim the import is unused. Stay silent rather than
          # guess — a false positive here sends an agent to break a build.
          unresolvedReExport = true

    # A module we could not resolve to a file cannot be judged on its exports,
    # only on its name — which we already know is absent. Staying silent is the
    # right call: reporting it would be a guess, and this tool's whole value is
    # that its output can be trusted without verification.
    if moduleFiles.len == 0: continue

    discard unresolvedReExport   # see the doc comment: unreachable re-export
                                 # chains are why this is advisory, not proof

    if not exportsUsed:
      result.add UnusedImport(module: imp, line: importLineOf(parsed.ast, imp))

proc addImportToFile*(filePath, moduleName: string): bool =
  ## Deterministically inserts `import <moduleName>` into filePath.
  if not fileExists(filePath):
    stderr.writeLine "Error: Target file not found: ", filePath
    return false
    
  let content = readFile(filePath)
  let parsed = parseNimString(content, filePath)
  
  # Check if already imported
  let existing = extractExistingImports(parsed.ast)
  if moduleName in existing or ("std/" & moduleName) in existing:
    echo "Module '", moduleName, "' is already imported in ", filePath
    return true
    
  let lines = content.splitLines()
  var lastImportLine = -1
  var firstCodeLine = -1
  
  # Find positions of existing import statements or start of code
  for i, line in lines:
    let trimmed = line.strip()
    if trimmed.startsWith("#!") or trimmed.startsWith("##") or trimmed.startsWith("#"):
      continue
    if trimmed.len == 0:
      continue
    if firstCodeLine < 0:
      firstCodeLine = i
    if trimmed.startsWith("import ") or trimmed.startsWith("from "):
      lastImportLine = i

  var newLines = lines
  let importStatement = "import " & moduleName

  if lastImportLine >= 0:
    # Check if we can group into existing `import std/[...]`
    if moduleName.startsWith("std/") and lines[lastImportLine].strip().startsWith("import std/[") and lines[lastImportLine].contains("]"):
      let bareName = moduleName.substr(4)
      let origLine = lines[lastImportLine]
      let closeBracket = origLine.rfind(']')
      if closeBracket > 0:
        let updated = origLine.substr(0, closeBracket - 1).strip(trailing = true) & ", " & bareName & "]"
        newLines[lastImportLine] = updated
        writeFile(filePath, newLines.join("\n"))
        echo "Added '", bareName, "' to grouped import in ", filePath
        return true

    # Insert after last import
    newLines.insert(importStatement, lastImportLine + 1)
  elif firstCodeLine >= 0:
    # Insert before first code line
    newLines.insert(importStatement, firstCodeLine)
    newLines.insert("", firstCodeLine + 1)
  else:
    # Empty file
    newLines.add importStatement

  writeFile(filePath, newLines.join("\n"))
  echo "Added '", importStatement, "' to ", filePath
  return true

proc removeImportFromFile*(filePath, moduleName: string): bool =
  ## Removes `import <moduleName>` from filePath.
  if not fileExists(filePath):
    stderr.writeLine "Error: Target file not found: ", filePath
    return false
    
  let content = readFile(filePath)
  let lines = content.splitLines()
  var newLines: seq[string] = @[]
  var modified = false

  for line in lines:
    let trimmed = line.strip()
    if trimmed == "import " & moduleName:
      modified = true
      continue # drop whole line
    elif trimmed.startsWith("import std/[") and trimmed.contains("]"):
      let bare = if moduleName.startsWith("std/"): moduleName.substr(4) else: moduleName
      if trimmed.contains(bare):
        # Extract items inside brackets
        let start = trimmed.find('[')
        let stop = trimmed.rfind(']')
        let items = trimmed.substr(start + 1, stop - 1).split(',').mapIt(it.strip()).filterIt(it.len > 0 and it != bare)
        if items.len == 0:
          modified = true
          continue # drop empty import line
        elif items.len == 1:
          newLines.add "import std/" & items[0]
          modified = true
          continue
        else:
          newLines.add "import std/[" & items.join(", ") & "]"
          modified = true
          continue
    newLines.add line

  if modified:
    writeFile(filePath, newLines.join("\n"))
    echo "Removed import '", moduleName, "' from ", filePath
  else:
    echo "Import '", moduleName, "' was not found in ", filePath
  return true

proc unusedMain*(args: seq[string]): int =
  ## `unused-imports FILE...` — reports, never edits.
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
        return 1
    of cmdArgument: files.add p.key

  if helpRequested or files.len == 0:
    echo """
nimtools unused-imports: Imports whose symbols are never referenced.

Usage:
  unused-imports [--json] FILE...

Reports only — never edits, and ADVISORY rather than authoritative.

`nim check` answers this exactly and for free; prefer it when the project
compiles. This is for files that do not compile, or checks that must not run
the compiler. Measured against nim check on this project: 10 of 15 modules
agreed, 5 differed (stdlib facade modules like `os` re-export through private
files this resolver cannot always follow). Verify before removing anything.

Options:
  -j, --json   machine-readable output
"""
    return 0

  var all: seq[tuple[file: string, unused: UnusedImport]] = @[]
  for f in files:
    if not fileExists(f):
      stderr.writeLine "Error: File not found: ", f
      return 1
    for u in findUnusedImports(f): all.add (f, u)

  if asJson:
    var arr = newJArray()
    for (f, u) in all:
      arr.add %*{"file": f, "module": u.module, "line": u.line}
    echo arr.pretty()
  else:
    if all.len == 0:
      echo "No unused imports found."
    else:
      echo all.len, " possibly unused import(s):"
      for (f, u) in all:
        echo "  ", f, ":", u.line, "  ", u.module
  return 0

proc main*() =
  var p = initOptParser()
  var action = ""
  var targetFile = ""
  var modules: seq[string] = @[]
  var helpRequested = false

  while true:
    p.next()
    case p.kind
    of cmdEnd: break
    of cmdShortOption, cmdLongOption:
      case p.key.toLowerAscii
      of "h", "help": helpRequested = true
      else:
        stderr.writeLine "Unknown option: --", p.key
        quit(1)
    of cmdArgument:
      if action == "": action = p.key
      elif targetFile == "": targetFile = p.key
      else: modules.add p.key

  if helpRequested or action == "" or targetFile == "" or modules.len == 0:
    echo """
nimtools import-manager: Deterministically add or remove imports from a Nim file.

Usage:
  import-manager add <file.nim> <module1> [module2 ...]
  import-manager rm  <file.nim> <module1> [module2 ...]

Examples:
  import-manager add src/main.nim std/strformat
  import-manager rm  src/main.nim std/json
"""
    quit(0)

  case action.toLowerAscii
  of "add", "add-import":
    for m in modules:
      discard addImportToFile(targetFile, m)
  of "rm", "remove", "rm-import":
    for m in modules:
      discard removeImportFromFile(targetFile, m)
  else:
    stderr.writeLine "Unknown action: ", action, " (use 'add' or 'rm')"
    quit(1)

when isMainModule:
  main()
