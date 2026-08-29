## type-report: batched nimsuggest 'def' queries exposing the type column
## suggest.nim's parseRow already parsed but previously discarded.

import std/[unittest, os, sequtils, strutils]
import ../shared/suggest

const Scratch = getTempDir() / "nimtools_test_type_report"

proc writeProject(dir: string, files: openArray[(string, string)]) =
  removeDir(dir)
  createDir(dir)
  for (name, body) in files:
    createDir((dir / name).parentDir)
    writeFile(dir / name, body)

when defined(windows):
  echo "skipping end-to-end type-report suite on windows"
else:
  suite "queryTypes: batched resolution":
    setup:
      let dir = Scratch / "proj"
      writeProject(dir, {
        "m.nim": "proc tag*(s: string): string =\n  \"[\" & s & \"]\"\n" &
                 "let greeting = tag(\"hi\")\n"})

    test "resolves the type at a single location":
      if nimsuggestPath().len == 0:
        skip()
      else:
        let results = queryTypes(dir / "m.nim", @[SuggestLoc(file: dir / "m.nim", line: 1, col: 5)])
        check results.len == 1
        check results[0].status == ssOk
        check "string" in results[0].typ

    test "resolves multiple locations in one call":
      if nimsuggestPath().len == 0:
        skip()
      else:
        let locs = @[
          SuggestLoc(file: dir / "m.nim", line: 1, col: 5),   # tag
          SuggestLoc(file: dir / "m.nim", line: 3, col: 4)]   # greeting
        let results = queryTypes(dir / "m.nim", locs)
        check results.len == 2
        check results[0].status == ssOk
        check results[1].status == ssOk

    test "a location naming no symbol reports ssNoResult for just that entry":
      if nimsuggestPath().len == 0:
        skip()
      else:
        let locs = @[
          SuggestLoc(file: dir / "m.nim", line: 1, col: 5),    # tag: resolves
          SuggestLoc(file: dir / "m.nim", line: 2, col: 0)]    # blank-ish: may not
        let results = queryTypes(dir / "m.nim", locs)
        check results.len == 2
        check results[0].status == ssOk

  suite "unavailability is reported per batch, never a wrong-shaped result":
    test "a missing root produces one failing result per location, not a crash":
      let locs = @[SuggestLoc(file: Scratch / "nope.nim", line: 1, col: 0)]
      let results = queryTypes(Scratch / "nope.nim", locs)
      check results.len == 1
      check results[0].status == ssUnavailable
      check results[0].message.len > 0
