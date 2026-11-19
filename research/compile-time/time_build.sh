#!/bin/bash
# Times `roc build --timings --no-cache` of each given app through scripts/roc.sh (capped,
# serialized), with the machine load before and after. Usage: time_build.sh <app.roc>... [-- extra roc args]
# Logs: .tmp/ct/<name>.log
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
mkdir -p "$ROOT/.tmp/ct"
apps=(); extra=()
while [ $# -gt 0 ]; do
	if [ "$1" = -- ]; then shift; extra=("$@"); break; fi
	apps+=("$1"); shift
done
for app in "${apps[@]}"; do
	n=$(basename "$app" .roc)
	log=$ROOT/.tmp/ct/$n.log
	{
		echo "load before: $(cut -d' ' -f1-3 /proc/loadavg)"
		s=$(date +%s)
		"$ROOT/scripts/roc.sh" build --timings --no-cache "$app" --output="$ROOT/.tmp/ct/$n.bin" "${extra[@]}"
		echo "exit: $?"
		echo "wall: $(( $(date +%s) - s )) s"
		echo "load after: $(cut -d' ' -f1-3 /proc/loadavg)"
	} >"$log" 2>&1
	echo "$n: $(grep -E '^wall|^exit' "$log" | tr '\n' ' ')"
done
