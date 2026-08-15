import std/[unittest, strutils]
import ../shared/[compiler_env, scope_rename]

proc renamed(src, oldName, newName: string; line, col: int): string =
  let r = renameScoped(src, "t.nim", oldName, newName, line, col)
  doAssert r.status == srRenamed, r.message
  r.source

suite "scope-aware rename: locals":
  const Src = """
proc outer(a: int): int =
  var i = 0
  for i in 0..3:
    echo i
  let x = a + i
  result = x

proc other(): int =
  var i = 99
  i
"""

  test "renaming a local does not touch a same-named local in another proc":
    # `i` declared at line 2 col 6 -> only outer's `i` binding changes
    let got = renamed(Src, "i", "idx", 2, 6)
    check "var idx = 0" in got
    check "var i = 99" in got          # other proc untouched

  test "renaming a local does not capture a shadowing for-loop variable":
    let got = renamed(Src, "i", "idx", 2, 6)
    check "for i in 0..3:" in got      # for-loop binds its own `i`
    check "echo i" in got              # body refers to the for-loop `i`

  test "the use site inside the same scope is renamed":
    let got = renamed(Src, "i", "idx", 2, 6)
    check "a + idx" in got

suite "scope-aware rename: parameters":
  const Src = """
proc outer(a: int): int =
  proc inner(a: string): string =
    a & "x"
  result = a + 1
"""

  test "renaming a param renames its uses but not a shadowing inner param":
    let got = renamed(Src, "a", "value", 1, 11)
    check "proc outer(value: int)" in got
    check "result = value + 1" in got
    check "proc inner(a: string)" in got   # inner param is a different binding
    check "a & \"x\"" in got

suite "scope-aware rename: refusals":
  test "refuses when the position names no binding":
    let r = renameScoped("proc f() =\n  discard\n", "t.nim", "zzz", "q", 2, 2)
    check r.status == srNotFound

  test "refuses to shadow an existing binding in the same scope":
    const Src = """
proc f() =
  var a = 1
  var b = 2
  echo a, b
"""
    let r = renameScoped(Src, "t.nim", "a", "b", 2, 6)
    check r.status == srConflict
    check "b" in r.message

suite "scope-aware rename: strings and comments":
  test "leaves the name inside strings and comments alone":
    const Src = """
proc f() =
  var target = 1
  ## target in a doc comment
  echo "target in a string"  # target in a comment
  echo target
"""
    let got = renamed(Src, "target", "renamed", 2, 6)
    check "var renamed = 1" in got
    check "echo renamed" in got
    check "## target in a doc comment" in got
    check "\"target in a string\"" in got
    check "# target in a comment" in got
