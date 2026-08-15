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

  test "does not add a back-import when nothing staying references the moved symbol":
    let (src, dest) = setupFiles()
    let r = moveSymbols(src, dest, @["standalone"])
    check r.status == mvMoved
    check "import" notin readFile(src)

  test "adds a back-import when a staying symbol references the moved one":
    let (src, dest) = setupFiles()
    writeFile(src, """
proc a(x: int): int = x
proc b(x: int): int = a(x)
""")
    let r = moveSymbols(src, dest, @["a"])
    check r.status == mvMoved
    check "proc a" notin readFile(src)   # a's definition gone
    check "b" in readFile(src)           # b stays, calls a
    check "import" in readFile(src)      # back-import wired so b still compiles

suite "delete-symbol":
  test "removes a self-contained symbol's definition":
    let (src, _) = setupFiles()
    let r = deleteSymbols(src, @["standalone"])
    check r.status == mvMoved
    check "standalone" notin readFile(src)
    check "usesPerson" in readFile(src)

  test "refuses to delete a symbol that is still referenced":
    let (src, _) = setupFiles()
    writeFile(src, """
proc helper(x: int): int = x
proc main() =
  echo helper(1)
""")
    let r = deleteSymbols(src, @["helper"])
    check r.status == mvRefused
    check "helper" in readFile(src)

  test "force overrides the delete refusal":
    let (src, _) = setupFiles()
    writeFile(src, """
proc helper(x: int): int = x
proc main() =
  echo helper(1)
""")
    let r = deleteSymbols(src, @["helper"], force = true)
    check r.status == mvMoved
    check "proc helper" notin readFile(src)   # definition gone
    check "main" in readFile(src)             # call site left (broken, as forced)
