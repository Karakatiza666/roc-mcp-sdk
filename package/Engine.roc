import JsonValue
import McpError
import LogLevel
import Input
import Ctx
import Outcome
import Server
import Tool
import Resource
import ResourceContents
import ResourceTemplate
import Prompt
import ToolResult
import UriTemplate
import Internal/Wire
import Internal/Legacy
import Internal/Paging
import Internal/Complete
import Internal/Validate
import Internal/Modern
import SchemaCheck

## The pure protocol core. Transports feed it messages and run the handler calls it returns.
##
## A transport loop:
## 1. `receive` (a line) or `receive_json` (a parsed message) gives a `Step`: the new session,
##    the lines to write (`out`), lines for the transport's log (`log`), and the handler `calls`.
## 2. For each call, install the writer (`call.ctx.with_sender(...)`, see `Ctx`), run
##    `(call.run!)(state, ctx)`, and pass its outcome to `finish`, which gives the next `Step`
##    (it may hold more calls: run them the same way).
## 3. When `next_deadline` passes, call `expire`.
##
## What `run!` returns (and what a test gives `finish` as a scripted outcome) is the raw result
## of the handler; `finish` turns it into the response:
## - tools/call: `ToolResult.to_json` of the result (`finish` checks the output schema, adds the
##   text block, wraps non-object `structuredContent` and validates base64 and dates);
## - prompts/get: `Prompt.result_to_json`; resources/read: `{contents: [...]}`;
## - resources/list: an `Array` with one `Array` of `Resource.to_json` per template that has a
##   `template_list` callback, in registration order (`finish` adds the static resources first,
##   merges each template's metadata in, and pages the list);
## - completion/complete: an `Array` of `String`s, all candidates (`finish` keeps 100);
## - resources/subscribe and unsubscribe: `{}`; custom `on_request` methods: the result as is;
## - notifications: anything (`Null`); nothing is written.
Engine :: [].{

	## The state of one connection (stdio) or one session (HTTP).
	Session :: {
		era : [Undecided, Legacy, Modern],
		initialized : Bool,
		protocol_version : Str,
		client_capabilities : JsonValue,
		client_info : JsonValue,
		log_level : Try(LogLevel, [None]),
		next_out_id : U64,
		parked : List(Engine.Parked),
		session_id : Try(Str, [None]),
		auth : Try(Ctx.AuthInfo, [None]),
		subscriptions : List(JsonValue),
		probe : Bool,
	}.{
		new : Engine.Session
		new = {
			era: Undecided,
			initialized: Bool.False,
			protocol_version: "",
			client_capabilities: Object([]),
			client_info: Null,
			log_level: Err(None),
			next_out_id: 0,
			parked: [],
			session_id: Err(None),
			auth: Err(None),
			subscriptions: [],
			probe: Bool.False,
		}

		## Requests parked on unanswered input requests.
		waiting : Engine.Session -> U64
		waiting = |s| s.parked.len()

		## The era the first message selected (`Undecided` before any message).
		current_era : Engine.Session -> [Undecided, Legacy, Modern]
		current_era = |s| s.era

		## True once the client sent notifications/initialized.
		is_initialized : Engine.Session -> Bool
		is_initialized = |s| s.initialized

		## The version initialize negotiated (`""` before it).
		negotiated_version : Engine.Session -> Str
		negotiated_version = |s| s.protocol_version

		## The level logging/setLevel stored.
		logging_level : Engine.Session -> Try(LogLevel, [None])
		logging_level = |s| s.log_level

		## For HTTP: the authentication of the request about to be received. Every `Ctx` built
		## from now on has it (`Ctx.auth`). It is not part of `to_json`.
		with_auth : Engine.Session, Try(Ctx.AuthInfo, [None]) -> Engine.Session
		with_auth = |s, a| { ..s, auth: a }

		## For HTTP: the `Mcp-Session-Id` (`Ctx.session_id`).
		with_session_id : Engine.Session, Str -> Engine.Session
		with_session_id = |s, i| { ..s, session_id: Ok(i) }

		## A JSON form for an external session store. `from_json(to_json(s))` gives `s` back,
		## except `auth`, which is per request and never stored.
		to_json : Engine.Session -> JsonValue
		to_json = |s| {
			era_str = match s.era {
				Undecided => "undecided"
				Legacy => "legacy"
				Modern => "modern"
			}
			level = match s.log_level {
				Ok(l) => String(l.to_str())
				Err(None) => Null
			}
			sid = match s.session_id {
				Ok(i) => String(i)
				Err(None) => Null
			}
			Object([
				("era", String(era_str)),
				("initialized", Bool(s.initialized)),
				("protocolVersion", String(s.protocol_version)),
				("clientCapabilities", s.client_capabilities),
				("clientInfo", s.client_info),
				("logLevel", level),
				("nextOutId", JsonValue.from_u64(s.next_out_id)),
				("parked", Array(s.parked.map(parked_to_json))),
				("sessionId", sid),
				("subscriptions", Array(s.subscriptions)),
				("probe", Bool(s.probe)),
			])
		}

		from_json : JsonValue -> Try(Engine.Session, [BadSession(Str)])
		from_json = |j| {
			era_val = match j.get("era") {
				Ok(String("undecided")) => Ok(Undecided)
				Ok(String("legacy")) => Ok(Legacy)
				Ok(String("modern")) => Ok(Modern)
				_ => Err(BadSession("era"))
			}?
			init = j.get("initialized").map_err(|_| BadSession("initialized"))?.as_bool().map_err(|_| BadSession("initialized"))?
			version = j.get("protocolVersion").map_err(|_| BadSession("protocolVersion"))?.as_str().map_err(|_| BadSession("protocolVersion"))?
			level = match j.get_or_null("logLevel") {
				Null => Ok(Err(None))
				String(l) => LogLevel.from_str(l).map_ok(|x| Ok(x)).map_err(|_| BadSession("logLevel"))
				_ => Err(BadSession("logLevel"))
			}?
			next = j.get("nextOutId").map_err(|_| BadSession("nextOutId"))?.to_u64().map_err(|_| BadSession("nextOutId"))?
			parked_list = match j.get("parked") {
				Ok(Array(xs)) => xs.map_try(parked_from_json)
				_ => Err(BadSession("parked"))
			}?
			sid = match j.get_or_null("sessionId") {
				String(i) => Ok(i)
				_ => Err(None)
			}
			subs = match j.get("subscriptions") {
				Ok(Array(xs)) => xs
				_ => []
			}
			Ok({
				era: era_val,
				initialized: init,
				protocol_version: version,
				client_capabilities: j.get_or_null("clientCapabilities"),
				client_info: j.get_or_null("clientInfo"),
				log_level: level,
				next_out_id: next,
				parked: parked_list,
				session_id: sid,
				auth: Err(None),
				subscriptions: subs,
				probe: j.get("probe") == Ok(Bool(Bool.True)),
			})
		}
	}

	## A request waiting for the answers to its server-to-client requests (2025 input shim).
	## `pending` are the requests not answered yet; `round` counts from 1.
	Parked : {
		id : JsonValue,
		message : JsonValue,
		method : Str,
		round : U64,
		pending : List({ key : Str, out_id : U64 }),
		answers : List((Str, Input.Answer)),
		request_state : Try(Str, [None]),
		deadline_ms : U64,
	}

	latest_version : Str
	latest_version = "2025-11-25"

	legacy_versions : List(Str)
	legacy_versions = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05", "2024-10-07"]

	modern_versions : List(Str)
	modern_versions = ["2026-07-28"]

	## A handler call for the transport to run. `run!` already holds the decoded arguments.
	Call(state) : {
		request_id : Try(JsonValue, [Notification]),
		message : JsonValue,
		ctx : Ctx,
		run! : state, Ctx => (state, Outcome(JsonValue)),
	}

	## `log` holds diagnostics for the transport's log (stderr), never for the client.
	Step(state) : { session : Engine.Session, out : List(Str), calls : List(Engine.Call(state)), log : List(Str) }

	## One incoming line. A trailing `\r` is ignored and a blank line gives nothing. A line that
	## is not JSON gets -32700 with `id: null`; a line over 10 MB gets -32600.
	receive : Server(state), Engine.Session, state, Str -> Engine.Step(state)
	receive = |server, sess, st, line| {
		text = line.drop_suffix("\r")
		if text.count_utf8_bytes() > Wire.max_line_bytes {
			{ ..reply(sess, [Wire.error_line(Null, McpError.new(-32600, "Invalid Request"))]), log: ["Refused a message of ${text.count_utf8_bytes().to_str()} bytes (the limit is 10 MB)"] }
		} else if text.trim() == "" {
			reply(sess, [])
		} else {
			match JsonValue.parse(text) {
				Ok(msg) => receive_json(server, sess, st, msg)
				Err(InvalidJson(why)) => { ..reply(sess, [Wire.error_line(Null, McpError.new(-32700, "Parse error"))]), log: ["Parse error: ${why}"] }
			}
		}
	}

	## One incoming message.
	receive_json : Server(state), Engine.Session, state, JsonValue -> Engine.Step(state)
	receive_json = |server, sess, st, msg| {
		parts = server.parts()
		match Wire.classify(msg) {
			Invalid({ id, why }) => { ..reply(sess, [Wire.error_line(id, McpError.new(-32600, "Invalid Request"))]), log: ["Invalid Request: ${why}"] }
			Request(r) => route_request(server, parts, sess, st, r, msg)
			Notification(n) => route_notification(parts, sess, n, msg)
			Response(r) => answer_received(parts, sess, r, msg)
		}
	}

	## The outcome of a Call: a response, or (2025) server-to-client requests and a parked request.
	finish : Server(state), Engine.Session, Engine.Call(state), Outcome(JsonValue), U64 -> Engine.Step(state)
	finish = |server, sess, call, outcome, now_ms| match call.request_id {
		Err(Notification) => reply(sess, [])
		Ok(id) => {
			parts = server.parts()
			method = call.ctx.method()
			match outcome {
				Done(raw) => reply(sess, [done_line(parts, sess, call.message, method, id, raw)])
				Fail(e) => reply(sess, [Wire.error_line(id, legacy_error(e))])
				NeedInput(req) =>
					if sess.era == Modern {
						# 2026-07-28: the client gets `input_required` and retries with the answers.
						match Modern.input_required(method, req, call.ctx.client_capabilities()) {
							Ok(j) => reply(sess, [result_line(parts, sess, id, method, j)])
							Err(e) => error_reply(sess, id, e)
						}
					} else {
						need_input(parts, sess, call, id, method, req, now_ms)
					}
			}
		}
	}

	## Ends the rounds whose input deadline passed: cancels their requests and runs the handler
	## again with `TimedOut` answers (or fails the request, see `Server.with_input_failures`).
	expire : Server(state), Engine.Session, state, U64 -> Engine.Step(state)
	expire = |server, sess, _st, now_ms| {
		parts = server.parts()
		due = sess.parked.keep_if(|p| p.deadline_ms <= now_ms)
		start = { ..reply(sess, []), session: { ..sess, parked: sess.parked.drop_if(|p| p.deadline_ms <= now_ms) } }
		due.fold(
			start,
			|acc, p| {
				cancels = p.pending.map(|leg| Wire.cancelled_line(leg.out_id, Ok("SdkError: Request timed out")))
				next = match parts.input_failures {
					FailRequest => reply(acc.session, [shim_failure_line(p.id, p.method, Legacy.fulfil_failed(p.method, "Request timed out"))])
					ToHandler => {
						answers = p.answers.concat(p.pending.map(|leg| (leg.key, TimedOut)))
						rerun(parts, acc.session, p.message, p.id, { inputs: answers, request_state: p.request_state, round: p.round })
					}
				}
				join(acc, { ..next, out: cancels.concat(next.out) })
			},
		)
	}

	## The state to continue from after `(state_after_run, outcome) = call.run!(before, ctx)`:
	## with `NeedInput` it is `before` (the round's changes are dropped, so a call changes the
	## state once; `Server.with_input_round_state(Keep)` keeps them), else the returned state.
	## Transports call it after every `run!`.
	state_after : Server(state), state, state, Outcome(JsonValue) -> state
	state_after = |server, before, after, outcome| match outcome {
		NeedInput(_) =>
			match server.parts().round_state {
				Discard => before
				Keep => after
			}
		_ => after
	}

	## The earliest input deadline, for a transport that can wait with a timeout.
	next_deadline : Engine.Session -> Try(U64, [None])
	next_deadline = |sess| match sess.parked.map(|p| p.deadline_ms).min() {
		Ok(d) => Ok(d)
		Err(_) => Err(None)
	}

	## Lines to send on graceful shutdown: the final result of each open `subscriptions/listen`
	## subscription (2026-07-28). A 2025 session sends nothing: parked requests are dropped with
	## the connection.
	close : Engine.Session -> List(Str)
	close = |sess| Modern.final_results(sess.subscriptions)
}

