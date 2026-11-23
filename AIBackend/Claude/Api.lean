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

namespace Client

@[extern "claude_client_new"]
opaque newRaw (url key : @& String) : IO Client

@[extern "claude_client_post"]
opaque postRaw (c : @& Client) (body : @& String) : IO (UInt32 × UInt32 × String)

def endpoint : String := "https://api.anthropic.com/v1/messages"

/-- The Keychain service name under which `fromKeychain` looks up the key. -/
def keychainService : String := "lean-aibackend-anthropic-api-key"

/-- Creates a client from an explicit API key. Prefer `fromKeychain` or
`fromCommand`, which keep the key out of source files. -/
def new (key : String) (url : String := endpoint) : IO Client := newRaw url key

/-- Creates a client whose key is the standard output of a secret store command,
such as `security`, `secret-tool` or `pass`. The key travels through a pipe.
It occurs in no argument list, environment variable or file. -/
def fromCommand (cmd : String) (args : Array String := #[]) (url : String := endpoint) :
    IO Client := do
  let out ← IO.Process.output { cmd, args }
  if out.exitCode != 0 then
    throw (IO.userError s!"{cmd} exited with {out.exitCode}: {out.stderr}")
  let key := out.stdout.trimAscii.toString
  if key.isEmpty then throw (IO.userError s!"{cmd} returned an empty key")
  new key url

/-- Creates a client whose key is a generic password of the macOS login Keychain.
Store the key once with
`security add-generic-password -a "$USER" -s lean-aibackend-anthropic-api-key -w`,
which prompts for the key without echoing it. -/
def fromKeychain (service : String := keychainService) (url : String := endpoint) : IO Client :=
  fromCommand "/usr/bin/security" #["find-generic-password", "-s", service, "-w"] url

/-- Creates a client from the `ANTHROPIC_API_KEY` environment variable. The
environment holds the key in the clear, so prefer `fromKeychain`. -/
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
status other than 200 and on a refusal. -/
def send (c : Client) (messages : Array Message) (system : String := "")
    (model : String := defaultModel) (maxTokens : Nat := defaultMaxTokens) : IO Reply := do
  let r ← c.post (buildChatRequest messages system model maxTokens)
  if r.status != 200 then
    throw (IO.userError s!"HTTP {r.status}: {r.body}")
  let reply ← IO.ofExcept (parseReply r.body)
  if reply.stopReason == "refusal" then
    throw (IO.userError "the model declined the request (stop_reason refusal)")
  return reply

/-- Sends one user message and returns the concatenated text blocks of the reply. -/
def ask (c : Client) (prompt : String) (model : String := defaultModel)
    (maxTokens : Nat := defaultMaxTokens) : IO String :=
  (·.text) <$> c.send #[.user prompt] "" model maxTokens

/-- This client as a uniform `AIBackend.Backend`. -/
def backend (c : Client) (model : String := defaultModel) : AIBackend.Backend :=
  { name := "claude/api", ask := (c.ask · model) }

end Client
end AIBackend.Claude.Api
