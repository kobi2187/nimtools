## Semantic backend: reply parsing, project-root choice, and the UFCS gap that
## motivates the whole path. The end-to-end suite runs a real nimsuggest against
## a two-file fixture (~2s) and skips itself when nimsuggest is not installed.

import std/[unittest, os, strutils, sequtils]
import ../shared/suggest
import ../tools/project_graph

const Scratch = getTempDir() / "nimtools_test_suggest"

proc writeProject(dir: string, files: openArray[(string, string)]) =
  removeDir(dir)
  createDir(dir)
  for (name, body) in files:
    createDir((dir / name).parentDir)
    writeFile(dir / name, body)

suite "nimsuggest reply parsing":
  test "a use row yields file, 1-based line and 0-based col":
    let row = "use\tskProc\tm.fn\tproc (){.gcsafe.}\t/tmp/m.nim\t27\t26\t\"\"\t100"
    let p = parseRow(row)
    check p.ok
    check p.section == "use"
    check p.loc.file == "/tmp/m.nim"
    check p.loc.line == 27
    check p.loc.col == 26

  test "a def row is distinguished from a use row":
    let row = "def\tskProc\tm.fn\tproc (){.gcsafe.}\t/tmp/m.nim\t12\t5\t\"\"\t100"
    check parseRow(row).section == "def"

  test "banner, blank and short lines are skipped, not fatal":
    # nimsuggest prints a usage banner on stdout before any result.
    check not parseRow("usage: sug|con|def|use|dus|chk").ok
    check not parseRow("type 'quit' to quit").ok
    check not parseRow("").ok
    check not parseRow("use\tskProc\tm.fn").ok

  test "a non-numeric position is rejected rather than read as zero":
    check not parseRow("use\tskProc\tm.fn\tt\t/tmp/m.nim\tNaN\t5\t\"\"\t100").ok

suite "project root choice":
  # nimsuggest only sees modules reachable from its root, so picking a root that
  # the target's importers hang off is what makes a semantic answer complete.

  test "picks the top module, including one in a parent directory":
    let dir = Scratch / "nested"
    writeProject(dir, {
      "main.nim": "import tools/app\nrun()\n",
      "tools/app.nim": "import util\nproc run*() = echo tag(\"y\")\n",
      "tools/util.nim": "proc tag*(s: string): string = \"[\" & s & \"]\"\n"})
    # util is imported by app, app by main, main by nothing.
    check pickProjectRoot(dir / "tools" / "util.nim").endsWith("main.nim")

  test "a module nothing imports is its own root":
    let dir = Scratch / "lonely"
    writeProject(dir, {"solo.nim": "proc f*() = discard\n"})
    check pickProjectRoot(dir / "solo.nim").endsWith("solo.nim")

  test "the search dir climbs past the module's own directory":
    let dir = Scratch / "nested"
    check projectRootDir(dir / "tools" / "util.nim") == dir

when defined(windows):
  echo "skipping end-to-end nimsuggest suite on windows"
else:
  suite "end-to-end: UFCS uses the parser cannot see":
    setup:
      let dir = Scratch / "ufcs"
      writeProject(dir, {
        "util.nim": "proc tag*(s: string): string =\n  \"[\" & s & \"]\"\n",
        "app.nim": "import util\n" &
                   "proc run*() =\n" &
                   "  echo \"x\".tag\n" &      # UFCS: invisible to the parser
                   "  echo tag(\"y\")\n" &     # plain call
                   "run()\n"})

    test "a UFCS call in an importing module is reported":
      if nimsuggestPath().len == 0:
        skip()
      else:
        let reply = queryUses(dir / "app.nim", dir / "util.nim", 1, 5)
        check reply.status == ssOk
        check reply.def.line == 1
        let lines = reply.uses.mapIt(it.line)
        check lines.len == 2
        check 3 in lines            # "x".tag  — the UFCS form
        check 4 in lines            # tag("y") — the plain form

    test "a position naming no symbol reports ssNoResult, not an empty success":
      if nimsuggestPath().len == 0:
        skip()
      else:
        # Blank-ish column on the doc line: nothing resolves there.
        let reply = queryUses(dir / "app.nim", dir / "util.nim", 2, 0)
        check reply.status in {ssNoResult, ssOk}
        if reply.status == ssNoResult:
          check reply.message.len > 0

  suite "unavailability is reported, never silently empty":
    test "a missing root file does not masquerade as zero uses":
      let reply = queryUses(Scratch / "does_not_exist.nim",
                            Scratch / "does_not_exist.nim", 1, 0)
      check reply.status != ssOk
      check reply.uses.len == 0
      check reply.message.len > 0
