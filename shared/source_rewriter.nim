import compiler/[lexer, idents, options, lineinfos, llstream]
import std/[strutils, algorithm]

proc detectLineEnding*(source: string): string =
  ## Returns the dominant line ending of `source` ("\r\n" or "\n").
  ## Rewrites must restore this: splitLines() discards \r, so joining with a
  ## bare "\n" silently converts a CRLF file and reformats lines the caller
  ## never asked to touch.
  if source.contains("\r\n"): "\r\n" else: "\n"

proc extractLineRange*(source: string, startLine, endLine: int): string =
  ## Extracts 1-based lines from `startLine` to `endLine` inclusive.
  let lines = source.splitLines()
  let lo = max(1, startLine) - 1
  let hi = min(lines.len, endLine) - 1
  if lo <= hi and lo < lines.len:
    return lines[lo..hi].join(detectLineEnding(source))
  return ""

proc replaceLineRange*(source: string, startLine, endLine: int, replacement: string): string =
  ## Replaces 1-based lines from `startLine` to `endLine` inclusive with `replacement`.
  let lines = source.splitLines()
  let lo = max(1, startLine) - 1
  let hi = min(lines.len, endLine) - 1
  
  var newLines: seq[string] = @[]
  if lo > 0:
    newLines.add lines[0..<lo]
  if replacement.len > 0:
    newLines.add replacement
  if hi + 1 < lines.len:
    newLines.add lines[(hi + 1)..^1]
  return newLines.join(detectLineEnding(source))

proc ensureSymbolExported*(defCode: string, name: string): string =
  ## If the definition `name` does not have an export marker `*`, inserts `*` right after `name`.
  # Check if already exported: e.g. `name*`
  if defCode.contains(name & "*"):
    return defCode
  
  # Search for the identifier word and append `*`
  var pos = 0
  while pos < defCode.len:
    let idx = defCode.find(name, pos)
    if idx < 0: break
    
    # Check boundaries to ensure whole word match
    let beforeOk = (idx == 0 or not (defCode[idx - 1].isAlphaNumeric or defCode[idx - 1] == '_'))
    let afterIdx = idx + name.len
    let afterOk = (afterIdx >= defCode.len or not (defCode[afterIdx].isAlphaNumeric or defCode[afterIdx] == '_'))
    
    if beforeOk and afterOk:
      # If not already followed by '*', insert it
      if afterIdx < defCode.len and defCode[afterIdx] == '*':
        return defCode
      return defCode.substr(0, idx + name.len - 1) & "*" & defCode.substr(idx + name.len)
    pos = idx + 1
  return defCode

proc renameTokenStream*(source: string, oldName, newName: string): string =
  ## Renames identifiers in the source code at the token level, strictly skipping comments and string literals.
  var cache = newIdentCache()
  var conf = newConfigRef()
  var stream = llStreamOpen(source)
  
  var lex: Lexer
  # Use FileIndex(0) for in-memory stream
  openLexer(lex, FileIndex(0), stream, cache, conf)
  
  # We read tokens sequentially to find character offsets of identifier tokens matching oldName
  # Because openLexer uses line/col offsets, we can also perform precise regex/word replacement
  # on token intervals.
  # Let's perform lexer-guided character substitution:
  
  var token: Token = default(Token)
  
  type ReplaceSpan = tuple[line, col, len: int]
  var spans: seq[ReplaceSpan] = @[]
  
  while true:
    rawGetTok(lex, token)
    if token.tokType == tkEof: break
    if token.tokType == tkSymbol and token.ident != nil:
      if token.ident.s == oldName:
        spans.add (token.line, token.col, oldName.len)
  
  closeLexer(lex)
  
  if spans.len == 0:
    return source
    
  # Apply replacements from end to start per line to preserve column positions
  let lines = source.splitLines()
  var modifiedLines = lines
  
  # Group spans by line
  var lineSpans: seq[seq[ReplaceSpan]] = newSeq[seq[ReplaceSpan]](lines.len + 1)
  for s in spans:
    if s.line <= lines.len:
      lineSpans[s.line].add s
      
  for lineNum in 1..lines.len:
    var sps = lineSpans[lineNum]
    if sps.len == 0: continue
    # Sort backwards by col
    sps.sort(proc(a, b: ReplaceSpan): int = cmp(b.col, a.col))
    var lineStr = modifiedLines[lineNum - 1]
    for sp in sps:
      let col = sp.col
      if col >= 0 and col + sp.len <= lineStr.len:
        if lineStr.substr(col, col + sp.len - 1) == oldName:
          lineStr = lineStr.substr(0, col - 1) & newName & lineStr.substr(col + sp.len)
    modifiedLines[lineNum - 1] = lineStr

  return modifiedLines.join(detectLineEnding(source))
