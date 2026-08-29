import compiler/[ast, parser, idents, options, lineinfos]
import std/os

type
  ParseError* = object
    ## A parse error with its position kept apart from its text, so a caller can
    ## report it as `file:line:col` instead of re-parsing a prose string.
    line*: int          ## 1-based
    col*: int           ## 0-based
    message*: string

  ParseResult* = object
    ast*: PNode
    errors*: seq[string]        ## legacy prose form; kept for existing callers
    diagnostics*: seq[ParseError]
    cache*: IdentCache
    config*: ConfigRef

proc newSafeCompilerConfig*(): (IdentCache, ConfigRef, ref seq[string],
                               ref seq[ParseError]) =
  let cache = newIdentCache()
  let config = newConfigRef()
  let errors = new(seq[string])
  errors[] = @[]
  let diags = new(seq[ParseError])
  diags[] = @[]

  config.ideCmd = ideSug
  config.errorMax = 1000
  config.writelnHook = proc(output: string) {.closure, gcsafe.} = discard

  config.structuredErrorHook = proc(conf: ConfigRef; info: TLineInfo; msg: string; severity: Severity) {.closure, gcsafe.} =
    {.cast(gcsafe).}:
      if severity == Severity.Error:
        errors[].add("Line " & $info.line & ", col " & $info.col & ": " & msg)
        diags[].add ParseError(line: info.line.int, col: info.col.int,
                               message: msg)

  return (cache, config, errors, diags)

proc parseNimString*(code: string, filename: string = "snippet.nim"): ParseResult =
  let (cache, config, errors, diags) = newSafeCompilerConfig()
  let root = try:
    parseString(code, cache, config, filename)
  except CatchableError as e:
    errors[].add("Parse exception: " & e.msg)
    diags[].add ParseError(line: 0, col: 0, message: e.msg)
    nil
  return ParseResult(ast: root, errors: errors[], diagnostics: diags[],
                     cache: cache, config: config)

proc parseNimFile*(filePath: string): ParseResult =
  if not fileExists(filePath):
    return ParseResult(ast: nil, errors: @["File does not exist: " & filePath],
                       diagnostics: @[ParseError(line: 0, col: 0,
                         message: "file does not exist")],
                       cache: nil, config: nil)
  let content = try:
    readFile(filePath)
  except CatchableError as e:
    return ParseResult(ast: nil, errors: @["Could not read file: " & e.msg],
                       diagnostics: @[ParseError(line: 0, col: 0,
                         message: "could not read file: " & e.msg)],
                       cache: nil, config: nil)
  return parseNimString(content, filePath)
