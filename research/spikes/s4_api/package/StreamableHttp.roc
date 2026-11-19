import JsonValue
import Server
import Engine
import Ctx

## Streamable HTTP transport. STUB in this release: every effectful function crashes.
## Platform-agnostic: the app maps its platform's request and response to these records.
StreamableHttp(state) :: {
	server : Server(state),
	options : StreamableHttp.Options,
	sessions : List((Str, Engine.Session)),
}.{
	Request : { method : Str, uri : Str, headers : List((Str, Str)), body : List(U8) }

	Response : { status : U16, headers : List((Str, Str)), body : StreamableHttp.Body }

	## A finite body, a finite event stream (all events of one POST), or an open stream (GET, subscriptions/listen).
	Body := [Bytes(List(U8)), Events(List(StreamableHttp.Event)), Open(StreamableHttp.EventStream)]

	Event : { id : Try(Str, [None]), event : Try(Str, [None]), data : Str, retry_ms : Try(U64, [None]) }

	## An open SSE stream. The platform pulls events until `Closed`.
	EventStream :: { poll! : () => Try(List(StreamableHttp.Event), [Closed]) }

	Options : {
		sessions : [Stateful, Stateless],
		response_mode : [Auto, Sse, Json],
		legacy : [Serve, Reject],
		allowed_hosts : List(Str),
		allowed_origins : List(Str),
		keep_alive_ms : U64,
		max_subscriptions : U64,
	}

	default_options : StreamableHttp.Options
	default_options = { sessions: Stateful, response_mode: Auto, legacy: Serve, allowed_hosts: [], allowed_origins: [], keep_alive_ms: 15000, max_subscriptions: 1024 }

	## Effects the transport needs from the platform.
	Io : {
		new_session_id! : () => Str,
		now_ms! : () => U64,
		log! : Str => {},
		authenticate! : StreamableHttp.Request => Try(Try(Ctx.AuthInfo, [Anonymous]), [Unauthorized(StreamableHttp.Response)]),
	}

	new : Server(state), StreamableHttp.Options -> StreamableHttp(state)
	new = |server, options| { server, options, sessions: [] }

	## Handles one HTTP request: POST (messages), GET (stream), DELETE (end session).
	handle! : StreamableHttp(state), state, StreamableHttp.Request, StreamableHttp.Io => { transport : StreamableHttp(state), state : state, response : StreamableHttp.Response }
	handle! = |_transport, _state, _request, _io| crash "StreamableHttp.handle! is not implemented in this release"

	## Publishes a list_changed / resources/updated event to open streams.
	notify! : StreamableHttp(state), [ToolsChanged, PromptsChanged, ResourcesChanged, ResourceUpdated(Str)] => StreamableHttp(state)
	notify! = |_transport, _event| crash "StreamableHttp.notify! is not implemented in this release"

	## DNS-rebinding protection: 403 unless the Host header is allowed.
	validate_host : StreamableHttp.Request, List(Str) -> Try({}, StreamableHttp.Response)
	validate_host = |_request, _allowed| crash "StreamableHttp.validate_host is not implemented in this release"

	validate_origin : StreamableHttp.Request, List(Str) -> Try({}, StreamableHttp.Response)
	validate_origin = |_request, _allowed| crash "StreamableHttp.validate_origin is not implemented in this release"

	## RFC 9728 protected-resource metadata response.
	oauth_metadata_response : JsonValue -> StreamableHttp.Response
	oauth_metadata_response = |_metadata| crash "StreamableHttp.oauth_metadata_response is not implemented in this release"
}
