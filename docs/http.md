# Streamable HTTP transport: specification for the implementer

`StreamableHttp` has its final API in this release, but `handle!` and `notify!` crash with
`roc-mcp-sdk: StreamableHttp.<fn> is not implemented in this release`. The pure helpers
`validate_host`, `validate_origin` and `oauth_metadata_response` return a `501` placeholder
instead of crashing, because the compiler evaluates a pure call with constant arguments at build
time (DESIGN 12.3). The placeholder fails closed: a validator that is not implemented rejects
every request. `new`, `default_options` and `options` are complete.

This document says what each function must do once implemented. It is written from the MCP
specification (transports chapter, revisions 2025-03-26 to 2025-11-25 and 2026-07-28) and from
observed behaviour of the JS SDK 2.0.0. No code or text is taken from the SDK (DESIGN 3,
"Licence consequence").

## 1. API

```roc
StreamableHttp(state)                       # opaque: the Server, the Options, in-transport sessions
Request  : { method : Str, uri : Str, headers : List((Str, Str)), body : List(U8) }
Response : { status : U16, headers : List((Str, Str)), body : Body }
Body     := [Bytes(List(U8)), Events(List(Event)), Open(EventStream)]
Event    : { id : Str?, event : Str?, data : Str, retry_ms : U64? }
EventStream :: { .. }                       # EventStream.poll! : EventStream => Try(List(Event), [Closed])
Options  : { sessions : [Stateful, Stateless], response_mode : [Auto, Sse, Json], legacy : [Serve, Reject],
             allowed_hosts : List(Str), allowed_origins : List(Str),
             keep_alive_ms : U64, retry_ms : U64, max_subscriptions : U64 }
SessionStore : { load! : Str => Try(Engine.Session, [NotFound]), save! : Str, Engine.Session => {}, remove! : Str => {} }
EventStore   : { append! : Str, Str => Str,
                 after! : Str, Str? => Try(List({ id : Str, data : Str }), [UnknownStream]),
                 stream_of! : Str => Try(Str, [UnknownEvent]),
                 drop! : Str => {} }
Io : { new_session_id! : () => Str, now_ms! : () => U64, log! : Str => {},
       authenticate! : Request => Try(Try(Ctx.AuthInfo, [Anonymous]), [Unauthorized(Response)]),
       sessions : [InTransport, External(SessionStore)],
       events : [Disabled, Enabled(EventStore)] }
Change : [ToolsChanged, PromptsChanged, ResourcesChanged, ResourceUpdated(Str)]

new : Server(state), Options -> StreamableHttp(state)                    # real
default_options : Options                                                  # real
options : StreamableHttp(state) -> Options                                # real
handle! : StreamableHttp(state), state, Request, Io
    => { transport : StreamableHttp(state), state : state, response : Response }   # crash
notify! : StreamableHttp(state), Io, Change => StreamableHttp(state)               # crash
validate_host : Request, List(Str) -> Try({}, Response)                            # 501 placeholder
validate_origin : Request, List(Str) -> Try({}, Response)                          # 501 placeholder
oauth_metadata_response : JsonValue -> Response                                    # 501 placeholder
```

`T?` means `Try(T, [None])`. `default_options` is `Stateful`, `Auto`, `Serve`, no allowed hosts or
origins (no check), keep-alive 15 000 ms, no retry hint, 1024 subscriptions.

## 2. Hosts and state

Two kinds of host run this transport.

- **A sequential host** threads one `StreamableHttp` value and one app `state` through a loop, as
  `Stdio.serve!` does. It uses `sessions: InTransport`: sessions live in the value that `handle!`
  returns, and the host passes that value to the next call.
- **A concurrent host without shared memory** (basic-webserver: `respond!` runs concurrently and
  gets an immutable `Context`) keeps nothing between requests. It builds the transport once in
  `init!`, ignores the returned `transport`, and keeps every lasting thing in its own store:
  `sessions: External(store)` and `events: Enabled(store)`, for example on Sqlite. The app's own
  `state` is the app's business: such a host passes a fresh or loaded state and stores the
  returned one itself, or uses `{}`.

