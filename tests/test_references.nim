import std/[unittest, os, strutils, sequtils]
import ../tools/[references_tool, rename_tool]

const Dir = "/tmp/claude-1000/-home-kl-prog-TEST-nimtools/ce257534-ab85-4122-b499-36dbb0623cb4/scratchpad/refs"

proc setupFiles() =
  removeDir(Dir); createDir(Dir)
  writeFile(Dir / "util.nim", """
proc exportedFn*(x: int): int = x
proc privateFn(x: int): int = x
""")
  writeFile(Dir / "model.nim", """
import util
proc caller(): int = exportedFn(1)
""")
  writeFile(Dir / "app.nim", """
import model
import util
proc main() =
  echo exportedFn(2)
""")

suite "cross-file references":
  setup: setupFiles()

  test "finds uses in every importing module":
    let r = findProjectReferences(Dir / "util.nim", "exportedFn")
    let files = r.files.mapIt(it.file.extractFilename)
    check "util.nim" in files
    check "model.nim" in files
    check "app.nim" in files
    let model = r.files.filterIt(it.file.endsWith("model.nim"))[0]
    let app = r.files.filterIt(it.file.endsWith("app.nim"))[0]
    check model.uses.len == 1
    check app.uses.len == 1

  test "a private symbol yields no cross-file uses":
    let r = findProjectReferences(Dir / "util.nim", "privateFn")
    check r.files.len == 1
    check r.files[0].file.endsWith("util.nim")

  test "unknown symbol yields no files":
    check findProjectReferences(Dir / "util.nim", "nosuch").files.len == 0

  test "a local binding in an importer is not mistaken for the import":
    # app.nim shadows exportedFn with its own proc: uses resolve locally, so
    # they must not be reported as references to util's exportedFn.
    writeFile(Dir / "app.nim", """
import util
proc exportedFn(x: int): int = x
proc main() =
  echo exportedFn(2)
""")
    let r = findProjectReferences(Dir / "util.nim", "exportedFn")
    let app = r.files.filterIt(it.file.endsWith("app.nim"))
    check app.len == 0

suite "cross-file rename":
  setup: setupFiles()

  test "renames the definition and every importing use":
    let r = renameProjectScoped(Dir / "util.nim", "exportedFn", "renamedFn", 1, 5)
    check r.status == srRenamed
    check "renamedFn" in readFile(Dir / "util.nim")
    check "exportedFn" notin readFile(Dir / "util.nim")
    check "renamedFn(1)" in readFile(Dir / "model.nim")
    check "renamedFn(2)" in readFile(Dir / "app.nim")

  test "refuses when the symbol is private":
    let r = renameProjectScoped(Dir / "util.nim", "privateFn", "x", 2, 5)
    check r.status == srNotFound

  test "refuses when another module also exports the name":
    writeFile(Dir / "other.nim", "proc exportedFn*(x: int): int = x\n")
    let r = renameProjectScoped(Dir / "util.nim", "exportedFn", "y", 1, 5)
    check r.status == srConflict

  test "leaves a shadowing local in an importer alone":
    writeFile(Dir / "app.nim", """
import util
proc exportedFn(x: int): int = x
proc main() =
  echo exportedFn(2)
""")
    let r = renameProjectScoped(Dir / "util.nim", "exportedFn", "renamedFn", 1, 5)
    check r.status == srRenamed
    # app.nim's own exportedFn is a different binding and must be untouched
    check "proc exportedFn" in readFile(Dir / "app.nim")
    check "renamedFn(1)" in readFile(Dir / "model.nim")
