#!/bin/bash
# Capped roc invocation for the spikes (machine rules: no /tmp, memory cap, timeout).
# Usage: research/spikes/roc.sh <roc args...>   (run from the repo root)
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
ROC=${ROC:-/home/george/dev/Karakatiza666/roc-syntax-mcp/roc_nightly-linux_x86_64-2026-11-14-a87808d/roc}
mkdir -p "$ROOT/.tmp/tmp" "$ROOT/.tmp/xdg/roc"
export TMPDIR=$ROOT/.tmp/tmp XDG_CACHE_HOME=$ROOT/.tmp/xdg ROC_CACHE_DIR=$ROOT/.tmp/xdg/roc
exec systemd-run --user --scope --quiet -p MemoryMax=16G -p MemorySwapMax=0 timeout 600 "$ROC" "$@"
