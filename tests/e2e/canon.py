"""Canonical form of a JSON-lines stream, for the E2E comparison (see scripts/e2e.sh).

Usage: python3 canon.py FILE  -> one canonical line per message, sorted.
Lines starting with '#' and empty lines are comments. Each other line is parsed as JSON
and printed with sorted keys and compact separators; a line that is not JSON is kept
as `RAW <text>`. Numbers are compared by value: an integral float prints as an integer.
The lines are then sorted, so the comparison is of the multiset of messages: the JS SDK
answers concurrently, and its order is not a contract.
"""
import json
import sys


def norm(v):
    if isinstance(v, float) and v.is_integer():
        return int(v)
    if isinstance(v, list):
        return [norm(x) for x in v]
    if isinstance(v, dict):
        return {k: norm(x) for k, x in v.items()}
    return v


def canon(path):
    out = []
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.rstrip("\n")
            if not line.strip() or line.startswith("#"):
                continue
            try:
                out.append(json.dumps(norm(json.loads(line)), sort_keys=True, separators=(",", ":"), ensure_ascii=False))
            except ValueError:
                out.append("RAW " + line)
    return sorted(out)


if __name__ == "__main__":
    for line in canon(sys.argv[1]):
        print(line)
