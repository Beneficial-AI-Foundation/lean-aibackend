import AIBackend.Backend

/-! The Codex command line backend. It runs `codex exec -`, the
non-interactive mode of the Codex CLI. The prompt travels through a pipe on
stdin, so it occurs in no argument list. The reply carries the agent's full
transcript, not only a final answer. -/

namespace AIBackend.Codex.Cli

/-- Sends one prompt through `codex exec` and returns its output. The prompt
reaches the CLI on stdin, which the argument `-` selects. `model` passes
`-c model=<model>`; the empty default uses the CLI's configuration.

The prompt must be nonempty. The model name must not start with `-`, which the
CLI would read as an option. -/
def ask (prompt : String) (model : String := "") : IO String := do
  ensure (!prompt.isEmpty) "the prompt is empty"
  ensure (!model.startsWith "-") "the model name starts with a dash"
  let modelArgs := if model.isEmpty then #[] else #["-c", s!"model={model}"]
  AIBackend.runProcess "codex" (#["exec"] ++ modelArgs ++ #["-"]) (some prompt)

/-- The Codex CLI as a uniform `Backend`. -/
def backend (model : String := "") : AIBackend.Backend :=
  { name := "codex/cli", ask := (ask · model) }

end AIBackend.Codex.Cli
