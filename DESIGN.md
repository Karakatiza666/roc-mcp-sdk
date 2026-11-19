# roc-mcp-sdk design

`roc-mcp-sdk` is a Roc package for writing a Model Context Protocol (MCP) **server**. The package itself has no platform: the app gives it the effects. The stdio transport is complete in this release. The Streamable HTTP transport has its final API, but every function of it crashes ("stub"). The reference for behaviour is the JS SDK `@modelcontextprotocol/server` 2.0.0 (with `@modelcontextprotocol/core`). The acceptance test is a lossless port of `roc-syntax-mcp` (`src/server.ts`, `src/index.ts`) to Roc on this package.

Toolchain: nightly-2026-11-14-a87808d, the first nightly that basic-cli 0.28.1 accepts. Every API shape below was type-checked with that compiler in `research/spikes/` (section 11).

Contents: 1 decisions, 2 architecture, 3 repository layout, 4 public API, 5 engine and transports, 6 errors, 7 JS parity, 8 roc-syntax-mcp mapping, 9 testing, 10 work breakdown, 11 spike results, 12 compiler limits and workarounds, 13 open questions.

## 1. Key decisions

| # | Decision | Reason |
| --- | --- | --- |
| D1 | **The engine is pure, and the transports are thin effectful drivers.** `Engine.receive` takes a message and returns the lines to write plus `Call`s: closures that already hold the decoded arguments. The driver runs each `Call` and passes its outcome to `Engine.finish`. | `roc test` rejects any effect in an `expect` ("effectful expect", spike s1). A pure engine lets L0 tests cover the whole protocol: lifecycle, negotiation, dispatch, validation, errors, pagination, completion, the input shim and both eras. Only the handler bodies need effects. |
| D2 | **The app's state is threaded through handlers.** Every handler is `state, Ctx, input => (state, output)`. A notification handler is `state, Ctx, JsonValue => state`. | Roc has no mutable cell that a closure can write (`var` is local to its function). roc-syntax-mcp mutates caches inside tool calls and notification handlers. The loop is sequential, so threading is exact (spikes s1, s3). |
| D3 | **Server-to-client requests use the `input_required` model.** A handler that needs roots, an elicitation or a sampling result returns `Outcome.need_input(...)`. The SDK gets the answers and calls the handler again, and the handler reads them with `Ctx.input(key)`. On a 2025 connection the engine sends real `roots/list`, `elicitation/create` and `sampling/createMessage` requests. This is the JS `LegacyInputRequiredShim`. On a 2026-07-28 connection it returns `resultType: "input_required"` to the client. | This is the pattern that JS 2.0 recommends, and it works in both eras. It needs no blocking read inside a handler and no queue of messages read during a wait. While the answers are pending, the engine serves every other message: ping, other tool calls, notifications (spike s3). |
| D4 | **`JsonValue` is our own recursive nominal union with our own parser and serializer.** A number keeps its source text (`Number(Str)`). An object is an ordered list of pairs. | `Encoding.Json` has no dynamic value type. Keeping the text makes ids and big integers pass through exactly, with no choice between Dec and F64 when parsing. Measured speed: parsing 1.7 MB takes 10 to 13 ms (spike s2). |
| D5 | **Typed arguments go through `Encoding.Json`.** `Server.tool` accepts any `args` that satisfies `where [args.Json.Parseable(_)]`. The engine serializes the JSON arguments and decodes them into the app's record. Before decoding, the arguments are checked against the tool's input schema by `SchemaCheck`, with zod's messages ("Input validation error: Invalid arguments for tool X: <zod issues>", as in JS); a decode failure after that is the same `isError` result with the decoder's text. Raw (checked) JSON is available through `tool_json`. JSON Schema is written by hand with `Schema` builders: Roc has no reflection, so nothing can derive a schema. | Spike s2/s3. The documented form `a.Json.Parseable([InvalidJson(Str), ..errs])` does not compile on this nightly (12.1). |
| D6 | **Effects are injected as records of functions** (`Stdio.Io`, `StreamableHttp.Io`). The package has no dependencies. | It works with any platform. basic-cli needs a 6-line adapter (4.13). |
| D7 | **Dynamic enable/disable is a predicate on state** (`tool_enabled_when`) plus `Ctx.list_changed!`. The `Server` value stays immutable after it is built. | It replaces JS `RegisteredTool.enable/disable/remove` without mutation. |
| D8 | **One public type per module.** Nested types that have methods get their own module (`ToolResult`, `ResourceContents`, `ResourceTemplate`). | The methods of a nested type share one scope with the methods of the outer type, so the names collide (12.4). |

## 2. Architecture

```
app (basic-cli, or any platform)
  │ Stdio.Io { read_line!, write_line!, log!, now_ms! }
  ▼
Stdio.serve!  ── the loop: read a line ─► Engine.receive ─► write the out lines
  │                                         │ returns Calls
  │  (state, outcome) = call.run!(state, ctx)    ◄─┘
  └─► Engine.finish(outcome) ─► the response, or the server→client requests (and the request is parked)
Engine (pure): Session, era, negotiation, dispatch, decoding, paging, completion, input shim, envelope
Server(state) (pure value): the registered tools, resources, templates, prompts, handlers, options
```

