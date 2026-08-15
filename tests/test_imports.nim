import std/[unittest, os, sequtils]
import ../tools/import_tool

const Dir = "/tmp/claude-1000/-home-kl-prog-TEST-nimtools/ce257534-ab85-4122-b499-36dbb0623cb4/scratchpad/unused"

proc write(body: string): string =
  createDir(Dir)
  result = Dir / "u.nim"
  writeFile(result, body)

suite "unused-imports":
  setup:
    removeDir(Dir); createDir(Dir)

  test "flags an import whose symbols are never referenced":
    let f = write("""
import std/strutils
import std/json

let x = %*{"a": 1}
echo x
""")
    check findUnusedImports(f).mapIt(it.module) == @["std/strutils"]

  test "does not flag an import that is used":
    let f = write("""
import std/strutils

echo "a,b".split(',')
""")
    check findUnusedImports(f).len == 0

  test "decomposes a grouped import and flags only the unused member":
    let f = write("""
import std/[strutils, json]

echo "a,b".split(',')
""")
    check findUnusedImports(f).mapIt(it.module) == @["std/json"]

  test "a name appearing only in a comment does not count as use":
    let f = write("""
import std/json

# json is mentioned here but never called
echo 1
""")
    check findUnusedImports(f).mapIt(it.module) == @["std/json"]

  test "a name appearing only in a string does not count as use":
    let f = write("""
import std/json

echo "json"
""")
    check findUnusedImports(f).mapIt(it.module) == @["std/json"]

  test "qualified use counts":
    let f = write("""
import std/json

echo json.pretty(newJNull())
""")
    check findUnusedImports(f).len == 0

  test "reports the line the import sits on":
    let f = write("import std/json\n\necho 1\n")
    let u = findUnusedImports(f)
    check u.len == 1
    check u[0].line == 1
