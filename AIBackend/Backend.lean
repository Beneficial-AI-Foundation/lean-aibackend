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

/-- A run time check of a precondition. Raises an `IO` error when `cond` is
false. The check stays active in every build. -/
def ensure (cond : Bool) (msg : String) : IO Unit :=
  unless cond do throw (IO.userError s!"precondition violated: {msg}")

/-- Whether `s` holds only printable ASCII characters other than the space. -/
def isPrintableAscii (s : String) : Bool :=
  s.all fun c => 0x21 ≤ c.toNat && c.toNat ≤ 0x7e

/-- The default time limit of a subprocess, in milliseconds. -/
def defaultTimeoutMs : Nat := 600000

/-- Runs a command non-interactively and returns its exit code, its stdout
and its stderr. The optional `input?` reaches the command through a pipe on
stdin, so it occurs in no argument list. A nonzero exit code is a result, not
an error.

The command runs in a session of its own, without a terminal. When it does not
finish within `timeoutMs` milliseconds, the helper ends its whole process
group and raises an `IO` error.

The command must be nonempty, no argument may hold a NUL character, and the
time limit must be positive. -/
def runProcessOutput (cmd : String) (args : Array String) (input? : Option String := none)
    (timeoutMs : Nat := defaultTimeoutMs) : IO IO.Process.Output := do
  ensure (!cmd.isEmpty) "the command is empty"
  ensure ((cmd :: args.toList).all (!·.contains '\x00')) "an argument holds a NUL character"
  ensure (timeoutMs > 0) "the time limit is zero"
  let spawned ← IO.Process.spawn {
    cmd, args, stdin := .piped, stdout := .piped, stderr := .piped, setsid := true }
  let (stdin, child) ← spawned.takeStdin
  -- The readers start before the input goes out, so no pipe fills up unread.
  let stdout ← IO.asTask child.stdout.readToEnd Task.Priority.dedicated
  let stderr ← IO.asTask child.stderr.readToEnd Task.Priority.dedicated
  let finished ← IO.mkRef false
  let timedOut ← IO.mkRef false
  let _ ← IO.asTask (prio := .dedicated) do
    let start ← IO.monoMsNow
    while !(← finished.get) && (← IO.monoMsNow) - start < timeoutMs do
      IO.sleep 50
    unless (← finished.get) do
      timedOut.set true
      child.kill
  -- The handle of stdin closes when its last use ends, which the command reads as the end of input.
  let writeInput : IO Unit := do
    if let some input := input? then
      stdin.putStr input
      stdin.flush
  -- A command that ends early closes the pipe. Its exit code reports the cause.
  try writeInput catch _ => pure ()
  let exitCode ← child.wait
  finished.set true
  if ← timedOut.get then
    throw (IO.userError s!"{cmd} did not finish within {timeoutMs} ms")
  return { exitCode, stdout := ← IO.ofExcept stdout.get, stderr := ← IO.ofExcept stderr.get }

/-- Runs a command as `runProcessOutput` does and returns its trimmed stdout.
Raises an `IO` error on a nonzero exit, carrying stderr. -/
def runProcess (cmd : String) (args : Array String) (input? : Option String := none)
    (timeoutMs : Nat := defaultTimeoutMs) : IO String := do
  let out ← runProcessOutput cmd args input? timeoutMs
  if out.exitCode != 0 then
    throw (IO.userError s!"{cmd} exited with {out.exitCode}: {out.stderr}")
  return out.stdout.trimAsciiEnd.toString

end AIBackend