- **A session and its era.** The first message picks the era, as JS `serveStdio` does (section 7, row "Era selection"). A legacy (2025) session stores the client capabilities from `initialize`. A modern (2026-07-28) session reads them from the `_meta` envelope of each request.
- **Parked requests (legacy input shim).** `finish` with `NeedInput` sends one request for each key, with integer ids `0, 1, ...` from one counter per session (`Session.next_out_id`), as JS's `_requestMessageId`; they cannot collide with client ids because JSON-RPC keeps the two directions apart. A response is matched as JS matches it (`Number(id)`: an integer, or a string of digits). By default the request has the form of the JS direct calls (`server.listRoots({})` sends `params: {}`, no `_meta`); `Input.Required.with_progress_token(Bool.True)` gives the form of the JS `inputRequired` shim, `params._meta.progressToken: <id>`. The capability gate follows the form: the direct form sends roots/list and sampling without tools unchecked, and an elicitation or a sampling request with tools that the client cannot take is not sent: its key reads `Failed(-32603 "Client does not support form elicitation.")` (JS's `SdkError` texts; with `FailRequest` the call ends with "Fulfilling input required by ...: <text>"); the shim form ends the call with "Cannot request input ..." as below. It parks the original message with the answers of the round. When the last answer arrives, `receive` dispatches the original message again (without the `enabled` check: JS looks a tool up once per request) and `Ctx.input` gives this round's answers only, as JS does. Limits: at most 8 rounds, after which `tools/call` gets `isError` "Multi-round-trip request 'tools/call' still required input after 8 rounds (inputRequired.maxRounds)" and the other methods get -32603. A deadline is set when `Input.Required.with_timeout_ms` is given, else 600 000 ms. Both values are JS parity. Before sending (shim form), each request is checked against the client capabilities of `initialize` (a bare `elicitation: {}` means form; URL mode needs `elicitation.url`; sampling with `tools`/`toolChoice` needs `sampling.tools`); a missing one ends the request at once with "Cannot request input '<key>' (<method>): the client on this 2025-era connection did not declare the required capability". A `NeedInput` with only a state (`Input.Required.keep_state`) runs the handler again at once. A returned `requestState` goes through `with_request_state_verifier` before the re-run.
- **State across rounds.** A JS handler that awaits a server-to-client request runs once, so its effects on app state happen once. Ours runs again from the top in each round, so the state it returns together with `NeedInput` is dropped by default: the transport continues from the state before that round (`Engine.state_after(server, before, after, outcome)`, which `Stdio.serve!` calls after each `run!`; `Server.with_input_round_state(Keep)` keeps it, the 0.1 rule). This holds in both eras (a modern `input_required` result also drops it; the retry is a new request). Work done before asking is redone in each round; a handler that must not redo it memoizes it in the request state (`with_state`, `Ctx.request_state`): legacy keeps it in the parked entry, modern round-trips it through the client and `with_request_state_verifier`.
- **One key per request per call.** `Ctx.input` gives only the previous round's answers, and the handler runs again from the start. A handler that asks twice in one call (e.g. a second roots request in a later round) must use a different key the second time, or it reads the first answer again; answers it needs across rounds go in `with_state`.
- **Failed and late answers.** `Server.with_input_failures(ToHandler)` (the default) runs the handler again when every request of the round is answered or timed out, and `Ctx.input` gives `Failed(McpError)` or `TimedOut` for those keys, so the handler can fall back (roc-syntax-mcp falls back to the environment when roots fail). `with_input_failures(FailRequest)` is the JS behaviour: the first error answer, or the deadline, ends the request with "Fulfilling input required by '<method>' failed: <message>" (`isError` for tools/call, -32603 for the others; the message of a timeout is "Request timed out"), and the requests still open are cancelled with `notifications/cancelled` (reason `ProtocolError: <message>` or `SdkError: Request timed out`, JS's strings). A timeout cancels the open requests in both modes.
- **Cancellation.** `notifications/cancelled` for a parked request drops it, and no response is sent. Its open server-to-client requests are cancelled with the client's `reason` (JS: `AbortError: This operation was aborted` when there is none). A late answer to them is logged and ignored. A request that is running cannot be interrupted, because the loop is sequential. By the time the loop reads the cancellation, the response has already been written.
- **Concurrency is honest.** One handler runs at a time. While a handler runs, the loop reads no stdin, so a ping waits until the handler ends. JS answers a ping in the meantime. Parked requests interleave with other traffic, like the await points of JS. A platform with a timed stdin read (`read_line!(Within(ms))`) gets deadlines that fire on time. basic-cli 0.28.1 has none, so a deadline fires when the next line arrives. basic-cli would need `Stdin.line_timeout!` or a poll.

## 3. Repository layout (Talon generic package, R-GP2 to R-GP7)

```
package/main.roc            package [ ...public modules... ] {}    (no dependencies)
package/*.roc               the public modules (section 4)
package/Internal/*.roc      hidden: Wire (JSON-RPC framing), Legacy (input shim, 2025 projections), Modern (envelope, discover,
                            subscriptions/listen; S5), Paging, Complete, Validate (result checks), Base64
tests/*.roc                 L0: `app [main!] { pkg: "../package/main.roc" }`, one `roc test` run per file
tests/e2e/<name>.in.jsonl   transcripts piped into a built example
tests/e2e/<name>.out.jsonl  the expected stdout, compared as JSON after canonical key order
examples/everything.roc     basic-cli app: every feature (the E2E target)
examples/hello.roc          basic-cli app: the smallest server (one tool)
scripts/test.sh             check, fmt --check, L0, build the examples, E2E. Every step capped (systemd-run, timeout)
scripts/e2e.sh              build examples/everything.roc, pipe each transcript, compare
.roc-version                nightly-2026-11-14-a87808d
.github/workflows/release.yml  copy of ../roc-semver/.github/workflows/release.yml: PACKAGE_DIR=package,
                            ROC_NIGHTLY from .roc-version, one <base58>.tar.zst asset, tag X.Y.Z
LICENSE                     UPL-1.0 (R-GP7). First line: `Copyright © 2026 Heorhii Bulakh and subsequent roc-mcp-sdk
                            authors <github.com/Karakatiza666/roc-mcp-sdk/graphs/contributors>`
README.md                   overview, import line with the release URL, the basic-cli adapter
```

**Licence consequence.** The JS SDK is under MIT, moving to Apache-2.0; the MIT notice is "Copyright (c) 2024-2025 Model Context Protocol a Series of LF Projects, LLC". Its documentation is under CC-BY-4.0. We **port no code and no doc text**. We implement from the MCP specification and from the behaviour inventory in section 7 (facts about a protocol, not expression). The LICENSE then has only our own copyright line. If an implementer copies code or doc comments, R-GP7 requires a second line: `Copyright © 2024-2025 Model Context Protocol a Series of LF Projects, LLC (portions: ...)`. Apache-2.0 portions also need their NOTICE text. Thus: do not copy. Short protocol strings ("Method not found", "Input validation error: ...") are wire behaviour that we reproduce, not ported text.

## 4. Public API

The signatures are those of `research/spikes/s4_api/package/`, and they type-check (12.1). That directory is the starting point of slice S0. Only the signatures are binding: the stub bodies there are placeholders. Notation: `T?` below means `Try(T, [None])`.

### 4.1 `JsonValue` (spikes s2, s3: `parse`, `to_str`, `get`, `get_or_null`, `as_str`, `to_*` and `from_i64` are implemented and tested; the other signatures type-check)
```roc
JsonValue := [Null, Bool(Bool), Number(Str), String(Str), Array(List(JsonValue)), Object(List((Str, JsonValue)))].{
	is_eq : _                                   # order-sensitive. Tests use `equivalent`
	parse : Str -> Try(JsonValue, [InvalidJson(Str)])   # max depth 256; a lone surrogate becomes U+FFFD
	to_str : JsonValue -> Str                   # compact; escapes " \ and control characters
	get : JsonValue, Str -> Try(JsonValue, [NotFound])
	get_or_null : JsonValue, Str -> JsonValue
	as_str : JsonValue -> Try(Str, [NotAString])
	as_bool, as_list, as_object, to_i64, to_u64, to_f64, to_dec   # Try(_, [Not<Kind>])
	from_i64, from_u64, from_dec : _ -> JsonValue   # also from_f64 : F64 -> Try(JsonValue, [NotFinite])
	equivalent : JsonValue, JsonValue -> Bool   # ignores object key order, compares numbers by value
	decode : JsonValue -> Try(a, [InvalidJson(Str)]) where [a.Json.Parseable(_)]      # through Encoding.Json
	decode_camel : (same, with Json.parser_camel)
	encode : a -> JsonValue where [a.Json.Encodable([])]
}
```
Apps build values with tags: `Object([("type", String("object"))])` where the type `JsonValue` is expected.

### 4.2 Definitions: `Schema`, `Content`, `Tool`, `ToolResult`, `Resource`, `ResourceContents`, `ResourceTemplate`, `Prompt`, `UriTemplate`

| Module | Main items |
| --- | --- |
| `Schema` | `object : List((Str, Schema.Prop)) -> JsonValue`, `Schema.Prop.required/optional : JsonValue -> Prop`, `string/integer/number/boolean : Schema.Opts -> JsonValue`, `enum : List(Str), Opts -> JsonValue`, `array : JsonValue, Opts -> JsonValue`, `any_of`, `with_keywords : JsonValue, List((Str, JsonValue)) -> JsonValue`, `described : Str -> Opts`, `none : Opts` |
| `Content` | `:: [Text, Image, Audio, ResourceLink, EmbeddedResource]`, `text`, `image(base64, mime)`, `image_bytes(List(U8), mime)`, `audio`, `resource_link(uri, name)`, `with_annotations`, `as_text`, `map_text`, `to_json`. Types `Content.Annotations` (audience, priority, lastModified) and `Content.Icon` (src, mimeType, sizes, theme) |
| `Tool` | `new(name)`, `with_title`, `with_description`, `with_input_schema` (the root must be `type: object`), `has_input_schema` (only such a tool's arguments are checked, as JS), `with_output_schema`, `read_only/destructive/idempotent/open_world : Tool, Bool -> Tool` (each one sent only when set), `annotation_title`, `with_icon`, `with_meta`, `name`, `to_json` |
| `ToolResult` | `text(Str)`, `error(Str)` (`isError: true`), `from_content`, `with_structured(JsonValue)`, `with_structured_value(a) where [a.Json.Encodable([])]`, `with_is_error`, `with_meta`, `content`, `with_content`, `is_error`, `map_last_text(Str -> Str)`, `to_json` |
| `Resource` | `new(uri, name)`, `with_title/description/mime_type/size/meta`, `uri`, `to_json` |
| `ResourceContents` | `text(uri, mime, text)`, `blob(uri, mime, base64)`; `:: [Text({...}), Blob({...})]` with `meta` |
| `ResourceTemplate` | `new(template, name)` (crashes on an invalid template, which is a programming error), `with_title/description/mime_type`, `name`, `uri_template` |
| `Prompt` | `new(name)`, `with_title/description`, `with_argument({ name, description, required })`, `user(Str)`, `assistant(Str)`, types `Prompt.Message` and `Prompt.Result : { description : Str?, messages : List(Prompt.Message) }` |
| `SchemaCheck` | `validate : JsonValue, JsonValue -> Try(JsonValue, [Invalid(List(Str))])` (schema, value: the parsed value as zod returns it, or zod's issues as `path: message`), `type_name`, `js_number`, `utf16_length`. Checks `type`, `properties`, `required`, `additionalProperties`, `items`, `enum`, `const`, `anyOf` (nullable and union rules), `default`, `min/maxLength`, `minimum`/`maximum`/`exclusive*`, `min/maxItems`; not `pattern`, `format`, `$ref`, `allOf` (accepted). See section 7 |
| `UriTemplate` | `parse : Str -> Try(UriTemplate, [InvalidTemplate(Str)])`, `match_uri : UriTemplate, Str -> Try(UriTemplate.Vars, [NoMatch])`, `expand`, `variable_names`, `to_str`. `Vars.get` (first value), `Vars.get_all`, `Vars.to_list`. The matching rules are the JS ones (section 7, row "URI templates") |

### 4.3 Outcomes, errors, input: `Outcome`, `McpError`, `Input`, `LogLevel`
```roc
Outcome(a) := [Done(a), NeedInput(Input.Required), Fail(McpError)]   # done, need_input, fail, map
McpError :: { code : I64, message : Str, data : JsonValue? }        # is_eq; new, with_data, code, message, data, to_json, from_json,
	# invalid_params, internal, method_not_found, resource_not_found(uri) (-32602 + data {uri}: JS parity),
	# url_elicitation_required(List(JsonValue)) (-32042), and the code constants
Input.Request := [ListRoots, ElicitForm({ message, requested_schema }), ElicitUrl({ message, url }), CreateMessage(JsonValue)]
Input.Required :: { requests, request_state, timeout_ms, progress_token }   # one(key, req), also(key, req), keep_state(state), with_state, with_timeout_ms,
	# with_progress_token : Input.Required, Bool -> Input.Required  (2025 wire form: False (default) = JS direct calls, True = JS inputRequired shim)
Input.Answer : [NotAsked, Answered(JsonValue), Failed(McpError), TimedOut]
Input.roots : JsonValue -> Try(List({ uri : Str, name : Str? }), [BadAnswer(Str)])   # a non-file:// uri: BadAnswer("roots.<i>.uri: Invalid string: must start with \"file://\"") (JS)
Input.file_uri_to_path : Str -> Try(Str, [NotAFileUri])   # Node's fileURLToPath on POSIX: host empty or localhost, ?/# dropped, dot segments, %-decoding (UTF-8), %2F refused
Input.elicitation : JsonValue -> Try([Accept(JsonValue), Decline, Cancel], [BadAnswer(Str)])
LogLevel := [Debug, Info, Notice, Warning, Error, Critical, Alert, Emergency]   # to_str, from_str, severity
```

### 4.4 `Ctx`: what a handler sees
`request_id : Ctx -> Try(JsonValue, [Notification])`, `method`, `era : Ctx -> [Legacy, Modern]`, `protocol_version`, `client_capabilities : Ctx -> JsonValue`, `has_client_capability : Ctx, Str -> Bool`, `client_info`, `meta` (`_meta` without the envelope keys; `Null` when absent), `progress_token`, `input : Ctx, Str -> Input.Answer` (the previous round's answers only), `request_state`, `round : Ctx -> U64` (0 on the first call), `session_id` (HTTP), `auth : Ctx -> Try(Ctx.AuthInfo, [None])` (HTTP).

For the engine and tests: `Ctx.new : Ctx.Parts -> Ctx` (a context whose writer drops every line), `Ctx.parts`, and `Ctx.LogThreshold : [All, AtLeast(LogLevel), Nothing]`.

**How the sends reach the wire (implemented in S4).** A `Ctx` holds one writer, `send! : Str => {}`, that takes a whole JSON-RPC line. The engine is pure, so every `Ctx` it puts in an `Engine.Call` has a writer that drops the line. The transport installs its writer right before it runs the call, and passes that `Ctx` to `run!`:

```roc
ctx = call.ctx.with_sender(|line| io.write_line!(line) ?? {})
(state2, outcome) = (call.run!)(state, ctx)
state3 = Engine.state_after(server, state, state2, outcome)   # drops the state of a NeedInput round
step = Engine.finish(server, session, call, outcome, io.now_ms!())   # pass the original `call`
```

Each send builds its line with a pure twin (`log_line : Ctx, LogLevel, JsonValue -> Try(Str, [Skip])`, `progress_line`, `list_changed_line`, `resource_updated_line`, `notify_line`) and writes it with `send!` unless the twin returns `Err(Skip)`. L0 tests call the twins on `call.ctx` (a test cannot run `run!`: `roc test` rejects effects, 11.2). An HTTP transport that queues lines per stream installs a writer that appends to its queue (through an effect such as its event store). Handlers never call `with_sender`.

The sends, each one written at once through the transport's writer:
- `log! : Ctx, LogLevel, JsonValue => {}` sends nothing below the session level, and nothing at all unless `with_logging` was set. The params are `{level, data}` (no `logger`).
- `progress! : Ctx, { progress : Dec, total : Dec?, message : Str? } => {}` sends only when the request has a progress token.
- `list_changed! : Ctx, [Tools, Resources, Prompts] => {}` (no params, as JS)
- `resource_updated! : Ctx, Str => {}`
- `notify! : Ctx, Str, JsonValue => {}`

In the modern era, the four change notifications (`list_changed!`, `resource_updated!`, and `notify!` with `notifications/{tools,prompts,resources}/list_changed` or `notifications/resources/updated`) go only to the `subscriptions/listen` subscriptions that asked for them, one line each with `_meta["io.modelcontextprotocol/subscriptionId"]`, and nowhere when none did; log, progress and other notifications go out unchanged (JS `StdioListenRouter`). The pure twins of these three are `list_changed_lines`, `resource_updated_lines` and `notify_lines : ... -> List(Str)` (added in S5; the `_line` twins keep giving the 2025 line). The engine gives a modern `Ctx` the session's subscriptions with `Ctx.with_subscriptions`. `with_sender` is for transports only.

### 4.5 `Server(state)`: the registry
```roc
new : { name : Str, version : Str } -> Server(state)
with_title, with_description, with_website_url, with_instructions : Server(state), Str -> Server(state)
with_icon : Server(state), Content.Icon -> Server(state)
with_logging : Server(state) -> Server(state)                       # capability + logging/setLevel
with_capability : Server(state), Str, JsonValue -> Server(state)    # experimental / extensions
with_page_size : Server(state), U64 -> Server(state)                # off by default (JS parity)
with_cache_hint : Server(state), Str, { ttl_ms : U64, scope : [Public, Private] } -> Server(state)
with_request_state_verifier : Server(state), (Ctx, Str -> Bool) -> Server(state)
with_protocol_versions : Server(state), { legacy : List(Str), modern : List(Str) } -> Server(state)
with_input_failures : Server(state), [ToHandler, FailRequest] -> Server(state)   # 2025 shim, see 2. Default ToHandler
with_input_round_state : Server(state), [Discard, Keep] -> Server(state)   # the state returned with NeedInput: dropped (default) or kept, see 2
tool : Server(state), Tool, (state, Ctx, args => (state, Outcome(ToolResult))) -> Server(state) where [args.Json.Parseable(_)]
tool_json : Server(state), Tool, (state, Ctx, JsonValue => (state, Outcome(ToolResult))) -> Server(state)
tool_enabled_when : Server(state), Str, (state -> Bool) -> Server(state)
around_tools : Server(state), (state, Ctx, Str, (state => (state, Outcome(ToolResult))) => (state, Outcome(ToolResult))) -> Server(state)
                                    # runs once per handler run: every input round (NeedInput), then the final Done
map_tool_results : Server(state), (state, Ctx, Str, ToolResult => (state, ToolResult)) -> Server(state)   # only the final Done (an around_tools)
with_input_validation : Server(state), Bool -> Server(state)          # SchemaCheck on tools/call and prompts/get arguments; default on
tool_input_validation : Server(state), Str, Bool -> Server(state)     # per tool (e.g. a JS z.preprocess tool)
resource : Server(state), Resource, (state, Ctx, Str => (state, Outcome(List(ResourceContents)))) -> Server(state)
resource_template : Server(state), ResourceTemplate, (state, Ctx, Str, UriTemplate.Vars => (state, Outcome(List(ResourceContents)))) -> Server(state)
template_list : Server(state), Str, (state, Ctx => (state, List(Resource))) -> Server(state)
template_complete : Server(state), Str, Str, Server.Completer(state) -> Server(state)
prompt : Server(state), Prompt, (state, Ctx, args => (state, Outcome(Prompt.Result))) -> Server(state) where [args.Json.Parseable(_)]
prompt_complete : Server(state), Str, Str, Server.Completer(state) -> Server(state)
on_notification : Server(state), Str, (state, Ctx, JsonValue => state) -> Server(state)
on_request : Server(state), Str, (state, Ctx, JsonValue => (state, Outcome(JsonValue))) -> Server(state)
on_subscribe : Server(state), (state, Ctx, Str => (state, Try({}, McpError))), (same, for unsubscribe) -> Server(state)
capabilities : Server(state) -> JsonValue
warnings : Server(state) -> List(Str)        # e.g. tool names outside ^[A-Za-z0-9._-]{1,128}$
parts : Server(state) -> Server.Parts(state) # the registry as a record, for the engine (Server is opaque)
Middleware(state), ToolEntry(state), ResourceEntry(state), TemplateEntry(state), PromptEntry(state), Subscribe(state), Parts(state)   # aliases of the registry
Completer(state) : state, Ctx, Str, Server.CompletionContext => (state, List(Str))
CompletionContext : { arguments : List((Str, Str)) }
```

Rules:
- The capabilities are derived from what is registered, as in JS. A tool gives `tools.listChanged: true`. A resource or template gives `resources.listChanged: true`. Any completer gives `completions: {}`. A prompt gives `prompts.listChanged: true`. `with_logging` gives `logging`. `on_subscribe` gives `resources.subscribe`. The keys come in the order of the first registration of each kind (JS builds the object the same way): `with_logging` first gives the JS order `logging, tools, resources, completions, prompts` for roc-syntax-mcp-like servers. `with_capability(k, v)` adds `k`, or merges `v` into a derived object (its keys win).
- A duplicate name (tool, resource URI, template, prompt) crashes when the server is built, as do `tool_enabled_when`, `template_list`, `template_complete` and `prompt_complete` for a name that is not registered, and `on_request` for a method the SDK serves.
- `Tool.with_input_schema` adds `"$schema":"https://json-schema.org/draft/2020-12/schema"` after `type` unless the schema has a `$schema` (`Schema.with_dialect`), and `Tool.with_output_schema` adds it first: the bytes JS sends for a zod schema. A tool without an input schema sends `{"type":"object","properties":{}}` (JS). JS also adds `additionalProperties: false` to a zod output object; add it with `Schema.with_keywords` for byte parity.
- Handlers are usually lambdas. A named handler needs a `=>` annotation (`echo : St, Ctx, { text : Str } => (St, Outcome(ToolResult))`): a named pure function is not accepted where `=>` is expected (12.15).
- `Server` values are usually top-level constants, which the compiler evaluates at compile time. That works with closures inside (12.3).

### 4.6 `Engine`: for transports and tests
```roc
latest_version : Str                    # "2025-11-25"; also legacy_versions, modern_versions
Engine.Session                          # new, waiting, current_era, is_initialized, negotiated_version, logging_level,
                                        # with_auth (HTTP: the request's auth, not stored), with_session_id,
                                        # to_json, from_json : JsonValue -> Try(Session, [BadSession(Str)]) (external stores)
Engine.Parked                           # a request waiting for input (inside Session)
Engine.Call(state) : { request_id, message : JsonValue, ctx : Ctx, run! : state, Ctx => (state, Outcome(JsonValue)) }
Engine.Step(state) : { session : Engine.Session, out : List(Str), calls : List(Engine.Call(state)), log : List(Str) }
receive : Server(state), Engine.Session, state, Str -> Engine.Step(state)          # one line
receive_json : Server(state), Engine.Session, state, JsonValue -> Engine.Step(state)
finish : Server(state), Engine.Session, Engine.Call(state), Outcome(JsonValue), U64 -> Engine.Step(state)  # U64 = now_ms
state_after : Server(state), state, state, Outcome(JsonValue) -> state   # before, after run!: drops the state returned with NeedInput (with_input_round_state)
expire : Server(state), Engine.Session, state, U64 -> Engine.Step(state)
next_deadline : Engine.Session -> Try(U64, [None])
close : Engine.Session -> List(Str)
```
`state` is read only in `receive`: it is used for the `enabled` predicates.

Changes made in S5 (additive): `Session` has an internal `probe` flag (a `server/discover` probe; `to_json` writes `"probe"`, `from_json` reads it when present), `Session.subscriptions` holds the open `subscriptions/listen` subscriptions (`{id, notifications, serverInfo}`), and `close` returns their final results. Responses and invalid messages no longer select the era.

Changes made in S4: `Step` gained `log` (diagnostics for stderr, e.g. a response with an unknown id or the reason of a -32600; the transport writes them to `log!`), and `Session` gained the accessors and setters above. HTTP auth reaches `Ctx.auth` through `Session.with_auth` before `receive_json`.

What `run!` returns, which is also what an L0 test gives `finish` as a scripted outcome, is the raw handler result, and `finish` makes the response from it: tools/call: `ToolResult.to_json` (then the output-schema check, the text block, the `{result}` wrap, base64/date validation); prompts/get: `Prompt.result_to_json`; resources/read: `{contents}`; resources/list: one `Array` of `Resource.to_json` per template with a `template_list`, in registration order (`finish` puts the static resources first, merges each template's metadata, pages); completion/complete: an `Array` of all candidate strings (`finish` keeps 100, adds `total`, `hasMore`); resources/(un)subscribe: `{}`; `on_request`: the result as is.

### 4.7 `Stdio`
```roc
Stdio.Io : { read_line! : [Forever, Within(U64)] => Try(Str, [EndOfInput, TimedOut]),
             write_line! : Str => Try({}, [Closed]), log! : Str => {}, now_ms! : () => U64 }
Stdio.serve! : Server(state), state, Stdio.Io => { state : state, stopped : [InputEnded, OutputClosed] }
```
The loop:
1. Compute the wait from `next_deadline`.
2. Read a line. An empty line is skipped.
3. On `TimedOut`, call `expire`.
4. On `EndOfInput`, write `close`, then return. stdin EOF ends the server. JS does not close on EOF, but its process exits.
5. Otherwise call `receive`, write `out`, and run each call: `finish`, then write.
6. If a write fails, return `OutputClosed`.

The lines are written with `write_line!`. basic-cli's `Stdout.line!` writes each line at once, with no buffering (measured, 11.5). Logs go only to `log!` (stderr).

### 4.8 `StreamableHttp(state)` (stub: every effectful function crashes "not implemented in this release")

**Superseded by slice S7:** the final API is in `package/StreamableHttp.roc` and the spec is in `docs/http.md`. Changes from the sketch below:
- `Io` gained `sessions : [InTransport, External(SessionStore)]` and `events : [Disabled, Enabled(EventStore)]`. The event store covers resumability with `Last-Event-ID`, the event bus, and delivery for parked requests.
- `notify!` now takes `Io` and a named `Change`.
- `Options` gained `retry_ms`.
- `EventStream.poll!` is now real.
- There is an `options` accessor.
- The pure helpers return a fail-closed 501 response rather than crashing (12.3).

The Engine must provide, for the future implementation, `auth` input on `receive_json` and `Engine.Session.to_json`/`from_json`.
```roc
Request : { method : Str, uri : Str, headers : List((Str, Str)), body : List(U8) }
Response : { status : U16, headers : List((Str, Str)), body : StreamableHttp.Body }
Body := [Bytes(List(U8)), Events(List(Event)), Open(EventStream)]   # Open: GET stream / subscriptions/listen
Event : { id : Str?, event : Str?, data : Str, retry_ms : U64? }
EventStream :: { poll! : () => Try(List(Event), [Closed]) }
Options : { sessions : [Stateful, Stateless], response_mode : [Auto, Sse, Json], legacy : [Serve, Reject],
            allowed_hosts, allowed_origins : List(Str), keep_alive_ms : U64, max_subscriptions : U64 }
Io : { new_session_id! : () => Str, now_ms! : () => U64, log! : Str => {},
       authenticate! : Request => Try(Try(Ctx.AuthInfo, [Anonymous]), [Unauthorized(Response)]) }
new : Server(state), Options -> StreamableHttp(state)               # real
default_options : Options                                            # real
handle! : StreamableHttp(state), state, Request, Io => { transport, state, response }   # crash
notify! : StreamableHttp(state), [ToolsChanged, PromptsChanged, ResourcesChanged, ResourceUpdated(Str)] => StreamableHttp(state)  # crash
validate_host, validate_origin : Request, List(Str) -> Try({}, Response)   # crash (pure: see 12.3)
oauth_metadata_response : JsonValue -> Response                    # crash
```
The types are our own records, so the package needs no dependency. A basic-webserver app maps `roc-lang/http` 1.0.0 `Request`/`Response` to them, and maps `Open` to `Sse.unfold!`. The API can be implemented later on the same `Engine`: one `Engine.Session` per `Mcp-Session-Id`, and a POST body is a `receive_json`.

### 4.9 The basic-cli adapter (in README and the examples)
```roc
io : Stdio.Io
io = {
	read_line!: |_wait| Stdin.line!().map_err(|_| EndOfInput),      # basic-cli 0.28.1 cannot wait with a timeout
	write_line!: |line| Stdout.line!(line).map_err(|_| Closed),
	log!: |line| Stderr.line!(line) ?? {},
	now_ms!: || Utc.now!().to_millis_since_epoch().to_u64_wrap(),
}
```
basic-cli 0.28.1's `Stdin.line!` returns `Err(EndOfInput | Interrupted | BadUtf8(..) | StdinErr(..))`. `BadUtf8` consumes the bad line. The adapter may map it to an empty line, which is skipped, rather than to an EOF.

## 5. Protocol behaviour in the engine

| Area | Rule |
| --- | --- |
| Versions | Legacy: `2025-11-25` (latest), `2025-06-18`, `2025-03-26`, `2024-11-05`, `2024-10-07`. `initialize` echoes a supported version and never fails: an unknown version (also `2026-07-28`) gets `2025-11-25`, and missing params are read as defaults (JS: -32603 with zod's issue list). A second `initialize` negotiates again (JS). The result is `{protocolVersion, capabilities, serverInfo, instructions?}`. Modern: `2026-07-28`. |
| Era selection | The first request or notification decides (JS `serveStdio`); a response or an invalid message before it is logged and leaves the era open. `initialize` without a valid modern claim, or any message without `_meta["io.modelcontextprotocol/protocolVersion"]`, gives legacy. A claim is validated: an invalid envelope gives -32602 "Invalid _meta envelope for protocol revision 2026-07-28: <key>: <problem>" with `data.envelope {key, problem}` (missing `protocolVersion`/`clientCapabilities` first, as "missing", then zod's texts for wrong types); a version not in `with_protocol_versions(...).modern` (a 2025 version included) gives -32022 with `data {supported, requested}`. Both leave the era open; a notification with such a claim is logged and dropped. A valid claim gives modern. `server/discover` makes a probe session (`current_era` is `Modern`): more discovers and claimed notifications keep it, a claimed request pins it, and any 2025 message (also a notification) replaces it with a fresh 2025 session. Once the session is modern, `initialize` without a valid claim gets -32022 (`requested` is its `protocolVersion`; without one: "Unsupported protocol version: the request did not name a protocol version", `data {supported}`); with a valid claim it is -32601. An empty `legacy` list (JS `legacy: 'reject'`) answers every 2025 request the same -32022 (`requested` only for `initialize`), ignores 2025 notifications, and leaves the era open. Later requests are not checked against the session's version (JS). |
| Legacy methods | `initialize`, `ping`, `tools/*`, `resources/list`, `resources/templates/list`, `resources/read`, `resources/subscribe`/`unsubscribe` (only with `on_subscribe`), `prompts/*`, `completion/complete` (only with completers), `logging/setLevel` (only with logging), custom `on_request` methods. Any other method gets -32601 "Method not found". Requests before `initialize` are served (JS parity). |
| Modern methods | `server/discover`, `tools/*`, `prompts/*`, `resources/list`, `resources/templates/list`, `resources/read`, `completion/complete`, `subscriptions/listen`, and custom `on_request` methods. The 2025 spec methods the revision removed (`initialize`, `ping`, `logging/setLevel`, `resources/(un)subscribe`, `tasks/*`, `roots/list`, `sampling/createMessage`, `elicitation/create`) get -32601, as does any method not served; this check comes before the envelope check. Every request then needs the envelope: none of the reserved keys gives -32602 "Request is missing the required _meta envelope for protocol revision 2026-07-28 (io.modelcontextprotocol/protocolVersion, io.modelcontextprotocol/clientCapabilities)", a bad one "Invalid _meta envelope for protocol revision 2026-07-28: <zod texts joined by '; '>" (no data). `server/discover` answers `{supportedVersions, capabilities, instructions?}` (the `tasks` capability removed). Every result gets `resultType: "complete"` unless it has one; a custom result with another `resultType` gets -32603 "Internal error" (only tools/call, prompts/get and resources/read may carry another). The cacheable results (`tools/list`, `prompts/list`, `resources/list`, `resources/templates/list`, `resources/read`, `server/discover`) get top-level `ttlMs` and `cacheScope`: `with_cache_hint(method, ...)`, else 0 and `private`. Every result, `input_required` included, gets `_meta["io.modelcontextprotocol/serverInfo"]` (the `serverInfo` of `initialize`), appended last. tools/list sends output schemas unwrapped, and tools/call results are never wrapped as `{result}` (the text block for a non-object `structuredContent` stays). The Ctx comes from the envelope of each request: `client_capabilities`, `client_info`, `protocol_version`, `meta` without the reserved keys, and the log level: a log line goes out only when the envelope has `logLevel`, at that level or above. Notifications: the removed ones (`initialized`, `roots/list_changed`, `tasks/status`, `elicitation/complete`) are ignored; custom ones reach `on_notification` with or without an envelope. |
| `subscriptions/listen` (modern, stdio) | Served by the engine, with its own envelope check: no claim gives -32602 "Invalid _meta envelope: _meta: the per-request envelope is required on protocol revision 2026-07-28", a bad envelope "Invalid _meta envelope: <key>: <problem>" (no data), a version not served -32022. More than 1024 open subscriptions: -32603 "Subscription limit reached". A `params.notifications` that is not a valid filter: -32602 "Invalid params: 'notifications' is required and must be a valid SubscriptionFilter". The answer is no result but `notifications/subscriptions/acknowledged` with `{notifications: <honoured>, _meta: {"io.modelcontextprotocol/subscriptionId": <listen id>}}`: the `true` flags whose `listChanged` capability is advertised and a non-empty `resourceSubscriptions` when `resources.subscribe` is (`on_subscribe`). From then on `Ctx.list_changed!`, `resource_updated!` (and `notify!` with one of those four methods) write one line per subscription that asked for it, with `params._meta.subscriptionId`, and nothing when none did; other notifications (log, progress, custom) go out as is. `notifications/cancelled` with a listen id ends that subscription. `Engine.close` writes `{"jsonrpc":"2.0","id":<listen id>,"result":{"resultType":"complete","_meta":{subscriptionId, serverInfo}}}` for each open one (JS on `handle.close()`; `Stdio.serve!` calls `close` at stdin EOF). |
| input_required | Legacy: the shim of section 2. Modern: `NeedInput` becomes the result `{resultType:"input_required", inputRequests?:{key:{method, params?}}, requestState?}` (form elicitation params `{message, requestedSchema, mode:"form"}`, URL `{message, url, mode:"url"}`, no `elicitationId`). Each request is checked first against the envelope's capabilities: the first one missing gives -32021 "Cannot request input '<key>' (<method>): the request's client capabilities do not declare the required capability" with `data.requiredCapabilities` (only the missing part: `{roots:{}}`, `{sampling:{}}`, `{sampling:{tools:{}}}`, `{elicitation:{form:{}}}`, `{elicitation:{url:{}}}`; a bare `elicitation: {}` declares form). Neither requests nor state: -32603. Only `tools/call`, `prompts/get` and `resources/read` may return it; any other method gives -32603 "Handler for <method> returned an input-required result, but only tools/call, prompts/get and resources/read support input_required (protocol revision 2026-07-28)". The retry is a new request: its `params.inputResponses` fill `Ctx.input` (`Answered`; an entry that is not an object or wraps `method`/`result` is dropped, so it reads `NotAsked`), `Ctx.round` is 1 when `inputResponses` or `requestState` is present, and a `requestState` of those three methods goes through `with_request_state_verifier`: a refused or non-string one gives -32602 "Invalid or expired requestState" with `data {reason: "invalid_request_state"}`. On other methods both fields are ignored. There are no rounds or deadlines on the server side. |
| tools/call | Unknown tool: -32602 "Tool X not found"; disabled: -32602 "Tool X disabled" (JS). Missing `params`, no string `name`, or `arguments` present and not an object (`null` included): -32602 "Invalid tools/call request: <zod's issue list>", the list as JS prints it (`JSON.stringify(issues, null, 2)`, `invalid_type` issues with path `params`/`params.name`/`params.arguments`, `expected` `object`/`string`/`record`); this check comes before the tool lookup. Missing `arguments` are `{}`. For a tool with an input schema, the arguments are checked by `SchemaCheck` (unless turned off): a failure is an `isError` result "Input validation error: Invalid arguments for tool X: <zod's issues joined by ', '>" and the handler gets the parsed value (unknown keys dropped, defaults filled). Undecodable arguments after that: the same result with the decoder's message. `Fail(e)` becomes a JSON-RPC error, except that JS turns every thrown error but -32042 into `isError`; for that, a handler returns `ToolResult.error`. With `outputSchema`, a non-error result without `structured` becomes an `isError` result "Output validation error: Tool X has an output schema but no structured content was provided". In both eras, a non-object `structured` (array, scalar, `null`) gets a text block with its JSON when the result has no text block. Legacy only: a non-object `structured`, or any `structured` when the output schema's root is not `type: object`, is wrapped as `{result: ...}`, and such an output schema is listed as `{$schema?, type: "object", properties: {result: <schema>}, required: ["result"]}`. A result with invalid base64 (`data` of image/audio, `blob`) or a `lastModified` that is not ISO 8601 gets -32602 "Invalid tools/call result: <path>: <reason>" (JS rejects it too, with zod's issue list); the same check runs on resources/read and prompts/get results. -32002 is sent as -32602 (JS 2025 codec). |
| prompts/get | Missing `params`, a `name` that is not a string, or `arguments` that are not an object of strings: -32603 with zod's issue list as the message (JS's request schema; paths `params.arguments.<key>` for each non-string value). Unknown: -32602 "Prompt X not found"; disabled: "Prompt X disabled". A prompt with declared arguments (`with_argument`, JS `argsSchema`): no `arguments` gives -32602 "Invalid arguments for prompt X: Invalid input: expected object, received undefined", a missing required one "...: <name>: Invalid input: expected string, received undefined"; undeclared ones are dropped. A prompt without declared arguments takes anything. |
| resources | All resource methods are served once any resource or template is registered. `resources/list` returns the static resources, then each template's `template_list` result, with the template's metadata merged in as JS `{...metadata, ...entry}` (a shared key keeps the metadata's position with the entry's value). `resources/read`: an invalid URI (no `scheme:`, or spaces) gives -32602 "Resource URI X is invalid" with `data {uri, reason:"invalid_uri"}`; we do not normalize URIs as JS `new URL` does. Static resources are tried first, then templates in registration order. No match gives -32602 "Resource not found: X" with `data {uri}`. `resources/subscribe`/`unsubscribe` call `on_subscribe`'s functions; `Ok` is `{}`. |
| completion/complete | Served once any completer is registered. `ref/prompt` uses the argument's completer ("Prompt X not found" / "disabled" otherwise). `ref/resource` uses the template whose source equals `ref.uri`; a static resource's URI gives the empty result; anything else gives -32602 "Resource template X not found". With no completer the result is `{values:[], hasMore:false}` (no `total`). A bad ref type gives -32602 "Invalid completion reference" (JS: -32603 with zod's list). At most 100 values are returned, with `total` and `hasMore`. `context.arguments` (string values) reaches the completer. |
| Pagination | Off by default: everything is returned and the `cursor` is ignored (JS). With `with_page_size(n)`, the cursor is the decimal offset (canonical digits, at most the list length) and `nextCursor` is set while items remain; an invalid cursor gives -32602 "Invalid cursor". Applies to tools/list, prompts/list, resources/list (after merging) and resources/templates/list. |
| logging | `logging/setLevel` stores the level in the session and answers `{}`. `Ctx.log!` filters by it. With no level set, everything is sent. An unknown level gives -32602 (JS: -32603 with zod's list). Without `with_logging`: -32601. |
| notifications in | `initialized` marks the session and also calls its `on_notification` handler. `cancelled` drops a parked request. `roots/list_changed` and the others call `on_notification`. A notification with no handler (and client `notifications/progress`) is ignored. |
| Framing | One JSON value per line. A bare `\r` at the end is stripped; a blank line gives nothing. A line that is not JSON gets -32700 "Parse error" with `id: null`; JS skips it silently (open question Q1). A JSON array (or any non-object) gets -32600 "Invalid Request" with `id: null`, because batching was removed after 2025-03-26 (JS stdio drops it). A response with an unknown id is logged (`Step.log`) and ignored. An object that is not JSON-RPC 2.0 (no or wrong `jsonrpc`, non-string `method`, non-object `params`, a bad `id`) gets -32600 with its id when the id is a string or an integer, else `null` (JS drops all of these). `id` is a string or an integer; big integers keep their text. A line over 10 MB gets -32600 and a log line (JS closes the transport). |

## 6. Error handling

- **Protocol errors** come from the engine as JSON-RPC errors, or from handlers as `Outcome.fail(McpError)`. The codes are -32700, -32600, -32601, -32602, -32603, -32020, -32021, -32022 and -32042. Like JS, the engine never sends -32002 (it accepts it on input).
- **Tool failures that the model should see** are `ToolResult.error(text)` (`isError: true`).
- **Programming errors** crash at build time: an invalid URI template, a duplicate name, an input schema whose root is not an object. The `Server` is usually a compile-time constant, so these surface at compile time (12.3).
- The SDK never crashes on input. A malformed message is an error response or a log line. Our `JsonValue.parse` has a depth limit (256). A line longer than 10 MB is refused with -32600: JS closes the transport, and we keep serving.
- `Stdio.serve!` returns instead of crashing. The app decides the exit code. roc-syntax-mcp exits non-zero only when the transport fails to open, which cannot happen on stdio.

## 7. JS SDK 2.0.0 feature parity

Status: **S** supported, **D** supported differently, **T** stub (HTTP), **N** not applicable.

| Feature (JS) | St | Roc / reason |
| --- | --- | --- |
| `initialize`, version negotiation, `serverInfo` (name, version, title, description, websiteUrl, icons), `instructions` | S | `Server.new`, `with_*`, the engine |
| Capabilities derived from registrations, `registerCapabilities`, experimental/extensions | S | automatic, plus `with_capability`. There is no "after connect" error, because the `Server` is immutable |
| `ping` (inbound) | S | engine |
| `Server.ping()` (outbound) | N | unused. There is no request API outside `input_required` |
| tools/list, tools/call, inputSchema (Standard Schema), outputSchema, structuredContent rules, annotations, icons, `_meta`, title | D | hand-written JSON Schema (`Schema`) instead of zod. Arguments are checked against it by `SchemaCheck` with zod 4.4.3's messages, then decoded into a Roc type (`tool`) or passed as JSON (`tool_json`). Not reproduced: `pattern` and `format` checks, `$ref`/`allOf`, and zod transforms that a JSON Schema does not show (`z.preprocess`, refinements): turn the check off for such a tool (`tool_input_validation`) and check by hand |
| `RegisteredTool.enable/disable/update/remove`, `send*ListChanged` | D | `tool_enabled_when(state -> Bool)` plus `Ctx.list_changed!`. `update` is not supported: a definition is fixed when built |
| Tool name check (warning) | S | `Server.warnings`, which `Stdio.serve!` logs at start |
| resources (static), ResourceTemplate (`list`, `complete`), URI templates (`{x}`, `+`, `#`, `.`, `/`, `?`, `&`, `*`), resources/read errors | S | `resource`, `resource_template`, `template_list`, `template_complete`, `UriTemplate` (JS matching quirks kept: no percent-decoding, `{#x}` matched without `#`) |
| resources/subscribe/unsubscribe, `sendResourceUpdated` | S | `on_subscribe`, `Ctx.resource_updated!`. JS has no built-in handler; we add one |
| prompts/list, prompts/get, argsSchema, `completable()` | D | `prompt` (typed string-map arguments; the argument list is given explicitly with `with_argument`), `prompt_complete` |
| completion/complete (100 cap, total, hasMore, context.arguments) | S | engine |
| logging/setLevel, notifications/message, level filter, `sendLoggingMessage` | D | `with_logging`, `Ctx.log!`. Logging works only inside a handler: there is no loop-level sender. No `logger` field |
| Malformed input (not JSON, batches, invalid JSON-RPC, bad params of SDK methods) | D | JS stdio drops malformed lines and answers bad params with zod issue dumps (-32602 or -32603). We answer -32700/-32600 (Q1) and -32602 with a short message (5) |
| Invalid results (bad base64, bad ISO `lastModified`) | S | -32602 "Invalid <method> result: <path>: <reason>"; JS adds zod's issue list |
| progress notifications (ctx.mcpReq.notify with progressToken) | S | `Ctx.progress!` |
| inbound `notifications/cancelled` → AbortSignal, no response | D | a parked request is dropped with no response. A running handler cannot be interrupted (sequential loop) |
| list_changed notifications | S | `Ctx.list_changed!` |
| pagination | S | none by default (parity). Optional `with_page_size` |
| server→client roots/list, sampling/createMessage (with tools), elicitation/create (form, url), timeouts, `resetTimeoutOnProgress` | D | only through `Outcome.need_input` plus `Ctx.input` (D3), legacy shim with 8 rounds, JS capability gate and JS failure texts. Ids are integers from 0 (JS parity); the request form is the JS direct call's by default and the JS shim's with `with_progress_token(Bool.True)`. URL elicitations get `elicitationId: "mcp-sdk-<n>"` (JS shim: a random UUID; direct: the app's). Error and late answers reach the handler (`Failed`/`TimedOut`) by default; `with_input_failures(FailRequest)` ends the request as JS does (2). Answers are not schema-checked by the engine (JS rejects e.g. a bad elicitation `action` or a non-`file://` root); `Input.roots`/`Input.elicitation` report `BadAnswer` (`Input.roots` with JS's path and text for a non-`file://` root). The timeout is enforced only by a transport that can wait. `resetTimeoutOnProgress`: N (progress on server→client requests is ignored) |
| `inputRequired` helpers, `acceptedContent`, `requestState`, `createRequestStateCodec` (HMAC) | D | `Input.*`, `Ctx.input`, `Ctx.request_state`, `with_request_state_verifier`. The HMAC codec comes later; it can be built on `Crypto.SHA256` |
| elicitation `-32042` UrlElicitationRequired, `notifications/elicitation/complete` | S | `McpError.url_elicitation_required`, `Ctx.notify!` |
| `getClientCapabilities`, `getClientVersion`, `getNegotiatedProtocolVersion` | S | `Ctx.client_capabilities`, `client_info`, `protocol_version` |
| `setRequestHandler` / `setNotificationHandler` for custom or spec methods, fallback handlers | D | `on_request` and `on_notification` for methods the SDK does not own. Overriding a spec method is not supported |
| `oninitialized` | S | `on_notification("notifications/initialized", ...)` |
| JSON-RPC batching | N | stdio has no batching in JS either. HTTP legacy batching is part of the HTTP stub |
| `_meta` (request, results, content, definitions), W3C trace keys | S | `Ctx.meta`, `with_meta` on every definition and result |
| Protocol revision 2026-07-28 over stdio (`serveStdio`): era selection by the first message, probe and fallback, `server/discover`, the per-request envelope, `resultType`, `ttlMs`/`cacheScope` (`cacheHints`), serverInfo in `_meta`, `input_required` (`inputRequired`, `inputResponses`, `requestState.verify`), `subscriptions/listen` and routed change notifications, removed methods, `legacy: 'reject'` | S | engine, modern era (slice S5), section 5. Differences: the envelope's zod texts are reproduced for the reserved keys, `clientInfo.name/version` and the `roots`/`sampling`/`elicitation` capability types only (deeper capability shapes are not checked); a cache hint is per method (`with_cache_hint`, both fields), JS also has per-resource hints and partial hints (N); `maxSubscriptions` is fixed at 1024 |
| tasks (2025-11-25) | N | JS has no runtime: schemas only |
| `debouncedNotificationMethods` | N | one handler at a time. A handler sends a list_changed once |
| `jsonSchemaValidator` (AJV, cfworker), `fromJsonSchema`, Standard Schema | D | `SchemaCheck`: the subset `Schema` emits, with zod's messages (see the tools row). No elicitation-content validation |
| stdio transport (`StdioServerTransport`, `serveStdio`, max buffer 10 MB) | S | `Stdio.serve!` (EOF ends the loop) |
| Streamable HTTP: `WebStandardStreamableHTTPServerTransport`, `createMcpHandler` (sessions, SSE, JSON mode, event store/resumability, GET/DELETE, header checks -32020) | T | `StreamableHttp` (4.8). Resumability: N in this release |
| DNS-rebinding helpers, bearer auth, OAuth metadata (RFC 9728) | T | `validate_host`, `validate_origin`, `Io.authenticate!`, `oauth_metadata_response` |
| `InMemoryTransport`, `InMemoryServerEventBus` | D | `Engine.receive`/`finish` drive a server in tests without any transport |
| `McpServer.close`, `isConnected`, `onclose`/`onerror` | D | `serve!` returns `stopped`. Errors go to `log!` |

## 8. roc-syntax-mcp mapping (benchmark)

Every SDK use in `src/server.ts` and `src/index.ts`, and its Roc form. `research/spikes/s4_api/port_sketch.roc` type-checks the main ones.

| roc-syntax-mcp (TS) | Roc |
| --- | --- |
| `new McpServer({name, version, description, websiteUrl}, {instructions})` (l.900) | `Server.new({name, version}).with_description(..).with_website_url(..).with_instructions(..)` |
| `createServer(config)` closure state: `detected`, `detecting`, `stillFetching`, `stillFetchingTold`, `fetching`, `pluginProblemsShown`, `DetectionCache`, `ScopeRegistry` caches, `projectIndex` | one `App` record, threaded through every handler (D2). The `detecting` and `fetching` promises are not needed, because calls never overlap. A background `roc deps` is a basic-cli `Cmd.spawn!` `Child` kept in `App` and checked with `Child.poll!` |
| `registerTool` wrapper (l.936): append `stillFetchingNote()` to the last text block | `map_tool_results(still_fetching_note!)` with `ToolResult.map_last_text`: runs on the final result only, as the JS wrapper does (`around_tools` would also see each input round) |
| `registerTool(name, {title, description, annotations, inputSchema: z.object})`, 8 tools | `.tool(Tool.new(..).with_title(..).with_description(..).with_input_schema(Schema.object(..)).read_only(..).open_world(..), handler!)` |
| `READ_ONLY = {readOnlyHint:true, openWorldHint:false}`, `READ_ONLY_FETCHES` | `.read_only(True).open_world(False)` and `.read_only(True).open_world(True)` |
| zod `optional`, `enum`, `int().positive()`, `describe` | `Schema.Prop.optional`, `Schema.enum`, `Schema.with_keywords(Schema.integer(..), [("exclusiveMinimum", 0), ("maximum", 9007199254740991)])`. `SchemaCheck` gives zod's messages before the handler runs |
| `QUERY_LIST = z.preprocess(string → [string], array.min(1).max(8))` | `tool_json` with a `JsonValue` match (sketch `search_symbols!`) and `tool_input_validation(name, Bool.False)`: zod emits only the array schema (`{minItems, maxItems, type: "array", items}`, not required), which does not show the preprocess, so the handler checks the arguments itself |
| `scopeArg` (enum, or a refined string when it is too big) | `Schema.enum` or `Schema.string`, the same branch logic in app code |
| handler returns `{content:[{type:"text", text}]}` / `{..., isError: true}` (`badInput`, roc_check `isError: !ok`) | `ToolResult.text`, `ToolResult.error`, `.with_is_error(!ok)` |
| no `outputSchema`, no `structuredContent` (asserted by resources.test.ts) | we send neither unless they are set |
| `server.server.getClientCapabilities()?.roots` (l.189) | `ctx.has_client_capability("roots")` |
| `server.server.listRoots({}, {timeout: 2000})`, catch → env fallback, `fileURLToPath(first file:// root)` | `Outcome.need_input(Input.Required.one("roots", ListRoots).with_timeout_ms(2000))` (the default form is the direct call's: `params: {}`, integer id), then `Input.roots(answer)` (JS's `file://` check) and `Input.file_uri_to_path` on the call again. `Failed`/`TimedOut` fall back to the env (sketch `detection_root`). The tool re-runs from the start, and that is safe because detection is the first step of each tool. The 2 s limit is exact only with a timed read (section 2). In the modern era the same code returns `input_required` to the client |
| `ensureDetection()` at the top of each tool, TTL via `Date.now()` | `ensure_detection!(app, ctx) => Try(App, Input.Required)`. The clock comes from basic-cli `Utc.now!` inside the handler |
| `fetchPinnedReleases`: `Promise.race(run, timeout)`, continue in background | app logic with basic-cli `Cmd` (`timeout_value`, `spawn!`, `Child.poll!`). Out of scope for the SDK |
| `execFile(roc, ["fmt"...], {timeout: 30000})`, roc check with timeouts, scratch dirs | basic-cli `Cmd` with a timeout, `Env.create_temp_dir_in!`, `File`, `Path`. Out of scope |
| `registerResource(name, uri, {title, description, mimeType}, cb)`, 3 static resources | `.resource(Resource.new(uri, name).with_title(..).with_description(..).with_mime_type(..), read!)` returning `[ResourceContents.text(uri, mime, text)]` |
| `new ResourceTemplate(tpl, {list, complete: {var: prefix filter}})`, 5 templates, callback `(uri, {vars})` with `Array.isArray(v) ? v[0] : v` | `.resource_template(ResourceTemplate.new(tpl, name)..., read!)`, `.template_list(name, list!)`, `.template_complete(name, var, completer!)`. `vars.get(name)` gives the first value |
| `throw new Error("Unknown topic: ...")` in a resource callback | `Outcome.fail(McpError.internal("Unknown topic: ..."))`: a plain thrown Error is -32603 with its message in JS |
| `server.server.setNotificationHandler("notifications/roots/list_changed", {params: z.any()}, () => invalidate)` (l.2793) | `.on_notification("notifications/roots/list_changed", \|app, _ctx, _params\| { ..app, detected: Err(NotYet), ... })` |
| `console.error(...)` diagnostics in index.ts and server.ts | basic-cli `Stderr.line!` (`io.log!`) |
| `serverConfig(process.argv, process.env)`, `--platform=`, `--workspace=` | basic-cli `main!` args and `Env.var!`. App code |
| `await createServer(config).connect(new StdioServerTransport())` | `Stdio.serve!(server, init_app, io)` in `main!` |
| tests: `InMemoryTransport.createLinkedPair()`, `LATEST_PROTOCOL_VERSION` | L0 tests that drive `Engine.receive`/`finish`. Full sessions run E2E against the built app. `Protocol` constants are in `Engine` (`latest_version`) |

**What basic-cli 0.28.1 lacks for a fully lossless port:**
1. A stdin read with a timeout, or a poll. Without it, the 2 s `listRoots` limit fires late, and a ping is not answered during a long handler.
2. Nothing else: it has `Cmd` (timeouts, spawn, poll, kill), `File`, `Path`, `Env`, `Utc`/`Monotonic`, `Sleep`, and `Http` for release fetches.

## 9. Testing strategy

| Level | What | How |
| --- | --- | --- |
| L0 (`roc test tests/*.roc`) | `JsonValue` (round trips, escapes, surrogates, numbers, depth, errors), `Schema`, the `to_json` of each type, `UriTemplate` (the JS regex cases), and the **whole protocol through `Engine`**: transcripts as lists of lines. Tests assert the `out` lines with `JsonValue.equivalent`, and give scripted outcomes to `finish` for each `Call`: negotiation, both eras, every method and error, the input shim (park, answer, re-dispatch, cancel, expire, 8 rounds), pagination, completion, log filter, subscriptions | Each test file starts with `app [main!] { pkg: "../package/main.roc" }` (roc-semver pattern). Handlers in test servers are pure lambdas, which are accepted where `=>` is expected (spike s3). |
| L0 helper | `tests/Support/Session.roc` (imported by test apps as `import Support/Session`; a test app cannot import hidden package modules): `run : Server(s), s, List(Str), (Engine.Call(s) -> Outcome(JsonValue)) -> List(Str)` drives a transcript with a pure stand-in for each handler; `drive` (from a session, at a time, returning session, out and log), `settle`, `expire`, `json`, `same` (JSON-equivalent lines), `first_has`, `tool_name`, `text`, `no_calls`. Expected lines are JS SDK 2.0.0 stdio transcripts, compared byte for byte (key order included) where we match JS. Handler bodies, `around_tools` and the effectful sends are covered by E2E (S6); L0 checks the sends through the `Ctx.*_line` twins | `tests/engine_{lifecycle,framing,tools,resources,ctx,paging,shim,modern,modern_input}.roc`; `tests/schema_check.roc` (zod 4.4.3 messages captured from the JS SDK, one expect per call); the modern ones use `tests/Support/Modern.roc`, the twin of the JS server `.tmp/s5/js/l0.mjs` |
| L1 (fuzz, optional) | `fuzz/json_roundtrip.roc`: parse, then `to_str`, then parse is stable, and the parser never crashes | roc-semver's `scripts/test.sh` pattern |
| E2E | `scripts/e2e.sh` builds `examples/everything.roc` (basic-cli) with `roc build`, pipes each `tests/e2e/*.in.jsonl` and compares with `*.out.jsonl` after canonical sorting (`python3 -c` json sort_keys). Covers handler effects, `Ctx.log!`/`progress!`, state threading, EOF, and a broken stdout | capped as in the machine rules. Use `roc build`, never `roc run` (12.12). |
| Differential (later) | the same transcripts against a tiny JS server built on `@modelcontextprotocol/server` 2.0.0 (node, from `roc-syntax-mcp/node_modules`). Diff the outputs, ignoring documented differences | `scripts/differential/` |

## 10. Work breakdown (implementer slices)

Each slice owns its files and nobody else edits them. A change to a shared signature goes through S0's owner (the lead). The signatures are frozen from `research/spikes/s4_api/package/`.

| Slice | Depends on | Files owned | Done when |
| --- | --- | --- | --- |
| **S0 scaffold** (first, small) | none | `package/main.roc`; copies of every `s4_api` module as stubs; `LICENSE`; `.roc-version`; `.gitignore`; `scripts/test.sh`; `README.md` (skeleton) | `roc check package/main.roc` is clean. The stubs are in place for all slices |
| **S1 JSON** | S0 | `package/JsonValue.roc`, `package/Schema.roc`, `package/Internal/Base64.roc`, `tests/json.roc`, `tests/schema.roc`, `fuzz/json_roundtrip.roc` | 4.1 is complete. The spike s2 tests pass and more are added |
| **S2 types** | S0 (S1 API) | `Content`, `Tool`, `ToolResult`, `Resource`, `ResourceContents`, `ResourceTemplate`, `Prompt`, `Input`, `Outcome`, `McpError`, `LogLevel`; `tests/types.roc` | every `to_json` matches the JS wire shape; `Input.roots` and `Input.elicitation` decode |
| **S3 URI templates** | S0 | `package/UriTemplate.roc`, `tests/uri_template.roc` | the JS operator table and its quirks (section 7) |
| **S4 engine (legacy)** | S1, S2, S3 APIs | `package/Engine.roc` (session, dispatch and shim: they need the `Session` type, so they live with it), `package/Server.roc`, `package/Ctx.roc`, `package/Internal/{Wire,Legacy,Paging,Complete,Validate}.roc`, `tests/Support/Session.roc`, `tests/engine_*.roc` | section 5 for 2025: every row has a test. Done: 158 L0 expects in 7 files |
| **S5 engine (2026-07-28)** | S4 | `package/Internal/Modern.roc` (envelope, discover, resultType, cache hints, input_required out, subscriptions/listen), `tests/engine_modern.roc`, `tests/engine_modern_input.roc`, `tests/Support/Modern.roc`, `tests/e2e/modern_*`. It adds hooks to Engine.roc only by changes that the S4 owner reviews | the modern rows of section 5. Done: 2 L0 files, 5 E2E transcripts |
| **S6 stdio and examples** | S4 | `package/Stdio.roc`, `examples/hello.roc`, `examples/everything.roc`, `tests/e2e/*`, `scripts/e2e.sh` | E2E is green; the README adapter compiles |
| **S7 HTTP stub and docs** | S0 | `package/StreamableHttp.roc`, the final `README.md` | 4.8 type-checks; README covers install, adapter, example, the parity table summary |
| **S8 release** | S1 to S7 | `.github/workflows/release.yml`, `.github/workflows/ci.yml` (copied from roc-semver) | a dry-run PR build makes exactly one `<base58>.tar.zst` from `package/` |
| **S9 port** (another repo) | release 0.1.0 | roc-syntax-mcp Roc port | section 8 |

Parallelism:
1. S0 first.
2. Then S1, S2, S3 and S7 in parallel.
3. S4 can start in parallel against the stub APIs. Its tests go green once S1 to S3 land.
4. S5 and S6 in parallel after S4.
5. S8 last.

## 11. Spike results (nightly-2026-11-14-a87808d, basic-cli 0.28.1)

| # | Question | Result |
| --- | --- | --- |
| 11.1 | Effectful callbacks in a package, a generic `Server(state)`, handlers in a List of records, a Dict of handlers, a loop that calls them (s1) | **Works.** `serve!` in a package calls app handlers stored in `List({name, run! : state, Str => (state, Str)})`. `Dict(Str, (state, Str => (state, Str)))` works too (echo host). A pure lambda is accepted where `=>` is expected. |
| 11.2 | Can `roc test` run effectful code? | **No.** "effectful expect: Keep expect conditions pure". This is the reason for D1. |
| 11.3 | Dynamic JSON (s2) | `Encoding.Json` has no dynamic type. Our `JsonValue` (≈300 lines) passes 11 tests: escapes, `\u` with surrogate pairs, a lone surrogate to U+FFFD, `[1,]`/`01`/trailing data rejected, a 20-digit id kept exactly, Dec/I64 accessors. Speed: 20 000 objects, 1.76 MB: encode 9 ms / parse 13 ms (dev), 7 / 10 ms (`--opt=speed`), max RSS 27 MB. |
| 11.4 | Typed records from JSON (s2, s3) | `Json.parse(value.to_str())` into `{ text : Str, times : Try(U64, [Missing]) }` works, as do `scope ?: Str` and `{}`. The error text is `InvalidJson("Missing field: text")`. Needs `where [a.Json.Parseable(_)]` (12.1). |
| 11.5 | Stdio on basic-cli (s3) | `Stdin.line!` reads lines and returns `Err(EndOfInput)` at EOF. The loop ends and the final state is returned. Interactive pipes: each `Stdout.line!` reaches the reader at once (python select test, < 1 ms per round trip), so there is no buffering problem. stderr is separate. |
| 11.6 | Server→client request while other traffic flows (s3) | **Works.** `tools/call where` sends `{"id":"srv-0","method":"roots/list"}`. A ping and another `tools/call` that arrive in the meantime are answered. The client's answer re-runs `where`, which then answers id 5. `roots/list_changed` resets the cached state. An unanswered request at EOF is reported. -32700 and -32601 work. The pure engine passes `roc test` (13 tests) with scripted outcomes. |
| 11.7 | State threading (s3) | `(state, reply)` threading through tools and notification handlers is exact: the final state is returned from `serve!` (`detections=1`). |
| 11.8 | Whole API skeleton (s4) | `roc check package/main.roc` (19 modules, every signature in section 4) and `port_sketch.roc` (the roc-syntax-mcp shapes, basic-cli) are clean. That includes `around_tools` composed with `fold_rev` over effectful middleware. |
| 11.9 | Top-level `server` constant holding closures | Built at compile time, and it runs the same as a server built in `main!` (identical output md5). |
| 11.10 | `roc bundle` on the package dir | One `<base58>.tar.zst` (14.8 kB for the skeleton). |

## 12. Compiler limits and workarounds (nightly-2026-11-14)

| # | Limit | Workaround |
| --- | --- | --- |
| 12.1 | **Bug:** the documented wrapper `from_json : Str -> Try(a, [InvalidJson(Str), ..errs]) where [a.Json.Parseable([InvalidJson(Str), ..errs])]` fails with a type mismatch, both in an app and in a package. Minimal repro: `research/spikes/s2_json/wrap_app.roc`. | Use `where [a.Json.Parseable(_)]` and map the error to a closed union: `Json.parse(s).map_err(\|e\| InvalidArgs(Str.inspect(e)))`. |
| 12.2 | `roc test` cannot run effects (11.2). | A pure engine (D1). |
| 12.3 | Constant subexpressions are evaluated at compile time, **even inside function bodies**: `ResourceTemplate.new("lit", ..)` inside `make_server = \|{}\| ...` ran at compile time. A stub that crashes therefore breaks the build of every caller that passes literals. | A pure stub returns a placeholder rather than crashing. The HTTP stubs that crash are effectful (`!`) or take runtime input. Invalid templates and duplicate names deliberately surface at compile time. |
| 12.4 | The methods of a nested type (`Tool.Result :: ... .{}`) share one scope with the methods of the outer type, so names such as `to_json`, `with_meta` and `content` collide ("duplicate definition"). | One public type per module (D8). |
| 12.5 | No shadowing. A lambda parameter cannot have the name of a method or top-level value in the same module (`new = \|name\| ...` with a `name` method fails). A top-level private def cannot have a method's name. | Short parameter names (`\|n\|`, `\|u, m, t\|`). |
| 12.6 | Reserved words that look like names: `app`, `platform`, `with`, `var`, `and`, `or`. The builtin type `Stream` is shadowed with a warning. | `with_keywords`, `also`, `variable`, `st` for app state, `EventStream`. |
| 12.7 | A type alias for a function type inside `Try(...)` needs parentheses: `Try((state, Ctx, JsonValue => state), [NotFound])`. | Write the parentheses. |
| 12.8 | `List.range` does not exist. A `Range` has no `map`. | `(0.U64..<n).iter().map(f).collect()`. |
| 12.9 | `List.fold_rev(list, init, \|elem, acc\| ...)`: the element comes first. | |
| 12.10 | `join_with` is not a method of `List(Str)`. | `Str.join_with(list, sep)`. |
| 12.11 | The roc-syntax tool's basic-cli index is 0.25.0, and 0.28.1 differs: `Stdin.line!` errors are `EndOfInput/Interrupted/BadUtf8/StdinErr`, `Utc` is opaque (`Utc.now!().since(..)`), and there is a `Monotonic` and a `Duration`. | Read `.tmp/xdg/roc/packages/7brgw.../*.roc`, the real 0.28.1 sources. |
| 12.12 | Machine, not compiler: `roc <file>` (run) needs an inotify instance, and all 128 are in use, so it fails with "failed to start filesystem watching". | `roc build --output=...`, then run the binary. `check`, `test` and `bundle` are not affected. |
| 12.13 | `if` with a condition known at compile time gives a warning ("unconditional condition"). | Ignore it in the sketches. |
| 12.14 | Imports in a module under `package/Internal/` are relative to that directory: `import JsonValue` there looks for `Internal/JsonValue.roc`. | `import ../JsonValue` in `Internal/*.roc`; `import Internal/Wire` from `package/*.roc`. |
| 12.15 | A lambda parameter cannot carry a type annotation (`\|s, _c, args : { text : Str }\|` is a parse error), and a named function annotated with `->` is refused where `=>` is expected ("This function is pure, but an effectful function is expected"); only lambda literals are accepted there. | Name typed handlers and annotate them with `=>`: `echo : St, Ctx, { text : Str } => (St, Outcome(ToolResult))`. |
| 12.16 | `??` binds looser than `\|>`: `xs.first() ?? "" \|> Str.contains(p)` parses as `xs.first() ?? ("" \|> ...)`. | Parenthesize, or use a helper. |
| 12.17 | `var $r = Ok({})` gets the closed type `[Ok({})]`, which has no `is_ok`. | Start from an annotated constant: `still_ok : Try({}, Str)`. |
| 12.18 | `Iter` has no `all`. | `list.sublist(...).all(...)`. |
| 12.19 | A test cannot call `call.run!` even when the handler is a pure lambda ("effectful expect"). | Scripted outcomes for `finish` (D1); the `Ctx.*_line` twins for the sends. |
| 12.20 | A local lambda is generalized: `f = \|i\| "${i.to_str()}"` used with `U64`s and then called as `f(5000)` gives the literal its default type, `Dec`, so `to_str` is `"5000.0"`, not a `U64` (found as an invalid JSON-RPC id in a test). | Suffix the literal (`f(5000.U64)`) or annotate the lambda. |

## 13. Open questions for the user

| # | Question | Default if unanswered |
| --- | --- | --- |
| Q1 | A line that is not JSON: answer -32700 with `id: null` (spec), or skip it silently (JS)? | -32700 |
| Q2 | Does 0.1.0 include the 2026-07-28 era (S5), or ship legacy-only and add it in 0.2.0? JS 2.0 serves both, and roc-syntax-mcp needs only legacy. | include it, so that 0.1.0 has parity |
| Q3 | Request a basic-cli addition: `Stdin.line_timeout!(Duration)` (or a readiness poll) for exact input deadlines and pings during long handlers? | note it in README; do not block on it |
| Q4 | Use our own HTTP request/response records (no dependencies), or depend on `roc-lang/http` 1.0.0 (the types of basic-webserver and basic-cli)? | own records, no dependencies |
| Q5 | Confirm the clean-room policy: no code or doc text from the JS SDK, and LICENSE with our copyright line only. | yes |
| Q6 | No runtime JSON-Schema validation of tool arguments (decoding into a Roc type instead). Is that acceptable, or do you want a validator for a subset of JSON Schema (type, required, enum, min/max) in a later release? | **Answered:** a validator for the subset `Schema` emits (`SchemaCheck`), with zod's messages, run before decoding; on by default |
