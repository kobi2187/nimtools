import std/[unittest, os, strutils, sequtils]
import ../tools/api_tool

const Dir = "/tmp/claude-1000/-home-kl-prog-TEST-nimtools/ce257534-ab85-4122-b499-36dbb0623cb4/scratchpad/api"

proc setupFiles() =
  removeDir(Dir)
  createDir(Dir)
  writeFile(Dir / "m.nim", """
import std/strutils
export strutils

const PublicConst* = 1
const privateConst = 2

let publicLet* = "x"

type
  Person* = object
    name*: string
    secret: int

  Hidden = object
    v*: int

proc exportedProc*(p: Person): int =
  p.secret

proc privateProc(x: int): int =
  x

func exportedFunc*(a: int): int = a

template exportedTemplate*(b: untyped): untyped = b

iterator exportedIter*(): int =
  yield 1
""")
  writeFile(Dir / "n.nim", """
proc onlyPrivate(x: int): int = x
""")

suite "api-surface: what is exported":
  setup: setupFiles()

  test "lists exported routines of every kind":
    let names = surfaceOf(Dir / "m.nim").symbols.mapIt(it.name)
    check "exportedProc" in names
    check "exportedFunc" in names
    check "exportedTemplate" in names
    check "exportedIter" in names

  test "never lists private symbols":
    let names = surfaceOf(Dir / "m.nim").symbols.mapIt(it.name)
    check "privateProc" notin names
    check "privateConst" notin names
    check "Hidden" notin names

  test "lists exported types with their rendered shape":
    let syms = surfaceOf(Dir / "m.nim").symbols.filterIt(it.name == "Person")
    check syms.len == 1
    check syms[0].kind == "type"
    check "name" in syms[0].sig

  test "lists exported const and let":
    let names = surfaceOf(Dir / "m.nim").symbols.mapIt(it.name)
    check "PublicConst" in names
    check "publicLet" in names

  test "a const shows its value, since that is the contract":
    let c = surfaceOf(Dir / "m.nim").symbols.filterIt(it.name == "PublicConst")[0]
    check "1" in c.sig

  test "a let does not show its initial value":
    let l = surfaceOf(Dir / "m.nim").symbols.filterIt(it.name == "publicLet")[0]
    check "\"x\"" notin l.sig

  test "records re-exports":
    check "strutils" in surfaceOf(Dir / "m.nim").reExports

  test "counts hidden private symbols":
    check surfaceOf(Dir / "m.nim").privateCount > 0

  test "a module with no exports yields an empty surface":
    let s = surfaceOf(Dir / "n.nim")
    check s.symbols.len == 0
    check s.privateCount == 1

suite "api-surface: directories":
  setup: setupFiles()

  test "walks a directory and groups per module":
    let mods = surfaceOfPaths(@[Dir])
    check mods.len == 2
    check mods.anyIt(it.file.endsWith("m.nim"))
    check mods.anyIt(it.file.endsWith("n.nim"))

  test "modules keep their own symbols":
    let mods = surfaceOfPaths(@[Dir])
    let m = mods.filterIt(it.file.endsWith("m.nim"))[0]
    check m.symbols.anyIt(it.name == "exportedProc")
    check not m.symbols.anyIt(it.name == "onlyPrivate")

suite "api-surface: module documentation":
  setup: setupFiles()

  test "captures the module header doc comment":
    writeFile(Dir / "d.nim", """
## This module does a thing.
## Second line of rationale.

import std/os

proc f*(): int = 1
""")
    check "does a thing" in surfaceOf(Dir / "d.nim").moduleDoc

  test "a module with no header doc has an empty moduleDoc":
    check surfaceOf(Dir / "n.nim").moduleDoc.len == 0

  test "a routine doc is not mistaken for the module doc":
    writeFile(Dir / "e.nim", """
proc f*(): int =
  ## Routine doc, not module doc.
  1
""")
    check surfaceOf(Dir / "e.nim").moduleDoc.len == 0

  test "symbols carry their own doc comments":
    writeFile(Dir / "g.nim", """
proc documented*(): int =
  ## What it does.
  1
""")
    let s = surfaceOf(Dir / "g.nim").symbols[0]
    check s.doc == "What it does."

suite "api-surface: executables":
  setup: setupFiles()

  test "includePrivate reveals a program's internals":
    writeFile(Dir / "cli.nim", """
proc helper(x: int): int = x
proc main() =
  discard helper(1)
when isMainModule: main()
""")
    check surfaceOf(Dir / "cli.nim").symbols.len == 0
    let all = surfaceOf(Dir / "cli.nim", includePrivate = true)
    check all.symbols.mapIt(it.name) == @["helper", "main"]

  test "private symbols are marked as private":
    writeFile(Dir / "cli.nim", "proc helper(x: int): int = x\n")
    let all = surfaceOf(Dir / "cli.nim", includePrivate = true)
    check not all.symbols[0].exported

  test "exported symbols stay marked exported under includePrivate":
    let all = surfaceOf(Dir / "m.nim", includePrivate = true)
    check all.symbols.filterIt(it.name == "exportedProc")[0].exported

  test "exported consts and lets are marked exported":
    let s = surfaceOf(Dir / "m.nim")
    check s.symbols.filterIt(it.name == "PublicConst")[0].exported
    check s.symbols.filterIt(it.name == "publicLet")[0].exported

  test "includePrivate reveals private const/let/var":
    writeFile(Dir / "cli.nim", """
const limit = 10
let name = "x"
var state = 0
""")
    let all = surfaceOf(Dir / "cli.nim", includePrivate = true)
    check all.symbols.mapIt(it.name) == @["limit", "name", "state"]
    check all.symbols.allIt(not it.exported)

  test "locals inside a routine body are not module symbols":
    writeFile(Dir / "cli.nim", """
proc helper(x: int): int =
  var local = x + 1
  let tmp = local * 2
  tmp
""")
    check surfaceOf(Dir / "cli.nim").privateCount == 1
    let all = surfaceOf(Dir / "cli.nim", includePrivate = true)
    check all.symbols.mapIt(it.name) == @["helper"]
