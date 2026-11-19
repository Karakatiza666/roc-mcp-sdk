import JsonValue
import Server
import Engine
import Ctx

## Streamable HTTP transport (MCP 2025-03-26 .. 2025-11-25 sessions, and 2026-07-28 per-request
## serving). STUB in this release: the API is final, but every effectful function crashes with
## "roc-mcp-sdk: StreamableHttp.<fn> is not implemented in this release". The pure helpers that
## would otherwise crash return a fail-closed `501` placeholder instead (DESIGN 12.3: a crash in a
## pure function runs at compile time when the arguments are constants). `docs/http.md` is the spec.
##
## Platform-agnostic: the app maps its platform's request and response to these records
## (`docs/http.md` has a basic-webserver adapter). Every piece of state that must outlive one
## request on a concurrent host lives behind `Io` (`sessions`, `events`).
StreamableHttp(state) :: {
	server : Server(state),
	options : StreamableHttp.Options,
	sessions : List((Str, Engine.Session)),
}.{

	## One HTTP request. `method` is upper case ("POST", "GET", "DELETE", ...). `uri` is the
	## request target as received (path and query). Header names compare case-insensitively.
	Request : { method : Str, uri : Str, headers : List((Str, Str)), body : List(U8) }

	Response : { status : U16, headers : List((Str, Str)), body : StreamableHttp.Body }

	## A finite body, a finite event stream (every event of one POST exchange), or an open stream
	## (the GET stream, a POST waiting for a parked request, `subscriptions/listen`). For an `Open`
	## body the adapter pulls events with `EventStream.poll!` until `Closed`.
	Body := [Bytes(List(U8)), Events(List(StreamableHttp.Event)), Open(StreamableHttp.EventStream)]

	## One SSE event. `id` is set when an event store is configured (resumability).
	Event : { id : Try(Str, [None]), event : Try(Str, [None]), data : Str, retry_ms : Try(U64, [None]) }

	## An open SSE stream. Only the transport creates one. `poll!` returns the events that are ready
	## (possibly none: the adapter waits and polls again) or `Closed` when the stream has ended.
	EventStream :: { next! : () => Try(List(StreamableHttp.Event), [Closed]) }.{
		poll! : StreamableHttp.EventStream => Try(List(StreamableHttp.Event), [Closed])
		poll! = |st| (st.next!)()
	}

	Options : {
		## `Stateful`: 2025-era clients get an `Mcp-Session-Id` at `initialize`, and later requests
		## must carry it. `Stateless`: no session id; GET and DELETE answer 405.
		sessions : [Stateful, Stateless],

		## How a POST that carries a request is answered: `Json` one JSON body (mid-call
		## notifications are dropped), `Sse` always an event stream, `Auto` JSON unless the handler
		## emits something before its result.
		response_mode : [Auto, Sse, Json],

		## 2025-era traffic (no per-request envelope): `Serve` it, or `Reject` it (modern-only endpoint).
		legacy : [Serve, Reject],

		## DNS-rebinding protection inside `handle!`: when non-empty, the Host hostname (port ignored)
		## must be in `allowed_hosts`, and a present Origin's hostname must be in `allowed_origins`.
		allowed_hosts : List(Str),
		allowed_origins : List(Str),

		## SSE comment keep-alive interval; 0 disables.
		keep_alive_ms : U64,

		## The `retry` hint sent in the priming event of a resumable stream; 0 sends none.
		retry_ms : U64,

		## Open `subscriptions/listen` streams allowed at once; the next one gets -32603.
		max_subscriptions : U64,
	}

	default_options : StreamableHttp.Options
	default_options = {
		sessions: Stateful,
		response_mode: Auto,
		legacy: Serve,
		allowed_hosts: [],
		allowed_origins: [],
		keep_alive_ms: 15000,
		retry_ms: 0,
		max_subscriptions: 1024,
	}

	## Where 2025-era sessions live between requests. `InTransport`: in the `StreamableHttp` value
	## that `handle!` returns (a host that threads one value through a sequential loop). `External`:
	## in the app's store (a concurrent host such as basic-webserver, where no value survives a request).
	SessionStore : {
		load! : Str => Try(Engine.Session, [NotFound]),
		save! : Str, Engine.Session => {},
		remove! : Str => {},
	}

	## Append-only per-stream event log. It makes streams resumable (`Last-Event-ID`) and is how an
	## open stream sees messages produced by other requests (notifications, a parked request's
	## result). `append!` returns the new event id: unique across streams, so `stream_of!` can map it back.
	EventStore : {
		append! : Str, Str => Str,
		after! : Str, Try(Str, [None]) => Try(List({ id : Str, data : Str }), [UnknownStream]),
		stream_of! : Str => Try(Str, [UnknownEvent]),
		drop! : Str => {},
	}

	## Effects the transport needs from the platform.
	Io : {
		new_session_id! : () => Str,
		now_ms! : () => U64,
		log! : Str => {},

		## Verifies the request's credentials (usually `Authorization: Bearer`). `Ok(Ok(info))` reaches
		## handlers as `Ctx.auth`; `Ok(Err(Anonymous))` serves without auth; `Err(Unauthorized(r))`
		## answers `r` (a 401/403 with a `WWW-Authenticate` challenge) without touching the engine.
		authenticate! : StreamableHttp.Request => Try(Try(Ctx.AuthInfo, [Anonymous]), [Unauthorized(StreamableHttp.Response)]),
		sessions : [InTransport, External(StreamableHttp.SessionStore)],

		## `Disabled`: no resumability, GET answers 405, and a parked request cannot finish on HTTP.
		events : [Disabled, Enabled(StreamableHttp.EventStore)],
	}

	## A change to publish on open streams (the GET stream of a subscribed 2025 session, or a
	## 2026-07-28 `subscriptions/listen` stream that opted in).
	Change : [ToolsChanged, PromptsChanged, ResourcesChanged, ResourceUpdated(Str)]

	new : Server(state), StreamableHttp.Options -> StreamableHttp(state)
	new = |srv, opts| { server: srv, options: opts, sessions: [] }

	## The options this transport was built with.
	options : StreamableHttp(state) -> StreamableHttp.Options
	options = |t| t.options

	## Handles one HTTP request on the MCP endpoint: POST (messages), GET (server stream),
	## DELETE (end session); any other method answers 405.
	handle! : StreamableHttp(state), state, StreamableHttp.Request, StreamableHttp.Io => { transport : StreamableHttp(state), state : state, response : StreamableHttp.Response }
	handle! = |_transport, _state, _request, _io| crash "roc-mcp-sdk: StreamableHttp.handle! is not implemented in this release"

	## Publishes a list_changed / resources/updated notification to every open stream that wants it.
	notify! : StreamableHttp(state), StreamableHttp.Io, StreamableHttp.Change => StreamableHttp(state)
	notify! = |_transport, _io, _change| crash "roc-mcp-sdk: StreamableHttp.notify! is not implemented in this release"

	## DNS-rebinding protection: `Err(403 response)` unless the Host header's hostname (port
	## ignored) is in the list. STUB: always `Err(501)`, fail-closed.
	validate_host : StreamableHttp.Request, List(Str) -> Try({}, StreamableHttp.Response)
	validate_host = |_request, _allowed| Err(not_implemented("validate_host"))

	## `Err(403 response)` when an Origin header is present and its hostname is not in the list
	## (an unparsable or "null" Origin is rejected). STUB: always `Err(501)`, fail-closed.
	validate_origin : StreamableHttp.Request, List(Str) -> Try({}, StreamableHttp.Response)
	validate_origin = |_request, _allowed| Err(not_implemented("validate_origin"))

	## RFC 9728 protected-resource metadata document as a `200 application/json` response, for the
	## app to serve at `/.well-known/oauth-protected-resource[/<path>]`. STUB: a `501` placeholder.
	oauth_metadata_response : JsonValue -> StreamableHttp.Response
	oauth_metadata_response = |_metadata| not_implemented("oauth_metadata_response")
}

## The `501` placeholder of the pure stubs.
not_implemented : Str -> StreamableHttp.Response
not_implemented = |fn_name| {
	status: 501,
	headers: [("Content-Type", "text/plain; charset=utf-8")],
	body: Bytes(Str.to_utf8("roc-mcp-sdk: StreamableHttp.${fn_name} is not implemented in this release")),
}
