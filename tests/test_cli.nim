import std/[unittest, os, osproc, strutils]

const Root = "/home/kl/prog/TEST/nimtools"
const Scratch = "/tmp/claude-1000/-home-kl-prog-TEST-nimtools/ce257534-ab85-4122-b499-36dbb0623cb4/scratchpad/cli"

proc run(args: string, workDir = Root): tuple[output: string, exitCode: int] =
  execCmdEx(Root / "nimtools " & args, workingDir = workDir)

suite "exit codes are agent-legible":
  setup:
    removeDir(Scratch); createDir(Scratch)
    writeFile(Scratch / "f.nim", "proc present*(): int =\n  1\n")

  test "missing file is an error, not success":
    check run("inspect " & Scratch / "nope.nim").exitCode == 1

  test "rename no-op succeeds":
    check run("rename-symbol " & Scratch / "f.nim absent other").exitCode == 0

  test "rename that changes something succeeds":
    check run("rename-symbol " & Scratch / "f.nim present renamed").exitCode == 0

  test "add-import to missing file is an error":
    check run("add-import " & Scratch / "nope.nim std/json").exitCode == 1

suite "delegation works outside project root":
  test "outline runs from another cwd":
    let r = run("outline " & Scratch / "f.nim", workDir = "/tmp")
    check r.exitCode == 0
    check "present" in r.output

  test "cyc runs from another cwd":
    check run("cyc " & Scratch / "f.nim", workDir = "/tmp").exitCode == 0

suite "outline writes to stdout by default":
  setup:
    removeDir(Scratch); createDir(Scratch)
    writeFile(Scratch / "g.nim", "proc present*(): int =\n  1\n")

  test "prints outline to stdout":
    let r = run("outline " & Scratch / "g.nim")
    check r.exitCode == 0
    check "present" in r.output

  test "does not create a sidecar file unless asked":
    discard run("outline " & Scratch / "g.nim")
    check not fileExists(Scratch / "g.outline.txt")

  test "-o still writes to a file":
    let outF = Scratch / "custom.txt"
    let r = run("outline " & Scratch / "g.nim -o:" & outF)
    check r.exitCode == 0
    check "present" in readFile(outF)
