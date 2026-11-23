import Lean.Data.Json
import AIBackend.Backend

/-! The Claude HTTP backend. It calls the Messages API through a libcurl FFI
shim (`c/claude_ffi.c`). The client reads the API key from a secret store, so
the key occurs in no source file, argument list or environment variable. -/

namespace AIBackend.Claude.Api

private opaque ClientPointed : NonemptyType

/-- A Messages API client. It owns one libcurl easy handle and reuses its connection. -/
def Client : Type := ClientPointed.type

instance : Nonempty Client := ClientPointed.property

/-- The response of one request. -/
structure Response where
  status : UInt32
  /-- The number of new connections the request opened. Zero means a reused connection. -/
  newConnections : UInt32
  body : String

/-- One message of a conversation. The content is a string or an array of content blocks. -/
structure Message where
  role : String
  content : Lean.Json

namespace Message

/-- A user message with one text. -/
def user (text : String) : Message := { role := "user", content := text }

def toJson (m : Message) : Lean.Json :=
  Lean.Json.mkObj [("role", m.role), ("content", m.content)]

end Message

/-- The parsed reply of the model. -/
structure Reply where
  /-- The concatenated text blocks. -/
  text : String
  /-- The `stop_reason` of the response, or the empty string when absent. -/
  stopReason : String
  /-- The content blocks as the API returned them. -/
  content : Lean.Json

/-- The reply as an assistant message. It carries every content block unchanged,
which the API requires when a later request replays the turn. -/
def Reply.toMessage (r : Reply) : Message := { role := "assistant", content := r.content }

def defaultModel : String := "claude-opus-5-5"

def defaultMaxTokens : Nat := 16000

@[extern "claude_key_service"]
private opaque keyServiceRaw : Unit → String

@[extern "claude_key_helper"]
private opaque keyHelperRaw : Unit → String

/-- The name under which the secret store of the operating system holds the
key. The definition `keyService` of `lakefile.lean` sets it. -/
def keyService : String := keyServiceRaw ()

/-- A key helper, as a command and its arguments. It prints the key on stdout. -/
structure KeySource where
  cmd : String
  args : Array String := #[]
deriving Repr, BEq

namespace KeySource

/-- The helper that the definition `keyHelper` of `lakefile.lean` sets, if any. -/
def configured : Option KeySource :=
  match (keyHelperRaw ()).splitOn "\n" |>.filter (· ≠ "") with
  | [] => none
  | cmd :: args => some { cmd, args := args.toArray }

