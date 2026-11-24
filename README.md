# roc-mcp-sdk

A [Roc](https://www.roc-lang.org) package for writing a [Model Context Protocol](https://modelcontextprotocol.io)
(MCP) **server**: tools, resources, resource templates, prompts, completion, logging, progress,
notifications, and server-to-client requests (roots, elicitation, sampling).

- The package has no platform and no dependencies. The app gives it the effects: on
  [basic-cli](https://github.com/roc-lang/basic-cli), that is a six-line adapter (below).
- The protocol core (`Engine`) is pure, so the whole protocol is tested with `roc test`.
- The **stdio** transport is complete. The **Streamable HTTP** transport has its final API, but its
  effectful functions crash in this release (see [docs/http.md](docs/http.md)).
- The reference for behaviour is the JS SDK `@modelcontextprotocol/server` 2.0.0. Both protocol
  eras are served: 2025-11-25 (and older) and 2026-07-28.

Toolchain: Roc nightly-2026-11-23-b5c77fc (see `.roc-version`), basic-cli 0.28.1.

## Install

```roc
app [main!] {
	pf: platform "https://github.com/roc-lang/basic-cli/releases/download/0.28.1/7brgwR8YUqfeGrkdfF1V4GPPN7DnP7ftqub9KcrTEZtr.tar.zst",
	mcp: "https://github.com/Karakatiza666/roc-mcp-sdk/releases/download/0.0.1/EdXXAsG8NbSKd8b92V5wg1MiMZAKBzf98Ua1jzJrwfED.tar.zst",
}
```

## Hello, MCP

[examples/hello.roc](examples/hello.roc), the smallest server: one tool.

```roc
GreetArgs : { name : Str }

greet! : {}, Ctx, GreetArgs => ({}, Outcome(ToolResult))
greet! = |st, _ctx, args| (st, Outcome.done(ToolResult.text("Hello, ${args.name}!")))

server : Server({})
server =
	Server.new({ name: "hello", version: "0.1.0" })
		.tool(
			Tool.new("greet")
				.with_description("Say hello")
				.with_input_schema(Schema.object([("name", Schema.Prop.required(Schema.string(Schema.described("Who to greet"))))])),
			greet!,
		)

main! = |_args| {
	_ = Stdio.serve!(server, {}, io)
	Ok({})
}
```

Build it with `roc build examples/hello.roc` and point an MCP client at the binary.
[examples/everything.roc](examples/everything.roc) uses every feature, and is the E2E target.

Concepts:
- **State is threaded.** Every handler is `state, Ctx, input => (state, output)`. `Stdio.serve!`
  returns the final state.
- **Typed arguments.** Schemas are written with the `Schema` builders. Before a handler runs, the
  arguments are checked against the tool's input schema with zod's messages (`SchemaCheck`), so a
  bad call gets the same `isError` text as from a JS server ("Input validation error: Invalid
  arguments for tool echo: text: Invalid input: expected string, received undefined"). Then
  `Server.tool` decodes them into your record type; `Server.tool_json` gives the checked
  `JsonValue`. Prompt arguments are checked against the `with_argument` list.
  `Server.with_input_validation(Bool.False)` or `tool_input_validation(name, Bool.False)` turns
  the check off (for a tool whose JS original used `z.preprocess`, which no JSON Schema shows).
- **Server-to-client requests** use the `input_required` model: a handler returns
  `Outcome.need_input(Input.Required.one("roots", ListRoots))`, the SDK obtains the answer (on a
  2025 connection it sends a real `roots/list` request) and calls the handler again, which reads
  it with `Ctx.input(ctx, "roots")`. The request has the form of the JS direct call
  (`server.listRoots({})`: `{"method":"roots/list","params":{},"jsonrpc":"2.0","id":0}`, integer
  ids from 0); `.with_progress_token(Bool.True)` gives the form of the JS `inputRequired` shim
  (`params._meta.progressToken`). The handler runs again from the top in each round, and the
  answers of all earlier rounds of the call stay readable; see
  [Asking the client for input](#asking-the-client-for-input). `Input.roots` rejects a root whose
  URI is not `file://` (as JS does), and `Input.file_uri_to_path` converts one to a path like
  Node's `fileURLToPath`.
- **Middleware.** `Server.around_tools` wraps every handler run, so a call that asks for input
  passes through it once per round (`NeedInput` outcomes, then the final `Done`).
  `Server.map_tool_results` changes only the final result, like a JS wrapper around a tool
  callback.
- **Notifications** from a handler: `Ctx.log!`, `Ctx.progress!`, `Ctx.list_changed!`,
  `Ctx.resource_updated!`, `Ctx.notify!`.

## Asking the client for input

A handler that needs roots, an elicitation or a sampling result does not wait for it. It returns
`Outcome.need_input(...)`, and the SDK calls it again when the answers are in. Each call is a
**round**:

- **The handler runs again from the top in each round.** It sees the same arguments, and
  `Ctx.round` counts the rounds (0 on the first run).
- **Answers accumulate.** `Ctx.input(key)` gives the answer to `key` from any earlier round of
  the same call, or `NotAsked` if `key` was never asked. If a key is asked again, the latest
  answer wins. So ask for a key only while it reads `NotAsked`:

  ```roc
  match (ctx.input("roots"), ctx.input("confirm")) {
  	(NotAsked, _) => (st, Outcome.need_input(Input.Required.one("roots", ListRoots)))
  	(_, NotAsked) => (st, Outcome.need_input(Input.Required.one("confirm", ElicitForm(form))))
  	(roots, confirm) => (st, Outcome.done(work(roots, confirm)))
  }
  ```

  A handler that asks again for a key it already has an answer for repeats the request in every
  round. On a 2025 connection, the call ends after 8 rounds. The SDK logs this once per call to
  the transport's log (stderr), and the log line names the key.
- **The state of a `NeedInput` round is discarded.** The next round starts from the app state
  before this round, so state changes happen once, in the final round, as in a JS handler that
  awaits. `Server.with_input_round_state(Keep)` keeps the state of every round instead.
- **Side effects before asking repeat.** A process spawned, a file written, or a `Ctx.log!` sent
  before the handler returns `NeedInput` happens again in the next round. Do this work after you
  have the input. Or do it once and keep its result in the request state:
  `Input.Required.one(...).with_state(memo)` stores the result, and `Ctx.request_state` reads it
  back in later rounds.

Where the answers and the request state are kept depends on the protocol era:

- **2025 connection:** the SDK keeps them with the waiting request (`Engine.Session.to_json`
  stores them too).
- **2026-07-28 connection:** the client sends only the answers to the latest round's requests
  (spec: the keys of `inputResponses` are those of the latest `inputRequests`). The SDK therefore
  sends the earlier answers to the client in `requestState`, together with your own state, and
  the client echoes them back on its retry.
  - `Server.with_request_state_verifier` sees only your own state.
  - Answers come from the client in both eras, so check them before you trust them (`Input.roots`,
    `Input.elicitation`).

## The basic-cli adapter

`Stdio.serve!` takes its effects as a record, `Stdio.Io`. For basic-cli 0.28.1:

```roc
import pf.Stdin
import pf.Stdout
import pf.Stderr
import pf.Utc
import mcp.Stdio

io : Stdio.Io
io = {
	read_line!: |_wait|
		match Stdin.line!() {
			Ok(line) => Ok(line)
			Err(BadUtf8(_)) => Ok("") # the bad line is consumed; an empty line is skipped
			Err(_) => Err(EndOfInput)
		},
	write_line!: |line| Stdout.line!(line).map_err(|_| Closed),
	log!: |line| Stderr.line!(line) ?? {},
	now_ms!: || Utc.now!().to_millis_since_epoch().to_u64_wrap(),
}
```

`read_line!` receives `Forever` or `Within(ms)` (a deadline of a request that waits for client
input). basic-cli has no timed read, so the adapter ignores it (see below). Logs go to stderr only;
stdout carries nothing but protocol messages.

## Parity with the JS SDK

The full table is in [DESIGN.md section 7](DESIGN.md#7-js-sdk-200-feature-parity). In short:

- **Supported:** initialize and version negotiation, server info and instructions, capabilities
  derived from what is registered, ping, tools (annotations, icons, `_meta`, output schemas and
  structured content), resources, resource templates (with `list` and `complete`), subscriptions,
  prompts, completion, logging with the level filter, progress, list-changed notifications,
  cancellation of waiting requests, pagination (off by default, as in JS), roots/elicitation/sampling
  through `input_required` (the JS legacy shim on 2025 connections), custom requests and
  notifications, and the 2026-07-28 revision as JS's `serveStdio` serves it: the era chosen by
  the first message (`server/discover` probes, fallback to `initialize`, `-32022` for versions
  not served), the per-request `_meta` envelope (client capabilities and log level per request),
  `resultType`, `ttlMs`/`cacheScope` (`Server.with_cache_hint`), serverInfo in every result's
  `_meta`, `input_required` results with `inputResponses`/`requestState` retries (the same
  `Outcome.need_input` handler code serves both eras), `subscriptions/listen` with change
  notifications routed to the subscriptions, and `-32601` for the removed methods.
- **Supported differently:** JSON Schema is written by hand (Roc has no reflection), and arguments
  are checked by `SchemaCheck`, which gives zod's messages for the subset of JSON Schema that
  `Schema` writes and zod emits (no `pattern`, `format` or `$ref`); tools are enabled by a
  predicate on the state rather than by mutation; logging works only inside a handler.
- **Not applicable:** tasks (JS has schemas only), batching, debounced notifications, and (2026-07-28)
  per-resource cache hints.
- **Stub:** Streamable HTTP (API final, implementation in a later release).

The E2E suite runs the same transcripts against `examples/everything.roc` and a JS twin built on
the real JS SDK; the deliberate differences are listed in
[tests/e2e/ALLOWED_DIFFS.md](tests/e2e/ALLOWED_DIFFS.md).

## The loop is sequential

`Stdio.serve!` runs one handler at a time and reads no input while a handler runs. Honest
consequences, compared with the JS SDK:

- A `ping` (or any message) that arrives during a long handler is answered when the handler ends.
  JS answers it at once.
- A running handler cannot be interrupted: `notifications/cancelled` drops only a request that is
  waiting for client input (no response is sent for it, and the SDK cancels its own pending
  request to the client), as JS does. A request whose handler is
  running has its response written before the cancellation is read.
- Requests waiting for client input (roots, elicitation, sampling) do not block the loop: other
  requests, pings and notifications are served meanwhile, like the await points of JS.
- An input deadline (`Input.Required.with_timeout_ms`, default 600 000 ms) fires exactly only with
  a platform whose `read_line!` can wait with a timeout. On basic-cli 0.28.1 it fires when the next
  line arrives.
- A line that is not JSON gets a `-32700` error with `id: null` (the JSON-RPC spec); JS skips it.
- At the end of stdin the server stops (on a 2026-07-28 connection, after writing the final result
  of each open `subscriptions/listen`). JS keeps its process alive until it is killed.

### A request to basic-cli

A timed stdin read, such as `Stdin.line_timeout! : Duration => Try(Str, [TimedOut, ..])`, or a
readiness poll, would make input deadlines exact. Pings during a long handler would still need
concurrency in the handler itself.

## Streamable HTTP

`StreamableHttp` has its final API: `new`, `default_options` and `options` work, the effectful
functions crash with "not implemented in this release", and the pure helpers fail closed. The
specification for the implementation is [docs/http.md](docs/http.md).

## Development

- `scripts/test.sh`: check, `fmt --check`, the L0 tests, the fuzz target (fixed count and seed),
  and the E2E transcripts.
- `scripts/e2e.sh`: builds the examples and compares each `tests/e2e/*.in.jsonl` transcript's
  output with its `.out.jsonl`.
- `tests/e2e/js/gen.sh`: regenerates the expected outputs from the JS twin (needs node and the
  JS SDK).

## Licence

[UPL-1.0](LICENSE).
