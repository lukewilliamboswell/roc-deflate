#!/usr/bin/env bash
# Puts libdeflate-gzip on PATH for the suite's non-Nix legs, since
# tests/harness.roc compares our output with it byte for byte. Windows has no
# package for it, and the harness skips the comparison there.
set -euo pipefail

case "$RUNNER_OS" in
  Linux)
    sudo apt-get update
    sudo apt-get install -y libdeflate-tools
    ;;
  macOS)
    brew install libdeflate
    ;;
  Windows)
    echo "No libdeflate-gzip on Windows, the harness skips the comparison"
    exit 0
    ;;
  *)
    echo "::error::no libdeflate install for $RUNNER_OS"
    exit 1
    ;;
esac

libdeflate-gzip -V
