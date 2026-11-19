"""Turns the JS twin's output into the expected output of the Roc server.

Usage: python3 allowed.py TRANSCRIPT.in.jsonl JS_OUTPUT.jsonl > TRANSCRIPT.out.jsonl

Each rule is one entry of tests/e2e/ALLOWED_DIFFS.md, and nothing else is changed. A line a
rule changes or adds is preceded by a `# ALLOWED_DIFF <rule>: <why>` comment line, which
scripts/e2e.sh ignores.
"""
import json
import sys

transcript, js_output = sys.argv[1], sys.argv[2]


def dump(v):
    return json.dumps(v, separators=(",", ":"), ensure_ascii=False)


inputs = []
for line in open(transcript, encoding="utf-8"):
    line = line.rstrip("\n")
    if not line.strip() or line.startswith("#"):
        continue
    try:
        inputs.append(json.loads(line))
    except ValueError:
        inputs.append(None)  # not JSON

out = []  # (comment or None, message)
for line in open(js_output, encoding="utf-8"):
    if line.strip():
        out.append((None, json.loads(line)))

# D1 parse error: Roc answers a line that is not JSON with -32700 and id null; JS skips it.
PARSE_ERROR = {"jsonrpc": "2.0", "id": None, "error": {"code": -32700, "message": "Parse error"}}
for msg in inputs:
    if msg is None:
        out.append(("D1 parse error: Roc answers -32700 with id null, JS skips the line", PARSE_ERROR))

# D2 argument validation text: the message after "Invalid arguments for <tool|prompt> X: "
# comes from zod in JS and from the Roc decoder (Encoding.Json) in Roc.
def roc_decode_error(field):
    return f"Missing field: {field}"


def fix_validation(text):
    for kind in ("tool", "prompt"):
        marker = f"Invalid arguments for {kind} "
        if marker in text:
            head, _, rest = text.partition(marker)
            name, _, detail = rest.partition(": ")
            field = detail.split(":", 1)[0]
            return f"{head}{marker}{name}: {roc_decode_error(field)}"
    return None


for i, (c, m) in enumerate(out):
    if not isinstance(m, dict):
        continue
    res = m.get("result")
    if isinstance(res, dict) and res.get("isError") and res.get("content"):
        t = res["content"][0].get("text", "")
        fixed = fix_validation(t)
        if fixed is not None:
            content = [{**res["content"][0], "text": fixed}] + res["content"][1:]
            out[i] = ("D2 validation message from the Roc decoder", {**m, "result": {**res, "content": content}})
    err = m.get("error")
    if isinstance(err, dict):
        fixed = fix_validation(err.get("message", ""))
        if fixed is not None:
            out[i] = ("D2 validation message from the Roc decoder", {**m, "error": {**err, "message": fixed}})

name = transcript.rsplit("/", 1)[-1].replace(".in.jsonl", "")
print(f"# Expected output of tests/e2e/{name}.in.jsonl. Made by tests/e2e/js/gen.sh from the JS twin;")
print("# compared as a multiset of canonical JSON lines (scripts/e2e.sh). Do not edit by hand.")
for c, m in out:
    if c:
        print(f"# ALLOWED_DIFF {c}")
    print(dump(m))
