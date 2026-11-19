import JsonValue
import LogLevel
import Input

## What a handler knows about the request it serves, and the notifications it may send.
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
	log_level : Try(LogLevel, [Off]),
	logging_enabled : Bool,
	session_id : Try(Str, [None]),
	auth : Try(Ctx.AuthInfo, [None]),
	send! : Str => {},
}.{
	AuthInfo : { token : Str, client_id : Str, scopes : List(Str), expires_at : Try(U64, [None]), resource : Try(Str, [None]), extra : JsonValue }

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
	has_client_capability = |c, name| c.client_capabilities.get(name).is_ok()

	client_info : Ctx -> JsonValue
	client_info = |c| c.client_info

	## `params._meta` without the reserved envelope keys.
	meta : Ctx -> JsonValue
	meta = |c| c.meta

	progress_token : Ctx -> Try(JsonValue, [None])
	progress_token = |c| c.meta.get("progressToken").map_err(|_| None)

	input : Ctx, Str -> Input.Answer
	input = |c, key| match c.inputs.find_first(|(k, _)| k == key) {
		Ok((_, a)) => a
		Err(_) => NotAsked
	}

	request_state : Ctx -> Try(Str, [None])
	request_state = |c| c.request_state

	session_id : Ctx -> Try(Str, [None])
	session_id = |c| c.session_id

	auth : Ctx -> Try(Ctx.AuthInfo, [None])
	auth = |c| c.auth

	## notifications/message, dropped below the client's level or when logging is not enabled.
	log! : Ctx, LogLevel, JsonValue => {}
	log! = |_c, _level, _data| crash "unimplemented"

	## notifications/progress, sent only when the request carried a progress token.
	progress! : Ctx, { progress : Dec, total : Try(Dec, [None]), message : Try(Str, [None]) } => {}
	progress! = |_c, _p| crash "unimplemented"

	## notifications/{tools,resources,prompts}/list_changed.
	list_changed! : Ctx, [Tools, Resources, Prompts] => {}
	list_changed! = |_c, _which| crash "unimplemented"

	## notifications/resources/updated.
	resource_updated! : Ctx, Str => {}
	resource_updated! = |_c, _uri| crash "unimplemented"

	## Any other notification, tied to this request.
	notify! : Ctx, Str, JsonValue => {}
	notify! = |c, notification, params| {
		msg : JsonValue
		msg = Object([("jsonrpc", String("2.0")), ("method", String(notification)), ("params", params)])
		(c.send!)(msg.to_str())
	}

	## For transports: attach the writer. Handlers never call this.
	with_sender : Ctx, (Str => {}) -> Ctx
	with_sender = |c, send!| { ..c, send! }
}
