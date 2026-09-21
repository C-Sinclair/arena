#!/usr/bin/env bash
# Build arena, sign it, and link it onto the PATH.
#
# The signature is the point. arena reads the Claude Code token out of the login Keychain,
# and macOS asks for the login password because arena is not in that item's access control
# list. "Always Allow" remembers a binary by its designated requirement, and an unsigned
# binary gets a fresh ad-hoc signature from every `swift build`, so the answer never sticks.
# Signing with one identity every time gives it something stable to remember, and the
# password is asked for once.
#
# Pick the identity with `git config arena.signingIdentity "<name>"`, from the list that
# `security find-identity -v -p codesigning` prints.
set -euo pipefail

cd "$(dirname "$0")/.."

destination="${ARENA_BIN:-$HOME/.local/bin/arena}"
binary="$PWD/.build/release/arena"

swift build -c release

identity="$(git config --get arena.signingIdentity || true)"
if [ -n "$identity" ]; then
    codesign --force --sign "$identity" "$binary"
    echo "signed as $identity"
else
    echo "no arena.signingIdentity set; arena stays ad-hoc signed and the Keychain will" >&2
    echo "ask for the login password again after every build. Set one with:" >&2
    echo "    git config arena.signingIdentity \"<name from security find-identity -v -p codesigning>\"" >&2
fi

mkdir -p "$(dirname "$destination")"
ln -sf "$binary" "$destination"
echo "$destination -> $binary"