## The 2026-07-28 era (`Internal/Modern.roc`). The first request or notification picks the era
## of the connection, as JS `serveStdio` does (DESIGN 5, "Era selection"); responses and invalid
## messages leave it undecided. `server/discover` makes a probe session (`era: Modern`,
## `probe: True`) that a later 2025 message replaces. A modern session dispatches through
## `modern_request`: removed methods, the envelope check, `server/discover`,
## `subscriptions/listen`, the retry fields, and then the shared `dispatch`, whose results
## `result_line` encodes for the era.

route_request : Server(state), Server.Parts(state), Engine.Session, state, { id : JsonValue, method : Str, params : JsonValue }, JsonValue -> Engine.Step(state)
route_request = |server, parts, sess, st, r, msg|
	if sess.era == Legacy {
		legacy_request(server, parts, sess, st, r, msg)
	} else if sess.era == Modern and !sess.probe {
		if r.method == "initialize" and !(Modern.valid_claim(r.params)) {
			{ ..error_reply(sess, r.id, Modern.legacy_rejection(r.method, r.params, parts.versions.modern)), log: ["Rejected a 2025-era initialize on a 2026-07-28 connection"] }
		} else {
			modern_request(server, parts, sess, st, r, msg)
		}
	} else {
		match Modern.opening(r.method, r.params, parts.versions.modern) {
			InvalidEnvelope(issue) => {
				detail = "Invalid _meta envelope for protocol revision 2026-07-28: ${issue.key}: ${issue.problem}"
				error_reply(sess, r.id, McpError.invalid_params(detail).with_data(Object([("envelope", Object([("key", String(issue.key)), ("problem", String(issue.problem))]))])))
			}
			Unsupported(v) => error_reply(sess, r.id, McpError.unsupported_version(parts.versions.modern, v))
			Modern(v) => modern_request(server, parts, { ..sess, era: Modern, probe: r.method == "server/discover", protocol_version: v }, st, r, msg)
			Legacy =>
				if parts.versions.legacy.is_empty() {
					{ ..error_reply(sess, r.id, Modern.legacy_rejection(r.method, r.params, parts.versions.modern)), log: ["Rejected a 2025-era request on a modern-only connection"] }
				} else {
					legacy_request(server, parts, { ..leave_probe(sess), era: Legacy }, st, r, msg)
				}
		}
	}

