import std/[unittest, os, strutils]
import ../tools/move_tool

const Dir = "/tmp/claude-1000/-home-kl-prog-TEST-nimtools/ce257534-ab85-4122-b499-36dbb0623cb4/scratchpad/mv"

proc setupFiles(): (string, string) =
  removeDir(Dir); createDir(Dir)
  let src = Dir / "src.nim"
  writeFile(src, """
type
  Person* = object
    age*: int

proc usesPerson*(p: Person): int =
  p.age + 1

proc standalone*(x: int): int =
  x * 2
""")
  (src, Dir / "dest.nim")

suite "move-symbol safety":
  test "refuses to move a proc whose types would be left behind":
    let (src, dest) = setupFiles()
    let r = moveSymbols(src, dest, @["usesPerson"])
    check r.status == mvRefused
    check "Person" in r.message
    check not fileExists(dest)

  test "moves a self-contained proc successfully":
    let (src, dest) = setupFiles()
    let r = moveSymbols(src, dest, @["standalone"])
    check r.status == mvMoved
    check "standalone" in readFile(dest)
    check "standalone" notin readFile(src)

  test "force overrides the refusal":
    let (src, dest) = setupFiles()
    let r = moveSymbols(src, dest, @["usesPerson"], force = true)
    check r.status == mvMoved
