import AIBackend.Backend

/-! The Gemini command line backend. It runs `gemini -p <prompt>`, the
non-interactive mode of the Gemini CLI. -/

namespace AIBackend.Gemini.Cli

/-- Sends one prompt through the `gemini` CLI and returns the reply text.
`model` passes `-m`; the empty default lets the CLI choose. -/
def ask (prompt : String) (model : String := "") : IO String :=
  let modelArgs := if model.isEmpty then #[] else #["-m", model]
  AIBackend.runProcess "gemini" (#["-p", prompt] ++ modelArgs)

/-- The Gemini CLI as a uniform `Backend`. -/
def backend (model : String := "") : AIBackend.Backend :=
  { name := "gemini/cli", ask := (ask · model) }

end AIBackend.Gemini.Cli
