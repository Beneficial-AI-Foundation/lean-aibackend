# aibackend

A Lean 4 package that reaches AI assistants behind one interface. Backends are
organized by tool, then by access method.

## Interface

`AIBackend.Backend` holds a `name` and an `ask : String → IO String`. Every
backend exposes one, so a caller picks a tool without knowing the transport.

## Backends

| Tool | Access method | Module | Needs a key |
| --- | --- | --- | --- |
| Claude | HTTP API, libcurl FFI, persistent handle | `AIBackend.Claude.Api` | yes, from a secret store |
| Claude | `claude -p` subprocess | `AIBackend.Claude.Cli` | no |
| Codex | `codex exec` subprocess | `AIBackend.Codex.Cli` | no |
| Gemini | `gemini -p` subprocess | `AIBackend.Gemini.Cli` | no |

The CLI backends carry the tool's own authentication, so they need no API key.
The `Claude.Api` client reuses its TLS connection, so every call after the
first skips the handshakes.

## API key

The `Claude.Api` client reads the key from a secret store. The key occurs in no
source file, argument list, environment variable or log.

Store the key once in the macOS login Keychain. The command prompts for the
key without echoing it.

```
security add-generic-password -a "$USER" -s lean-aibackend-anthropic-api-key -w
```

| Constructor | Source of the key |
| --- | --- |
| `Client.fromKeychain` | The Keychain item above, read through `/usr/bin/security` |
| `Client.fromCommand cmd args` | The standard output of any secret store command, such as `secret-tool` or `pass` |
| `Client.fromEnv` | The variable `ANTHROPIC_API_KEY`. The environment holds the key in the clear |
| `Client.new key` | An explicit string, for the test suite |

The key travels from the secret store to the process through a pipe. The
process holds it in memory for the life of the client. The C shim overwrites
its copies when it frees the client. Requests travel over TLS.

## Layout

- `c/claude_ffi.c` — the libcurl shim for `Claude.Api`. One `Client` owns one `CURL` handle.
- `AIBackend/Backend.lean` — the `Backend` interface and a subprocess helper.
- `AIBackend/<Tool>/<Method>.lean` — one file per backend.
- `Main.lean` — a demo of the `Claude.Api` client with connection reuse.
- `cli_demo.lean` — runs one prompt through every CLI backend.
- `examples/` — the examples below.
- `tests/` — a 1000-case suite over `tests/mock_server.py`, no key needed.

## Examples

| Executable | Source | Shows |
| --- | --- | --- |
| `ask` | `examples/Ask.lean` | One prompt through the Claude API |
| `chat` | `examples/Chat.lean` | A three-turn conversation with a system prompt |
| `formalize` | `examples/Formalize.lean` | The formalization in Lean 4 of a two-part artifact |
| `compare` | `examples/Compare.lean` | The same prompt through the API backend and the CLI backend |
| `review` | `examples/Review.lean` | A proposal by the API backend and an objection by the CLI backend |

## Build, run, test

```
lake build ask chat formalize compare review clidemo
./.lake/build/bin/callclaude        # Claude.Api demo, connection reuse
./.lake/build/bin/ask "<prompt>"    # one prompt through the API
./.lake/build/bin/clidemo           # every CLI backend
lake test                           # 1000 cases, no key
```

## Notes

- A `CURL` easy handle is not thread safe. Use one `Claude.Api.Client` per thread.
- On macOS, Lean's bundled linker does not search the SDK, so `lakefile.lean`
  passes `$(xcrun --show-sdk-path)/usr/lib` with `-lcurl`.
- `codex exec` returns the agent's full transcript, not only a final answer.
- Requests name the model `claude-opus-5-5` by default. They opt into the
  server-side refusal fallback with `fallbacks: "default"`.
- `Client.send` raises an `IO` error when the response has `stop_reason` `refusal`.
