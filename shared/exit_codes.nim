## Exit-code contract for every nimtools command.
##
## Agents cannot see a diff, so the exit code has to carry the outcome.
## The distinction that matters: "nothing needed changing" is SUCCESS, and a
## refusal is neither success nor a crash — it means the tool understood the
## request and declined because carrying it out would produce broken code.

const
  ExitOk* = 0        ## completed: changed something, or correctly did nothing
  ExitError* = 1     ## bad input: missing file, parse failure, symbol not found
  ExitRefused* = 2   ## understood, declined: would emit non-compiling code
