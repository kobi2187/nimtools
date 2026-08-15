import std/[unittest, os, strutils, sequtils]
import ../tools/[extract_tool, doc_tool]

const F = "/tmp/claude-1000/-home-kl-prog-TEST-nimtools/ce257534-ab85-4122-b499-36dbb0623cb4/scratchpad/tf_ex.nim"

proc setupFixture() =
  writeFile(F, """
type
  Config* = object
    ## A configuration.
    path*: string

proc documented*(x: int): int =
  ## Doubles x.
  x * 2

proc undocumented*(y: int): int =
  y + 1

proc overloaded*(a: int): int = a
proc overloaded*(a, b: int): int = a + b

proc withNested*(x: int): int =
  proc helper(y: int): int = y * 3
  helper(x)
""")

suite "extract":
  setup: setupFixture()

  test "returns signature and doc without body by default":
    let r = findSymbol(F, "documented")
    check r.len == 1
    check "documented" in r[0].sig
    check r[0].doc == "Doubles x."
    check r[0].body.len == 0

  test "--body returns the real source span":
    let r = findSymbol(F, "documented", withBody = true)
    check "x * 2" in r[0].body

  test "reports every overload, not just the first":
    check findSymbol(F, "overloaded").len == 2

  test "finds a nested routine":
    check findSymbol(F, "helper").len == 1

  test "finds a type":
    let r = findSymbol(F, "Config")
    check r.len == 1
    check r[0].kind == "type"

  test "reports the 0-based declaration column for --at round-trips":
    let r = findSymbol(F, "documented")
    check r.len == 1
    check r[0].col == 5

  test "unknown symbol returns nothing":
    check findSymbol(F, "nosuch").len == 0

suite "missing-docs":
  setup: setupFixture()

  test "lists exported routines lacking docs":
    let names = findUndocumented(F).mapIt(it.name)
    check "undocumented" in names
    check "documented" notin names

  test "excludes private routines by default":
    check "helper" notin findUndocumented(F).mapIt(it.name)

  test "--all includes private routines":
    check "helper" in findUndocumented(F, includePrivate = true).mapIt(it.name)
