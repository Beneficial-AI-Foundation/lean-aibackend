import AIBackend.Backend

/-! The Claude command line backend. It runs `claude -p` as a subprocess, so
it needs no `ANTHROPIC_API_KEY`. The prompt and the reply travel through pipes,
so neither occurs in an argument list. There is no connection reuse.

The `claude` binary owns its network connection. This backend refuses to start
it when the environment would direct it away from TLS. -/

namespace AIBackend.Claude.Cli

/-- The environment variables that replace the URL of the service. -/
def baseUrlVariables : List String :=
  ["ANTHROPIC_BASE_URL", "ANTHROPIC_BEDROCK_BASE_URL", "ANTHROPIC_VERTEX_BASE_URL",
   "ANTHROPIC_FOUNDRY_BASE_URL"]

/-- The variable that disables certificate validation in a Node.js runtime. -/
def tlsValidationVariable : String := "NODE_TLS_REJECT_UNAUTHORIZED"

/-- The reason why the environment `env` would let the CLI leave TLS, if any.
A base URL must have the `https` scheme. The variable
`NODE_TLS_REJECT_UNAUTHORIZED` must not be `0`. -/
def transportViolation (env : List (String × String)) : Option String :=
  env.findSome? fun (name, value) =>
    if baseUrlVariables.contains name && !value.startsWith "https://" then
      some s!"{name} does not have the https scheme"
    else if name == tlsValidationVariable && value == "0" then
      some s!"{name} disables certificate validation"
    else none

/-- Checks the environment of this process with `transportViolation`. Raises
an `IO` error on a violation. -/
def checkTransport : IO Unit := do
  let mut env : List (String × String) := []
  for name in tlsValidationVariable :: baseUrlVariables do
    if let some value ← IO.getEnv name then env := (name, value) :: env
  if let some reason := transportViolation env then
    throw (IO.userError s!"precondition violated: {reason}")

/-- The options of an isolated call. The CLI saves no session, and the model
has no tool. The call can therefore neither read nor write a file, a memory
or the session of another call. -/
def isolationArgs : Array String := #["--no-session-persistence", "--tools", ""]

/-- Sends one prompt through the `claude` CLI and returns the reply text.
The prompt reaches the CLI on stdin. `model` passes `--model`; the empty
default lets the CLI choose. Each call starts one process with a connection of
its own. `isolated` adds `isolationArgs`.

The prompt must be nonempty. The model name must not start with `-`, which the
CLI would read as an option. The environment must pass `checkTransport`. -/
def ask (prompt : String) (model : String := "") (isolated : Bool := false) : IO String := do
  ensure (!prompt.isEmpty) "the prompt is empty"
  ensure (!model.startsWith "-") "the model name starts with a dash"
  checkTransport
  let modelArgs := if model.isEmpty then #[] else #["--model", model]
  let isolation := if isolated then isolationArgs else #[]
  AIBackend.runProcess "claude" (#["-p"] ++ modelArgs ++ isolation) (some prompt)

/-- The Claude CLI as a uniform `Backend`. -/
def backend (model : String := "") (isolated : Bool := false) : AIBackend.Backend :=
  { name := "claude/cli", ask := (ask · model isolated) }

end AIBackend.Claude.Cli
