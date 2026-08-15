import std/[unittest, os, sequtils]
import ../tools/effects_tool

const Dir = "/tmp/claude-1000/-home-kl-prog-TEST-nimtools/ce257534-ab85-4122-b499-36dbb0623cb4/scratchpad/effects"

proc write(body: string): string =
  createDir(Dir)
  result = Dir / "e.nim"
  writeFile(result, body)

suite "raises: declared effect surface":
  setup:
    removeDir(Dir); createDir(Dir)

  test "reports a declared raises list":
    let f = write("proc risky*() {.raises: [IOError].} =\n  discard\n")
    let r = effectsOf(f)
    check r.len == 1
    check r[0].raises == @["IOError"]
    check r[0].declared

  test "reports raises: [] as explicitly nothing":
    let f = write("proc safe*() {.raises: [].} =\n  discard\n")
    let r = effectsOf(f)
    check r[0].raises.len == 0
    check r[0].declared

  test "a proc with no pragma is marked undeclared, not silent":
    let f = write("proc unknown*() =\n  discard\n")
    let r = effectsOf(f)
    check not r[0].declared

  test "reports multiple exceptions":
    let f = write("proc two*() {.raises: [IOError, ValueError].} =\n  discard\n")
    check effectsOf(f)[0].raises == @["IOError", "ValueError"]

  test "notes other effect pragmas":
    let f = write("proc tagged*() {.tags: [ReadIOEffect].} =\n  discard\n")
    check "tags" in effectsOf(f)[0].otherPragmas

suite "func-candidates":
  setup:
    removeDir(Dir); createDir(Dir)

  test "flags a proc with no side effects as a func candidate":
    let f = write("""
proc pure*(a, b: int): int =
  result = a + b
""")
    check funcCandidates(f).mapIt(it.name) == @["pure"]

  test "does not flag a proc that echoes":
    let f = write("""
proc noisy*(a: int): int =
  echo a
  a
""")
    check funcCandidates(f).len == 0

  test "does not flag a proc that is already a func":
    let f = write("func alreadyPure*(a: int): int = a\n")
    check funcCandidates(f).len == 0

  test "does not flag a proc with a var parameter":
    let f = write("""
proc mutates*(x: var int) =
  x = 1
""")
    check funcCandidates(f).len == 0

  test "does not flag a proc that assigns to a global":
    let f = write("""
var counter = 0
proc bumps*(a: int): int =
  counter = counter + a
  counter
""")
    check funcCandidates(f).len == 0
