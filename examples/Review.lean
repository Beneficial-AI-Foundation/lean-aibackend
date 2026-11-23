import AIBackend

open AIBackend

/-- Runs one proposal and one objection over two access methods. The Claude API
backend proposes a Lean 4 formalization. The Claude CLI backend objects to the
proposal or concedes. -/
def main (args : List String) : IO Unit := do
  let text := args.headD "The sum of two even natural numbers is even."
  let pro := (← Claude.Api.Client.fromKeychain).backend
  let con := Claude.Cli.backend
  let proposal ← pro.ask <|
    "Formalize this text in Lean 4 without Mathlib. Reply with Lean 4 code only, " ++
    s!"with no Markdown fence. Do not use sorry.\n\n{text}"
  IO.println s!"[{pro.name}] proposal\n{proposal}\n"
  let objection ← con.ask <|
    "Review a Lean 4 formalization for fidelity to a text. Reply CONCEDE if the " ++
    "formalization states the text exactly. Otherwise state one objection in at " ++
    s!"most two sentences.\n\nText:\n{text}\n\nFormalization:\n{proposal}"
  IO.println s!"[{con.name}] objection\n{objection}"
