#!/bin/bash
# Regenerates tests/e2e/<name>.out.jsonl from the JS twin (differential E2E, DESIGN 9).
# For each tests/e2e/<name>.in.jsonl (except hello_*): drive.mjs feeds it to everything.mjs
# on @modelcontextprotocol/server 2.0.0, then allowed.py applies the documented differences
# (tests/e2e/ALLOWED_DIFFS.md) so that the file states the Roc behaviour.
# Needs node and an existing node_modules with the SDK (MCP_JS_NODE_MODULES, default
# ../roc-syntax-mcp/node_modules). Local only: CI compares against the committed files.
# Usage: tests/e2e/js/gen.sh [name...]
set -eu
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
cd "$ROOT"
RAW=$ROOT/.tmp/e2e/js
mkdir -p "$RAW" "$ROOT/.tmp/tmp"
export TMPDIR=$ROOT/.tmp/tmp
names=("$@")
if [ ${#names[@]} = 0 ]; then
	for f in tests/e2e/*.in.jsonl; do
		n=$(basename "$f" .in.jsonl)
		case $n in hello_*) ;; *) names+=("$n") ;; esac
	done
fi
for n in "${names[@]}"; do
	systemd-run --user --scope --quiet -p MemoryMax=4G -p MemorySwapMax=0 timeout 120 \
		node tests/e2e/js/drive.mjs "tests/e2e/$n.in.jsonl" >"$RAW/$n.jsonl" 2>"$RAW/$n.stderr"
	python3 tests/e2e/js/allowed.py "tests/e2e/$n.in.jsonl" "$RAW/$n.jsonl" >"tests/e2e/$n.out.jsonl"
	echo "$n: $(grep -vc '^#' "tests/e2e/$n.out.jsonl") lines, $(grep -c '^# ALLOWED' "tests/e2e/$n.out.jsonl" || true) allowed differences"
done