An open SSE stream is a closure that the host polls after `handle!` has returned. Roc has no
mutable cell that the closure could watch, so every message that reaches an already open stream
from another request goes through `Io.events`: notifications from `notify!`, and the result of a
parked request that a later POST completes. With `events: Disabled` the transport has no open
streams: GET answers 405, and a handler that returns `Outcome.need_input` on a 2025 session gets
the error described in 4.4.

A `SessionStore` sees `save!` after every request that changed the session (initialize,
logging/setLevel, subscribe, park, answer) and `remove!` on DELETE. These calls are also the
session lifecycle hooks; there are no separate callbacks. Concurrent requests of one session may
race: the store should serialize writes per session id (a Sqlite transaction) or accept
last-writer-wins. Storing an `Engine.Session` outside the process needs a serialized form; that
is an addition to `Engine` (`Session.to_json` / `from_json`), which the implementer of this
module requests from the Engine owner.

## 3. The order of checks in `handle!`

Every request goes through these steps in order. The first one that answers ends the request.

1. **Host and Origin.** When `allowed_hosts` is non-empty, run `validate_host`; when
   `allowed_origins` is non-empty, run `validate_origin`. A failure is answered as returned
   (403, JSON-RPC error body, `id: null`).
2. **Authentication.** Call `io.authenticate!`. `Err(Unauthorized(r))` is answered with `r`
   unchanged. `Ok(Ok(info))` is put into the `Ctx` of every call this request makes
   (`Ctx.auth`); `Ok(Err(Anonymous))` leaves it `None`. (The engine needs a way to receive it:
   either an `auth` argument on `receive_json`, or a session setter. This is a request to the
   Engine owner.)
3. **Method.** POST (4), GET (5), DELETE (6). Anything else: 405 with `Allow: GET, POST, DELETE`
   (`Allow: POST` when stateless or when GET is unavailable), JSON-RPC error -32000
   "Method not allowed.", `id: null`.

Errors that the transport makes itself (not the engine) have a JSON-RPC error body with
`id: null` and `Content-Type: application/json`. The codes used below: -32700 parse error,
-32600 invalid request, -32000 transport error (wrong session, wrong headers), -32020 header
mismatch (2026-07-28), -32602 bad envelope.

## 4. POST

### 4.1 Request checks

1. `Accept` must list both `application/json` and `text/event-stream` (`*/*` or the type
   wildcards count). Otherwise 406, -32000. For a 2026-07-28 request in `Json` mode,
   `application/json` alone suffices.
2. `Content-Type` must be `application/json` (parameters such as `charset` allowed). Otherwise
   415, -32000.
3. The body must parse with `JsonValue.parse`. Otherwise 400, -32700.
4. The body is one JSON-RPC message, or (2025 only) a non-empty array of them. Anything else:
   400, -32700 (JS parity: an invalid message counts as a parse error).

### 4.2 Era classification

The body decides the era; the headers are cross-checks.

- **Modern (2026-07-28)**: a request or notification whose `params._meta` carries the
  per-request envelope (protocol version, client info, client capabilities). Then:
  - the `MCP-Protocol-Version` header must equal the envelope's version, else 400, -32020;
  - the `Mcp-Method` header must be present and equal the body's `method`, else 400, -32020;
  - for `tools/call`, `prompts/get` and `resources/read` the `Mcp-Name` header must equal the
    tool name, prompt name or resource URI, else 400, -32020;
  - a tool whose input schema marks properties for header exposure (`x-mcp-header`) needs the
    matching `Mcp-Param-<Name>` headers, equal to the argument values (a value that is not
    plain ASCII comes Base64-encoded in a sentinel form), else 400, -32020;
  - a version that the server does not serve is answered by the engine's
    unsupported-version error;
  - a `MCP-Protocol-Version` header naming a modern version on a body without an envelope:
    400, -32602.
