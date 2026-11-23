# aibackend

A Lean 4 package that reaches AI assistants behind one interface. Backends are
organized by tool, then by access method.

**Platforms.** The package works on macOS. Linux and Windows are work in
progress. On Linux the build fails at the link step today, since the linker
that Lean bundles does not find the system libcurl. Windows has no default key
helper.

The repository is `lean-aibackend`, the Lake package is `aibackend`, and the
library to import is `AIBackend`.

## Installation

The package needs the following tools.

| Tool | Needed for |
| --- | --- |
| `elan`, which installs the Lean version of `lean-toolchain` | every build |
| A C compiler, as `cc` | the C shim |
| The libcurl library with TLS support, version 7.85.0 or later, with its headers and `curl-config` | the `Claude.Api` backend |
| The `claude` CLI, already logged in | the `Claude.Cli` backend |
| `python3` with the `ssl` module, and `openssl` | the test suite |
| `security` on macOS, or `secret-tool` on Linux | the key of the `Claude.Api` backend |

Run the following commands from the package directory.

```
lake run check      # reports every missing tool
lake build          # builds the library and the demo `callclaude`
lake test           # runs the test suite, no key needed
```

Then store the API key once, as the section "API key" describes. The command
`./.lake/build/bin/callclaude` confirms the installation with a live request.

Once `lake run check` reports no missing tool, the definition
`environmentChecks` in `lakefile.lean` may become `false`. The build and the
tests then skip the checks of the tools.

Linux and Windows are work in progress. On Linux the build needs the
development files of libcurl, and the key helper is `secret-tool`. Windows has
no default key helper, so it needs `keyHelper` in `lakefile.lean`.

## Interface

`AIBackend.Backend` holds a `name` and an `ask : String → IO String`. Every
backend exposes one, so a caller picks a tool without knowing the transport.

## Backends

| Tool | Access method | Module | Needs a key |
| --- | --- | --- | --- |
| Claude | HTTP API, libcurl FFI, persistent handle | `AIBackend.Claude.Api` | yes, from a secret store |
| Claude | `claude -p` subprocess, prompt on stdin | `AIBackend.Claude.Cli` | no |
| Codex | `codex exec -` subprocess, prompt on stdin | `AIBackend.Codex.Cli` | no |
| Gemini | `gemini -p` subprocess | `AIBackend.Gemini.Cli` | no |

The CLI backends carry the tool's own authentication, so they need no API key.
The `Claude.Api` client reuses its TLS connection, so every call after the
first skips the handshakes.

## API key

The `Claude.Api` client reads the key from a secret store. The code of the
package places the key in no source file, argument list, environment variable
or log.

Store the key once in the macOS login Keychain. The command prompts for the
key without echoing it.

```
security add-generic-password -a "$USER" -s lean-aibackend-anthropic-api-key -w
```

On Linux the command `secret-tool store --label='Anthropic API key' service
lean-aibackend-anthropic-api-key` stores the key in the Secret Service.

The client identifies the operating system and runs the matching helper. The
definitions `keyService` and `keyHelper` in `lakefile.lean` hold the
configuration. Windows has no default helper and needs `keyHelper`.

| Constructor | Source of the key |
| --- | --- |
| `Client.fromDefault` | The helper of `lakefile.lean`, or else the secret store of the operating system |
| `Client.fromKeychain` | The Keychain item above, read through `/usr/bin/security` |
| `Client.fromCommand cmd args` | The standard output of any secret store command, such as `secret-tool` or `pass` |
| `Client.fromEnv` | The variable `ANTHROPIC_API_KEY`. The environment holds the key in the clear |
| `Client.new key` | An explicit string, for the test suite |

The key travels from the secret store to the process through a pipe. The
process holds it in memory for the life of the client. The C shim overwrites
its copies when it frees the client.

The file `docs/key-handling.md` describes the design of the key handling
across operating systems. The script `get-key.sh` prints the key from the
macOS login Keychain.

## Usage

A program imports `AIBackend` and creates a client. The constructor
`Client.fromDefault` reads the key from the secret store of the operating
system.

One prompt through the Claude API.

```lean
import AIBackend
open AIBackend.Claude.Api

def main : IO Unit := do
  let c ← Client.fromDefault
  IO.println (← c.ask "State the definition of an even natural number.")
```

A conversation with a system prompt. Each request replays the earlier turns,
and `Reply.toMessage` keeps the content blocks of a reply unchanged.

```lean
def main : IO Unit := do
  let c ← Client.fromDefault
  let mut history : Array Message := #[]
  for q in #["What is a structure in Lean 4?", "How does it differ from an inductive type?"] do
    history := history.push (.user q)
    let reply ← c.send history "You are a concise Lean 4 tutor."
    history := history.push reply.toMessage
    IO.println reply.text
```

The same call over two backends, behind the uniform `Backend` interface. The
CLI backend needs no key.

