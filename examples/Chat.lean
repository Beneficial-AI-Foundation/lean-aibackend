import AIBackend

open AIBackend.Claude.Api

/-- Holds a three-turn conversation with a system prompt on one Claude API
client. Each request replays the earlier turns, so the model reads the whole
conversation. -/
def main : IO Unit := do
  let c ← Client.fromKeychain
  let system := "You are a concise tutor of the Lean 4 proof assistant. Answer in at most three sentences."
  let questions := #[
    "What is a structure in Lean 4?",
    "How does it differ from an inductive type?",
    "Give a one-line example of the first notion."]
  let mut history : Array Message := #[]
  for q in questions do
    history := history.push (.user q)
    let reply ← c.send history system
    history := history.push reply.toMessage
    IO.println s!"user: {q}"
    IO.println s!"claude: {reply.text}\n"