- **Legacy (2025)**: everything else: `initialize`, envelope-less requests and notifications,
  JSON-RPC responses (answers to server-to-client requests), batches.
  With `legacy: Reject`, a legacy request is answered with the unsupported-version error that
  lists the modern versions; a legacy notification gets 202 and is dropped.

### 4.3 Modern exchange

There are no sessions in the modern era: each POST is complete in itself. `handle!` creates a
fresh `Engine.Session.new`, feeds the message with `Engine.receive_json`, runs each `Call`
(`call.run!(state, ctx)`) and `Engine.finish`es it, threading `state`, exactly as the stdio loop
does, until no calls remain. Then:

- a notification: 202 with an empty body;
- a request, `response_mode`:
  - `Json`: 200 `application/json` with the final response line only (progress and log
    notifications produced before it are dropped);
  - `Sse`: 200 `Events(...)`: every `out` line in order, the response last;
  - `Auto`: as `Json` when the response is the only line, else as `Sse`.
- `subscriptions/listen`: always an `Open` stream. It counts against `max_subscriptions` (when
  full: -32603 "Subscription limit reached" in a 200 JSON body, before any acknowledgement).
  The first event is the engine's acknowledgement; later events come from `notify!` through the
  event store, filtered by what the subscription asked for and stamped with its subscription
  id. With `events: Disabled` the stream stays open with only keep-alives (the in-process
  delivery that JS does is impossible, see 2).
- `input_required` results are plain results in this era: no parking.

### 4.4 Legacy exchange

**Sessions.** With `sessions: Stateful`:

- `initialize` (it must be the only message of the POST, else 400, -32600): create
  `Engine.Session.new`, call `io.new_session_id!()` (a cryptographically random visible-ASCII
  string), answer with header `Mcp-Session-Id: <id>`, and save the session. An `initialize` on
  a request that already carries a valid session id is answered 400, -32600 (already
  initialized).
- any other POST: the `Mcp-Session-Id` header is required (400, -32000 when missing); an unknown
  or deleted id is 404, -32001 "Session not found" (the client then starts a new session).
- `MCP-Protocol-Version` header: when present it must be a version the server serves, else 400,
  -32000. When absent, the negotiated version applies (2025-03-26 clients send none).

With `sessions: Stateless`: no session id is issued or checked; every POST uses a fresh
`Engine.Session` that is marked initialized at the version of the `MCP-Protocol-Version` header
(or the latest legacy version). `initialize` is still answered normally.

**Messages.**

- Only notifications and/or responses: feed each one, answer 202 with an empty body.
- Requests (one, or a batch): feed each, run the calls, and answer as in 4.3 by
  `response_mode`. A batch in `Json` mode is answered with a JSON array of the responses, in
  request order. In SSE mode every response of the batch is an event, and the stream ends after
  the last one.
- **Parked requests** (`Outcome.need_input`, DESIGN D3). `finish` returns server-to-client
  requests (`roots/list`, `elicitation/create`, `sampling/createMessage`) instead of a response.
  They go out as events on this POST's stream, so this POST is answered with `Open(stream)`
  even in `Json` mode (`Json` mode with a parked request is answered as SSE; if the client did
  not accept SSE this is impossible and the call gets the transport-closed error of the input
  shim). The stream id is the request's id inside the session, and every message of that
  exchange is `append!`ed to it. The client answers with a new POST carrying the JSON-RPC
  response; that POST is answered 202, and its `receive_json` re-dispatches the original
  request. The resulting `out` lines are appended to the original request's stream, whose
  `poll!` then delivers them and reports `Closed` after the final response. With
  `events: Disabled` there is nowhere to deliver them: the parked call is finished at once with
  the shim's transport error (`tools/call`: `isError` result; other methods: -32603).
- Deadlines (`Engine.next_deadline`, `Engine.expire`) are checked at the start of each
  `handle!` of that session and on each `poll!` of its streams, using `io.now_ms!`.

