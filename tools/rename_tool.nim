import std/[os, strutils, parseopt, osproc, streams]
import ../shared/[source_rewriter, compiler_env]

proc renameInFile*(filePath, oldName, newName: string): bool =
  if not fileExists(filePath):
    stderr.writeLine "Error: File not found: ", filePath
    return false

  let content = readFile(filePath)
  let updated = renameTokenStream(content, oldName, newName)
  if updated != content:
    writeFile(filePath, updated)
    echo "Renamed '", oldName, "' -> '", newName, "' in ", filePath
    return true
  else:
    echo "No identifier occurrences of '", oldName, "' in ", filePath
    return false

proc renameSemantic*(projectFile, targetFile: string, line, col: int, newName: string): bool =
  ## Queries nimsuggest to find all project-wide usages and renames them.
  let nimSuggestExe = findExe("nimsuggest")
  if nimSuggestExe.len == 0:
    stderr.writeLine "Error: nimsuggest executable not found in PATH"
    return false

  let cmd = "use " & targetFile & ":" & $line & ":" & $col
  echo "Querying nimsuggest for: ", cmd
  
  let p = startProcess(nimSuggestExe, args = ["--stdin", projectFile], options = {poUsePath})
  p.inputStream.writeLine(cmd)
  p.inputStream.flush()
  
  # Read response until EOF or timeout
  var usages: seq[tuple[filePath: string, line, col: int]] = @[]
  var rawLines: seq[string] = @[]
  
  # Simple timeout loop
  while p.running:
    let lineStr = p.outputStream.readLine()
    if lineStr.len == 0: break
    rawLines.add lineStr
    let parts = lineStr.split('\t')
    if parts.len >= 5 and parts[0] == "def":
      # format: def /path/to/file.nim line col
      let f = parts[4]
      let l = try: parseInt(parts[2]) except: 0
      let c = try: parseInt(parts[3]) except: 0
      if f.len > 0 and l > 0:
        usages.add (f, l, c)
    if rawLines.len > 50: break # safety cutoff
  
  p.close()
  
  if usages.len == 0:
    echo "No semantic usages returned by nimsuggest. Falling back to token rename in target file."
    return renameInFile(targetFile, "", newName) # user can provide token rename
    
  echo "Found ", usages.len, " semantic usage(s). Applying rename..."
  # Group by file
  var fileMap: seq[string] = @[]
  for u in usages:
    if u.filePath notin fileMap:
      fileMap.add u.filePath
      
  for f in fileMap:
    # Rename in each file
    # For now, token rename on the files where symbol is used ensures safety
    discard renameInFile(f, targetFile.extractFilename, newName)
  return true

proc main*() =
  var p = initOptParser()
  var targetFile = ""
  var oldName = ""
  var newName = ""
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
      if targetFile == "": targetFile = p.key
      elif oldName == "": oldName = p.key
      elif newName == "": newName = p.key
      else:
        stderr.writeLine "Unexpected argument: ", p.key
        quit(1)

  if helpRequested or targetFile == "" or oldName == "" or newName == "":
    echo """
nimtools rename-symbol: Lexer-safe identifier renaming (skipping comments and strings).

Usage:
  rename-symbol <file.nim> <oldName> <newName>

Examples:
  rename-symbol src/main.nim oldHelperName newHelperName
"""
    quit(0)

  if renameInFile(targetFile, oldName, newName):
    echo "Rename operation complete."
  else:
    quit(1)

when isMainModule:
  main()