/-- The default helper of the operating system that runs the program.
On macOS it reads the login Keychain through `/usr/bin/security`. On Windows
there is none. On any other system it reads the Secret Service through
`secret-tool`. -/
def platformDefault (service : String := keyService) : Except String KeySource :=
  if service.isEmpty then
    .error "precondition violated: the key service name is empty"
  else if System.Platform.isOSX then
    .ok { cmd := "/usr/bin/security", args := #["find-generic-password", "-s", service, "-w"] }
  else if System.Platform.isWindows then
    .error "Windows has no default key helper. Set `keyHelper` in lakefile.lean."
  else
    .ok { cmd := "secret-tool", args := #["lookup", "service", service] }

/-- The configured helper, or else the default of the operating system. -/
def resolve : Except String KeySource :=
  match configured with
  | some s => .ok s
  | none => platformDefault

end KeySource

namespace Client

@[extern "claude_client_new"]
opaque newRaw (url key caFile : @& String) : IO Client

@[extern "claude_client_post"]
opaque postRaw (c : @& Client) (body : @& String) : IO (UInt32 × UInt32 × String)

def endpoint : String := "https://api.anthropic.com/v1/messages"

/-- The Keychain service name under which `fromKeychain` looks up the key. -/
def keychainService : String := keyService

/-- Creates a client from an explicit API key. Prefer `fromDefault` or
`fromCommand`, which keep the key out of source files.

The key must be nonempty printable ASCII without spaces. The URL must have the
`https` scheme, with no exception. A nonempty `caFile` names a PEM file of
trusted certificates that replaces the system trust store, which the test
suite uses for its local TLS server. The C shim checks each precondition
again. -/
def new (key : String) (url : String := endpoint) (caFile : String := "") : IO Client := do
  ensure (!key.isEmpty) "the key is empty"
  ensure (isPrintableAscii key) "the key holds a character other than printable ASCII"
  ensure (url.startsWith "https://") "the URL does not have the https scheme"
  newRaw url key caFile

/-- The time limit of a key helper, in milliseconds. -/
def keyHelperTimeoutMs : Nat := 60000

/-- Creates a client whose key is the standard output of a secret store command,
such as `security`, `secret-tool` or `pass`. The key travels through a pipe.
It occurs in no argument list, environment variable or file. The command must
be nonempty, and it must finish within `keyHelperTimeoutMs`. -/
def fromCommand (cmd : String) (args : Array String := #[]) (url : String := endpoint) :
    IO Client := do
  ensure (!cmd.isEmpty) "the key helper command is empty"
  let key := (← runProcess cmd args none keyHelperTimeoutMs).trimAscii.toString
  if key.isEmpty then throw (IO.userError s!"{cmd} returned an empty key")
  new key url

/-- Creates a client whose key is a generic password of the macOS login Keychain.
Store the key once with
`security add-generic-password -a "$USER" -s lean-aibackend-anthropic-api-key -w`,
which prompts for the key without echoing it. -/
def fromKeychain (service : String := keychainService) (url : String := endpoint) : IO Client := do
  ensure (!service.isEmpty) "the Keychain service name is empty"
  fromCommand "/usr/bin/security" #["find-generic-password", "-s", service, "-w"] url

/-- Creates a client on any operating system. The key comes from the helper
that `KeySource.resolve` selects, which is the helper of `lakefile.lean` or
else the secret store of the operating system. -/
def fromDefault (url : String := endpoint) : IO Client := do
  let s ← IO.ofExcept (KeySource.resolve.mapError IO.userError)
  fromCommand s.cmd s.args url

/-- Creates a client from the `ANTHROPIC_API_KEY` environment variable. The
environment holds the key in the clear, so prefer `fromDefault`. -/
def fromEnv : IO Client := do
  let some key ← IO.getEnv "ANTHROPIC_API_KEY"
    | throw (IO.userError "ANTHROPIC_API_KEY is not set")
  new key

/-- Sends a JSON request body and returns the raw response. -/
def post (c : Client) (body : Lean.Json) : IO Response := do
  let (status, newConnections, body) ← c.postRaw body.compress
  return { status, newConnections, body }

/-- Builds a Messages API request body from a conversation. An empty `system`
omits the system prompt. The body opts into the server-side refusal fallback. -/
def buildChatRequest (messages : Array Message) (system : String := "")
    (model : String := defaultModel) (maxTokens : Nat := defaultMaxTokens) : Lean.Json :=
  let fields : List (String × Lean.Json) :=
    [("model", model),
     ("max_tokens", maxTokens),
     ("fallbacks", "default"),
     ("messages", Lean.Json.arr (messages.map Message.toJson))]
  let systemField : List (String × Lean.Json) :=
    if system.isEmpty then [] else [("system", system)]
  Lean.Json.mkObj (fields ++ systemField)

/-- Builds a Messages API request body with one user message. -/
def buildRequest (prompt model : String) (maxTokens : Nat) : Lean.Json :=
  buildChatRequest #[.user prompt] "" model maxTokens

/-- Parses a Messages API response body. -/
def parseReply (body : String) : Except String Reply := do
  let json ← Lean.Json.parse body
  let blocks ← json.getObjValAs? (Array Lean.Json) "content"
  let texts := blocks.filterMap fun b =>
    match b.getObjValAs? String "type", b.getObjValAs? String "text" with
    | .ok "text", .ok t => some t
    | _, _ => none
  let stopReason := (json.getObjValAs? String "stop_reason").toOption.getD ""
  return { text := String.join texts.toList, stopReason, content := Lean.Json.arr blocks }

/-- Extracts the concatenated text blocks from a Messages API response body. -/
def parseText (body : String) : Except String String :=
  (·.text) <$> parseReply body

/-- Sends a conversation and returns the reply. Raises an `IO` error on a
status other than 200, on a refusal and on a reply that stops at `maxTokens`.
The thinking of the model counts toward `maxTokens`, so a long reasoning can
exhaust the limit before the visible text ends.

The conversation must be nonempty. Every role must be `user` or `assistant`.
The model name must be nonempty, and `maxTokens` must be positive. -/
def send (c : Client) (messages : Array Message) (system : String := "")
    (model : String := defaultModel) (maxTokens : Nat := defaultMaxTokens) : IO Reply := do
  ensure (!messages.isEmpty) "the conversation is empty"
  ensure (messages.all fun m => m.role == "user" || m.role == "assistant")
    "a message has a role other than user or assistant"
  ensure (!model.isEmpty) "the model name is empty"
  ensure (maxTokens > 0) "maxTokens is zero"
  let r ← c.post (buildChatRequest messages system model maxTokens)
  if r.status != 200 then
    throw (IO.userError s!"HTTP {r.status}: {r.body}")
  let reply ← IO.ofExcept (parseReply r.body)
  if reply.stopReason == "refusal" then
    throw (IO.userError "the model declined the request (stop_reason refusal)")
  if reply.stopReason == "max_tokens" then
    throw (IO.userError
      s!"the reply is incomplete, since it reached the limit of {maxTokens} tokens (stop_reason max_tokens)")
  return reply

/-- Sends one user message and returns the concatenated text blocks of the
reply. The prompt must be nonempty. -/
def ask (c : Client) (prompt : String) (model : String := defaultModel)
    (maxTokens : Nat := defaultMaxTokens) : IO String := do
  ensure (!prompt.isEmpty) "the prompt is empty"
  (·.text) <$> c.send #[.user prompt] "" model maxTokens

/-- This client as a uniform `AIBackend.Backend`. -/
def backend (c : Client) (model : String := defaultModel)
    (maxTokens : Nat := defaultMaxTokens) : AIBackend.Backend :=
  { name := "claude/api", ask := (c.ask · model maxTokens) }

end Client
end AIBackend.Claude.Api
