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

suite "find-references":
  test "lists a binding's declaration and every use":
    const Src = """
proc greet(name: string): string =
  "Hello, " & name

proc main() =
  echo greet("a")
  echo greet("b")
"""
    let refs = findReferences(Src, "t.nim", "greet")
    check refs.len == 1
    check refs[0].declaredLine == 1
    check refs[0].declaredCol == 5
    check refs[0].uses.len == 2
    check refs[0].uses[0].line == 5
    check refs[0].uses[1].line == 6
    check "greet(\"a\")" in refs[0].uses[0].text

  test "disambiguates shadowed bindings by position":
    const Src = """
proc outer() =
  var x = 1
  echo x
proc other() =
  var x = 2
  echo x
"""
    let one = findReferences(Src, "t.nim", "x", line = 2, col = 6)
    check one.len == 1
    check one[0].declaredLine == 2
    check one[0].uses.len == 1
    check one[0].uses[0].line == 3

  test "returns every binding when no position is given":
    const Src = """
proc outer() =
  var x = 1
  echo x
proc other() =
  var x = 2
  echo x
"""
    check findReferences(Src, "t.nim", "x").len == 2

  test "an unused binding reports zero uses, not a miss":
    const Src = """
proc unused(): int = 1
"""
    let refs = findReferences(Src, "t.nim", "unused")
    check refs.len == 1
    check refs[0].uses.len == 0

  test "an unknown name returns nothing":
    check findReferences("proc f() =\n  discard\n", "t.nim", "nosuch").len == 0

suite "find-unbound-uses":
  test "reports an imported name's uses":
    const Src = """
import util

proc f() =
  echo sanitize("x")
  echo sanitize("y")
"""
    let uses = findUnboundUses(Src, "t.nim", "sanitize")
    check uses.len == 2
    check uses[0].line == 4
    check uses[1].line == 5

  test "a local binding shadows the import, so it is not unbound":
    const Src = """
import util
var sanitize = 5
proc f() =
  echo sanitize
"""
    check findUnboundUses(Src, "t.nim", "sanitize").len == 0

  test "a from-import and a label are not uses":
    const Src = """
from util import sanitize
proc f() =
  let p = Person(name: "x")
  discard g(flag: true)
"""
    check findUnboundUses(Src, "t.nim", "sanitize").len == 0
    check findUnboundUses(Src, "t.nim", "name").len == 0
    check findUnboundUses(Src, "t.nim", "flag").len == 0

suite "scope-aware walk: while and block bodies":
  # Regression: walkBody used to re-walk the node it was given, so nkWhileStmt /
  # nkBlockStmt re-entered their own case arm and recursed until the stack blew.
  # Any file with a `while` — every parseopt loop in this repo — crashed the
  # reference and rename tools outright.

  test "a while loop terminates and its body is searched":
    const Src = """
proc f(n: int): int =
  var total = 0
  var i = 0
  while i < n:
    total = total + i
    i = i + 1
  total
"""
    let refs = findReferences(Src, "t.nim", "total", 2, 6)
    check refs.len == 1
    check refs[0].uses.len == 3       # while body twice, trailing result

  test "a block statement terminates and its label is not a use":
    const Src = """
proc f(n: int): int =
  var total = 0
  block outer:
    total = total + n
  total
"""
    let refs = findReferences(Src, "t.nim", "total", 2, 6)
    check refs.len == 1
    check refs[0].uses.len == 3       # assignment target, rhs, trailing result
    check findUnboundUses(Src, "t.nim", "outer").len == 0

  test "a binding declared inside a while body stays scoped to it":
    const Src = """
proc f(n: int): int =
  var i = 0
  while i < n:
    var tmp = i * 2
    i = i + tmp
  i
"""
    let refs = findReferences(Src, "t.nim", "tmp", 4, 8)
    check refs.len == 1
    check refs[0].uses.len == 1
