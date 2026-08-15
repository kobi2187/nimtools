import std/strutils

proc clean*(s: string): string =
  toLowerAscii(strip(s))
