import AIBackend

open AIBackend.Claude.Api

/-- Sends one prompt through the Claude API. The key comes from the Keychain.
Usage: `ask "<prompt>"`. -/
def main (args : List String) : IO Unit := do
  let c ← Client.fromKeychain
  let prompt := args.headD "State the definition of an even natural number in one sentence."
  IO.println (← c.ask prompt)
