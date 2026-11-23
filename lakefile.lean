import Lake
open System Lake DSL

package aibackend

/-! The key configuration of the `Claude.Api` client. This file is its only
store. The build passes both values to the C shim, which hands them to
`Client.fromDefault`. Neither value is the key. -/

/-- The name under which the secret store of the operating system holds the API key. -/
def keyService : String := "lean-aibackend-anthropic-api-key"

/-- An optional key helper, as a command followed by its arguments. A helper
prints the key on stdout. The empty array selects the default helper of the
operating system. An example is `#["pass", "show", "anthropic/api-key"]`. -/
def keyHelper : Array String := #[]

/-- The body of a C string literal with the content of `s`. -/
def cEscape (s : String) : String :=
  (s.replace "\\" "\\\\").replace "\"" "\\\""

/-- The compiler definitions that carry the key configuration. A newline
separates the entries of `keyHelper`. -/
def keyDefines : Array String :=
  #["-DAIBACKEND_KEY_SERVICE=\"" ++ cEscape keyService ++ "\"",
    "-DAIBACKEND_KEY_HELPER=\"" ++ "\\n".intercalate (keyHelper.toList.map cEscape) ++ "\""]

/-! The environment checks. They verify that the tools of the build, of the
test runner and of the C shim are available. -/

/-- Whether the build, the test runner and the C shim check the availability
of their tools. Set it to `false` once the environment is in place. The value
does not affect the checks of a call, such as the checks of the key, of the
URL and of TLS. The script `check` runs whatever the value. -/
def environmentChecks : Bool := true

/-- One requirement on the environment, with the command that verifies it. -/
structure Requirement where
  name : String
  cmd : String
  args : Array String := #[]
  /-- Whether the standard output of the command satisfies the requirement. -/
  accepts : String → Bool := fun _ => true

/-- The reason why the environment does not satisfy `r`, if any. -/
def Requirement.failure? (r : Requirement) : IO (Option String) := do
  try
    let out ← IO.Process.output { cmd := r.cmd, args := r.args }
    if out.exitCode != 0 then
      return some s!"{r.name}: `{r.cmd}` is not available, or it exited with code {out.exitCode}"
    else if !r.accepts out.stdout then
      return some s!"{r.name}: `{r.cmd}` reports that the requirement does not hold"
    else return none
  catch _ => return some s!"{r.name}: `{r.cmd}` is not available"

/-- The requirements that the environment does not satisfy. -/
def unmet (rs : List Requirement) : IO (List String) :=
  rs.filterMapM Requirement.failure?

