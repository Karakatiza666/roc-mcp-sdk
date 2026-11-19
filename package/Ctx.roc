import JsonValue
import LogLevel
import Input
import Internal/Wire
import Internal/Modern

## What a handler knows about the request it serves, and the notifications it may send.
##
## **How the sends reach the wire.** A `Ctx` carries one writer, `send! : Str => {}`, that takes
## a complete JSON-RPC line. The engine is pure, so the `Ctx` inside an `Engine.Call` has a writer
## that drops every line. The transport installs its own writer right before it runs the call:
##
## ```roc
## ctx = call.ctx.with_sender(|line| { _ = io.write_line!(line) })
## (state2, outcome) = (call.run!)(state, ctx)
## ```
##
## Each send (`log!`, `progress!`, `list_changed!`, `resource_updated!`, `notify!`) builds its
## line with the pure function of the same name ending in `_line` (`log_line`, ...) and, unless
## that returns `Err(Skip)`, writes it at once with `send!`. Tests and transports that queue
## lines call the `_line` functions directly.
##
## **2026-07-28.** On a modern connection the change notifications (`list_changed!`,
## `resource_updated!`, and `notify!` with one of their methods) go only to the
## `subscriptions/listen` subscriptions that asked for them, one line per subscription with
## `_meta["io.modelcontextprotocol/subscriptionId"]`; the `_lines` twins give those lines.
## Other notifications go out as on a 2025 connection.
Ctx :: {
	request_id : Try(JsonValue, [Notification]),
	method : Str,
	era : [Legacy, Modern],
	protocol_version : Str,
	client_capabilities : JsonValue,
	client_info : JsonValue,
	meta : JsonValue,
	inputs : List((Str, Input.Answer)),
	request_state : Try(Str, [None]),
	log_threshold : Ctx.LogThreshold,
	logging_enabled : Bool,
	session_id : Try(Str, [None]),
	auth : Try(Ctx.AuthInfo, [None]),
	round : U64,
	routing : [Direct, Subscriptions(List(JsonValue))],
	repeat_noted : Bool,
	send! : Str => {},
}.{

	## Bearer-token information that an HTTP transport's `authenticate!` produced.
	AuthInfo : { token : Str, client_id : Str, scopes : List(Str), expires_at : Try(U64, [None]), resource : Try(Str, [None]), extra : JsonValue }

	## Which `notifications/message` lines go out: all of them (2025, no `logging/setLevel` yet),
	## those at a level or above, or none (2026-07-28 without `logLevel` in the envelope).
	LogThreshold : [All, AtLeast(LogLevel), Nothing]

	## What the engine fills in. Handlers never build a `Ctx`; tests may.
	Parts : {
		request_id : Try(JsonValue, [Notification]),
		method : Str,
		era : [Legacy, Modern],
		protocol_version : Str,
		client_capabilities : JsonValue,
		client_info : JsonValue,
		meta : JsonValue,
		inputs : List((Str, Input.Answer)),
		request_state : Try(Str, [None]),
		log_threshold : Ctx.LogThreshold,
		logging_enabled : Bool,
		session_id : Try(Str, [None]),
		auth : Try(Ctx.AuthInfo, [None]),
		round : U64,
	}

	## A context whose writer drops every line (see the module doc).
	new : Ctx.Parts -> Ctx
	new = |p| {
		request_id: p.request_id,
		method: p.method,
		era: p.era,
		protocol_version: p.protocol_version,
		client_capabilities: p.client_capabilities,
		client_info: p.client_info,
		meta: p.meta,
		inputs: p.inputs,
		request_state: p.request_state,
		log_threshold: p.log_threshold,
		logging_enabled: p.logging_enabled,
		session_id: p.session_id,
		auth: p.auth,
		round: p.round,
		routing: Direct,
		repeat_noted: Bool.False,
		send!: |_line| {},
	}

	## The fields `new` was given.
	parts : Ctx -> Ctx.Parts
	parts = |c| {
		request_id: c.request_id,
		method: c.method,
		era: c.era,
		protocol_version: c.protocol_version,
		client_capabilities: c.client_capabilities,
		client_info: c.client_info,
		meta: c.meta,
		inputs: c.inputs,
		request_state: c.request_state,
		log_threshold: c.log_threshold,
		logging_enabled: c.logging_enabled,
		session_id: c.session_id,
		auth: c.auth,
		round: c.round,
	}

	request_id : Ctx -> Try(JsonValue, [Notification])
	request_id = |c| c.request_id

	method : Ctx -> Str
	method = |c| c.method

	era : Ctx -> [Legacy, Modern]
	era = |c| c.era

	protocol_version : Ctx -> Str
	protocol_version = |c| c.protocol_version

	## initialize's `capabilities` (2025), or the request envelope's (2026-07-28).
	client_capabilities : Ctx -> JsonValue
	client_capabilities = |c| c.client_capabilities

	## True when the client declared this top-level capability, e.g. "roots", "sampling", "elicitation".
	has_client_capability : Ctx, Str -> Bool
	has_client_capability = |c, n| c.client_capabilities.get(n).is_ok()

	client_info : Ctx -> JsonValue
	client_info = |c| c.client_info

	## `params._meta` without the reserved envelope keys (`Null` when absent).
	meta : Ctx -> JsonValue
	meta = |c| c.meta

	progress_token : Ctx -> Try(JsonValue, [None])
	progress_token = |c| c.meta.get("progressToken").map_err(|_| None)

	## The answer to one input request of this call: the answer from any earlier round (the
	## latest one when the key was asked again), or `NotAsked` when the key was never asked.
	## Answers accumulate over the rounds of one call, in both eras (DESIGN 2, "Answers
	## accumulate"), so a handler asks for a key only while it reads `NotAsked`.
	input : Ctx, Str -> Input.Answer
	input = |c, key| match c.inputs.find_first(|(k, _)| k == key) {
		Ok((_, a)) => a
		Err(_) => NotAsked
	}

	## The `request_state` of the previous round, after the server's verifier accepted it.
	request_state : Ctx -> Try(Str, [None])
	request_state = |c| c.request_state

	## 0 on the first call of a request, then 1, 2, ... for each round of input.
	round : Ctx -> U64
	round = |c| c.round

	session_id : Ctx -> Try(Str, [None])
	session_id = |c| c.session_id

	auth : Ctx -> Try(Ctx.AuthInfo, [None])
	auth = |c| c.auth

	## notifications/message, dropped below the session's level or when logging is not enabled.
	log! : Ctx, LogLevel, JsonValue => {}
	log! = |c, level, data| match log_line(c, level, data) {
		Ok(line) => (c.send!)(line)
		Err(Skip) => {}
	}

	## The line `log!` writes: `{level, data}` params.
	log_line : Ctx, LogLevel, JsonValue -> Try(Str, [Skip])
	log_line = |c, level, data| {
		passes = match c.log_threshold {
			All => Bool.True
			AtLeast(min) => level.is_at_least(min)
			Nothing => Bool.False
		}
		if c.logging_enabled and passes {
			Ok(Wire.notification_line("notifications/message", Ok(Object([("level", String(level.to_str())), ("data", data)]))))
		} else {
			Err(Skip)
		}
	}

	## notifications/progress, sent only when the request carried a progress token.
	progress! : Ctx, { progress : Dec, total : Try(Dec, [None]), message : Try(Str, [None]) } => {}
	progress! = |c, p| match progress_line(c, p) {
		Ok(line) => (c.send!)(line)
		Err(Skip) => {}
	}

	## The line `progress!` writes: `{progressToken, progress, total?, message?}` params.
	progress_line : Ctx, { progress : Dec, total : Try(Dec, [None]), message : Try(Str, [None]) } -> Try(Str, [Skip])
	progress_line = |c, p| match progress_token(c) {
		Ok(token) => {
			total = match p.total {
				Ok(t) => [("total", JsonValue.from_dec(t))]
				Err(None) => []
			}
			msg = match p.message {
				Ok(m) => [("message", String(m))]
				Err(None) => []
			}
			params : JsonValue
			params = Object([("progressToken", token), ("progress", JsonValue.from_dec(p.progress))].concat(total).concat(msg))
			Ok(Wire.notification_line("notifications/progress", Ok(params)))
		}
		Err(None) => Err(Skip)
	}

	## notifications/{tools,resources,prompts}/list_changed.
	list_changed! : Ctx, [Tools, Resources, Prompts] => {}
	list_changed! = |c, which| send_all!(c, list_changed_lines(c, which))

	## The 2025 line of `list_changed!` (no params, as JS sends it).
	list_changed_line : Ctx, [Tools, Resources, Prompts] -> Str
	list_changed_line = |_c, which| Wire.notification_line(list_changed_method(which), Err(None))

	## The lines `list_changed!` writes: the 2025 line, or one per matching subscription (2026-07-28).
	list_changed_lines : Ctx, [Tools, Resources, Prompts] -> List(Str)
	list_changed_lines = |c, which| routed(c, list_changed_method(which), Err(None))

	## notifications/resources/updated.
	resource_updated! : Ctx, Str => {}
	resource_updated! = |c, uri| send_all!(c, resource_updated_lines(c, uri))

	## The 2025 line of `resource_updated!`: `{uri}` params.
	resource_updated_line : Ctx, Str -> Str
	resource_updated_line = |_c, uri| Wire.notification_line("notifications/resources/updated", Ok(Object([("uri", String(uri))])))

	## The lines `resource_updated!` writes (2026-07-28: to the subscriptions listening to `uri`).
	resource_updated_lines : Ctx, Str -> List(Str)
	resource_updated_lines = |c, uri| routed(c, "notifications/resources/updated", Ok(Object([("uri", String(uri))])))

	## Any other notification, tied to this request.
	notify! : Ctx, Str, JsonValue => {}
	notify! = |c, notification, params| send_all!(c, notify_lines(c, notification, params))

	## The 2025 line of `notify!`.
	notify_line : Ctx, Str, JsonValue -> Str
	notify_line = |_c, notification, params| Wire.notification_line(notification, Ok(params))

	## The lines `notify!` writes (2026-07-28: a change notification goes to the subscriptions).
	notify_lines : Ctx, Str, JsonValue -> List(Str)
	notify_lines = |c, notification, params| routed(c, notification, Ok(params))

	## For the engine: the `subscriptions/listen` subscriptions of a 2026-07-28 connection, which
	## the change notifications are routed to.
	with_subscriptions : Ctx, List(JsonValue) -> Ctx
	with_subscriptions = |c, subs| { ..c, routing: Subscriptions(subs) }

	## For the engine: true once the engine has logged that this call asked again for a key it
	## already had an answer for (the diagnostic is logged once per call).
	input_repeat_noted : Ctx -> Bool
	input_repeat_noted = |c| c.repeat_noted

	## For the engine: see `input_repeat_noted`.
	with_input_repeat_noted : Ctx, Bool -> Ctx
	with_input_repeat_noted = |c, b| { ..c, repeat_noted: b }

	## For transports: install the writer. Handlers never call this.
	with_sender : Ctx, (Str => {}) -> Ctx
	with_sender = |c, send!| { ..c, send! }
}

list_changed_method : [Tools, Resources, Prompts] -> Str
list_changed_method = |which| match which {
	Tools => "notifications/tools/list_changed"
	Resources => "notifications/resources/list_changed"
	Prompts => "notifications/prompts/list_changed"
}

routed : Ctx, Str, Try(JsonValue, [None]) -> List(Str)
routed = |c, m, params| {
	direct = [Wire.notification_line(m, params)]
	match c.routing {
		Direct => direct
		Subscriptions(subs) =>
			match Modern.route(subs, m, params) {
				Passthrough => direct
				Lines(lines) => lines
			}
	}
}

send_all! : Ctx, List(Str) => {}
send_all! = |c, lines| {
	for line in lines {
		(c.send!)(line)
	}
}
