# Type-check-only sketch: an MCP endpoint on basic-webserver through `StreamableHttp`.
# `StreamableHttp.handle!` crashes in this release, so this app builds but must not be run.
# Spec: docs/http.md. Check: scripts/roc.sh check docs/http_example.roc
app [Context, program] {
	http: "https://github.com/roc-lang/http/releases/download/1.0.0/6ZUwqYhCS8PU9Mo6MF7oV82ET2o7KYb57CLKDq4cq4sS.tar.zst",
	mcp: "../package/main.roc",
	pf: platform "https://github.com/roc-lang/basic-webserver/releases/download/0.21.0/4viZsnWjdYsyH4Q87ESFAwM5c55Hnc15nAGW1UwzWpFU.tar.zst",
}

import pf.Server
import pf.Sse
import pf.Stderr
import pf.UnixTime
import http.Response
import mcp.Server as McpServer
import mcp.StreamableHttp

# basic-webserver runs `respond!` concurrently and lends it an immutable `Context`, so nothing a
# request changes survives it. This sketch therefore serves statelessly (no Mcp-Session-Id, no
# GET stream). A stateful server passes `sessions: External(store)` and `events: Enabled(store)`
# backed by Sqlite (docs/http.md, "Hosts without shared memory").
Context : { mcp : StreamableHttp({}) }

program = { init!, respond!, shutdown! }

init! : () => Try({ config : Server.Config, context : Context }, [Exit(I64)])
init! = || {
	server = McpServer.new({ name: "http-example", version: "0.1.0" })
	options = { ..StreamableHttp.default_options, sessions: Stateless, allowed_hosts: ["localhost", "127.0.0.1"] }
	config = Server.default_config.with_listen({ host: "127.0.0.1", port: 8080 })
	Ok({ config, context: { mcp: StreamableHttp.new(server, options) } })
}

io : StreamableHttp.Io
io = {
	new_session_id!: || crash "stateless: no session ids",
	now_ms!: || (UnixTime.now!().nanos_since_epoch() // 1_000_000).to_u64_wrap(),
	log!: |line| Stderr.line!(line) ?? {},
	authenticate!: |_request| Ok(Err(Anonymous)),
	sessions: InTransport,
	events: Disabled,
}

respond! : Server.Request, Context => Try(Server.Outcome, [ServerErr(Str)])
respond! = |request, context| {
	path =
		match request.target() {
			Resource({ raw_path, .. }) => raw_path
			_ => ""
		}
	if path != "/mcp" {
		return Ok(Server.respond(Response.from_status(404)))
	}
	body =
		match request.body().with_limit(4 * 1024 * 1024).read_all!() {
			Ok(bytes) => bytes
			Err(_) => return Ok(Server.respond(Response.from_status(413)))
		}
	req : StreamableHttp.Request
	req = {
		method: request.method().to_str(),
		uri: path,
		headers: request.headers().map(|h| (h.name, h.value)),
		body,
	}
	{ response, .. } = StreamableHttp.handle!(context.mcp, {}, req, io)
	Ok(to_outcome!(response))
}

# Maps the transport's response onto basic-webserver. The host writes its own SSE headers, so an
# event-stream response cannot carry extra headers (docs/http.md, "Adapter notes").
to_outcome! : StreamableHttp.Response => Server.Outcome
to_outcome! = |response|
	match response.body {
		Bytes(bytes) =>
			Server.respond(
				Response.from_status(response.status)
					.with_headers(response.headers.map(|(name, value)| { name, value }))
					.with_body(bytes),
			)
		Events(events) => Server.stream(Sse.unfold!({ pending: events, open: Done }, sse_step!))
		Open(stream) => Server.stream(Sse.unfold!({ pending: [], open: Polling(stream) }, sse_step!))
	}

SseState : { pending : List(StreamableHttp.Event), open : [Polling(StreamableHttp.EventStream), Done] }

sse_step! : SseState => Try(Sse.Step(SseState), [StreamFailed(Str)])
sse_step! = |st|
	match st.pending {
		[first, .. as rest] => Ok(Emit({ event: to_sse(first), state: { ..st, pending: rest }, wake: Immediately }))
		[] =>
			match st.open {
				Done => Ok(End)
				Polling(stream) =>
					match stream.poll!() {
						Ok([]) => Ok(Wait({ state: st, wake: After(100) }))
						Ok(events) => Ok(Wait({ state: { ..st, pending: events }, wake: Immediately }))
						Err(Closed) => Ok(End)
					}
			}
	}

to_sse : StreamableHttp.Event -> Sse.Event
to_sse = |event| {
	id =
		match event.id {
			Ok(text) => Sse.event_id(text) ?? Sse.clear_event_id
			Err(None) => Sse.default_event_options.id
		}
	retry =
		match event.retry_ms {
			Ok(ms) => Sse.retry_after(ms)
			Err(None) => Sse.default_event_options.retry
		}
	name =
		match event.event {
			Ok(text) => text
			Err(None) => "message"
		}
	Sse.Event.named_with(name, [event.data], { ..Sse.default_event_options, id, retry })
}

shutdown! : Server.ShutdownReason, Context => Try({}, [Exit(I64)])
shutdown! = |_reason, _context| Ok({})
