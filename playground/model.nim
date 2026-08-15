import util

type
  Person* = object
    name*: string

proc describe*(p: Person): string =
  "hello " & clean(p.name)
