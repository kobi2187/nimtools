## organize-imports: deterministic sort (std, then third-party, then local
## relative) and dedupe of a file's import statements. Parser-only, no
## nimsuggest — same cost class as add-import/rm-import.

import std/[unittest, os, strutils]
import ../tools/organize_imports_tool

const Scratch = getTempDir() / "nimtools_test_organize_imports"

proc fixture(name, body: string): string =
  createDir(Scratch)
  result = Scratch / name
  writeFile(result, body)

suite "organize-imports":
  test "sorts std imports before local relative imports":
    let f = fixture("unsorted.nim", "import ./util\nimport std/os\nimport std/json\n\nproc f*() = discard\n")
    let r = organizeImports(f)
    check r.changed
    let text = readFile(f)
    check text.find("std/json") < text.find("std/os")   # alphabetical within group
    check text.find("std/os") < text.find("./util")      # std group before local group

  test "dedupes an exact-duplicate import":
    let f = fixture("dup.nim", "import std/os\nimport std/os\nimport std/json\n\nproc f*() = discard\n")
    let r = organizeImports(f)
    check r.changed
    let text = readFile(f)
    check text.count("std/os") == 1

  test "is a no-op success on an already-sorted, deduped file":
    let f = fixture("clean.nim", "import std/json\nimport std/os\n\nproc f*() = discard\n")
    discard organizeImports(f)  # normalize first
    let before = readFile(f)
    let r = organizeImports(f)
    check not r.changed
    check readFile(f) == before

  test "leaves non-import code untouched":
    let f = fixture("body.nim", "import std/os\nimport std/json\n\nproc f*(): int =\n  42\n")
    discard organizeImports(f)
    check "proc f*(): int" in readFile(f)
    check "42" in readFile(f)
