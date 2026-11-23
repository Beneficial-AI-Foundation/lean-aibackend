import AIBackend.Backend

/-! The Codex command line backend. It runs `codex exec <prompt>`, the
non-interactive mode of the Codex CLI. The reply carries the agent's full
transcript, not only a final answer. -/

namespace AIBackend.Codex.Cli

/-- Sends one prompt through `codex exec` and returns its output.
`model` passes `-c model=<model>`; the empty default uses the CLI's configuration. -/
def ask (prompt : String) (model : String := "") : IO String :=
  let modelArgs := if model.isEmpty then #[] else #["-c", s!"model={model}"]
  AIBackend.runProcess "codex" (#["exec"] ++ modelArgs ++ #[prompt])

/-- The Codex CLI as a uniform `Backend`. -/
def backend (model : String := "") : AIBackend.Backend :=
  { name := "codex/cli", ask := (ask · model) }

end AIBackend.Codex.Cli
