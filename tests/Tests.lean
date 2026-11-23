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

/-- Whether an action raises an `IO` error. -/
def raises {α : Type} (act : IO α) : IO Bool := do
  try
    let _ ← act
    return false
  catch _ => return true

/-- Sends one request to `url` and returns the HTTP status, or the text of the
`IO` error that the client raised. -/
def probe (key url : String) : IO (Except String UInt32) := do
  try
    let c ← Client.new key url
    let r ← c.post (Client.buildRequest "x" "m" 1)
    return .ok r.status
  catch e => return .error (toString e)

/-- Whether an error text reports a TLS failure, as opposed to a failure of
name resolution or of the TCP connection. -/
def isTlsError (e : String) : Bool :=
  (e.splitOn "SSL").length > 1 || (e.splitOn "TLS").length > 1

/-- The TLS cases, which run with real servers over the network. Every request
carries the generated test key, never a real key. The hosts of badssl.com
serve deliberately defective TLS configurations. -/
def tlsCases (failures : Failures) (key : String) : IO Unit := do
  -- The real API host completes the handshake and answers the unknown key with 401.
  match ← probe key Client.endpoint with
  | .ok st => check failures "tls/api-host-401" (st == 401) s!"status={st}"
  | .error e => check failures "tls/api-host-401" false e
  -- A TLS 1.2 host is the control for the two version cases below.
  match ← probe key "https://tls-v1-2.badssl.com:1012/" with
  | .ok _ => pure ()
  | .error e => check failures "tls/accepts-tls-1.2" false e
  -- The client refuses a defective certificate and a TLS version below 1.2.
  for (name, url) in [
      ("expired-certificate", "https://expired.badssl.com/"),
      ("wrong-host-name", "https://wrong.host.badssl.com/"),
      ("self-signed-certificate", "https://self-signed.badssl.com/"),
      ("untrusted-root", "https://untrusted-root.badssl.com/"),
      ("tls-1.0", "https://tls-v1-0.badssl.com:1010/"),
      ("tls-1.1", "https://tls-v1-1.badssl.com:1011/")] do
    match ← probe key url with
    | .ok st => check failures s!"tls/rejects-{name}" false s!"status={st}"
    | .error e => check failures s!"tls/rejects-{name}" (isTlsError e) e