route_notification : Server.Parts(state), Engine.Session, { method : Str, params : JsonValue }, JsonValue -> Engine.Step(state)
route_notification = |parts, sess, n, msg|
	if sess.era == Legacy {
		legacy_notification(parts, sess, n, msg)
	} else if sess.era == Modern and !sess.probe {
		modern_notification(parts, sess, n, msg)
	} else {
		match Modern.opening(n.method, n.params, parts.versions.modern) {
			InvalidEnvelope(issue) => { ..reply(sess, []), log: ["Discarded a notification with a malformed envelope: ${issue.key}: ${issue.problem}"] }
			Unsupported(v) => { ..reply(sess, []), log: ["Discarded a notification claiming unsupported protocol revision ${v}"] }
			Modern(v) =>
				if sess.probe {
					modern_notification(parts, sess, n, msg)
				} else {
					modern_notification(parts, { ..sess, era: Modern, protocol_version: v }, n, msg)
				}
			Legacy =>
				if parts.versions.legacy.is_empty() {
					reply(sess, [])
				} else {
					legacy_notification(parts, { ..leave_probe(sess), era: Legacy }, n, msg)
				}
		}
	}

## A probe session is dropped when the client falls back to 2025 (JS discards the probe instance).
leave_probe : Engine.Session -> Engine.Session
leave_probe = |sess|
	if sess.probe {
		{ ..Engine.Session.new, session_id: sess.session_id, auth: sess.auth }
	} else {
		sess
	}

## True when the server serves `method` (else -32601, before the envelope is checked).
served : Server.Parts(state), Str -> Bool
served = |parts, method| match method {
	"server/discover" => Bool.True
	"tools/list" | "tools/call" => !(parts.tools.is_empty())
	"resources/list" | "resources/templates/list" | "resources/read" => resources_served(parts)
	"prompts/list" | "prompts/get" => !(parts.prompts.is_empty())
	"completion/complete" => completions_served(parts)
	_ => parts.request_handlers.any(|(m, _)| m == method)
}

modern_request : Server(state), Server.Parts(state), Engine.Session, state, { id : JsonValue, method : Str, params : JsonValue }, JsonValue -> Engine.Step(state)
modern_request = |server, parts, sess, st, r, msg|
	if r.method == "subscriptions/listen" {
		listen(server, parts, sess, r)
	} else if Modern.removed_request(r.method) or !(served(parts, r.method)) {
		not_found(sess, r.id)
	} else {
		match Modern.envelope_error(r.params) {
			Err(why) => error_reply(sess, r.id, McpError.invalid_params(why))
			Ok({}) =>
				if r.method == "server/discover" {
					reply(sess, [result_line(parts, sess, r.id, r.method, Modern.discover_result(parts.versions.modern, server.capabilities(), parts.instructions))])
				} else {
					inputs = Modern.input_responses(r.params)
					retried = r.params.get("inputResponses").is_ok() or r.params.get("requestState").is_ok()
					rr0 = { inputs, request_state: Err(None), round: if (retried) 1 else 0 }
					bad_state = McpError.invalid_params("Invalid or expired requestState").with_data(Object([("reason", String("invalid_request_state"))]))
					checked =
						if Modern.input_methods.contains(r.method) {
							match r.params.get("requestState") {
								Err(_) => Ok(rr0)
								Ok(String(rs)) => {
									rr1 = { ..rr0, request_state: Ok(rs) }
									ok = match parts.verify_request_state {
										Ok(verify) => verify(make_ctx(parts, sess, Ok(r.id), r.method, r.params, rr1), rs)
										Err(None) => Bool.True
									}
									if (ok) Ok(rr1) else Err(bad_state)
								}
								Ok(_) => Err(bad_state)
							}
						} else {
							Ok(rr0)
						}
					match checked {
						Ok(rr) => dispatch(parts, sess, Ok(st), r.id, r.method, r.params, msg, rr)
						Err(e) => error_reply(sess, r.id, e)
					}
				}
		}
	}

## `subscriptions/listen` (stdio): the acknowledgement, or an error. The subscription ends with
## `notifications/cancelled` or, on shutdown, with its final result (`close`).
listen : Server(state), Server.Parts(state), Engine.Session, { id : JsonValue, method : Str, params : JsonValue } -> Engine.Step(state)
listen = |server, parts, sess, r| {
	srv = { capabilities: server.capabilities(), versions: parts.versions.modern, info: parts.info, open: sess.subscriptions.len() }
	match Modern.listen(r.id, r.params, srv) {
		Subscribed(sub, ack) => {
			subs =
				if sess.subscriptions.any(|x| x.get_or_null("id") == r.id) {
					sess.subscriptions.map(|x| if (x.get_or_null("id") == r.id) sub else x)
				} else {
					sess.subscriptions.append(sub)
				}
			reply({ ..sess, subscriptions: subs }, [ack])
		}
		Refused(line) => reply(sess, [line])
	}
}

modern_notification : Server.Parts(state), Engine.Session, { method : Str, params : JsonValue }, JsonValue -> Engine.Step(state)
modern_notification = |parts, sess, n, msg| {
	target = n.params.get_or_null("requestId")
	if n.method == "notifications/cancelled" and sess.subscriptions.any(|x| x.get_or_null("id") == target) {
		reply({ ..sess, subscriptions: sess.subscriptions.drop_if(|x| x.get_or_null("id") == target) }, [])
	} else if Modern.removed_notification(n.method) {
		reply(sess, [])
	} else {
		legacy_notification(parts, sess, n, msg)
	}
}

## The response line of a result, encoded for the session's era (2026-07-28: `resultType`,
## the cache fields and serverInfo, see `Modern.encode_result`).
result_line : Server.Parts(state), Engine.Session, JsonValue, Str, JsonValue -> Str
result_line = |parts, sess, id, method, result|
	if sess.era == Modern {
		hint = match parts.cache_hints.keep_if(|(m, _)| m == method).last() {
			Ok((_, h)) => Ok(h)
			Err(_) => Err(None)
		}
		match Modern.encode_result(method, result, parts.info, hint) {
			Ok(j) => Wire.result_line(id, j)
			Err(e) => Wire.error_line(id, e)
		}
	} else {
		Wire.result_line(id, result)
	}

method_reply : Server.Parts(state), Engine.Session, JsonValue, Str, JsonValue -> Engine.Step(state)
method_reply = |parts, sess, id, method, result| reply(sess, [result_line(parts, sess, id, method, result)])

## Answers a request's id with a fixed set of lines.
reply : Engine.Session, List(Str) -> Engine.Step(state)
reply = |sess, out| { session: sess, out, calls: [], log: [] }

## `a` then `b`, with `b`'s session.
join : Engine.Step(state), Engine.Step(state) -> Engine.Step(state)
join = |a, b| { session: b.session, out: a.out.concat(b.out), calls: a.calls.concat(b.calls), log: a.log.concat(b.log) }

result_reply : Engine.Session, JsonValue, JsonValue -> Engine.Step(state)
result_reply = |sess, id, result| reply(sess, [Wire.result_line(id, result)])

