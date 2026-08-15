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
