#!/bin/bash
# All local checks, in order: check, fmt, L0 tests, L1 fuzz (fixed count and seed), E2E.
# Every compiler run goes through scripts/roc.sh (memory cap, timeout, one job at a time);
# every built binary runs under systemd-run (scripts/e2e.sh, and the fuzz run below).
# Usage: scripts/test.sh. Env: RUNS (fuzz runs per target, default 10000). Exit 0 only when all pass.
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"
RUNS=${RUNS:-10000}
W=$ROOT/.tmp/test
mkdir -p "$W/fuzz" "$ROOT/.tmp/tmp"
export TMPDIR=$ROOT/.tmp/tmp
RC=scripts/roc.sh # not ROC: roc.sh reads $ROC as the compiler path
FAIL=0
step() { echo; echo "== $*"; }
rc() { [ "$1" = 0 ] || { echo "FAIL ($1): $2"; FAIL=1; }; }
capped() {
	if [ -n "${GITHUB_ACTIONS:-}" ]; then "$@"; else
		systemd-run --user --scope --quiet -p MemoryMax=4G -p MemorySwapMax=0 timeout 600 "$@"
	fi
}

step "check: $($RC version)"
$RC check package/main.roc; rc $? "check package/main.roc"
for f in tests/*.roc fuzz/*.roc examples/*.roc; do
	$RC check "$f" >"$W/check.log" 2>&1 || { rc 1 "check $f"; tail -20 "$W/check.log"; }
done

step "format"
$RC fmt --check package tests fuzz examples; rc $? "fmt --check"

step "L0"
for f in tests/*.roc; do $RC test "$f"; rc $? "test $f"; done

step "L1: $RUNS runs, seed 1"
for f in fuzz/*.roc; do
	grep -qE '^app[[:space:]]*\[' "$f" || continue
	n=$(basename "$f" .roc)
	if ! $RC build --fuzz "$f" --output="$W/fuzz/$n" >"$W/fuzz/$n.build.log" 2>&1; then
		rc 1 "build $f (see $W/fuzz/$n.build.log)"
		continue
	fi
	# roc-fuzz 0.6.2: run from the directory that holds the baseline; the report dir must be new.
	rm -rf "$W/fuzz/report-$n"
	mkdir -p "$W/fuzz/corpus-$n"
	(cd fuzz && capped "$W/fuzz/$n" run "$W/fuzz/corpus-$n" --runs="$RUNS" --seed=1 --time=0 \
		--report-dir="$W/fuzz/report-$n") >"$W/fuzz/$n.log" 2>&1
	r=$?
	rc $r "fuzz $n (see $W/fuzz/$n.log)"
	head -1 "$W/fuzz/$n.log"
done

step "E2E"
scripts/e2e.sh; rc $? "scripts/e2e.sh"

echo
[ $FAIL = 0 ] && echo "ALL PASS" || { echo "SOME CHECKS FAIL"; exit 1; }
