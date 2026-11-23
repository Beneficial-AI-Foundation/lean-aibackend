import AIBackend

open AIBackend.Claude.Api

/-- The two parts of the text. The second part depends on the first. -/
def parts : Array String := #[
  "A natural number n is even if n = 2k for some natural number k.",
  "The sum of two even natural numbers is even."]

def system : String :=
  "You formalize mathematical text in Lean 4 without Mathlib. " ++
  "Reply with Lean 4 code only, with no Markdown fence and no commentary. " ++
  "Do not use sorry. Reuse the declarations given as context."

/-- Formalizes each part in Lean 4 through the Claude API. Each request carries
the formalizations of the earlier parts as context. -/
def main : IO Unit := do
  let c ← Client.fromDefault
  let mut context := ""
  for h : i in [0:parts.size] do
    let prompt :=
      (if context.isEmpty then "" else s!"Context:\n{context}\n\n") ++
      s!"Formalize this text:\n{parts[i]}"
    let reply ← c.send #[.user prompt] system
    IO.println s!"-- A[{i}]: {parts[i]}\n{reply.text}\n"
    context := context ++ reply.text ++ "\n"
