## change-signature: add/remove/reorder a proc's parameters and fix up every
## call site project-wide via the semantic engine (findSemanticReferences).
## One operation per invocation -- add, remove, or reorder, never combined --
## so each op's blast radius is independently reasoned about.

import std/[unittest, os, strutils]
import ../tools/change_signature_tool
import ../tools/project_graph
import ../shared/suggest

const Scratch = getTempDir() / "nimtools_test_change_signature"

proc writeProject(dir: string, files: openArray[(string, string)]) =
  removeDir(dir)
  createDir(dir)
  for (name, body) in files:
    createDir((dir / name).parentDir)
    writeFile(dir / name, body)

when defined(windows):
  echo "skipping end-to-end change-signature suite on windows"
else:
  suite "change-signature --add-param":
    test "adds a defaulted param to the decl; call sites are untouched":
      if nimsuggestPath().len == 0:
        skip()
      else:
        let dir = Scratch / "add"
        writeProject(dir, {
          "lib.nim": "proc greet*(name: string): string =\n  \"hi \" & name\n",
          "app.nim": "import lib\necho greet(\"x\")\n"})
        let r = addParam(dir / "lib.nim", pickProjectRoot(dir / "lib.nim"), 1, 5,
                         "loud", "bool", "false")
        check r.status == csApplied
        check "loud: bool = false" in readFile(dir / "lib.nim")
        check readFile(dir / "app.nim") == "import lib\necho greet(\"x\")\n"

  suite "change-signature --remove-param":
    test "removes a param when every call site passes a bare literal or ident":
      if nimsuggestPath().len == 0:
        skip()
      else:
        let dir = Scratch / "remove_safe"
        writeProject(dir, {
          "lib.nim": "proc greet*(name: string, loud: bool): string =\n  name\n",
          "app.nim": "import lib\nlet x = true\necho greet(\"a\", x)\necho greet(\"b\", false)\n"})
        let r = removeParam(dir / "lib.nim", pickProjectRoot(dir / "lib.nim"), 1, 5, "loud")
        check r.status == csApplied
        check "loud" notin readFile(dir / "lib.nim").splitLines[0]
        check "greet(\"a\")" in readFile(dir / "app.nim")
        check "greet(\"b\")" in readFile(dir / "app.nim")

    test "refuses when a call site's argument could have a side effect":
      if nimsuggestPath().len == 0:
        skip()
      else:
        let dir = Scratch / "remove_unsafe"
        writeProject(dir, {
          "lib.nim": "proc greet*(name: string, loud: bool): string =\n  name\n",
          "app.nim": "import lib\nproc mkLoud(): bool = true\necho greet(\"a\", mkLoud())\n"})
        let r = removeParam(dir / "lib.nim", pickProjectRoot(dir / "lib.nim"), 1, 5, "loud")
        check r.status == csRefused
        check r.blockedSites.len == 1
        check "loud" in readFile(dir / "lib.nim")   # decl NOT rewritten on refusal

    test "force removes anyway, dropping the side-effecting argument":
      if nimsuggestPath().len == 0:
        skip()
      else:
        let dir = Scratch / "remove_force"
        writeProject(dir, {
          "lib.nim": "proc greet*(name: string, loud: bool): string =\n  name\n",
          "app.nim": "import lib\nproc mkLoud(): bool = true\necho greet(\"a\", mkLoud())\n"})
        let r = removeParam(dir / "lib.nim", pickProjectRoot(dir / "lib.nim"), 1, 5, "loud", force = true)
        check r.status == csApplied
        check "greet(\"a\")" in readFile(dir / "app.nim")

  suite "change-signature --reorder":
    test "reorders positional args at call sites; named args are untouched":
      if nimsuggestPath().len == 0:
        skip()
      else:
        let dir = Scratch / "reorder"
        writeProject(dir, {
          "lib.nim": "proc greet*(a: string, b: int): string =\n  a\n",
          "app.nim": "import lib\necho greet(\"x\", 1)\necho greet(b = 2, a = \"y\")\n"})
        let r = reorderParams(dir / "lib.nim", pickProjectRoot(dir / "lib.nim"), 1, 5, @["b", "a"])
        check r.status == csApplied
        let libText = readFile(dir / "lib.nim")
        check libText.find("b: int") < libText.find("a: string")
        let appText = readFile(dir / "app.nim")
        check "greet(1, \"x\")" in appText
        check "greet(b = 2, a = \"y\")" in appText   # named call untouched
