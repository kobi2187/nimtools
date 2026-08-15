import model
import util

proc main() =
  let p = Person(name: "  ADA ")
  echo describe(p)
  echo clean("  WORLD ")

when isMainModule:
  main()