/-- The requirements of the build of the C shim. The option
`CURLOPT_PROTOCOLS_STR` needs libcurl 7.85.0, whose version number is `075500`. -/
def buildRequirements : List Requirement := [
  { name := "a C compiler", cmd := "cc", args := #["--version"] },
  { name := "libcurl with TLS support", cmd := "curl-config", args := #["--features"],
    accepts := fun out => (out.splitOn "\n").any (·.trimAscii.toString == "SSL") },
  { name := "libcurl 7.85.0 or later", cmd := "curl-config", args := #["--vernum"],
    accepts := fun out => !(out.trimAscii.toString < "075500") }]

/-- The requirements of the test runner. -/
def testRequirements : List Requirement := [
  { name := "python3 with the ssl module", cmd := "python3", args := #["-I", "-c", "import ssl"] },
  { name := "openssl", cmd := "openssl", args := #["version"] }]

/-- The requirements of a run of the backends. -/
def runRequirements : List Requirement :=
  [{ name := "the claude CLI", cmd := "claude", args := #["--version"] }] ++
  (if !keyHelper.isEmpty then []
   else if Platform.isOSX then
     [{ name := "the Keychain command", cmd := "/usr/bin/security", args := #["list-keychains"] }]
   else if Platform.isWindows then []
   else [{ name := "secret-tool", cmd := "sh", args := #["-c", "command -v secret-tool"] }])

/-- The compiler definition that carries `environmentChecks` to the C shim. -/
def environmentDefines : Array String :=
  #["-DAIBACKEND_ENV_CHECKS=" ++ (if environmentChecks then "1" else "0")]

/-- The C shim, compiled with the system C compiler so that it finds the SDK's curl headers. -/
target claude_ffi.o pkg : FilePath := do
  if environmentChecks then
    let missing ← unmet buildRequirements
    unless missing.isEmpty do
      error s!"the environment check failed. {" ".intercalate missing}"
  let src ← inputTextFile <| pkg.dir / "c" / "claude_ffi.c"
  let leanInc := (← getLeanIncludeDir).toString
  buildO (pkg.buildDir / "c" / "claude_ffi.o") src #["-I", leanInc]
    (#["-fPIC", "-O2"] ++ keyDefines ++ environmentDefines)

extern_lib libclaude_ffi pkg := do
  let o ← claude_ffi.o.fetch
  buildStaticLib (pkg.staticLibDir / nameToStaticLib "claude_ffi") #[o]

lean_lib AIBackend

/-- Lean's bundled linker does not search the macOS SDK, so pass its library directory. -/
def curlLinkArgs : Array String :=
  if Platform.isOSX then
    #["-L", run_io do
      let out ← IO.Process.output { cmd := "xcrun", args := #["--show-sdk-path"] }
      return out.stdout.trimAscii.toString ++ "/usr/lib", "-lcurl"]
  else #["-lcurl"]

@[default_target]
lean_exe callclaude where
  root := `Main
  moreLinkArgs := curlLinkArgs

/-- The test runner. It starts `tests/mock_server.py` and runs 1000 cases.
It then runs the TLS cases with real servers, unless `AIBACKEND_OFFLINE` is set. -/
lean_exe tests where
  root := `Tests
  srcDir := "tests"
  moreLinkArgs := curlLinkArgs

/-- Prints the requirements that the environment does not satisfy. -/
def reportUnmet (missing : List String) : IO Unit := do
  IO.eprintln "the environment check failed"
  for m in missing do IO.eprintln s!"  {m}"

/-- The test driver. It checks the tools of the test runner, unless
`environmentChecks` is `false`, then builds and runs the executable `tests`. -/
@[test_driver]
script test args do
  if environmentChecks then
    let missing ← unmet testRequirements
    unless missing.isEmpty do
      reportUnmet missing
      return 1
  let child ← IO.Process.spawn { cmd := (← getLake).toString, args := #["exe", "tests"] ++ args.toArray }
  child.wait

/-- Reports every requirement of the build, of the test runner and of a run.
Usage: `lake run check`. It runs whatever the value of `environmentChecks`. -/
script check do
  let missing ← unmet (buildRequirements ++ testRequirements ++ runRequirements)
  if missing.isEmpty then
    IO.println "the environment satisfies every requirement"
    return 0
  else
    reportUnmet missing
    return 1

/-- A demo of the CLI backend, which needs no API key. -/
lean_exe clidemo where
  root := `cli_demo

/-- One prompt through the Claude API. -/
lean_exe ask where
  root := `Ask
  srcDir := "examples"
  moreLinkArgs := curlLinkArgs

/-- A three-turn conversation with a system prompt. -/
lean_exe chat where
  root := `Chat
  srcDir := "examples"
  moreLinkArgs := curlLinkArgs

/-- The formalization in Lean 4 of a two-part artifact. -/
lean_exe formalize where
  root := `Formalize
  srcDir := "examples"
  moreLinkArgs := curlLinkArgs

/-- The same prompt through the API backend and the CLI backend. -/
lean_exe compare where
  root := `Compare
  srcDir := "examples"
  moreLinkArgs := curlLinkArgs

/-- A proposal by the API backend and an objection by the CLI backend. -/
lean_exe review where
  root := `Review
  srcDir := "examples"
  moreLinkArgs := curlLinkArgs
