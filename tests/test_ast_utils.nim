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

suite "nodeLineBounds excludes nkEmpty sentinel positions":
  # Regression: an nkIdentDefs' trailing "no default value" slot is an nkEmpty
  # node whose .info.line points at wherever the parser's cursor landed next --
  # for an object field with no default, that is the FOLLOWING declaration's
  # line, not this field's own. nodeLineBounds walked every child unconditionally
  # and took min/max over ALL of them, so that phantom line inflated a type's
  # span into its neighbor's. move-symbol then extracted and deleted one line
  # too many: dest gained the next typedef's header, source lost its own.
  test "a type's span does not reach into the next sibling typedef":
    let src = """
type
  Foo* = object
    a: int
    b: string
  Bar* = object
    c: float
"""
    let parsed = parseNimString(src, "t.nim")
    let defs = collectTypeDefs(parsed.ast)
    let foo = defs.filterIt(typeDefName(it) == "Foo")[0]
    let bar = defs.filterIt(typeDefName(it) == "Bar")[0]
    check nodeLineBounds(foo) == (2, 4)   # Foo* = object / a: int / b: string
    check nodeLineBounds(bar) == (5, 6)   # Bar* = object / c: float

  test "the last field's missing default does not leak a phantom trailing line":
    let src = """
type
  Solo* = object
    x: int

echo "after"
"""
    let parsed = parseNimString(src, "t.nim")
    let solo = collectTypeDefs(parsed.ast)[0]
    check nodeLineBounds(solo) == (2, 3)   # not reaching down to the echo line
