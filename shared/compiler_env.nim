import compiler/[ast, parser, idents, options, lineinfos]
import std/os

type
  ParseResult* = object
    ast*: PNode
    errors*: seq[string]
    cache*: IdentCache
    config*: ConfigRef

proc newSafeCompilerConfig*(): (IdentCache, ConfigRef, ref seq[string]) =
  let cache = newIdentCache()
  let config = newConfigRef()
  let errors = new(seq[string])
  errors[] = @[]

  config.ideCmd = ideSug
  config.errorMax = 1000
  config.writelnHook = proc(output: string) {.closure, gcsafe.} = discard

  config.structuredErrorHook = proc(conf: ConfigRef; info: TLineInfo; msg: string; severity: Severity) {.closure, gcsafe.} =
    {.cast(gcsafe).}:
      if severity == Severity.Error:
        errors[].add("Line " & $info.line & ", col " & $info.col & ": " & msg)

  return (cache, config, errors)

proc parseNimString*(code: string, filename: string = "snippet.nim"): ParseResult =
  let (cache, config, errors) = newSafeCompilerConfig()
  let root = try:
    parseString(code, cache, config, filename)
  except CatchableError as e:
    errors[].add("Parse exception: " & e.msg)
    nil
  return ParseResult(ast: root, errors: errors[], cache: cache, config: config)

proc parseNimFile*(filePath: string): ParseResult =
  if not fileExists(filePath):
    return ParseResult(ast: nil, errors: @["File does not exist: " & filePath], cache: nil, config: nil)
  let content = try:
    readFile(filePath)
  except CatchableError as e:
    return ParseResult(ast: nil, errors: @["Could not read file: " & e.msg], cache: nil, config: nil)
  return parseNimString(content, filePath)
