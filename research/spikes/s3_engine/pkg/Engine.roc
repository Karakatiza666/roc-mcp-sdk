import JsonValue
import Ctx
import Server

## Spike: the pure protocol core. It never calls a handler: it returns a Call for the driver.
Engine :: [].{
	## Session state of one connection.
	Session :: {
		initialized : Bool,
		protocol_version : Str,
		client_capabilities : JsonValue,
		next_out_id : U64,
		## Requests that wait for answers to server->client requests (legacy input_required shim).
		waiting : List({ original : JsonValue, pending : List((Str, Str)), answers : List((Str, JsonValue)) }),
	}.{
		new : Engine.Session
		new = { initialized: Bool.False, protocol_version: "", client_capabilities: Object([]), next_out_id: 0, waiting: [] }

		waiting_count : Engine.Session -> U64
		waiting_count = |s| s.waiting.len()
	}

	## One step of output: lines to write, and at most one handler to run.
	Step(state) : {
		session : Engine.Session,
		out : List(Str),
		call : Try({ request_id : Try(JsonValue, [Notification]), message : JsonValue, ctx : Ctx, run! : state, Ctx => (state, Server.Outcome) }, [NoCall]),
	}

	receive : Server(state), Engine.Session, Str -> Engine.Step(state)
	receive = |server, session, line| match JsonValue.parse(line) {
		Err(InvalidJson(why)) => no_call(session, [error_line(Null, -32700, "Parse error: ${why}")])
		Ok(msg) => {
			method = msg.get_or_null("method")
			id = msg.get_or_null("id")
			match (method, id) {
				(String(m), Null) => notification(server, session, m, msg)
				(String(_), _) => request(server, session, msg, [])
				(_, String(out_id)) => response(server, session, out_id, msg)
				_ => no_call(session, [error_line(id, -32600, "Invalid Request")])
			}
		}
	}

	## Turns the handler's outcome into output. On a legacy connection, input_required becomes
	## real server->client requests, and the original request is parked until they are answered.
	complete : Engine.Session, Try(JsonValue, [Notification]), JsonValue, Server.Outcome -> { session : Engine.Session, out : List(Str) }
	complete = |session, request_id, message, outcome| match (request_id, outcome) {
		(Err(Notification), _) => { session, out: [] }
		(Ok(id), Done(result)) => { session, out: [result_line(id, result)] }
		(Ok(_id), InputRequired(requests)) => {
			var $n = session.next_out_id
			var $pending = []
			var $out = []
			for (key, req) in requests {
				out_id = "srv-${$n.to_str()}"
				$n = $n + 1
				$pending = $pending.append((key, out_id))
				line : JsonValue
				line = Object([("jsonrpc", String("2.0")), ("id", String(out_id)), ("method", req.get_or_null("method")), ("params", req.get_or_null("params"))])
				$out = $out.append(line.to_str())
			}
			parked = { original: message, pending: $pending, answers: [] }
			{ session: { ..session, next_out_id: $n, waiting: session.waiting.append(parked) }, out: $out }
		}
	}
}

no_call : Engine.Session, List(Str) -> Engine.Step(state)
no_call = |session, out| { session, out, call: Err(NoCall) }

result_line : JsonValue, JsonValue -> Str
result_line = |id, result| JsonValue.to_str(Object([("jsonrpc", String("2.0")), ("id", id), ("result", result)]))

error_line : JsonValue, I64, Str -> Str
error_line = |id, code, message| JsonValue.to_str(Object([("jsonrpc", String("2.0")), ("id", id), ("error", Object([("code", JsonValue.from_i64(code)), ("message", String(message))]))]))

notification : Server(state), Engine.Session, Str, JsonValue -> Engine.Step(state)
notification = |server, session, method, msg| {
	if method == "notifications/initialized" {
		no_call({ ..session, initialized: Bool.True }, [])
	} else {
		match server.find_notification_handler(method) {
			Ok(run!) => {
				params = msg.get_or_null("params")
				ctx = Ctx.new(Null, session.client_capabilities, session.protocol_version, [])
				{ session, out: [], call: Ok({ request_id: Err(Notification), message: msg, ctx, run!: |state, c| (run!(state, c, params), Done(Null)) }) }
			}
			Err(NotFound) => no_call(session, [])
		}
	}
}

supported_versions : List(Str)
supported_versions = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]

request : Server(state), Engine.Session, JsonValue, List((Str, JsonValue)) -> Engine.Step(state)
request = |server, session, msg, answers| {
	id = msg.get_or_null("id")
	params = msg.get_or_null("params")
	method = msg.get_or_null("method").as_str() ?? ""
	if method == "initialize" {
		asked = params.get_or_null("protocolVersion").as_str() ?? ""
		version = if supported_versions.contains(asked) asked else "2025-11-25"
		info = server.info()
		result : JsonValue
		result = Object([
			("protocolVersion", String(version)),
			("capabilities", Object([("tools", Object([("listChanged", Bool(Bool.True))]))])),
			("serverInfo", Object([("name", String(info.name)), ("version", String(info.version))])),
			("instructions", String(info.instructions)),
		])
		session2 = { ..session, protocol_version: version, client_capabilities: params.get_or_null("capabilities") }
		no_call(session2, [result_line(id, result)])
	} else if method == "ping" {
		no_call(session, [result_line(id, Object([]))])
	} else if method == "tools/list" {
		tools = server.tool_list().map(|t| Object([("name", String(t.name)), ("description", String(t.description)), ("inputSchema", t.input_schema)]))
		no_call(session, [result_line(id, Object([("tools", Array(tools))]))])
	} else if method == "tools/call" {
		name = params.get_or_null("name").as_str() ?? ""
		match server.find_tool(name) {
			Err(NotFound) => no_call(session, [error_line(id, -32602, "Tool ${name} not found")])
			Ok(prepare) => {
				args = match params.get_or_null("arguments") {
					Null => Object([])
					a => a
				}
				match prepare(args) {
					Err(why) => {
						result : JsonValue
						result = Object([("content", Array([Object([("type", String("text")), ("text", String("Input validation error: ${why}"))])])), ("isError", Bool(Bool.True))])
						no_call(session, [result_line(id, result)])
					}
					Ok(run!) => {
						ctx = Ctx.new(id, session.client_capabilities, session.protocol_version, answers)
						{ session: session, out: [], call: Ok({ request_id: Ok(id), message: msg, ctx, run! }) }
					}
				}
			}
		}
	} else {
		no_call(session, [error_line(id, -32601, "Method not found")])
	}
}

response : Server(state), Engine.Session, Str, JsonValue -> Engine.Step(state)
response = |server, session, out_id, msg| {
	answer = match msg.get_or_null("result") {
		Null => Object([("error", msg.get_or_null("error"))])
		r => r
	}
	var $found = Err(NotFound)
	var $rest = []
	for w in session.waiting {
		match w.pending.find_first(|(_, oid)| oid == out_id) {
			Ok((key, _)) => {
				$found = Ok({ ..w, pending: w.pending.drop_if(|(_, oid)| oid == out_id), answers: w.answers.append((key, answer)) })
			}
			Err(_) => {
				$rest = $rest.append(w)
			}
		}
	}
	match $found {
		Err(NotFound) => no_call(session, [])
		Ok(w) if w.pending.is_empty() => request(server, { ..session, waiting: $rest }, w.original, w.answers)
		Ok(w) => no_call({ ..session, waiting: $rest.append(w) }, [])
	}
}
