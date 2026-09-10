#!/usr/bin/env bash
# Parse-check GDScript with a real Godot binary.
#
# Exists because a non-compiling SDK shipped for nine days: GDScript was
# never parsed anywhere between editing and a customer's editor. Two traps
# this script is built around:
#   1. Godot's CLI exits 0 even when the script fails to parse, so the
#      check greps stderr for SCRIPT ERROR instead of trusting exit codes.
#   2. Syntax-only linters (gdparse) miss undeclared identifiers - the exact
#      class of the escape - so a real Godot binary is required.
#
# Usage: scripts/check-gdscript.sh [godot-binary] [script...]
# Defaults: the macOS app bundle binary, and godot/Ravensight.gd.
set -euo pipefail

GODOT="${1:-/Applications/Godot.app/Contents/MacOS/Godot}"
shift || true
SCRIPTS=("${@:-godot/Ravensight.gd}")

status=0
for script in "${SCRIPTS[@]}"; do
  output=$("$GODOT" --headless --check-only --script "$script" 2>&1 || true)
  if echo "$output" | grep -q "SCRIPT ERROR"; then
    echo "FAIL: $script"
    echo "$output" | grep "ERROR"
    status=1
  else
    echo "OK: $script"
  fi
done
exit $status
