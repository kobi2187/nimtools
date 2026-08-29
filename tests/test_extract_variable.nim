## extract-variable: pulls the expression at one column span into a `let`
## above its containing statement. Deliberately narrow for this pass -- only
## the exact selected span is replaced; textually-identical occurrences
## elsewhere in the function are left alone (flagged in the design spec as
## needing refinement later).

import std/[unittest, os, strutils]
import ../tools/extract_variable_tool

const Scratch = getTempDir() / "nimtools_test_extract_variable"

proc fixture(name, body: string): string =
  createDir(Scratch)
  result = Scratch / name
  writeFile(result, body)

suite "extract-variable":
  test "extracts a simple call expression into a let above its statement":
    let f = fixture("simple.nim",
      "proc f*(a: int): int =\n" &
      "  echo compute(a) + 1\n" &
      "  0\n")
    # "compute(a)" spans columns 7..17 (0-based, end exclusive) on line 2.
    let r = extractVariable(f, 2, 7, 17, "tmp")
    check r.ok
    let text = readFile(f)
    check "let tmp = compute(a)" in text
    check "echo tmp + 1" in text

  test "does not touch a second identical occurrence elsewhere":
    let f = fixture("dup.nim",
      "proc f*(a: int): int =\n" &
      "  echo compute(a) + compute(a)\n" &
      "  0\n")
    let r = extractVariable(f, 2, 7, 17, "tmp")
    check r.ok
    let text = readFile(f)
    # One occurrence became "let tmp = compute(a)"; the second is untouched --
    # so the substring still appears twice total (once in each), and the
    # original statement line keeps exactly one live call plus the new "tmp".
    check text.count("compute(a)") == 2
    check "let tmp = compute(a)" in text
    check "echo tmp + compute(a)" in text

  test "fails on an out-of-range column span":
    let f = fixture("short.nim", "proc f*(): int =\n  1\n")
    let r = extractVariable(f, 2, 0, 999, "tmp")
    check not r.ok

  test "fails when the file does not parse":
    let f = fixture("broken.nim", "proc f*(: int =\n")
    let r = extractVariable(f, 1, 0, 5, "tmp")
    check not r.ok
