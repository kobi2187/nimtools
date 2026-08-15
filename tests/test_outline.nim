import std/[unittest, os, osproc, strutils]

const Root = "/home/kl/prog/TEST/nimtools"
const Nest = "/tmp/claude-1000/-home-kl-prog-TEST-nimtools/ce257534-ab85-4122-b499-36dbb0623cb4/scratchpad/tf_outline.nim"

suite "outline agrees with extract":
  setup:
    writeFile(Nest, """
type
  Holder* = object
    v*: int

proc outer*(x: int): int =
  proc nestedHelper(y: int): int = y * 2
  nestedHelper(x)
""")

  test "outline reports nested routines":
    let r = execCmdEx(Root / "nimoutline " & Nest)
    check r.exitCode == 0
    check "nestedHelper" in r.output

  test "outline still reports top-level routines and types":
    let r = execCmdEx(Root / "nimoutline " & Nest)
    check "outer" in r.output
    check "Holder" in r.output
