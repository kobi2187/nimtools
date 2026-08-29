## Semantic queries by driving `nimsuggest`.
##
## The parser-based tools in this repo resolve names lexically. That is enough
## for shape questions (outline, api-surface, complexity) but not for identity:
## `x.foo` is a field access or a UFCS call to `foo(x)` depending on the type of
## `x`, and the parser cannot tell. The consequence is not a missing feature but
## a wrong answer — `references` reported "0 uses" for a proc with five, every
## one of them written in UFCS form. An agent trusting that deletes live code.
##
## Resolving it needs the compiler's semantic pass. Rather than reimplement one,
## this drives the `nimsuggest` that ships with every Nim install. The protocol
## over `--stdin` is line based, so a query is: write `use file:line:col`, write
## `quit`, read the tab-separated reply to EOF. `osproc.execCmdEx` takes the
## stdin text directly, so no pipe handling or process supervision is needed.
##
## Columns of a reply row: section, symkind, qualified name, type, file, line,
## col, doc, quality. Line is 1-based and col 0-based — the same convention
## `inspect` and `extract` already report, so positions need no translation.
##
## LIMITS, and they are the honest kind — a caller can detect every one:
## - nimsuggest sees only modules reachable from the project root it was opened
##   with, so `projectRoot` decides how much of the project an answer covers.
## - it must run the compiler, so a query costs seconds, not milliseconds.
## - a missing binary, a crash, or a timeout returns `ssUnavailable` rather than
##   an empty result, so "no uses" is never confused with "could not tell".

import std/[os, osproc, strutils]

type
  SuggestLoc* = object
    file*: string
    line*: int           ## 1-based
    col*: int            ## 0-based

  SuggestStatus* = enum
    ssOk                 ## nimsuggest answered with at least a definition
    ssNoResult           ## it ran, but nothing is declared at that position
    ssUnavailable        ## missing binary, non-zero exit, or timeout

  SuggestReply* = object
    status*: SuggestStatus
    message*: string     ## why, when status is not ssOk
    def*: SuggestLoc     ## the declaration nimsuggest resolved the position to
    uses*: seq[SuggestLoc]  ## every use; excludes the declaration itself

const
  SuggestTimeoutSecs* = 120
  TimeoutExitCode = 124   ## coreutils `timeout` signals expiry with 124

proc nimsuggestPath*(): string =
  ## Empty when nimsuggest is not installed.
  findExe("nimsuggest")

proc parseRow*(row: string): tuple[section: string, loc: SuggestLoc, ok: bool] =
  ## A reply row, or ok=false for the banner and blank lines nimsuggest also
  ## prints. Anything not shaped like a result is skipped rather than fatal.
  let f = row.split('\t')
  if f.len < 7: return
  if f[0] notin ["def", "use"]: return
  let line = try: parseInt(f[5]) except ValueError: return
  let col = try: parseInt(f[6]) except ValueError: return
  (f[0], SuggestLoc(file: f[4], line: line, col: col), true)

proc runSuggest(projectRoot, command: string): tuple[output: string, ok: bool,
                                                     message: string] =
  let exe = nimsuggestPath()
  if exe.len == 0:
    return ("", false, "nimsuggest not found on PATH")

  var cmd = quoteShell(exe) & " --stdin " & quoteShell(projectRoot.absolutePath)
  # ponytail: coreutils `timeout` when present, so a wedged nimsuggest cannot
  # hang an agent forever. Absent (Windows), the query just has no deadline.
  let timeoutExe = findExe("timeout")
  if timeoutExe.len > 0:
    cmd = quoteShell(timeoutExe) & " " & $SuggestTimeoutSecs & " " & cmd

  let input = command & "\nquit\n"
  let r = try: execCmdEx(cmd, input = input)
          except OSError, IOError:
            return ("", false, "could not run nimsuggest: " &
                    getCurrentExceptionMsg())
  if r.exitCode == TimeoutExitCode:
    return ("", false, "nimsuggest timed out after " & $SuggestTimeoutSecs & "s")
  if r.exitCode != 0:
    return ("", false, "nimsuggest exited " & $r.exitCode)
  (r.output, true, "")

proc queryUses*(projectRoot, file: string; line, col: int): SuggestReply =
  ## Every use of whatever symbol is named at `file:line:col`, resolved
  ## semantically across the modules reachable from `projectRoot`.
  let query = "use " & file.absolutePath & ":" & $line & ":" & $col
  let r = runSuggest(projectRoot, query)
  if not r.ok:
    return SuggestReply(status: ssUnavailable, message: r.message)

  var reply = SuggestReply(status: ssNoResult)
  for row in r.output.splitLines:
    let p = parseRow(row)
    if not p.ok: continue
    if p.section == "def":
      # Only the first def is the queried symbol; later ones would be overloads.
      if reply.status == ssNoResult:
        reply.def = p.loc
        reply.status = ssOk
    else:
      reply.uses.add p.loc
  if reply.status == ssNoResult:
    reply.message = "nimsuggest resolved no symbol at " & file & ":" &
                    $line & ":" & $col
  reply