### 4.5 Response headers

- `Content-Type: application/json` or `text/event-stream`, `Cache-Control: no-cache` on streams.
- `Mcp-Session-Id` on the `initialize` response (and allowed on every stateful response).
- Event ids: when `events: Enabled`, every event of a stream gets the id that `append!`
  returned. The first event of a resumable stream is a priming event with an id and empty
  data (only for clients at 2025-11-25 or later, which accept empty data), carrying
  `retry_ms` when it is non-zero.
- Keep-alive: an SSE comment every `keep_alive_ms` while a stream is open (0 disables). The
  `Event` record cannot express a comment; the adapter (or host) emits them. basic-webserver
  configures its own SSE keep-alive with `with_sse_limits`.

## 5. GET (2025 sessions)

Opens the session's standalone stream for server-initiated messages.

1. Stateless, or `events: Disabled`: 405 (`Allow: POST`).
2. `Accept` must include `text/event-stream`, else 406, -32000.
3. Session checks as for POST (400 / 404).
4. With a `Last-Event-ID` header: `stream_of!(id)` finds the stream (unknown: 400, -32000);
   the stream must belong to this session, and a stream that already has a reader is 409. Answer `Open(stream)` whose first `poll!` returns
   `after!(stream, Ok(id))`, the events the client missed. This also resumes a POST's stream
   that was cut off.
5. Without it: at most one standalone stream per session; a second one is 409, -32000. The
   stream id is `"<session id>/standalone"`; answer `Open(stream)`, which delivers whatever
   `notify!` appends.

`EventStream.poll!` returns the events that are ready (possibly none; the adapter waits and polls
again) and `Closed` when the stream is over: the final response of a request stream was
delivered, the session was deleted, or the store forgot the stream.

## 6. DELETE (2025 sessions)

Ends a session. Stateless: 405. Session checks as for POST. Then: `Engine.close` the session (it
reports parked requests), `drop!` its streams, `remove!` it from the store (or from the
transport value), and answer 200 with an empty body. Later requests with that id get 404.

## 7. `notify!`

`notify!(transport, io, change)` publishes one change:

| `Change` | notification |
| --- | --- |
| `ToolsChanged` | `notifications/tools/list_changed` |
| `PromptsChanged` | `notifications/prompts/list_changed` |
| `ResourcesChanged` | `notifications/resources/list_changed` |
| `ResourceUpdated(uri)` | `notifications/resources/updated` with `uri` |

