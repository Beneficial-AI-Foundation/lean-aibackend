import AIBackend

open AIBackend

/-- Runs the same prompt through every available CLI backend. -/
def main : IO Unit := do
  let backends : List Backend := [Claude.Cli.backend, Codex.Cli.backend, Gemini.Cli.backend]
  for b in backends do
    try
      IO.println s!"[{b.name}] {← b.ask "Reply with the single word OK."}"
    catch e =>
      IO.println s!"[{b.name}] error: {e}"
