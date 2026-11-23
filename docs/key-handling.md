# Key handling across operating systems

Status. The package implements this design in `AIBackend/Claude/Api.lean`,
`c/claude_ffi.c` and `lakefile.lean`. The macOS path ran with a live request.
The Linux and Windows paths have not run.

## Goal

The `Claude.Api` client obtains the API key the same way on every operating
system. The key occurs in no source file, argument list, environment variable
or file in the clear.

## Contract

A key helper is an executable that prints the key on its standard output. The
client starts the helper and reads the key through a pipe. The client trims
ASCII whitespace from the output. An empty output is an error.

The existing `Client.fromCommand` implements this contract
(`AIBackend/Claude/Api.lean`). The contract is the part of the design that
does not depend on the operating system. Each platform supplies its own
helper.

## Configuration

The file `lakefile.lean` is the only store of the configuration. The design
adds no configuration file and reads no environment variable.

| Definition in `lakefile.lean` | Meaning | Default |
| --- | --- | --- |
| `keyService` | The name under which the secret store holds the key | `lean-aibackend-anthropic-api-key` |
| `keyHelper` | An optional helper, as a command followed by its arguments | `#[]` |

Neither value is the key. The build passes both to the C shim as compiler
definitions (`lakefile.lean`, `keyDefines`). The shim returns them to Lean
through `claude_key_service` and `claude_key_helper` (`c/claude_ffi.c`). A
change of either value triggers a rebuild of the shim.

## Resolution order

The constructor `Client.fromDefault` selects the helper through
`KeySource.resolve`.

1. A nonempty `keyHelper` is the helper. An array of arguments needs no
   command line quoting, which differs between shells.
2. The default of the operating system applies when `keyHelper` is empty.
   The function `KeySource.platformDefault` identifies the system through
   `System.Platform`, which holds the platform of the compiled program.
3. A failure raises an `IO` error. The error carries the helper's exit code
   and its standard error. It never carries the helper's standard output.

The constructor `Client.fromEnv` stays outside this order. A caller selects it
explicitly, because the environment holds the key in the clear.

## Platform defaults

| Platform | Default helper | Store |
| --- | --- | --- |
| macOS | `/usr/bin/security find-generic-password -s <service> -w` | login Keychain |
| Linux | `secret-tool lookup service <service>` | Secret Service |
| Windows | none | Credential Manager |

The service name is the value of `keyService`. Any system that is neither
macOS nor Windows takes the Linux row.

### macOS

The default is the command that `Client.fromKeychain` also runs
(`AIBackend/Claude/Api.lean`). The command
`security add-generic-password -a "$USER" -s <service> -w` stores the key. It
prompts for the key without echoing it (`README.md`, section "API key").

### Linux

The manual page secret-tool(1) gives the synopsis
`secret-tool lookup {attribute} {value} ...` and shows the command printing
the stored password [1]. For storage it gives
`secret-tool store --label='Label' {attribute} {value} ...`. It states that
the tool prompts for the password on a terminal and that "a password to store
can also be piped in via stdin" [1].

The same page states that "when printing the password to a terminal or tty,
an extra newline will be added after the password" [1]. The contract trims
whitespace, so the newline does not reach the key.

Hypothesis, not tested. A host without a running Secret Service provider,
such as a headless server, has no working default. Such a host sets
`keyHelper`, for instance to `#["pass", "show", "anthropic/api-key"]`.

### Windows

The `cmdkey` command stores credentials. Its documentation lists no parameter
that prints a stored password, and it states that "passwords are not displayed
after they're stored" [2]. Windows therefore has no default helper in this
design. On Windows `Client.fromDefault` raises an `IO` error that asks for
`keyHelper`.

Two candidates for that helper exist. Neither is verified.

- A PowerShell script over the SecretManagement module.
- A small program that calls `CredRead`. The function "reads a credential
  from the user's credential set". It lives in `wincred.h` and
  `Advapi32.dll` [3]. The same call could move into `c/claude_ffi.c`, which
  adds Windows specific C code to the shim.

## Lean interface

```lean
/-- A key helper, as a command and its arguments. -/
structure KeySource where
  cmd : String
  args : Array String := #[]

/-- The value of `keyService` in `lakefile.lean`. -/
def keyService : String

/-- The helper that `keyHelper` in `lakefile.lean` sets, if any. -/
def KeySource.configured : Option KeySource

/-- The default helper of the operating system, or an error on Windows. -/
def KeySource.platformDefault (service : String := keyService) : Except String KeySource

/-- The configured helper, or else the default of the operating system. -/
def KeySource.resolve : Except String KeySource

/-- A client whose key comes from the resolved helper. -/
def Client.fromDefault (url : String := endpoint) : IO Client
```

The function `KeySource.platformDefault` branches on `System.Platform.isOSX`
and `System.Platform.isWindows`. The examples and `Main.lean` call
`Client.fromDefault`. The constructor `Client.fromKeychain` keeps its
behavior.

## Limits

- The helper's output crosses a pipe inside one host. The design does not
  protect the key from a process that runs as the same user.
- The process holds the key in memory for the life of the client. The C shim
  overwrites its copies when it frees the client (`c/claude_ffi.c`,
  `client_finalize`).
- The build fixes the configuration. A change of `keyService` or `keyHelper`
  needs a rebuild.
- The Linux default names `secret-tool` without a directory, so `PATH`
  selects the program.
- The test suite checks the selection of the helper on the system that runs
  it (`tests/Tests.lean`). It ran on macOS only.

## References

1. secret-tool(1), Debian bookworm, package libsecret-tools.
   https://manpages.debian.org/bookworm/libsecret-tools/secret-tool.1.en.html
2. Microsoft Learn, "cmdkey".
   https://learn.microsoft.com/en-us/windows-server/administration/windows-commands/cmdkey
3. Microsoft Learn, "CredReadW function (wincred.h)".
   https://learn.microsoft.com/en-us/windows/win32/api/wincred/nf-wincred-credreadw