def main : IO Unit := do
  let key := "test-key-" ++ toString (← IO.monoNanosNow)
  -- Generate a certificate for 127.0.0.1, valid for two days. The mock server
  -- presents it, and the client trusts it through `caFile`.
  let tlsDir : System.FilePath := ".lake" / "build" / "tls-test"
  IO.FS.createDirAll tlsDir
  let cert := (tlsDir / "cert.pem").toString
  let certKey := (tlsDir / "key.pem").toString
  let gen ← IO.Process.output {
    cmd := "openssl"
    args := #["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", certKey, "-out", cert,
              "-days", "2", "-subj", "/CN=127.0.0.1", "-addext", "subjectAltName=IP:127.0.0.1"] }
  if gen.exitCode != 0 then throw (IO.userError s!"openssl failed: {gen.stderr}")
  -- Start the mock server and read the port it prints.
  let child ← IO.Process.spawn {
    cmd := "python3"
    args := #["-I", "tests/mock_server.py", key, cert, certKey]
    stdout := .piped, stdin := .null }
  let out := child.stdout
  let portLine ← out.getLine
  let port := portLine.trimAscii.toString
  let url := s!"https://127.0.0.1:{port}/v1/messages"
  let failures ← IO.mkRef 0

  try
    let c ← Client.new key url cert
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

    -- 1b. The client refuses every URL without the https scheme, loopback included.
    for bad in ["http://example.com/v1/messages", "http://127.0.0.1@example.com/v1/messages",
                "http://localhost:1/v1/messages", s!"http://127.0.0.1:{port}/v1/messages",
                "http://[::1]:1/v1/messages", "ftp://127.0.0.1/v1/messages", "not a url",
                "https://", "HTTP://example.com/"] do
      check failures s!"url/rejects {bad}" (← raises (Client.new key bad))
    check failures "url/accepts-https" (!(← raises (Client.new key Client.endpoint)))

    -- 1d. Each precondition has a run time check.
    check failures "pre/empty-key" (← raises (Client.new "" url cert))
    check failures "pre/key-with-newline" (← raises (Client.new "a\r\nx-evil: 1" url cert))
    check failures "pre/key-with-space" (← raises (Client.new "a b" url cert))
    check failures "pre/key-with-nul" (← raises (Client.new "a\x00b" url cert))
    check failures "pre/key-non-ascii" (← raises (Client.new "clé" url cert))
    check failures "pre/missing-ca-file" (← raises (Client.new key url (cert ++ ".absent")))
    check failures "pre/empty-helper" (← raises (Client.fromCommand ""))
    check failures "pre/failing-helper" (← raises (Client.fromCommand "false"))
    check failures "pre/empty-helper-output" (← raises (Client.fromCommand "true"))
    check failures "pre/empty-service" (← raises (Client.fromKeychain ""))
    check failures "pre/empty-service-default" (KeySource.platformDefault "").toOption.isNone
    check failures "pre/empty-prompt" (← raises (c.ask ""))
    check failures "pre/empty-conversation" (← raises (c.send #[]))
    check failures "pre/unknown-role" (← raises (c.send #[{ role := "system", content := "x" }]))
    check failures "pre/empty-model" (← raises (c.ask "x" ""))
    check failures "pre/zero-max-tokens" (← raises (c.ask "x" "echo-utf8" 0))
    check failures "pre/empty-body" (← raises (c.postRaw ""))
    check failures "pre/body-with-nul" (← raises (c.postRaw "{\"a\":\"\x00\"}"))
    check failures "pre/empty-command" (← raises (AIBackend.runProcess "" #[]))
    check failures "pre/zero-time-limit" (← raises (AIBackend.runProcess "true" #[] none 0))
    -- The subprocess helper passes the input on stdin, reports a failure and enforces the time limit.
    check failures "process/stdin" ((← AIBackend.runProcess "cat" #[] (some "λ input")) == "λ input")
    check failures "process/no-input" ((← AIBackend.runProcess "cat" #[]) == "")
    check failures "process/large-input"
      ((← AIBackend.runProcess "wc" #["-c"] (some ("".pushn 'x' 300000))).trimAscii.toString == "300000")
    check failures "process/failure" (← raises (AIBackend.runProcess "false" #[]))
    check failures "process/missing-command" (← raises (AIBackend.runProcess "no-such-command-xyz" #[]))
    let started ← IO.monoMsNow
    let late ← (do let _ ← AIBackend.runProcess "sleep" #["30"] none 400; pure "") <|>
      pure "raised"
    check failures "process/time-limit" (late == "raised")
    check failures "process/time-limit-prompt" ((← IO.monoMsNow) - started < 5000)
      (toString ((← IO.monoMsNow) - started))
    check failures "pre/cli-empty-prompt" (← raises (AIBackend.Claude.Cli.ask ""))
    check failures "pre/cli-model-dash" (← raises (AIBackend.Claude.Cli.ask "x" "--help"))
    check failures "pre/codex-empty-prompt" (← raises (AIBackend.Codex.Cli.ask ""))
    check failures "pre/codex-model-dash" (← raises (AIBackend.Codex.Cli.ask "x" "--help"))
    check failures "pre/gemini-empty-prompt" (← raises (AIBackend.Gemini.Cli.ask ""))
    check failures "pre/gemini-prompt-dash" (← raises (AIBackend.Gemini.Cli.ask "--help"))
    check failures "pre/gemini-model-dash" (← raises (AIBackend.Gemini.Cli.ask "x" "--help"))

    -- 1e. The transport check of the Claude CLI backend.
    let violation := AIBackend.Claude.Cli.transportViolation
    check failures "cli/empty-env" (violation []).isNone
    check failures "cli/https-base-url" (violation [("ANTHROPIC_BASE_URL", "https://example.com")]).isNone
    check failures "cli/http-base-url" (violation [("ANTHROPIC_BASE_URL", "http://example.com")]).isSome
    check failures "cli/http-loopback-base-url"
      (violation [("ANTHROPIC_BASE_URL", "http://127.0.0.1:8080")]).isSome
    check failures "cli/http-bedrock-url"
      (violation [("ANTHROPIC_BEDROCK_BASE_URL", "http://example.com")]).isSome
    check failures "cli/validation-off" (violation [("NODE_TLS_REJECT_UNAUTHORIZED", "0")]).isSome
    check failures "cli/validation-on" (violation [("NODE_TLS_REJECT_UNAUTHORIZED", "1")]).isNone
    check failures "cli/unrelated-variable" (violation [("HOME", "http://example.com")]).isNone

    -- 1f. Without `caFile` the client refuses the certificate of the mock server.
    match ← probe key url with
    | .ok st => check failures "tls/rejects-untrusted-mock" false s!"status={st}"
    | .error e => check failures "tls/rejects-untrusted-mock" (isTlsError e) e

    -- 1c. The key configuration of lakefile.lean reaches the program, and the
    -- helper matches the operating system.
    check failures "key/service-nonempty" (!keyService.isEmpty)
    match KeySource.platformDefault with
    | .ok s =>
      check failures "key/not-windows" (!System.Platform.isWindows)
      check failures "key/service-in-args" (s.args.contains keyService)
      check failures "key/command"
        (s.cmd == (if System.Platform.isOSX then "/usr/bin/security" else "secret-tool"))
    | .error _ => check failures "key/windows-has-no-default" System.Platform.isWindows
    if KeySource.configured.isNone then
      check failures "key/resolve-is-default"
        (KeySource.resolve.toOption == KeySource.platformDefault.toOption)

    -- 2. Error statuses map to a raised IO error through `ask`.
    for st in [400, 401, 403, 404, 429, 500, 529] do
      let threw ← (do let _ ← c.ask "x" s!"status-{st}"; pure false) <|> pure true
      check failures s!"status/{st}-raises" threw

    -- 2b. A refusal and a truncated reply raise, through `ask` and through `send`.
    check failures "stop/refusal-ask" (← raises (c.ask "x" "refuse"))
    check failures "stop/truncated-ask" (← raises (c.ask "x" "truncated"))
    check failures "stop/truncated-send" (← raises (c.send #[.user "x"] "" "truncated"))

    -- 2c. A second transfer on a busy client fails the precondition of the shim.
    let shared ← Client.new key url cert
    let slow ← IO.asTask (prio := .dedicated) (shared.ask "x" "slow-1500")
    IO.sleep 400
    let second ← (do let _ ← shared.ask "x" "echo-utf8"; pure "") <|> pure "raised"
    check failures "busy/second-transfer-raises" (second == "raised")
    match ← IO.wait slow with
    | .ok text => check failures "busy/first-transfer" (text == "slow") text
    | .error e => check failures "busy/first-transfer" false (toString e)
    check failures "busy/client-free-again" ((← shared.ask "after" "echo-utf8") == "after")
    -- Eight threads create and use one client each.
    let workers ← (List.range 8).mapM fun i =>
      IO.asTask (prio := .dedicated) do
        let own ← Client.new key url cert
        own.ask s!"worker {i}" "echo-utf8"
    for (i, worker) in (List.range 8).zip workers do
      match ← IO.wait worker with
      | .ok text => check failures s!"workers/{i}" (text == s!"worker {i}") text
      | .error e => check failures s!"workers/{i}" false (toString e)

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

    -- 5. The TLS settings, with real servers. The variable skips them offline.
    if (← IO.getEnv "AIBACKEND_OFFLINE").isSome then
      IO.println "TLS cases skipped, AIBACKEND_OFFLINE is set"
    else
      tlsCases failures key
      IO.println "TLS cases ran with real servers"

    let fails ← failures.get
    IO.println s!"connection reuse on echo cases: {reused}/1000"
    if fails == 0 then
      IO.println "all tests passed"
    else
      IO.eprintln s!"{fails} test(s) failed"
  finally
    child.kill
    IO.FS.removeDirAll tlsDir
  let fails ← failures.get
  if fails != 0 then throw (IO.userError s!"{fails} failures")