error_reply : Engine.Session, JsonValue, McpError -> Engine.Step(state)
error_reply = |sess, id, e| reply(sess, [Wire.error_line(id, e)])

not_found : Engine.Session, JsonValue -> Engine.Step(state)
not_found = |sess, id| error_reply(sess, id, McpError.new(-32601, "Method not found"))

## 2025 wire: -32002 is sent as -32602 (JS parity).
legacy_error : McpError -> McpError
legacy_error = |e|
	if e.code() == -32002 {
		match e.data() {
			Ok(d) => McpError.new(-32602, e.message()).with_data(d)
			Err(None) => McpError.new(-32602, e.message())
		}
	} else {
		e
	}

## The answers and state a request is dispatched with: none on the first call.
Rerun : { inputs : List((Str, Input.Answer)), request_state : Try(Str, [None]), round : U64 }

first_call : Rerun
first_call = { inputs: [], request_state: Err(None), round: 0 }

make_ctx : Server.Parts(state), Engine.Session, Try(JsonValue, [Notification]), Str, JsonValue, Rerun -> Ctx
make_ctx = |parts, sess, rid, method, params, rr|
	if sess.era == Modern {
		env = Modern.envelope(params)
		Ctx.new({
			request_id: rid,
			method,
			era: Modern,
			protocol_version: if (env.version == "") sess.protocol_version else env.version,
			client_capabilities: env.capabilities,
			client_info: env.info,
			meta: env.meta,
			inputs: rr.inputs,
			request_state: rr.request_state,
			log_threshold: match env.log_level {
				Ok(l) => AtLeast(l)
				Err(None) => Nothing
			},
			logging_enabled: parts.logging,
			session_id: sess.session_id,
			auth: sess.auth,
			round: rr.round,
		})
			.with_subscriptions(sess.subscriptions)
	} else {
		legacy_ctx(parts, sess, rid, method, params, rr)
	}

legacy_ctx : Server.Parts(state), Engine.Session, Try(JsonValue, [Notification]), Str, JsonValue, Rerun -> Ctx
legacy_ctx = |parts, sess, rid, method, params, rr|
	Ctx.new({
		request_id: rid,
		method,
		era: if (sess.era == Modern) Modern else Legacy,
		protocol_version: sess.protocol_version,
		client_capabilities: sess.client_capabilities,
		client_info: sess.client_info,
		meta: params.get_or_null("_meta"),
		inputs: rr.inputs,
		request_state: rr.request_state,
		log_threshold: match sess.log_level {
			Ok(l) => AtLeast(l)
			Err(None) => All
		},
		logging_enabled: parts.logging,
		session_id: sess.session_id,
		auth: sess.auth,
		round: rr.round,
	})

make_call : Server.Parts(state), Engine.Session, JsonValue, Str, JsonValue, JsonValue, Rerun, (state, Ctx => (state, Outcome(JsonValue))) -> Engine.Step(state)
make_call = |parts, sess, id, method, params, msg, rr, run!| {
	c = make_ctx(parts, sess, Ok(id), method, params, rr)
	{ session: sess, out: [], calls: [{ request_id: Ok(id), message: msg, ctx: c, run! }], log: [] }
}

## True when the predicate allows it; on a re-dispatch (no state) the check is skipped, as JS
## looks a tool up only once per request.
allowed : Try(state, [NoState]), (state -> Bool) -> Bool
allowed = |maybe_st, pred| match maybe_st {
	Ok(s) => pred(s)
	Err(NoState) => Bool.True
}

legacy_request : Server(state), Server.Parts(state), Engine.Session, state, { id : JsonValue, method : Str, params : JsonValue }, JsonValue -> Engine.Step(state)
legacy_request = |server, parts, sess, st, r, msg|
	if parts.versions.legacy.is_empty() {
		error_reply(sess, r.id, Modern.legacy_rejection(r.method, r.params, parts.versions.modern))
	} else {
		match r.method {
			"initialize" => initialize(server, parts, sess, r.id, r.params)
			"ping" => result_reply(sess, r.id, Object([]))
			"logging/setLevel" => set_level(parts, sess, r.id, r.params)
			_ => dispatch(parts, sess, Ok(st), r.id, r.method, r.params, msg, first_call)
		}
	}

initialize : Server(state), Server.Parts(state), Engine.Session, JsonValue, JsonValue -> Engine.Step(state)
initialize = |server, parts, sess, id, params| {
	requested = params.get_or_null("protocolVersion").as_str() ?? ""
	version = if (parts.versions.legacy.contains(requested)) requested else parts.versions.legacy.first() ?? Engine.latest_version
	caps = match params.get_or_null("capabilities") {
		Object(fs) => Object(fs)
		_ => Object([])
	}
	sess1 = { ..sess, era: Legacy, protocol_version: version, client_capabilities: caps, client_info: params.get_or_null("clientInfo") }
	instructions = match parts.instructions {
		Ok(text) => [("instructions", String(text))]
		Err(None) => []
	}
	result : JsonValue
	result = Object(
		[
			("protocolVersion", String(version)),
			("capabilities", server.capabilities()),
			("serverInfo", Object(parts.info)),
		].concat(instructions),
	)
	result_reply(sess1, id, result)
}

set_level : Server.Parts(state), Engine.Session, JsonValue, JsonValue -> Engine.Step(state)
set_level = |parts, sess, id, params|
	if !parts.logging {
		not_found(sess, id)
	} else {
		match params.get_or_null("level") {
			String(l) =>
				match LogLevel.from_str(l) {
					Ok(level) => result_reply({ ..sess, log_level: Ok(level) }, id, Object([]))
					Err(_) => error_reply(sess, id, McpError.invalid_params("Invalid params: level must be one of ${Str.join_with(LogLevel.all.map(|x| x.to_str()), ", ")}"))
				}
			_ => error_reply(sess, id, McpError.invalid_params("Invalid params: level must be a string"))
		}
	}

## The methods whose handlers the app registered (and the list methods).
dispatch : Server.Parts(state), Engine.Session, Try(state, [NoState]), JsonValue, Str, JsonValue, JsonValue, Rerun -> Engine.Step(state)
dispatch = |parts, sess, maybe_st, id, method, params, msg, rr| match method {
	"tools/list" => tools_list(parts, sess, maybe_st, id, params)
	"tools/call" => tools_call(parts, sess, maybe_st, id, params, msg, rr)
	"resources/list" => resources_list(parts, sess, maybe_st, id, params, msg)
	"resources/templates/list" => templates_list(parts, sess, id, params)
	"resources/read" => resources_read(parts, sess, maybe_st, id, params, msg, rr)
	"resources/subscribe" => subscription(parts, sess, id, method, params, msg)
	"resources/unsubscribe" => subscription(parts, sess, id, method, params, msg)
	"prompts/list" => prompts_list(parts, sess, maybe_st, id, params)
	"prompts/get" => prompts_get(parts, sess, maybe_st, id, params, msg, rr)
	"completion/complete" => complete(parts, sess, maybe_st, id, params, msg)
	_ =>
		match parts.request_handlers.find_first(|(m, _)| m == method) {
			Ok((_, h!)) => make_call(parts, sess, id, method, params, msg, rr, |s0, c| h!(s0, c, params))
			Err(_) => not_found(sess, id)
		}
}

