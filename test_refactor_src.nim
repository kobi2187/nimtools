import std/strutils

type
  Person = object
    name: string
    age: int

proc greetPerson(p: Person): string =
  result = "Hello, " & p.name

proc calculateAgeNextYear(p: Person): int =
  result = p.age + 1

proc main() =
  let p = Person(name: "Alice", age: 30)
  echo greetPerson(p)
  echo "Next year: ", calculateAgeNextYear(p)
