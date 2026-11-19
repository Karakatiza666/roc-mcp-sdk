#!/bin/bash
# Capped, serialized roc invocation (machine rules: no /tmp, memory cap, timeout,
# one heavy job at a time). Every agent and script runs roc only through this.
# Usage: scripts/roc.sh <roc args...>   ROC=<path> overrides the compiler.
ROOT=$(cd "$(dirname "$0")/.." && pwd)
# In CI (GITHUB_ACTIONS) the runner is the sandbox: run the `roc` on PATH directly.
if [ -n "${GITHUB_ACTIONS:-}" ]; then exec "${ROC:-roc}" "$@"; fi
ROC=${ROC:-/home/george/dev/Karakatiza666/roc-syntax-mcp/roc_nightly-linux_x86_64-2026-11-14-a87808d/roc}
mkdir -p "$ROOT/.tmp/tmp" "$ROOT/.tmp/xdg/roc"
export TMPDIR=$ROOT/.tmp/tmp XDG_CACHE_HOME=$ROOT/.tmp/xdg ROC_CACHE_DIR=$ROOT/.tmp/xdg/roc
# One compiler job at a time across all agents: wait for the lock (max 30 min).
# ROC_LOCK overrides the lock file (worktrees share the main checkout's lock this way).
exec flock -w 1800 "${ROC_LOCK:-$ROOT/.tmp/roc.lock}" \
  systemd-run --user --scope --quiet -p MemoryMax=16G -p MemorySwapMax=0 timeout 600 "$ROC" "$@"
