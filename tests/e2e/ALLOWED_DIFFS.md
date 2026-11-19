# Allowed differences between the Roc server and its JS twin

The expected outputs `tests/e2e/*.out.jsonl` come from the JS twin (`js/everything.mjs` on
`@modelcontextprotocol/server` 2.0.0), run by `js/gen.sh`. `js/allowed.py` then applies the rules
below, and only these, so that each file states the Roc behaviour. Every line a rule changes or
adds is preceded by a `# ALLOWED_DIFF <rule>` comment in the `.out.jsonl` file.

## Rules (changes to the JS output)

| # | Where | JS | Roc | Why |
| --- | --- | --- | --- | --- |
| D1 | a line that is not JSON (`basics`) | skipped silently | `{"jsonrpc":"2.0","id":null,"error":{"code":-32700,"message":"Parse error"}}` | The JSON-RPC spec answers a parse error. DESIGN 5 "Framing", open question Q1 (default -32700). |

D2 (argument validation text) was removed: tools/call and prompts/get arguments are now checked
against the input schema with zod's messages (`SchemaCheck`), so the texts are JS's.
Server-to-client request ids are integers from 0, as in JS, so the transcripts answer with the
ids both sides send and need no rewriting.

## Harness rules (not differences)

- **Order.** The JS SDK runs handlers concurrently, so `scripts/e2e.sh` compares the multiset
  of canonical messages (sorted keys, numbers by value), not their order. `drive.mjs` paces the
  lines (150 ms) so that a client answer never reaches JS before the request it answers.
- **One server per connection.** The twin is served by `serveStdio` (a factory, as the Roc engine
  picks the era from the first message), so the same transcripts drive both eras. On the 2026-07-28
  era JS's stdio entry does not copy the envelope's client capabilities into
  `getClientCapabilities()`; the twin reads them from `ctx.mcpReq.envelope`, which is what
  `Ctx.client_capabilities` gives in Roc.
- **End of input.** Roc stops at stdin EOF and closes gracefully (`Engine.close`: the final result
  of each open `subscriptions/listen`, as in `modern_listen`). JS does not watch EOF, so the twin
  calls `handle.close()` (the graceful close of `serveStdio`) when stdin ends; `drive.mjs` kills
  it after a grace period if it is still running. In `eof` neither side writes anything after the
  parked request; Roc logs the waiting request to stderr, which is not compared.

## Differences no transcript can show

These are documented in the README ("The loop is sequential") and DESIGN 2 / 7:

- A ping that arrives while a handler runs is answered after the handler (JS: at once). With
  piped input and fast handlers, the output is the same.
- Input deadlines fire when the next line arrives on basic-cli (no timed read). With the JS
  default of 600 s, no transcript reaches a deadline.
- `Ctx.input` keeps the answers of the earlier rounds of a call, while JS gives only the latest
  round's. On 2026-07-28, an `input_required` result of a retry that already has answers carries
  them in `requestState` (`mcp-sdk-carry:...`). JS sends only the app's state there (DESIGN 2,
  "Answers accumulate"). The twin's handlers never ask again after an answer, so no transcript
  shows the difference.
