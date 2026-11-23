import AIBackend.Backend

/-! The Gemini command line backend. It runs `gemini -p <prompt>`, the
non-interactive mode of the Gemini CLI. The prompt is an argument of the
command, so the process table shows it to other local users. -/

namespace AIBackend.Gemini.Cli

/-- Sends one prompt through the `gemini` CLI and returns the reply text.
`model` passes `-m`; the empty default lets the CLI choose.

The prompt must be nonempty. Neither the prompt nor the model name may start
with `-`, which the CLI would read as an option. -/
def ask (prompt : String) (model : String := "") : IO String := do
  ensure (!prompt.isEmpty) "the prompt is empty"
  ensure (!prompt.startsWith "-") "the prompt starts with a dash"
  ensure (!model.startsWith "-") "the model name starts with a dash"
  let modelArgs := if model.isEmpty then #[] else #["-m", model]
  AIBackend.runProcess "gemini" (#["-p", prompt] ++ modelArgs)

/-- The Gemini CLI as a uniform `Backend`. -/
def backend (model : String := "") : AIBackend.Backend :=
  { name := "gemini/cli", ask := (ask · model) }

end AIBackend.Gemini.Cli
