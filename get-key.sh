#!/bin/sh
# Prints the Anthropic API key from the macOS login Keychain.
# The service name matches `keyService` in lakefile.lean.
exec /usr/bin/security find-generic-password -s lean-aibackend-anthropic-api-key -w
