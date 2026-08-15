import std/[unittest, os, strutils]
import ../tools/delete_tool

const Dir = "/tmp/claude-1000/-home-kl-prog-TEST-nimtools/ce257534-ab85-4122-b499-36dbb0623cb4/scratchpad/del"

proc setupFiles(): string =
  removeDir(Dir); createDir(Dir)
  writeFile(Dir / "src.nim", """
type
  Person* = object
    age*: int

proc usesPerson*(p: Person): int =
  p.age + 1

proc standalone*(x: int): int =
  x * 2
""")
  Dir / "src.nim"

suite "delete-symbol":
  setup:
    discard setupFiles()

  test "removes a self-contained symbol's definition":
    let src = Dir / "src.nim"
    let r = deleteSymbols(src, @["standalone"])
    check r.status == delDeleted
    check "standalone" notin readFile(src)
    check "usesPerson" in readFile(src)

  test "refuses to delete a symbol that is still referenced":
    let src = Dir / "src.nim"
    writeFile(src, """
proc helper(x: int): int = x
proc main() =
  echo helper(1)
""")
    let r = deleteSymbols(src, @["helper"])
    check r.status == delRefused
    check "helper" in readFile(src)

  test "force overrides the delete refusal":
    let src = Dir / "src.nim"
    writeFile(src, """
proc helper(x: int): int = x
proc main() =
  echo helper(1)
""")
    let r = deleteSymbols(src, @["helper"], force = true)
    check r.status == delDeleted
    check "proc helper" notin readFile(src)   # definition gone
    check "main" in readFile(src)             # call site left (broken, as forced)

  test "an unknown symbol is an error":
    let src = Dir / "src.nim"
    let r = deleteSymbols(src, @["nosuch"])
    check r.status == delError