```lean
import AIBackend
open AIBackend

def main : IO Unit := do
  let api ← Claude.Api.Client.fromDefault
  for b in [api.backend, Claude.Cli.backend] do
    IO.println s!"[{b.name}] {← b.ask "Name the standard axioms of Lean 4."}"
```

| Call | Role |
| --- | --- |
| `Client.ask c prompt` | Sends one user message and returns the reply text |
| `Client.send c messages system model maxTokens` | Sends a conversation and returns a `Reply` with `text`, `stopReason` and `content` |
| `Client.post c body` | Sends a raw JSON body and returns the status, the number of new connections and the body |
| `Client.backend c`, `Claude.Cli.backend`, `Codex.Cli.backend`, `Gemini.Cli.backend` | A `Backend` for the uniform interface |
| `Claude.Cli.ask prompt` | Sends one prompt through `claude -p` |

The default model is `claude-opus-5-5`, and the default `maxTokens` is 16000.

### Use from another Lake project

Another project requires the package in its `lakefile.lean`. Lake passes the
C shim on to the dependent project, but not the libcurl link arguments, so each
executable of that project repeats them.

```lean
require aibackend from git "<URL of this repository>" @ "main"

def curlLinkArgs : Array String :=
  if Platform.isOSX then
    #["-L", run_io do
      let out ← IO.Process.output { cmd := "xcrun", args := #["--show-sdk-path"] }
      return out.stdout.trimAscii.toString ++ "/usr/lib", "-lcurl"]
  else #["-lcurl"]

lean_exe myapp where
  root := `MyApp
  moreLinkArgs := curlLinkArgs
```

A dependent project with this requirement and these link arguments built and
ran on macOS, under the toolchains v4.28.0, v4.35.0 and v4.36.0.

The file `lean-toolchain` of this package names v4.28.0, the lowest toolchain
on which the package is tested. Lake raises the toolchain of a dependent
project when a dependency names a newer one, so a low version here leaves a
dependent project on its own toolchain. For a project on a toolchain older
than v4.28.0, the command `lake update aibackend --keep-toolchain` prevents
the change.

### Executables only for the API backend

The API backend works in a compiled executable. It does not work in the
interpreter, which runs `#eval`, commands and tactics. A call of
`Client.new` there ends the Lean process with the message "Could not find
native implementation of external declaration". The CLI backends work in the
interpreter, since they start a subprocess and use no native code.

## Confidentiality of the key, the query and the reply

The `Claude.Api` client sends all three over HTTPS only. The C shim uses TLS
1.2 or later. It validates the certificate chain and the host name. It refuses
any URL whose scheme is not `https`, with no exception, and it follows no
redirect. After each transfer the shim checks that the transfer used the
`https` scheme and that the certificate verification succeeded.

The mock server of the test suite speaks HTTPS as well. The suite generates a
certificate for `127.0.0.1` with `openssl`, and the client trusts it through
the `caFile` argument of `Client.new`.

The test suite checks these settings with real servers. The API host answers
a generated key with status 401 after a complete handshake. Six hosts of
badssl.com serve an expired certificate, a wrong host name, a self-signed
certificate, an untrusted root, TLS 1.0 and TLS 1.1. The client refuses each
of them. These cases need the network and send no real key. The variable
`AIBACKEND_OFFLINE` skips them.

The `Claude.Cli` backend passes the prompt to `claude -p` on stdin. The reply
returns on stdout. Neither occurs in an argument list, so neither shows in the
process table.

The `claude` binary owns its own network connection, so this package cannot
inspect it. The backend checks the environment before each call. It refuses to
start the binary when a base URL variable, such as `ANTHROPIC_BASE_URL`, lacks
the `https` scheme, or when `NODE_TLS_REJECT_UNAUTHORIZED` is `0`. The check
does not read the settings files of the CLI.

The `Codex.Cli` backend also passes the prompt on stdin. The `Gemini.Cli`
backend still passes the prompt as an argument, which the process table
exposes to other local users. Neither of these two backends has run from end
to end, since neither CLI was logged in on the test machine.

## Preconditions

Every precondition has a run time check that raises an `IO` error. The checks
stay active in every build.

| Function | Preconditions |
| --- | --- |
| `Client.new` | The key is nonempty printable ASCII without spaces. The URL has the `https` scheme and a host. A nonempty `caFile` is readable. |
| `Client.fromCommand` | The command is nonempty, exits with code 0 and prints a nonempty key. |
| `Client.fromKeychain`, `KeySource.platformDefault` | The service name is nonempty. |
| `Client.send` | The conversation is nonempty. Every role is `user` or `assistant`. The model name is nonempty. The value of `maxTokens` is positive. |
| `Client.ask`, `Claude.Cli.ask` | The prompt is nonempty. |
| `Claude.Cli.ask` | The model name does not start with `-`. The environment passes `checkTransport`. |
| `Codex.Cli.ask`, `Gemini.Cli.ask` | The prompt is nonempty. The model name does not start with `-`. For Gemini the prompt does not start with `-` either. |
| `runProcess` | The command is nonempty. No argument holds a NUL character. The time limit is positive. |
| `claude_client_post` in the shim | The client holds a live handle. No other transfer runs on the client. The body is nonempty and holds no NUL byte. |

