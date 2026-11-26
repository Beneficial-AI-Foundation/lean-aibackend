# Contributing to Lean AI Backend

Thanks for your interest in contributing. Lean AI Backend (`aibackend`) is a
Lean 4 library for calling Claude — through the Anthropic API over a small
libcurl C shim, or through the Claude CLI — with key handling and TLS checks.
This guide covers how to build it, test it, and send a change. It follows the
shared contribution standard used across the
[Beneficial AI Foundation](https://github.com/Beneficial-AI-Foundation) Lean
projects.

## Platform

The package **works on macOS** (Apple silicon). Linux and Windows are work in
progress: on Linux the build fails at the link step today, because Lean's
bundled linker does not search the system libcurl; Windows has no default key
helper. Continuous integration builds and tests on macOS and reports the state
of the Linux build without blocking the workflow.

## Prerequisites

Install [`elan`](https://github.com/leanprover/elan), the Lean toolchain manager.
It reads `lean-toolchain` and fetches the exact Lean/Lake version this project
uses, so you don't install Lean by hand:

```sh
curl https://raw.githubusercontent.com/leanprover/elan/master/elan-init.sh -sSf | sh
```

Building the C shim and running the tests also needs, on macOS (the Command Line
Tools for Xcode provide all but `elan`):

- a C compiler (`cc`),
- **libcurl 7.85.0 or later**, with TLS support, its headers and `curl-config`,
- `python3` with the `ssl` module, and `openssl`.

Actually *running* a backend additionally needs the `claude` CLI and a key in the
operating-system secret store (the macOS login Keychain by default). Store the
key once with:

```sh
security add-generic-password -a "$USER" -s lean-aibackend-anthropic-api-key -w
```

## Building and testing

```sh
lake run check      # report every missing tool, by name
lake build          # build the library and the demo binary callclaude
lake test           # run the test suite against the mock server (no key needed)
```

`lake run check` reports every missing tool at once. The test runner starts
`tests/mock_server.py` and runs its cases; it needs no API key and spends no
tokens. Set `AIBACKEND_OFFLINE=1` to skip the cases that reach real TLS servers.

Continuous integration runs the build and the tests on macOS for every push and
pull request (see `.github/workflows/ci.yml`). Please make sure they pass locally
before opening a PR.

## Submitting a change

1. **Branch** off `main` (or fork the repository).
2. Keep each pull request focused, and add or update a test for behaviour you
   change.
3. Make sure `lake build` and `lake test` pass, and that CI is green.
4. Write a clear PR description: what changed, why, and how you verified it.
5. By contributing, you agree your contribution is licensed under this
   repository's license (see `LICENSE`), and you certify the
   [Developer Certificate of Origin](https://developercertificate.org/) — add a
   `Signed-off-by: Your Name <you@example.com>` line to your commits
   (`git commit -s`).

## Reporting issues

Open a GitHub issue with a clear title, what you expected, what happened, and the
smallest program or request that reproduces it. Security-sensitive reports can be
sent privately to **support@beneficialaifoundation.org** instead of a public
issue. Never paste an API key into an issue.

## Code of conduct

Be respectful and constructive. Harassment or abuse is not tolerated. Maintainers
may remove comments, commits or contributions that don't meet this standard.
