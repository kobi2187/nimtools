import std/[unittest, json, os, strutils, sequtils]
import ../tools/inspect_tool

const Fixture = "/tmp/claude-1000/-home-kl-prog-TEST-nimtools/ce257534-ab85-4122-b499-36dbb0623cb4/scratchpad/tf_inspect.nim"

suite "inspect JSON contract":
  setup:
    writeFile(Fixture, """
import std/[os, json]

proc outer*(x: int): int =
  ## Documented.
  proc nested(y: int): int =
    y * 2
  result = nested(x)

proc undocumented(a: int): int =
  a
""")

  test "reports nested routines":
    let names = inspectFile(Fixture)["routines"].getElems.mapIt(it["name"].getStr)
    check "outer" in names
    check "nested" in names

  test "imports are agent-consumable module paths":
    let imps = inspectFile(Fixture)["imports"].getElems.mapIt(it.getStr)
    check "std/os" in imps
    check "std/json" in imps
    check not imps.anyIt(" " in it)

  test "reports whether a routine has a doc comment":
    let rs = inspectFile(Fixture)["routines"].getElems
    let outer = rs.filterIt(it["name"].getStr == "outer")[0]
    let undoc = rs.filterIt(it["name"].getStr == "undocumented")[0]
    check outer["doc"].getStr.len > 0
    check undoc["doc"].getStr.len == 0

  test "reports the 0-based declaration column for --at round-trips":
    let rs = inspectFile(Fixture)["routines"].getElems
    let outer = rs.filterIt(it["name"].getStr == "outer")[0]
    check outer["col"].getInt == 5
