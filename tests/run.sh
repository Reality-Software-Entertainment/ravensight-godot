#!/usr/bin/env bash
# Runs the behaviour tests in tests/run.gd with a real Godot binary.
#
# Usage: bash tests/run.sh [godot-binary]   (default: godot on PATH)
#
# Godot's CLI exits 0 even when a script fails to parse, so a pass needs
# all three: exit code 0, the "PASS:" summary line, and no SCRIPT ERROR.
set -uo pipefail

GODOT="${1:-godot}"
cd "$(dirname "$0")/.."

output=$("$GODOT" --headless --script tests/run.gd 2>&1)
status=$?
echo "$output" | grep -E "^(PASS|FAIL)|checks failed|SCRIPT ERROR|Parse Error" || true

if [ "$status" -ne 0 ] || ! echo "$output" | grep -q "^PASS: " || echo "$output" | grep -q "SCRIPT ERROR"; then
  echo "tests/run.gd failed (exit $status)"
  exit 1
fi
