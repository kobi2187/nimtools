## syntax-check: the fast gate. Its whole value is that a broken file is
## reported as broken — `inspect` returned clean JSON and exit 0 on unparseable
## input because the parse diagnostics were computed and discarded.

import std/[unittest, os]
import ../tools/check_tool
import ../shared/compiler_env

const Scratch = getTempDir() / "nimtools_test_check"

proc fixture(name, body: string): string =
  createDir(Scratch)
  result = Scratch / name
  writeFile(result, body)

suite "syntax-check: verdicts":
  test "a well-formed file parses":
    let f = fixture("ok.nim", "proc f*(a: int): int =\n  result = a + 1\n")
    let c = checkFile(f)
    check c.ok
    check c.errors.len == 0

  test "a missing `:` is reported with a position":
    # `if a > 1` with no colon — the error inspect used to swallow.
    # The parser blames line 3, where the indented block makes the omission
    # unambiguous, not line 2 where a human would point. Position is the
    # compiler's, so assert what it actually reports rather than a guess.
    let f = fixture("bad.nim", "proc f*(a: int): int =\n" &
                               "  if a > 1\n" &
                               "    result = a\n")
    let c = checkFile(f)
    check not c.ok
    check c.errors.len > 0
    check c.errors[0].line == 3

  test "an unclosed bracket is reported":
    let f = fixture("unclosed.nim", "let x = @[1, 2, 3\n")
    check not checkFile(f).ok

  test "a missing file is a failure, not a silent pass":
    let c = checkFile(Scratch / "does_not_exist.nim")
    check not c.ok
    check c.errors.len > 0

suite "syntax-check: scope of the claim":
  test "a type error is NOT reported -- that needs nim check":
    # Syntactically perfect, semantically wrong. Documents the boundary so the
    # verdict is never read as "compiles".
    let f = fixture("typeerr.nim", "let x: int = \"not an int\"\n")
    check checkFile(f).ok

  test "an undeclared identifier is NOT reported":
    let f = fixture("undeclared.nim", "proc f*() =\n  echo totallyUndefined()\n")
    check checkFile(f).ok

  test "imports are never followed, so an unresolvable one still parses":
    # The point of the tool: a module mid-refactor still gives a syntax verdict.
    let f = fixture("badimport.nim",
                    "import no/such/module\nproc f*() = discard\n")
    check checkFile(f).ok

suite "structured parse diagnostics":
  test "compiler_env exposes line, col and message separately":
    let parsed = parseNimString("proc f*(a: int): int =\n  if a > 1\n" &
                                "    result = a\n", "t.nim")
    check parsed.diagnostics.len > 0
    check parsed.diagnostics[0].line == 3
    check parsed.diagnostics[0].message.len > 0

  test "the legacy prose errors are still populated":
    let parsed = parseNimString("let x = @[1, 2\n", "t.nim")
    check parsed.errors.len > 0
    check parsed.diagnostics.len == parsed.errors.len
