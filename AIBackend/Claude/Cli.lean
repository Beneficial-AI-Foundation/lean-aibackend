import AIBackend.Backend

/-! The Claude command line backend. It runs `claude -p <prompt>` as a
subprocess, so it needs no `ANTHROPIC_API_KEY`. There is no connection reuse. -/

namespace AIBackend.Claude.Cli

/-- Sends one prompt through the `claude` CLI and returns the reply text.
`model` passes `--model`; the empty default lets the CLI choose. -/
def ask (prompt : String) (model : String := "") : IO String :=
  let modelArgs := if model.isEmpty then #[] else #["--model", model]
  AIBackend.runProcess "claude" (#["-p", prompt] ++ modelArgs)

/-- The Claude CLI as a uniform `Backend`. -/
def backend (model : String := "") : AIBackend.Backend :=
  { name := "claude/cli", ask := (ask · model) }

end AIBackend.Claude.Cli
