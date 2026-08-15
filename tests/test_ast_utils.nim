import std/[unittest, sequtils]
import ../shared/[compiler_env, ast_utils]
import ../tools/import_tool

suite "walker finds nested routines":
  test "collectRoutines finds a proc nested inside another proc":
    let src = """
proc outer(x: int): int =
  proc nested(y: int): int =
    y * 2
  result = nested(x)
"""
    let parsed = parseNimString(src, "t.nim")
    let names = collectRoutines(parsed.ast).mapIt(routineName(it))
    check "outer" in names
    check "nested" in names

suite "import extraction is normalized":
  test "slash imports have no surrounding spaces":
    let parsed = parseNimString("import std/strutils\n", "t.nim")
    check extractExistingImports(parsed.ast) == @["std/strutils"]

  test "grouped imports decompose into one entry per module":
    let parsed = parseNimString("import std/[os, json]\n", "t.nim")
    let got = extractExistingImports(parsed.ast)
    check "std/os" in got
    check "std/json" in got

  test "nested-group modules are found by membership test":
    let parsed = parseNimString("import std/[os, json]\n", "t.nim")
    check "std/json" in extractExistingImports(parsed.ast)