## A page of a list method, or -32602 for a bad cursor.
paged : Server.Parts(state), Engine.Session, JsonValue, Str, JsonValue, Str, List(JsonValue) -> Engine.Step(state)
paged = |parts, sess, id, method, params, key, items| match Paging.page(items, parts.page_size, params.get_or_null("cursor")) {
	Ok(pg) => method_reply(parts, sess, id, method, Paging.result(key, pg.items, pg.next))
	Err(InvalidCursor) => error_reply(sess, id, McpError.invalid_params("Invalid cursor"))
}

## The tools/list entry on the 2025 wire: a non-object `outputSchema` root is wrapped.
legacy_tool_json : Tool -> JsonValue
legacy_tool_json = |t| match t.output_schema() {
	Ok(s) if s.get("type") != Ok(String("object")) => Object(Wire.put(Wire.fields(t.to_json()), "outputSchema", Legacy.wrap_output_schema(s)))
	_ => t.to_json()
}

tools_list : Server.Parts(state), Engine.Session, Try(state, [NoState]), JsonValue, JsonValue -> Engine.Step(state)
tools_list = |parts, sess, maybe_st, id, params|
	if parts.tools.is_empty() {
		not_found(sess, id)
	} else {
		visible = parts.tools.keep_if(|t| allowed(maybe_st, t.enabled))
		paged(parts, sess, id, "tools/list", params, "tools", visible.map(|t| if (sess.era == Modern) t.tool.to_json() else legacy_tool_json(t.tool)))
	}

## Composes the middlewares around a tool call, the first registered outermost.
compose_tool : List(Server.Middleware(state)), Str, (state, Ctx => (state, Outcome(ToolResult))) -> (state, Ctx => (state, Outcome(ToolResult)))
compose_tool = |middlewares, tool_name, inner!|
	middlewares.fold_rev(inner!, |mw!, next!| |s0, c| mw!(s0, c, tool_name, |s1| next!(s1, c)))

tools_call : Server.Parts(state), Engine.Session, Try(state, [NoState]), JsonValue, JsonValue, JsonValue, Rerun -> Engine.Step(state)
tools_call = |parts, sess, maybe_st, id, params, msg, rr|
	if parts.tools.is_empty() {
		not_found(sess, id)
	} else {
		issues = params_issues(present(msg, "params"), Bool.False)
		match (issues, params.get_or_null("name"), params.get_or_null("arguments")) {
			([], String(tool_name), args_raw) => {
				args = match args_raw {
					Object(fs) => Object(fs)
					_ => Object([])
				}
				match parts.tools.find_first(|t| t.tool.name() == tool_name) {
					Err(_) => error_reply(sess, id, McpError.invalid_params("Tool ${tool_name} not found"))
					Ok(entry) =>
						if !(allowed(maybe_st, entry.enabled)) {
							error_reply(sess, id, McpError.invalid_params("Tool ${tool_name} disabled"))
						} else {
							checked =
								if parts.input_validation and entry.validate and entry.tool.has_input_schema() {
									match SchemaCheck.validate(entry.tool.input_schema(), args) {
										Ok(v) => Ok(v)
										Err(Invalid(xs)) => Err("Invalid arguments for tool ${tool_name}: ${Str.join_with(xs, ", ")}")
									}
								} else {
									Ok(args)
								}
							prepared = match checked {
								Ok(v) => (entry.prepare)(v)
								Err(why) => Err(why)
							}
							match prepared {
								Err(why) => method_reply(parts, sess, id, "tools/call", Legacy.error_result("Input validation error: ${why}"))
								Ok(h!) => {
									composed! = compose_tool(parts.around_tools, tool_name, h!)
									make_call(
										parts,
										sess,
										id,
										"tools/call",
										params,
										msg,
										rr,
										|s0, c| {
											(s1, o) = composed!(s0, c)
											(s1, o.map(|r| r.to_json()))
										},
									)
								}
							}
						}
				}
			}
			_ => error_reply(sess, id, McpError.invalid_params("Invalid tools/call request: ${Wire.pretty(Array(issues))}"))
		}
	}

## A key of an object, or `Absent`.
present : JsonValue, Str -> Try(JsonValue, [Absent])
present = |v, k| match v.get(k) {
	Ok(x) => Ok(x)
	Err(_) => Err(Absent)
}

## A zod `invalid_type` issue as the JS SDK prints it in a request error.
type_issue : List(Str), Str, Try(JsonValue, [Absent]) -> JsonValue
type_issue = |path, expected, received|
	Object([
		("expected", String(expected)),
		("code", String("invalid_type")),
		("path", Array(path.map(|p| String(p)))),
		("message", String("Invalid input: expected ${expected}, received ${SchemaCheck.type_name(received)}")),
	])

## The issues zod finds in the params of tools/call or prompts/get (the JS SDK's request
## schemas): `params` an object, `name` a string, `arguments` absent or an object, whose
## values must be strings for prompts/get.
params_issues : Try(JsonValue, [Absent]), Bool -> List(JsonValue)
params_issues = |p, string_values| match p {
	Ok(Object(fs)) => {
		v : JsonValue
		v = Object(fs)
		name_issue = match present(v, "name") {
			Ok(String(_)) => []
			other => [type_issue(["params", "name"], "string", other)]
		}
		args_issue = match present(v, "arguments") {
			Err(Absent) => []
			Ok(Object(args)) =>
				if string_values {
					args.keep_oks(
						|(k, x)| match x {
							String(_) => Err(Fine)
							_ => Ok(type_issue(["params", "arguments", k], "string", Ok(x)))
						},
					)
				} else {
					[]
				}
			other => [type_issue(["params", "arguments"], "record", other)]
		}
		name_issue.concat(args_issue)
	}
	other => [type_issue(["params"], "object", other)]
}

resources_served : Server.Parts(state) -> Bool
resources_served = |parts| !(parts.resources.is_empty()) or !(parts.templates.is_empty())

resources_list : Server.Parts(state), Engine.Session, Try(state, [NoState]), JsonValue, JsonValue, JsonValue -> Engine.Step(state)
resources_list = |parts, sess, maybe_st, id, params, msg|
	if !(resources_served(parts)) {
		not_found(sess, id)
	} else {
		listers = parts.templates.keep_oks(|t| t.list!.map_err(|_| NoList))
		if listers.is_empty() {
			statics = parts.resources.keep_if(|r| allowed(maybe_st, r.enabled)).map(|r| r.resource.to_json())
			paged(parts, sess, id, "resources/list", params, "resources", statics)
		} else {
			make_call(
				parts,
				sess,
				id,
				"resources/list",
				params,
				msg,
				first_call,
				|s0, c| {
					var $s = s0
					var $groups = []
					for list! in listers {
						(s1, found) = list!($s, c)
						$s = s1
						$groups = $groups.append(Array(found.map(|r| r.to_json())))
					}
					($s, Outcome.done(Array($groups)))
				},
			)
		}
	}

templates_list : Server.Parts(state), Engine.Session, JsonValue, JsonValue -> Engine.Step(state)
templates_list = |parts, sess, id, params|
	if !(resources_served(parts)) {
		not_found(sess, id)
	} else {
		paged(parts, sess, id, "resources/templates/list", params, "resourceTemplates", parts.templates.map(|t| t.template.to_json()))
	}