Recipients: the standalone stream of every live 2025 session (for `ResourceUpdated`, only
sessions that subscribed to that URI with `resources/subscribe`), and every open 2026-07-28
`subscriptions/listen` stream that asked for that kind (or that URI). Delivery is an `append!`
per recipient stream. With `events: Disabled` it does nothing. It never fails: a store error is
logged with `io.log!`. A handler that changes a list during a request can also use
`Ctx.list_changed!` (delivered on that request's own stream); `notify!` is for changes made
outside a request.

## 8. Security helpers

- `validate_host(request, allowed)`: read `Host` (case-insensitive header name). Missing: 403.
  Strip the port (`host:port`, and `[v6]:port` keeps its brackets). The hostname must equal an
  entry of `allowed` (compare case-insensitively; entries are hostnames without port, IPv6 with
  brackets). Failure: 403 with a JSON-RPC error body (-32000, a message naming the bad host),
  `id: null`. Typical list: `["localhost", "127.0.0.1", "[::1]"]`.
- `validate_origin(request, allowed)`: no `Origin` header (non-browser clients) passes. A
  present value must parse as `scheme://host[:port]`; the opaque `null` origin and anything
  unparsable fail. Its hostname must be in `allowed` (same rules as hosts). Failure: 403 as above.
- `oauth_metadata_response(metadata)`: 200, `Content-Type: application/json`,
  `Access-Control-Allow-Origin: *`, body `metadata.to_str()`. The app builds the RFC 9728
  document (`resource`, `authorization_servers`, optionally `scopes_supported`,
  `resource_name`, `resource_documentation`) and serves this response at
  `/.well-known/oauth-protected-resource` followed by the MCP endpoint's path. It answers other
  methods than GET itself (405) and OPTIONS (204).
- `Io.authenticate!` is the bearer-token gate: read `Authorization: Bearer <token>`, verify it
  (introspection or local JWT check), and return `Ctx.AuthInfo`. Refuse a token without an expiry
  or past it. The refusal response is 401 for a missing or invalid token and 403 for missing
  scopes, each with `WWW-Authenticate: Bearer error="...", resource_metadata="<metadata url>"`
  (plus `scope="..."` for 403) so that the client can find the authorization server, and an
  OAuth error JSON body.

## 9. Mapping to `Engine`

| HTTP | Engine |
| --- | --- |
| `initialize` POST (stateful) | `Session.new`, `receive_json`, store under a new id |
| other POST (stateful) | load by `Mcp-Session-Id`, `receive_json` per message, run calls with `finish`, save |
| POST (stateless or modern) | `Session.new` per request; nothing is saved |
| answer to a server-to-client request | `receive_json` of the response; its `out` goes to the parked request's stream |
| DELETE | `close`, remove |
| time | `expire(server, session, state, io.now_ms!())` when `next_deadline` has passed |
| `Engine.Step.out` lines | parsed back to `JsonValue` only when batching JSON arrays; otherwise used as event data or body as is |

`handle!` returns the threaded `state` after all calls of this request have run.

## 10. Adapter notes (basic-webserver 0.21.0)

`docs/http_example.roc` type-checks against basic-webserver 0.21.0 with
`scripts/roc.sh check docs/http_example.roc` (it builds, but must not be run while `handle!` is a
stub). The mapping:

| basic-webserver | `StreamableHttp` |
| --- | --- |
| `request.method().to_str()` | `method` |
| `Resource({ raw_path, .. })` of `request.target()` | `uri` (path; add the query if needed) |
| `request.headers()`, each `{ name, value }` | `headers` as `(name, value)` |
| `request.body().with_limit(n).read_all!()` | `body` (413 when too large) |
| `Bytes(b)` | `Server.respond(Response.from_status(s).with_headers(..).with_body(b))` |
| `Events(list)` | `Server.stream(Sse.unfold!(..))` emitting the list, then `End` |
| `Open(stream)` | `Server.stream(Sse.unfold!(..))`: `stream.poll!()`; `Ok([])` is `Wait(After(ms))`, events are `Emit`, `Err(Closed)` is `End` |
| `Event` | `Sse.Event.named_with(event ?? "message", [data], { id: Sse.event_id(id), retry: Sse.retry_after(ms) })` |

Limits of basic-webserver 0.21.0 that the implementer must respect:

- `Server.stream` writes its own response headers, so an SSE response cannot carry
  `Mcp-Session-Id` or a non-200 status. The transport therefore answers `initialize` as JSON
  even in `Sse` mode (a single response needs no stream), so the session id header always
  reaches the client. Errors are never streamed.
- `respond!` runs concurrently with an immutable `Context`: use `External` sessions and an
  `Enabled` event store (Sqlite), see 2.
- SSE comments are not available to the app; the host's own keep-alive replaces
  `keep_alive_ms`.

## 11. Differences from the JS SDK

- One `handle!` serves both eras and both the stateful and the stateless 2025 modes; JS splits
  them over `createMcpHandler` (modern plus a stateless legacy fallback) and the sessionful
  `WebStandardStreamableHTTPServerTransport`.
- Host/Origin checks can run inside `handle!` (`allowed_hosts`, `allowed_origins`) or in front of
  it (`validate_host`, `validate_origin`); JS recommends the latter and deprecates the former.
- The JS event bus and event store are one hook here (`EventStore`), because an open stream in
  Roc can only see other requests' messages through an effect.
- Closing a stream on purpose to make the client poll (JS `closeSSEStream`) is not offered.
