import compiler/[ast, renderer]
import std/[os, strutils, sequtils, parseopt]
import ../shared/[compiler_env, ast_utils]

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