## A URI as JS `new URL` would accept it, roughly: a scheme, then anything without spaces.
valid_uri : Str -> Bool
valid_uri = |uri| {
	b = uri.to_utf8()
	alpha = |c| (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z')
	scheme_char = |c| alpha(c) or (c >= '0' and c <= '9') or c == '+' or c == '-' or c == '.'
	match b.find_first_index(|c| c == ':') {
		Ok(colon) if colon > 0 =>
			alpha(b.get(0) ?? 0) and b.take_first(colon).all(scheme_char) and !(b.any(|c| c == ' ' or c < 32))
		_ => Bool.False
	}
}

contents_json : List(ResourceContents) -> JsonValue
contents_json = |cs| Object([("contents", Array(cs.map(|x| x.to_json())))])

resources_read : Server.Parts(state), Engine.Session, Try(state, [NoState]), JsonValue, JsonValue, JsonValue, Rerun -> Engine.Step(state)
resources_read = |parts, sess, maybe_st, id, params, msg, rr|
	if !(resources_served(parts)) {
		not_found(sess, id)
	} else {
		match params.get_or_null("uri") {
			String(uri) =>
				if !(valid_uri(uri)) {
					error_reply(sess, id, McpError.invalid_params("Resource URI ${uri} is invalid").with_data(Object([("uri", String(uri)), ("reason", String("invalid_uri"))])))
				} else {
					match parts.resources.find_first(|r| r.resource.uri() == uri and allowed(maybe_st, r.enabled)) {
						Ok(entry) =>
							make_call(
								parts,
								sess,
								id,
								"resources/read",
								params,
								msg,
								rr,
								|s0, c| {
									(s1, o) = (entry.read!)(s0, c, uri)
									(s1, o.map(contents_json))
								},
							)
						Err(_) => {
							matched = parts.templates.keep_oks(
								|t| match t.template.uri_template().match_uri(uri) {
									Ok(vars) => Ok((t, vars))
									Err(NoMatch) => Err(NoMatch)
								},
							)
							match matched.first() {
								Ok((t, vars)) =>
									make_call(
										parts,
										sess,
										id,
										"resources/read",
										params,
										msg,
										rr,
										|s0, c| {
											(s1, o) = (t.read!)(s0, c, uri, vars)
											(s1, o.map(contents_json))
										},
									)
								Err(_) => error_reply(sess, id, McpError.resource_not_found(uri))
							}
						}
					}
				}
			_ => error_reply(sess, id, McpError.invalid_params("Invalid resources/read request: uri must be a string"))
		}
	}

subscription : Server.Parts(state), Engine.Session, JsonValue, Str, JsonValue, JsonValue -> Engine.Step(state)
subscription = |parts, sess, id, method, params, msg| match parts.subscribe {
	Err(NotSupported) => not_found(sess, id)
	Ok(handlers) =>
		match params.get_or_null("uri") {
			String(uri) =>
				make_call(
					parts,
					sess,
					id,
					method,
					params,
					msg,
					first_call,
					|s0, c| {
						(s1, r) = if (method == "resources/subscribe") (handlers.subscribe!)(s0, c, uri) else (handlers.unsubscribe!)(s0, c, uri)
						match r {
							Ok({}) => (s1, Outcome.done(Object([])))
							Err(e) => (s1, Outcome.fail(e))
						}
					},
				)
			_ => error_reply(sess, id, McpError.invalid_params("Invalid ${method} request: uri must be a string"))
		}
}

prompts_list : Server.Parts(state), Engine.Session, Try(state, [NoState]), JsonValue, JsonValue -> Engine.Step(state)
prompts_list = |parts, sess, maybe_st, id, params|
	if parts.prompts.is_empty() {
		not_found(sess, id)
	} else {
		visible = parts.prompts.keep_if(|p| allowed(maybe_st, p.enabled))
		paged(parts, sess, id, "prompts/list", params, "prompts", visible.map(|p| p.prompt.to_json()))
	}

prompts_get : Server.Parts(state), Engine.Session, Try(state, [NoState]), JsonValue, JsonValue, JsonValue, Rerun -> Engine.Step(state)
prompts_get = |parts, sess, maybe_st, id, params, msg, rr|
	if parts.prompts.is_empty() {
		not_found(sess, id)
	} else {
		issues = params_issues(present(msg, "params"), Bool.True)
		match (issues, params.get_or_null("name")) {
			([], String(prompt_name)) =>
				match parts.prompts.find_first(|p| p.prompt.name() == prompt_name) {
					Err(_) => error_reply(sess, id, McpError.invalid_params("Prompt ${prompt_name} not found"))
					Ok(entry) =>
						if !(allowed(maybe_st, entry.enabled)) {
							error_reply(sess, id, McpError.invalid_params("Prompt ${prompt_name} disabled"))
						} else {
							declared = entry.prompt.arguments()
							checked =
								if parts.input_validation and !(declared.is_empty()) {
									match present(params, "arguments") {
										Err(Absent) => Err("Invalid arguments for prompt ${prompt_name}: Invalid input: expected object, received undefined")
										Ok(a) =>
											match SchemaCheck.validate(prompt_schema(declared), a) {
												Ok(v) => Ok(v)
												Err(Invalid(xs)) => Err("Invalid arguments for prompt ${prompt_name}: ${Str.join_with(xs, ", ")}")
											}
									}
								} else {
									match params.get_or_null("arguments") {
										Object(fs) => Ok(Object(fs))
										_ => Ok(Object([]))
									}
								}
							prepared = match checked {
								Ok(args) => (entry.prepare)(args)
								Err(why) => Err(why)
							}
							match prepared {
								Err(why) => error_reply(sess, id, McpError.invalid_params(why))
								Ok(h!) =>
									make_call(
										parts,
										sess,
										id,
										"prompts/get",
										params,
										msg,
										rr,
										|s0, c| {
											(s1, o) = h!(s0, c)
											(s1, o.map(Prompt.result_to_json))
										},
									)
							}
						}
				}

			## JS: the request schema's zod issues, as an internal error.
			_ => error_reply(sess, id, McpError.internal(Wire.pretty(Array(issues))))
		}
	}

## The JSON Schema of a prompt's arguments, as the JS SDK's `argsSchema` of strings.
prompt_schema : List(Prompt.Argument) -> JsonValue
prompt_schema = |declared|
	Object([
		("type", String("object")),
		("properties", Object(declared.map(|a| (a.name, Object([("type", String("string"))]))))),
		("required", Array(declared.keep_if(|a| a.required).map(|a| String(a.name)))),
	])

completions_served : Server.Parts(state) -> Bool
completions_served = |parts| parts.templates.any(|t| !(t.complete.is_empty())) or parts.prompts.any(|p| !(p.complete.is_empty()))

## `context.arguments` as (name, value) pairs; non-string values are skipped.
context_arguments : JsonValue -> List((Str, Str))
context_arguments = |params| match params.get_or_null("context").get_or_null("arguments") {
	Object(fs) =>
		fs.keep_oks(
			|(k, v)| match v {
				String(s) => Ok((k, s))
				_ => Err(NotAString)
			},
		)
	_ => []
}

complete : Server.Parts(state), Engine.Session, Try(state, [NoState]), JsonValue, JsonValue, JsonValue -> Engine.Step(state)
complete = |parts, sess, maybe_st, id, params, msg|
	if !(completions_served(parts)) {
		not_found(sess, id)
	} else {
		ref = params.get_or_null("ref")
		arg_name = params.get_or_null("argument").get_or_null("name").as_str() ?? ""
		value = params.get_or_null("argument").get_or_null("value").as_str() ?? ""
		cc = { arguments: context_arguments(params) }
		run_completer = |completer!|
			make_call(
				parts,
				sess,
				id,
				"completion/complete",
				params,
				msg,
				first_call,
				|s0, c| {
					(s1, values) = completer!(s0, c, value, cc)
					(s1, Outcome.done(Array(values.map(|v| String(v)))))
				},
			)
		match (ref.get_or_null("type"), ref.get_or_null("name"), ref.get_or_null("uri")) {
			(String("ref/prompt"), String(prompt_name), _) =>
				match parts.prompts.find_first(|p| p.prompt.name() == prompt_name) {
					Err(_) => error_reply(sess, id, McpError.invalid_params("Prompt ${prompt_name} not found"))
					Ok(entry) =>
						if !(allowed(maybe_st, entry.enabled)) {
							error_reply(sess, id, McpError.invalid_params("Prompt ${prompt_name} disabled"))
						} else {
							match entry.complete.find_first(|(a, _)| a == arg_name) {
								Ok((_, completer!)) => run_completer(completer!)
								Err(_) => method_reply(parts, sess, id, "completion/complete", Complete.empty)
							}
						}
				}
			(String("ref/resource"), _, String(uri)) =>
				match parts.templates.find_first(|t| t.template.source() == uri) {
					Ok(t) =>
						match t.complete.find_first(|(a, _)| a == arg_name) {
							Ok((_, completer!)) => run_completer(completer!)
							Err(_) => method_reply(parts, sess, id, "completion/complete", Complete.empty)
						}
					Err(_) =>
						if parts.resources.any(|r| r.resource.uri() == uri) {
							method_reply(parts, sess, id, "completion/complete", Complete.empty)
						} else {
							error_reply(sess, id, McpError.invalid_params("Resource template ${uri} not found"))
						}
				}
			_ => error_reply(sess, id, McpError.invalid_params("Invalid completion reference"))
		}
	}

legacy_notification : Server.Parts(state), Engine.Session, { method : Str, params : JsonValue }, JsonValue -> Engine.Step(state)
legacy_notification = |parts, sess, n, msg| {
	sess1 = if (n.method == "notifications/initialized") { ..sess, initialized: Bool.True } else sess
	if n.method == "notifications/cancelled" {
		cancel_parked(sess1, n.params)
	} else {
		match parts.notification_handlers.find_first(|(m, _)| m == n.method) {
			Ok((_, h!)) => {
				c = make_ctx(parts, sess1, Err(Notification), n.method, n.params, first_call)
				params = n.params
				{ session: sess1, out: [], calls: [{ request_id: Err(Notification), message: msg, ctx: c, run!: |s0, cx| (h!(s0, cx, params), Outcome.done(Null)) }], log: [] }
			}
			Err(_) => reply(sess1, [])
		}
	}
}

## notifications/cancelled for a parked request: it is dropped with no response, and its
## server-to-client requests are cancelled. A request that is not parked has already been answered.
cancel_parked : Engine.Session, JsonValue -> Engine.Step(state)
cancel_parked = |sess, params| {
	target = params.get_or_null("requestId")
	reason = match params.get_or_null("reason") {
		String(r) => r
		_ => "AbortError: This operation was aborted"
	}
	match sess.parked.find_first(|p| p.id == target) {
		Ok(p) => {
			lines = p.pending.map(|leg| Wire.cancelled_line(leg.out_id, Ok(reason)))
			reply({ ..sess, parked: sess.parked.drop_if(|q| q.id == target) }, lines)
		}
		Err(_) => reply(sess, [])
	}
}

## An answer to a server-to-client request.
answer_received : Server.Parts(state), Engine.Session, { id : JsonValue, answer : [Result(JsonValue), Error(JsonValue)] }, JsonValue -> Engine.Step(state)
answer_received = |parts, sess, r, msg| {
	unknown = { ..reply(sess, []), log: ["Received a response for an unknown message ID: ${msg.to_str()}"] }
	out_id = match out_id_of(r.id) {
		Ok(n) => n
		Err(_) => return unknown
	}
	match sess.parked.find_first(|p| p.pending.any(|leg| leg.out_id == out_id)) {
		Err(_) => unknown
		Ok(p) => {
			key = (p.pending.find_first(|leg| leg.out_id == out_id) ?? { key: "", out_id }).key
			answer = match r.answer {
				Result(j) => Answered(j)
				Error(e) => Failed(McpError.from_json(e) ?? McpError.internal(e.to_str()))
			}
			p1 = { ..p, pending: p.pending.drop_if(|leg| leg.out_id == out_id), answers: p.answers.append((key, answer)) }
			others = sess.parked.drop_if(|q| q.id == p.id)
			match (parts.input_failures, answer) {
				(FailRequest, Failed(err)) => {
					cancels = p1.pending.map(|leg| Wire.cancelled_line(leg.out_id, Ok("ProtocolError: ${err.message()}")))
					reply({ ..sess, parked: others }, cancels.append(shim_failure_line(p.id, p.method, Legacy.fulfil_failed(p.method, err.message()))))
				}
				_ =>
					if p1.pending.is_empty() {
						rerun(parts, { ..sess, parked: others }, p1.message, p1.id, { inputs: p1.answers, request_state: p1.request_state, round: p1.round })
					} else {
						reply({ ..sess, parked: sess.parked.map(|q| if (q.id == p.id) p1 else q) }, [])
					}
			}
		}
	}
}

shim_failure_line : JsonValue, Str, Str -> Str
shim_failure_line = |id, method, text| match Legacy.failure(method, text) {
	Result(j) => Wire.result_line(id, j)
	Error(e) => Wire.error_line(id, e)
}

## Dispatches a parked request again with the answers of its last round. The request state is
## checked by the server's verifier first.
rerun : Server.Parts(state), Engine.Session, JsonValue, JsonValue, Rerun -> Engine.Step(state)
rerun = |parts, sess, msg, id, rr| {
	method = msg.get_or_null("method").as_str() ?? ""
	params = msg.get_or_null("params")
	verified = match (rr.request_state, parts.verify_request_state) {
		(Ok(rs), Ok(verify)) => verify(make_ctx(parts, sess, Ok(id), method, params, rr), rs)
		_ => Bool.True
	}
	if verified {
		dispatch(parts, sess, Err(NoState), id, method, params, msg, rr)
	} else {
		error_reply(sess, id, McpError.invalid_params("Invalid or expired requestState"))
	}
}

## `NeedInput` on a 2025 connection: the input shim. Requests are sent in the form of the JS
## direct calls, or of the JS `inputRequired` shim with `with_progress_token` (see `Input.Required`).
need_input : Server.Parts(state), Engine.Session, Engine.Call(state), JsonValue, Str, Input.Required, U64 -> Engine.Step(state)
need_input = |parts, sess, call, id, method, req, now_ms| {
	round_no = call.ctx.round() + 1
	requests = req.requests()
	shim_form = req.progress_token()
	missing = if (shim_form) requests.find_first(|(_, r)| Legacy.missing_capability(sess.client_capabilities, r)) else Err(NotFound)
	refused = if (shim_form) [] else requests.keep_oks(|(key, r)| Legacy.direct_refusal(sess.client_capabilities, r).map_ok(|why| (key, why)))
	to_send = requests.drop_if(|(key, _)| refused.any(|(k, _)| k == key))
	refused_answers = refused.map(|(key, why)| (key, Failed(McpError.internal(why))))
	if !(Legacy.input_methods.contains(method)) {
		error_reply(sess, id, McpError.internal("Handler for ${method} asked for input, but only tools/call, prompts/get and resources/read may"))
	} else if round_no > Legacy.max_rounds {
		reply(sess, [shim_failure_line(id, method, Legacy.rounds_exceeded(method))])
	} else if requests.is_empty() and req.request_state().is_err() {
		error_reply(sess, id, McpError.internal("Handler for ${method} returned an input-required result with neither inputRequests nor requestState"))
	} else {
		match missing {
			Ok((key, r)) => reply(sess, [shim_failure_line(id, method, Legacy.cannot_request(key, r.method()))])
			Err(_) =>
				match (parts.input_failures, refused) {
					(FailRequest, [(_, why), ..]) => reply(sess, [shim_failure_line(id, method, Legacy.fulfil_failed(method, why))])
					_ =>
						if to_send.is_empty() {
							rerun(parts, sess, call.message, id, { inputs: refused_answers, request_state: req.request_state(), round: round_no })
						} else {
							first_n = sess.next_out_id
							legs = to_send.map_with_index(|(key, r), i| { key, out_id: first_n + i, request: r })
							lines = legs.map(
								|leg| {
									token = if (shim_form) Ok(leg.out_id) else Err(None)
									Wire.request_line(JsonValue.from_u64(leg.out_id), leg.request.method(), Legacy.request_params(leg.request, token, "mcp-sdk-${leg.out_id.to_str()}"))
								},
							)
							timeout = req.timeout_ms() ?? Legacy.default_round_timeout_ms
							parked = {
								id,
								message: call.message,
								method,
								round: round_no,
								pending: legs.map(|leg| { key: leg.key, out_id: leg.out_id }),
								answers: refused_answers,
								request_state: req.request_state(),
								deadline_ms: now_ms + timeout,
							}
							reply({ ..sess, next_out_id: first_n + legs.len(), parked: sess.parked.append(parked) }, lines)
						}
				}
		}
	}
}

## The response line for a `Done` outcome.
done_line : Server.Parts(state), Engine.Session, JsonValue, Str, JsonValue, JsonValue -> Str
done_line = |parts, sess, msg, method, id, raw| {
	checked = |result| match Validate.result(result) {
		Ok({}) => result_line(parts, sess, id, method, result)
		Err(why) => Wire.error_line(id, McpError.invalid_params("Invalid ${method} result: ${why}"))
	}
	params = msg.get_or_null("params")
	match method {
		"tools/call" => {
			tool_name = params.get_or_null("name").as_str() ?? ""
			schema = match parts.tools.find_first(|t| t.tool.name() == tool_name) {
				Ok(t) => t.tool.output_schema()
				Err(_) => Err(None)
			}
			checked(if (sess.era == Modern) Modern.tool_result(tool_name, schema, raw) else Legacy.project_tool_result(tool_name, schema, raw))
		}
		"resources/read" | "prompts/get" => checked(raw)
		"resources/list" => {
			listers = parts.templates.keep_if(|t| t.list!.is_ok())
			groups = match raw {
				Array(gs) => gs
				_ => []
			}
			merged = listers.map2(
				groups,
				|t, g| match g {
					Array(entries) => entries.map(|e| Object(Wire.spread(t.template.metadata(), Wire.fields(e))))
					_ => []
				},
			)
			items = parts.resources.map(|r| r.resource.to_json()).concat(merged.join())
			match Paging.page(items, parts.page_size, params.get_or_null("cursor")) {
				Ok(pg) => result_line(parts, sess, id, method, Paging.result("resources", pg.items, pg.next))
				Err(InvalidCursor) => Wire.error_line(id, McpError.invalid_params("Invalid cursor"))
			}
		}
		"completion/complete" => {
			values = match raw {
				Array(vs) => vs.keep_oks(|v| v.as_str())
				_ => []
			}
			result_line(parts, sess, id, method, Complete.result(values))
		}
		_ => result_line(parts, sess, id, method, raw)
	}
}

parked_to_json : Engine.Parked -> JsonValue
parked_to_json = |p| {
	rs = match p.request_state {
		Ok(s) => String(s)
		Err(None) => Null
	}
	Object([
		("id", p.id),
		("message", p.message),
		("method", String(p.method)),
		("round", JsonValue.from_u64(p.round)),
		("pending", Array(p.pending.map(|leg| Object([("key", String(leg.key)), ("outId", JsonValue.from_u64(leg.out_id))])))),
		("answers", Array(p.answers.map(answer_to_json))),
		("requestState", rs),
		("deadlineMs", JsonValue.from_u64(p.deadline_ms)),
	])
}

answer_to_json : (Str, Input.Answer) -> JsonValue
answer_to_json = |(key, a)| {
	body = match a {
		NotAsked => [("notAsked", Bool(Bool.True))]
		Answered(j) => [("answered", j)]
		Failed(e) => [("failed", e.to_json())]
		TimedOut => [("timedOut", Bool(Bool.True))]
	}
	Object([("key", String(key))].concat(body))
}

## The id of a server-to-client request from a response's `id`, as JS matches it
## (`Number(id)`): an integer, or a string of decimal digits.
out_id_of : JsonValue -> Try(U64, [NotOurs])
out_id_of = |id| match id {
	Number(t) => U64.from_str(t).map_err(|_| NotOurs)
	String(s) => U64.from_str(s.trim()).map_err(|_| NotOurs)
	_ => Err(NotOurs)
}

## A stored `outId`: a number, or `"mcp-sdk-<n>"` in a session stored by release 0.1.
stored_out_id : JsonValue -> Try(U64, [NotOurs])
stored_out_id = |id| match id {
	String(s) => out_id_of(String(s.drop_prefix("mcp-sdk-")))
	other => out_id_of(other)
}

parked_from_json : JsonValue -> Try(Engine.Parked, [BadSession(Str)])
parked_from_json = |j| {
	bad = |_| BadSession("parked")
	pending = match j.get("pending") {
		Ok(Array(xs)) =>
			xs.map_try(
				|x| match (x.get("key"), x.get("outId")) {
					(Ok(String(k)), Ok(o)) =>
						match stored_out_id(o) {
							Ok(n) => Ok({ key: k, out_id: n })
							Err(_) => Err(BadSession("parked"))
						}
					_ => Err(BadSession("parked"))
				},
			)
		_ => Err(BadSession("parked"))
	}?
	answers = match j.get("answers") {
		Ok(Array(xs)) => xs.map_try(answer_from_json)
		_ => Err(BadSession("parked"))
	}?
	rs = match j.get_or_null("requestState") {
		String(s) => Ok(s)
		_ => Err(None)
	}
	Ok({
		id: j.get("id").map_err(bad)?,
		message: j.get("message").map_err(bad)?,
		method: j.get("method").map_err(bad)?.as_str().map_err(bad)?,
		round: j.get("round").map_err(bad)?.to_u64().map_err(bad)?,
		pending,
		answers,
		request_state: rs,
		deadline_ms: j.get("deadlineMs").map_err(bad)?.to_u64().map_err(bad)?,
	})
}

answer_from_json : JsonValue -> Try((Str, Input.Answer), [BadSession(Str)])
answer_from_json = |j| match j.get("key") {
	Ok(String(k)) =>
		match (j.get("answered"), j.get("failed"), j.get("timedOut")) {
			(Ok(a), _, _) => Ok((k, Answered(a)))
			(_, Ok(e), _) =>
				match McpError.from_json(e) {
					Ok(err) => Ok((k, Failed(err)))
					Err(_) => Err(BadSession("answer"))
				}
			(_, _, Ok(_)) => Ok((k, TimedOut))
			_ => Ok((k, NotAsked))
		}
	_ => Err(BadSession("answer"))
}
