# Allowed differences between the Roc server and its JS twin

The expected outputs `tests/e2e/*.out.jsonl` come from the JS twin (`js/everything.mjs` on
`@modelcontextprotocol/server` 2.0.0), run by `js/gen.sh`. `js/allowed.py` then applies the rules
below, and only these, so that each file states the Roc behaviour. Every line a rule changes or
adds is preceded by a `# ALLOWED_DIFF <rule>` comment in the `.out.jsonl` file.

## Rules (changes to the JS output)

| # | Where | JS | Roc | Why |
| --- | --- | --- | --- | --- |
| D1 | a line that is not JSON (`basics`) | skipped silently | `{"jsonrpc":"2.0","id":null,"error":{"code":-32700,"message":"Parse error"}}` | The JSON-RPC spec answers a parse error. DESIGN 5 "Framing", open question Q1 (default -32700). |
| D2 | arguments that do not decode (`basics` tool `echo`, `prompts_bad` prompt `greet`) | `Invalid arguments for tool echo: text: Invalid input: expected string, received undefined` (zod's text) | `Invalid arguments for tool echo: Missing field: text` (the `Encoding.Json` decoder's text) | Arguments are validated by decoding into a Roc type, not by zod (DESIGN 7, tools row). The prefix, the error kind (`isError` result for a tool, -32602 for a prompt) and the field are the same; only the detail text differs. |

## Harness rules (not differences)

- **Server-to-client request ids.** Roc sends `"mcp-sdk-<n>"`, JS the integer `<n>`, from the
  same counter starting at 0. The transcripts answer with the Roc ids; `js/drive.mjs` rewrites
  them to integers for JS and rewrites JS's ids (and `notifications/cancelled` `requestId`s)
  back. Both ids are valid JSON-RPC; clients echo whatever they get.
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
