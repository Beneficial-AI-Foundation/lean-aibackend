import AIBackend

open AIBackend.Claude.Api

/-- A mutable count of failures, reported at the end. -/
abbrev Failures := IO.Ref Nat

def check (f : Failures) (name : String) (cond : Bool) (detail : String := "") : IO Unit := do
  unless cond do
    f.modify (· + 1)
    IO.eprintln s!"FAIL {name} {detail}"

/-- A small deterministic linear congruential generator, so the suite is reproducible. -/
def lcg (s : UInt64) : UInt64 := s * 6364136223846793005 + 1442695040888963407

/-- A sample of code points that exercises ASCII, Latin, CJK, and non-BMP (emoji). -/
def sampleChars : Array Char :=
  #['a', 'Z', '0', ' ', '"', '\\', '/', '\n', '\t',
    'é', 'ß', 'λ', '𝔾', 'ℤ', '•', 'π', '中', '日', '😀', '🧪']

/-- Builds a pseudo-random string of printable and special characters from a seed. -/
def randString (seed : UInt64) (len : Nat) : String := Id.run do
  let mut s := seed
  let mut acc := ""
  for _ in [0:len] do
    s := lcg s
    let idx := (s >>> 16).toNat % sampleChars.size
    acc := acc.push sampleChars[idx]!
  return acc

def main : IO Unit := do
  let key := "test-key-" ++ toString (← IO.monoNanosNow)
  -- Start the mock server and read the port it prints.
  let child ← IO.Process.spawn {
    cmd := "python3"
    args := #["-I", "tests/mock_server.py", key]
    stdout := .piped, stdin := .null }
  let out := child.stdout
  let portLine ← out.getLine
  let port := portLine.trimAscii.toString
  let url := s!"http://127.0.0.1:{port}/v1/messages"
  let failures ← IO.mkRef 0

  try
    let c ← Client.new key url
    -- 1. Pure parseText and buildRequest cases, no network.
    check failures "parse/empty-content" ((Client.parseText "{\"content\":[]}").toOption == some "")
    check failures "parse/non-text-block"
      ((Client.parseText "{\"content\":[{\"type\":\"thinking\",\"text\":\"x\"}]}").toOption == some "")
    check failures "parse/two-blocks"
      ((Client.parseText "{\"content\":[{\"type\":\"text\",\"text\":\"a\"},{\"type\":\"text\",\"text\":\"b\"}]}").toOption == some "ab")
    check failures "parse/bad-json" (Client.parseText "not json").toOption.isNone
    let req := Client.buildRequest "hi" "m" 7
    check failures "build/model" ((req.getObjValAs? String "model").toOption == some "m")
    check failures "build/max" ((req.getObjValAs? Nat "max_tokens").toOption == some 7)

    -- 2. Error statuses map to a raised IO error through `ask`.
    for st in [400, 401, 403, 404, 429, 500, 529] do
      let threw ← (do let _ ← c.ask "x" s!"status-{st}"; pure false) <|> pure true
      check failures s!"status/{st}-raises" threw

    -- 3. Round trip of 1000 random prompts, echoed and compared exactly.
    let mut seed : UInt64 := 0x123456789
    let mut reused := 0
    for i in [0:1000] do
      seed := lcg seed
      let len := (seed >>> 8).toNat % 40
      let prompt := randString seed len
      let r ← c.post (Client.buildRequest prompt "echo-utf8" 16)
      check failures s!"echo/{i}/status" (r.status == 200)
      if r.newConnections == 0 then reused := reused + 1
      match Client.parseText r.body with
      | .ok t => check failures s!"echo/{i}/roundtrip" (t == prompt) s!"got={t.length} want={prompt.length}"
      | .error e => check failures s!"echo/{i}/parse" false e

    -- 4. A large body, to check the length-aware string constructor.
    let big ← c.ask "x" "big-100000"
    check failures "big/length" (big.length == 100000)

    let fails ← failures.get
    IO.println s!"connection reuse on echo cases: {reused}/1000"
    if fails == 0 then
      IO.println "all tests passed"
    else
      IO.eprintln s!"{fails} test(s) failed"
  finally
    child.kill
  let fails ← failures.get
  if fails != 0 then throw (IO.userError s!"{fails} failures")
