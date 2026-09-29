#!/usr/bin/env sh
# Runs the Stagger Lune tests. Needs `lune` on PATH (https://lune-org.github.io/docs). Run from the repo root.
set -e
cd "$(dirname "$0")/../../../.."
V=packages/src/Stagger/lune-tests/vendor
mkdir -p "$V"
[ -f "$V/Trove.luau" ] || curl -sSL -o "$V/Trove.luau" https://raw.githubusercontent.com/Sleitnick/RbxUtil/main/modules/trove/init.luau
[ -f "$V/Signal.luau" ] || curl -sSL -o "$V/Signal.luau" https://raw.githubusercontent.com/Sleitnick/RbxUtil/main/modules/signal/init.luau
lune run packages/src/Stagger/lune-tests/harness.luau
