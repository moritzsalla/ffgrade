#!/bin/bash
# Lint + test the pipeline. Run before trusting any change to scripts/.
#
# Neither tool is a substitute for the other, and this pipeline has proof:
#   - shellcheck found ZERO issues in scripts that contained two shipped, load-bearing bugs.
#   - bats found both, because it runs the code on the actual interpreter (bash 3.2 on macOS,
#     whose empty-array handling under `set -u` differs from every modern bash).
# Run both.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

echo "== shellcheck =="
if command -v shellcheck >/dev/null; then
	(cd scripts && shellcheck -x -s bash ./*.sh) && echo "clean"
else
	echo "shellcheck not installed — skipping (binary: github.com/koalaman/shellcheck/releases)"
fi

echo
echo "== curve parity (Bench JS vs make-tone-lut.py) =="
if command -v node >/dev/null; then
	./tests/curve-parity.py
else
	echo "node not installed — SKIPPING. This is the check that catches the Bench's preview"
	echo "silently diverging from the renderer; do not treat a skip as a pass."
fi

echo
echo "== bats =="
if command -v bats >/dev/null; then
	bats tests/
else
	echo "bats not installed — skipping (github.com/bats-core/bats-core, install.sh ~/.local)"
	exit 1
fi
