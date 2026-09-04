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

suite "move-symbol topo order":
  # Nim resolves top-level const/let/proc/type in textual order, not two-pass --
  # verified experimentally (`const b = a + 1; const a = 10` fails to compile).
  # A blind append in argument/source order can therefore emit a destination
  # file that does not compile even though the source file did.

  test "reorders moved procs so a dependency lands before its dependent":
    let (src, dest) = setupFiles()
    writeFile(src, """
proc h*(): int = f()
proc f*(): int = g() + 1
proc g*(): int = 10
""")
    # Requested out of dependency order: h (depends on f) before f before g.
    let r = moveSymbols(src, dest, @["h", "f", "g"])
    check r.status == mvMoved
    let destText = readFile(dest)
    check destText.find("proc g") < destText.find("proc f")
    check destText.find("proc f") < destText.find("proc h")

  test "refuses a cycle among the moved symbols rather than emit broken order":
    let (src, dest) = setupFiles()
    writeFile(src, """
proc isEven*(n: int): bool =
  if n == 0: true else: isOdd(n-1)
proc isOdd*(n: int): bool =
  if n == 0: false else: isEven(n-1)
""")
    let r = moveSymbols(src, dest, @["isEven", "isOdd"])
    check r.status == mvRefused
    check "isEven" in r.deps
    check "isOdd" in r.deps
    check not fileExists(dest)

  test "force moves a cycle anyway, in original order":
    let (src, dest) = setupFiles()
    writeFile(src, """
proc isEven*(n: int): bool =
  if n == 0: true else: isOdd(n-1)
proc isOdd*(n: int): bool =
  if n == 0: false else: isEven(n-1)
""")
    let r = moveSymbols(src, dest, @["isEven", "isOdd"], force = true)
    check r.status == mvMoved
    check fileExists(dest)

suite "move-symbol overloads":
  # Regression: codeByName (and topoSortMoved's byName) were Table[string, ...]
  # keyed only by symbol name. Two overloads share a name, so the second write
  # silently overwrote the first -- both copies in the destination ended up
  # identical to whichever overload was written last, and the OTHER overload's
  # code was lost entirely (not left behind either -- gone).
  test "moving two overloads together keeps both distinct signatures":
    let (src, dest) = setupFiles()
    writeFile(src, """
proc greet*(name: string): string =
  "hi " & name

proc greet*(name: string, loud: bool): string =
  "HI " & name
""")
    let r = moveSymbols(src, dest, @["greet"])
    check r.status == mvMoved
    let destText = readFile(dest)
    check "proc greet*(name: string): string" in destText
    check "proc greet*(name: string, loud: bool): string" in destText
    check destText.count("proc greet*") == 2