The shim repeats the checks of `Client.new`, and it checks the result of every
libcurl call.

Two properties of a reply also raise an `IO` error in `Client.send` and
`Client.ask`. The first is a refusal, with `stop_reason` `refusal`. The second
is an incomplete reply, with `stop_reason` `max_tokens`. The thinking of the
model counts toward `maxTokens`, so a long reasoning can exhaust the limit
before the visible text ends.

## Environment checks

The file `lakefile.lean` checks that the tools of the environment are
available.

| Moment | Requirements |
| --- | --- |
| Build of the C shim | A C compiler. A libcurl with TLS support, version 7.85.0 or later. |
| `lake test` | A `python3` with the `ssl` module. The `openssl` command. |
| First client of a run, in the shim | The libcurl of the run has TLS support and version 7.85.0 or later. |
| `lake run check` | All of the above, the `claude` CLI and the key helper of the operating system. |

The definition `environmentChecks` in `lakefile.lean` disables the first three
rows when its value is `false`. Set it once the environment is in place. The
script `lake run check` runs whatever the value. The definition does not
affect the preconditions of the section above, which stay active.

## Layout

- `c/claude_ffi.c` — the libcurl shim for `Claude.Api`. One `Client` owns one `CURL` handle.
- `AIBackend/Backend.lean` — the `Backend` interface and a subprocess helper.
- `AIBackend/<Tool>/<Method>.lean` — one file per backend.
- `Main.lean` — a demo of the `Claude.Api` client with connection reuse.
- `cli_demo.lean` — runs one prompt through every CLI backend.
- `examples/` — the examples below.
- `tests/` — a 1000-case suite over `tests/mock_server.py`, plus TLS cases with real servers. No key needed. The suite needs `python3` and `openssl`.
- `docs/key-handling.md` — the design of the key handling across operating systems.
- `get-key.sh` — prints the key from the macOS login Keychain.

## Examples

Each example is an executable. The command `lake exe <name>` builds it and
runs it. Every example except `clidemo` needs the API key in the secret store.
The examples `compare`, `review` and `clidemo` also need the `claude` CLI,
already logged in.

| Command | Source | Shows |
| --- | --- | --- |
| `lake exe callclaude` | `Main.lean` | Three requests on one client, with the status and the connection reuse of each |
| `lake exe ask "<prompt>"` | `examples/Ask.lean` | One prompt through the Claude API |
| `lake exe chat` | `examples/Chat.lean` | A three-turn conversation with a system prompt |
| `lake exe formalize` | `examples/Formalize.lean` | The formalization in Lean 4 of a two-part text, where the second request carries the first result |
| `lake exe compare "<prompt>"` | `examples/Compare.lean` | The same prompt through the API backend and the CLI backend, with the time of each |
| `lake exe review "<text>"` | `examples/Review.lean` | A formalization by the API backend and a review of it by the CLI backend |
| `lake exe clidemo` | `cli_demo.lean` | One prompt through every CLI backend. It needs the `claude`, `codex` and `gemini` CLIs, each logged in |

The prompt of `ask`, `compare` and `review` is optional. Each has a default.

A first run looks like this.

```
lake exe ask "Reply with the single word OK."
OK
```

## Notes

- A `CURL` easy handle is not thread safe. Use one `Claude.Api.Client` per thread.
  The shim refuses a second transfer on a client while one runs. The first
  client of a process may come from any thread.
- On macOS, Lean's bundled linker does not search the SDK, so `lakefile.lean`
  passes `$(xcrun --show-sdk-path)/usr/lib` with `-lcurl`.
- `codex exec` returns the agent's full transcript, not only a final answer.
- A subprocess of a CLI backend has a time limit of 10 minutes, and a key helper has one of
  60 seconds. At the limit the helper ends the process group and raises an `IO` error.
- Requests name the model `claude-opus-5-5` by default. They opt into the
  server-side refusal fallback with `fallbacks: "default"`. The fallback is a
  beta feature of the API, which the header
  `anthropic-beta: server-side-fallback-2026-07-01` selects, so it may change.
- The workflow `.github/workflows/ci.yml` builds every executable and runs the
  test suite on macOS. Its Linux job reports the state of the Linux build
  without failing the workflow.
- `Client.send` raises an `IO` error when the response has `stop_reason` `refusal`
  or `max_tokens`.

## License

The package is under the MIT license. See the file `LICENSE`.
