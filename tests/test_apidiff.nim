import std/[unittest, os, sequtils]
import ../tools/api_tool

const Dir = "/tmp/claude-1000/-home-kl-prog-TEST-nimtools/ce257534-ab85-4122-b499-36dbb0623cb4/scratchpad/apidiff"

proc write(name, body: string): string =
  createDir(Dir)
  result = Dir / name
  writeFile(result, body)

suite "api-diff: what changed in the public surface":
  setup:
    removeDir(Dir); createDir(Dir)

  test "an added export is reported as added":
    let a = write("a.nim", "proc keep*(x: int): int = x\n")
    let b = write("b.nim", "proc keep*(x: int): int = x\nproc fresh*(y: int): int = y\n")
    let d = diffSurfaces(surfaceOf(a), surfaceOf(b))
    check d.added.mapIt(it.name) == @["fresh"]
    check d.removed.len == 0
    check not d.isBreaking

  test "a removed export is breaking":
    let a = write("a.nim", "proc keep*(x: int): int = x\nproc gone*(y: int): int = y\n")
    let b = write("b.nim", "proc keep*(x: int): int = x\n")
    let d = diffSurfaces(surfaceOf(a), surfaceOf(b))
    check d.removed.mapIt(it.name) == @["gone"]
    check d.isBreaking

  test "a changed signature is breaking":
    let a = write("a.nim", "proc f*(x: int): int = x\n")
    let b = write("b.nim", "proc f*(x, y: int): int = x\n")
    let d = diffSurfaces(surfaceOf(a), surfaceOf(b))
    check d.changed.len == 1
    check d.changed[0].name == "f"
    check d.isBreaking

  test "making a symbol private is a removal":
    let a = write("a.nim", "proc f*(x: int): int = x\n")
    let b = write("b.nim", "proc f(x: int): int = x\n")
    let d = diffSurfaces(surfaceOf(a), surfaceOf(b))
    check d.removed.mapIt(it.name) == @["f"]
    check d.isBreaking

  test "an identical surface reports no change":
    let a = write("a.nim", "proc f*(x: int): int = x\n")
    let b = write("b.nim", "proc f*(x: int): int = x\n")
    let d = diffSurfaces(surfaceOf(a), surfaceOf(b))
    check d.added.len == 0
    check d.removed.len == 0
    check d.changed.len == 0
    check not d.isBreaking

  test "a changed const value is breaking":
    let a = write("a.nim", "const Limit* = 10\n")
    let b = write("b.nim", "const Limit* = 20\n")
    let d = diffSurfaces(surfaceOf(a), surfaceOf(b))
    check d.changed.len == 1
    check d.isBreaking

  test "a private-only change is invisible":
    let a = write("a.nim", "proc f*(x: int): int = x\nproc hidden(y: int): int = y\n")
    let b = write("b.nim", "proc f*(x: int): int = x\n")
    let d = diffSurfaces(surfaceOf(a), surfaceOf(b))
    check d.added.len == 0
    check d.removed.len == 0
    check not d.isBreaking

  test "a dropped re-export is breaking":
    let a = write("a.nim", "import std/strutils\nexport strutils\n")
    let b = write("b.nim", "import std/strutils\n")
    let d = diffSurfaces(surfaceOf(a), surfaceOf(b))
    check d.removedReExports == @["strutils"]
    check d.isBreaking
