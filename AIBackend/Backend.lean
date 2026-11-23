/-! The uniform interface over an AI assistant backend, and a subprocess helper
shared by the command line backends. Each tool lives in its own namespace
(`AIBackend.Claude`, `AIBackend.Codex`, `AIBackend.Gemini`), and each access
method (`.Api`, `.Cli`) exposes a `Backend`. -/

namespace AIBackend

/-- A backend that answers a prompt, whatever the tool or transport behind it. -/
structure Backend where
  /-- An identifier such as `"claude/api"` or `"codex/cli"`. -/
  name : String
  /-- Sends one prompt and returns the reply text. -/
  ask : String → IO String

/-- Runs a command non-interactively and returns its trimmed stdout.
Raises an `IO` error on a nonzero exit, carrying stderr. -/
def runProcess (cmd : String) (args : Array String) : IO String := do
  let out ← IO.Process.output { cmd, args }
  if out.exitCode != 0 then
    throw (IO.userError s!"{cmd} exited with {out.exitCode}: {out.stderr}")
  return out.stdout.trimAsciiEnd.toString

end AIBackend
