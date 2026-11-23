import AIBackend

open AIBackend

/-- Sends a few requests on one Claude API client and reports connection reuse. -/
def main (args : List String) : IO Unit := do
  let c ← Claude.Api.Client.fromDefault
  let prompt := args.headD "Reply with the single word OK."
  for i in [1:4] do
    let t0 ← IO.monoMsNow
    let r ← c.post (Claude.Api.Client.buildChatRequest #[.user prompt])
    let t1 ← IO.monoMsNow
    IO.println s!"request {i}: status={r.status} newConnections={r.newConnections} ms={t1 - t0}"
    if r.status != 200 then IO.println s!"  body={r.body}"
  IO.println s!"ask: {← c.ask prompt}"
