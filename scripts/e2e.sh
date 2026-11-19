#!/bin/bash
# E2E (DESIGN 9): build the basic-cli examples, pipe each transcript into a server, and
# compare its stdout with the expected output.
#
#   tests/e2e/<name>.in.jsonl    the client's lines. `#` lines and empty lines are comments.
#                                hello_*.in.jsonl go to examples/hello.roc, the others to
#                                examples/everything.roc.
#   tests/e2e/<name>.out.jsonl   the expected stdout, made by the JS twin
#                                (tests/e2e/js/gen.sh), with the allowed differences of
#                                tests/e2e/ALLOWED_DIFFS.md applied. `#` lines are comments.
#
# Comparison rule (tests/e2e/canon.py): each JSON line is parsed and re-serialized with
# sorted keys, and numbers are compared by value (1.0 == 1). The canonical lines of each side
# are then sorted, and the two sorted lists must be equal: the same multiset of messages.
# Order is not compared, because the JS SDK, which made the expected files, answers
# concurrently; ids, notification payloads and counts are all compared.
#
# Also: the server must stop on its own when stdout is closed (Stdio.serve! OutputClosed).
#
# Local runs: the compiler through scripts/roc.sh, each binary under systemd-run (4G, 120 s).
# CI (GITHUB_ACTIONS): plain roc, no systemd-run. Needs python3. Node is not needed: only
# tests/e2e/js/gen.sh runs the JS twin.
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"
OUT=$ROOT/.tmp/e2e
mkdir -p "$OUT" "$ROOT/.tmp/tmp"
export TMPDIR=$ROOT/.tmp/tmp

capped() {
	if [ -n "${GITHUB_ACTIONS:-}" ]; then
		if command -v timeout >/dev/null; then timeout 120 "$@"; else "$@"; fi
	else
		systemd-run --user --scope --quiet -p MemoryMax=4G -p MemorySwapMax=0 timeout 120 "$@"
	fi
}

FAIL=0
# Build time is part of the contract (DESIGN 12.21): each build's duration is printed, and one
# over BUILD_BUDGET seconds (default 120) fails the run. A cached build takes about a second.
BUILD_BUDGET=${BUILD_BUDGET:-120}
for ex in everything hello; do
	start=$(date +%s)
	if ! scripts/roc.sh build "examples/$ex.roc" --output="$OUT/$ex" >"$OUT/$ex.build.log" 2>&1; then
		echo "FAIL: build examples/$ex.roc (see $OUT/$ex.build.log)"
		tail -30 "$OUT/$ex.build.log"
		exit 1
	fi
	took=$(($(date +%s) - start))
	echo "build examples/$ex.roc: ${took} s (budget ${BUILD_BUDGET} s)"
	if [ "$took" -gt "$BUILD_BUDGET" ]; then
		echo "FAIL: building examples/$ex.roc took ${took} s, over the ${BUILD_BUDGET} s budget (DESIGN 12.21)"
		FAIL=1
	fi
done

pass=0
for in in tests/e2e/*.in.jsonl; do
	name=$(basename "$in" .in.jsonl)
	expected=tests/e2e/$name.out.jsonl
	case $name in hello_*) bin=$OUT/hello ;; *) bin=$OUT/everything ;; esac
	if [ ! -f "$expected" ]; then
		echo "FAIL: $name: no $expected"
		FAIL=1
		continue
	fi
	grep -v -e '^#' -e '^[[:space:]]*$' "$in" | capped "$bin" >"$OUT/$name.actual.jsonl" 2>"$OUT/$name.stderr"
	code=$?
	python3 tests/e2e/canon.py "$expected" >"$OUT/$name.expected.canon"
	python3 tests/e2e/canon.py "$OUT/$name.actual.jsonl" >"$OUT/$name.actual.canon"
	if [ $code != 0 ]; then
		echo "FAIL: $name: exit $code (stderr: $OUT/$name.stderr)"
		FAIL=1
	elif ! diff -u "$OUT/$name.expected.canon" "$OUT/$name.actual.canon" >"$OUT/$name.diff"; then
		echo "FAIL: $name (canonical diff, - expected + actual):"
		cat "$OUT/$name.diff"
		FAIL=1
	else
		echo "ok: $name"
		pass=$((pass + 1))
	fi
done

# A closed stdout stops the server even though stdin stays open.
if capped python3 - "$OUT/everything" <<'EOF'; then
import subprocess, sys, time
p = subprocess.Popen([sys.argv[1]], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
p.stdout.close()
init = b'{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"e2e","version":"1"}}}\n'
try:
    for i in range(3):
        p.stdin.write(init)
        p.stdin.flush()
        time.sleep(0.1)
except BrokenPipeError:
    pass
try:
    p.stdin.close()
except BrokenPipeError:
    pass
try:
    p.wait(timeout=10)
except subprocess.TimeoutExpired:
    p.kill()
    sys.exit("server kept running after stdout closed")
EOF
	echo "ok: closed stdout stops the server"
else
	echo "FAIL: closed stdout"
	FAIL=1
fi

echo
[ $FAIL = 0 ] && echo "E2E PASS ($pass transcripts)" || { echo "E2E FAIL"; exit 1; }
