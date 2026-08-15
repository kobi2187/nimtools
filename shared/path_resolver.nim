import std/[os, strutils]

type

  ModuleScope* = enum
    scopeStdlib
    scopeNimble
    scopeProject

  ModuleInfo* = object
    filePath*: string
    importPath*: string
    scope*: ModuleScope
    packageName*: string

proc findNimLibDir*(): string =
  ## Finds the Nim standard library directory from environment, nim executable, or standard paths.
  let nimExe = findExe("nim")
  if nimExe.len > 0:
    let binDir = nimExe.expandFilename.parentDir
    let candidate = binDir.parentDir / "lib"
    if dirExists(candidate / "pure"):
      return candidate
  # Common fallbacks
  for candidate in ["/usr/lib/nim", "/usr/local/lib/nim", getHomeDir() / ".choosenim/toolchains/nim-#head/lib"]:
    if dirExists(candidate / "pure"):
      return candidate
  return ""

proc findNimblePkgDirs*(): seq[string] =
  ## Returns existing Nimble package directories (~/.nimble/pkgs2, ~/.nimble/pkgs).
  let home = getHomeDir()
  for dir in [home / ".nimble/pkgs2", home / ".nimble/pkgs"]:
    if dirExists(dir):
      result.add dir

proc resolveStdlibImportPath*(libDir, fullPath: string): string =
  ## Normalizes a standard library file path to idiomatic import syntax: `std/<module>`.
  let rel = relativePath(fullPath, libDir)
  let cleanRel = rel.changeFileExt("")
  
  if cleanRel.startsWith("pure" / "collections" / ""):
    return "std" / cleanRel.substr(("pure" / "collections" / "").len)
  elif cleanRel.startsWith("pure" / ""):
    return "std" / cleanRel.substr(("pure" / "").len)
  elif cleanRel.startsWith("std" / ""):
    return cleanRel
  elif cleanRel.startsWith("core" / ""):
    return "std" / cleanRel.substr(("core" / "").len)
  else:
    return cleanRel

proc resolveNimbleImportPath*(pkgBaseDir, fullPath: string): tuple[pkgName, importPath: string] =
  ## Normalizes a Nimble package file path into package name and import path.
  let rel = relativePath(fullPath, pkgBaseDir)
  let parts = rel.split(DirSep)
  if parts.len == 0: return ("", "")
  
  # Package folder is typically `name-version-hash`
  let pkgDirName = parts[0]
  let dashIdx = pkgDirName.find('-')
  let pkgName = if dashIdx > 0: pkgDirName.substr(0, dashIdx - 1) else: pkgDirName
  
  # Remaining path within package
  if parts.len > 1:
    let innerRel = parts[1..^1].join("/").changeFileExt("")
    if innerRel == pkgName or innerRel == "src/" & pkgName or innerRel == pkgName & "/" & pkgName:
      return (pkgName, pkgName)
    elif innerRel.startsWith("src/"):
      return (pkgName, innerRel.substr(4))
    else:
      return (pkgName, innerRel)
  else:
    return (pkgName, pkgName)

proc resolveProjectImportPath*(targetFile: string; fromFile: string = ""): string =
  ## Converts a local project file path into a relative import.
  if fromFile.len == 0:
    return targetFile.changeFileExt("")
  let rel = relativePath(targetFile, fromFile.parentDir).changeFileExt("")
  if not rel.startsWith("."):
    return "./" & rel
  return rel

proc getCandidateNimFiles*(scopes: set[ModuleScope] = {scopeStdlib, scopeNimble, scopeProject},
                           projectRoot: string = getCurrentDir()): seq[ModuleInfo] =
  ## Scans and returns all available Nim files categorized by scope with normalized import paths.
  # 1. Stdlib
  if scopeStdlib in scopes:
    let libDir = findNimLibDir()
    if libDir.len > 0:
      for file in walkDirRec(libDir):
        if file.endsWith(".nim") and not file.contains("nimcache") and not file.contains("tests"):
          let imp = resolveStdlibImportPath(libDir, file)
          result.add ModuleInfo(filePath: file, importPath: imp, scope: scopeStdlib, packageName: "stdlib")

  # 2. Nimble packages
  if scopeNimble in scopes:
    for pkgDir in findNimblePkgDirs():
      for file in walkDirRec(pkgDir):
        if file.endsWith(".nim") and not file.contains("tests") and not file.contains("nimcache"):
          let (pkgName, imp) = resolveNimbleImportPath(pkgDir, file)
          result.add ModuleInfo(filePath: file, importPath: imp, scope: scopeNimble, packageName: pkgName)

  # 3. Project
  if scopeProject in scopes and dirExists(projectRoot):
    for file in walkDirRec(projectRoot):
      if file.endsWith(".nim") and not file.contains("nimcache") and not file.contains(".git"):
        let imp = resolveProjectImportPath(file)
        result.add ModuleInfo(filePath: file, importPath: imp, scope: scopeProject, packageName: "local")
