import Lake
open System Lake DSL

package aibackend

/-- The C shim, compiled with the system C compiler so that it finds the SDK's curl headers. -/
target claude_ffi.o pkg : FilePath := do
  let src ← inputTextFile <| pkg.dir / "c" / "claude_ffi.c"
  let leanInc := (← getLeanIncludeDir).toString
  buildO (pkg.buildDir / "c" / "claude_ffi.o") src #["-I", leanInc] #["-fPIC", "-O2"]

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

/-- The test runner. It starts `tests/mock_server.py` and runs 1000 cases. -/
@[test_driver]
lean_exe tests where
  root := `Tests
  srcDir := "tests"
  moreLinkArgs := curlLinkArgs

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
