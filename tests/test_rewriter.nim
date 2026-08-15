import std/[unittest, strutils]
import ../shared/source_rewriter

suite "line endings are preserved":
  test "CRLF file keeps CRLF after rename":
    let src = "proc target*(): int =\r\n  result = 1\r\n"
    let got = renameTokenStream(src, "target", "renamed")
    check "renamed" in got
    check got.count("\r\n") == 2

  test "LF file stays LF after rename":
    let src = "proc target*(): int =\n  result = 1\n"
    let got = renameTokenStream(src, "target", "renamed")
    check "renamed" in got
    check '\r' notin got

  test "replaceLineRange preserves CRLF":
    let src = "a\r\nb\r\nc\r\n"
    let got = replaceLineRange(src, 2, 2, "B")
    check got.count("\r\n") == 3
