import AIBackend

open AIBackend

/-- Sends the same prompt through the Claude API backend and the Claude CLI
backend, behind the uniform `Backend` interface, and reports the time of each. -/
def main (args : List String) : IO Unit := do
  let prompt := args.headD "Name the axioms that Lean 4 treats as standard. Answer in one line."
  let api ← Claude.Api.Client.fromKeychain
  let backends : List Backend := [api.backend, Claude.Cli.backend]
  for b in backends do
    let t0 ← IO.monoMsNow
    try
      let answer ← b.ask prompt
      IO.println s!"[{b.name}] {(← IO.monoMsNow) - t0} ms\n{answer}\n"
    catch e =>
      IO.println s!"[{b.name}] error: {e}\n"
