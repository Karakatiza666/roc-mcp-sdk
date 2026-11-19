import ../JsonValue
import ../McpError
import ../Input
import ../LogLevel
import Wire

## The 2026-07-28 wire rules: the per-request `_meta` envelope, era selection of the first
## message, the result encoding (`resultType`, `ttlMs`/`cacheScope`, serverInfo in `_meta`),
## `input_required` results and `subscriptions/listen` (stdio). Messages and key orders are the
## ones the JS SDK 2.0.0 writes (DESIGN 5 and 7).
Modern :: [].{

	## The reserved `_meta` keys of the request envelope.
	version_key : Str
	version_key = "io.modelcontextprotocol/protocolVersion"

	caps_key : Str
	caps_key = "io.modelcontextprotocol/clientCapabilities"

	info_key : Str
	info_key = "io.modelcontextprotocol/clientInfo"

	level_key : Str
	level_key = "io.modelcontextprotocol/logLevel"

	## The `_meta` key every result carries (the server's identity).
	server_info_key : Str
	server_info_key = "io.modelcontextprotocol/serverInfo"

	## The `_meta` key of the notifications a subscription delivers.
	subscription_key : Str
	subscription_key = "io.modelcontextprotocol/subscriptionId"

	## At most this many `subscriptions/listen` subscriptions per connection (JS default).
	max_subscriptions : U64
	max_subscriptions = 1024

	## What the first message of a connection selects.
	Opening : [Legacy, Modern(Str), InvalidEnvelope({ key : Str, problem : Str }), Unsupported(Str)]

	## The opening rules of a stdio connection (JS `serveStdio`): `initialize` without a valid
	## modern claim, or a message without the protocol-version key in `params._meta`, is 2025
	## traffic. A claim is validated, and its version must be one of `versions`.
	opening : Str, JsonValue, List(Str) -> Modern.Opening
	opening = |method, params, versions|
		if method == "initialize" and !(valid_claim(params)) {
			Legacy
		} else if !(has_claim(params)) {
			Legacy
		} else {
			match envelope_issues(params.get_or_null("_meta")).first() {
				Ok(issue) => InvalidEnvelope(issue)
				Err(_) => {
					v = params.get_or_null("_meta").get_or_null(version_key).as_str() ?? ""
					if (versions.contains(v)) Modern(v) else Unsupported(v)
				}
			}
		}

	## True when `params._meta` is an object with the protocol-version key.
	has_claim : JsonValue -> Bool
	has_claim = |params| match params.get_or_null("_meta") {
		Object(fs) => fs.any(|(k, _)| k == version_key)
		_ => Bool.False
	}

	## A claim with a valid envelope that names a 2026-07-28-or-later revision.
	valid_claim : JsonValue -> Bool
	valid_claim = |params|
		if has_claim(params) {
			meta = params.get_or_null("_meta")
			match meta.get_or_null(version_key) {
				String(v) => is_modern_version(v) and envelope_issues(meta).is_empty()
				_ => Bool.False
			}
		} else {
			Bool.False
		}

	## Revision identifiers are ISO dates: the modern era starts at 2026-07-28.
	is_modern_version : Str -> Bool
	is_modern_version = |v| !(bytes_before(v.to_utf8(), "2026-07-28".to_utf8()))

	## The problems of a request `_meta` envelope, missing keys first (as JS reports them in
	## `data.envelope` of the first message's -32602).
	envelope_issues : JsonValue -> List({ key : Str, problem : Str })
	envelope_issues = |meta| {
		missing = [version_key, caps_key].keep_if(|k| meta.get(k).is_err())
		shape = schema_issues(meta, Bool.True).drop_if(|i| missing.contains(i.key))
		missing.map(|k| { key: k, problem: "missing" }).concat(shape)
	}

	## The envelope check of every later request: `Ok` or the -32602 message.
	envelope_error : JsonValue -> Try({}, Str)
	envelope_error = |params| {
		meta = params.get_or_null("_meta")
		reserved = [version_key, info_key, caps_key, level_key].keep_if(|k| meta.get(k).is_ok())
		if reserved.is_empty() {
			Err("Request is missing the required _meta envelope for protocol revision 2026-07-28 (${version_key}, ${caps_key})")
		} else {
			match schema_issues(meta, Bool.False) {
				[] => Ok({})
				issues => Err("Invalid _meta envelope for protocol revision 2026-07-28: ${Str.join_with(issues.map(|i| i.problem), "; ")}")
			}
		}
	}

	## The -32022 for a 2025 request a modern-only connection (or a modern session) refuses.
	legacy_rejection : Str, JsonValue, List(Str) -> McpError
	legacy_rejection = |method, params, supported| {
		requested = if (method == "initialize") params.get_or_null("protocolVersion").as_str() else Err(NotAString)
		match requested {
			Ok(v) => McpError.unsupported_version(supported, v)
			Err(_) =>
				McpError.new(-32022, "Unsupported protocol version: the request did not name a protocol version")
					.with_data(Object([("supported", Array(supported.map(|v| String(v))))]))
		}
	}

	## The envelope of a request: the client's declared capabilities and info, the log level it
	## opted in to, and `_meta` without the reserved keys (`Null` when nothing is left).
	envelope : JsonValue -> { version : Str, capabilities : JsonValue, info : JsonValue, log_level : Try(LogLevel, [None]), meta : JsonValue }
	envelope = |params| {
		m = params.get_or_null("_meta")
		caps = match m.get_or_null(caps_key) {
			Object(fs) => Object(fs)
			_ => Object([])
		}
		rest = Wire.fields(m).drop_if(|(k, _)| k == version_key or k == caps_key or k == info_key or k == level_key)
		{
			version: m.get_or_null(version_key).as_str() ?? "",
			capabilities: caps,
			info: m.get_or_null(info_key),
			log_level: match m.get_or_null(level_key) {
				String(l) => LogLevel.from_str(l).map_err(|_| None)
				_ => Err(None)
			},
			meta: if (rest.is_empty()) Null else Object(rest),
		}
	}

	## Spec request methods of the 2025 revisions that 2026-07-28 removed: -32601.
	removed_request : Str -> Bool
	removed_request = |m|
		[
			"ping",
			"initialize",
			"logging/setLevel",
			"resources/subscribe",
			"resources/unsubscribe",
			"tasks/get",
			"tasks/result",
			"tasks/list",
			"tasks/cancel",
			"sampling/createMessage",
			"elicitation/create",
			"roots/list",
		].contains(m)

	## Spec notifications of the 2025 revisions that 2026-07-28 removed: ignored.
	removed_notification : Str -> Bool
	removed_notification = |m| ["notifications/initialized", "notifications/roots/list_changed", "notifications/tasks/status", "notifications/elicitation/complete"].contains(m)

	## The methods whose results carry `ttlMs` and `cacheScope`.
	cacheable : Str -> Bool
	cacheable = |m| ["tools/list", "prompts/list", "resources/list", "resources/templates/list", "resources/read", "server/discover"].contains(m)

	## The methods that may answer `input_required`.
	input_methods : List(Str)
	input_methods = ["tools/call", "prompts/get", "resources/read"]

	## A result as the 2026-07-28 wire carries it: `resultType` (default "complete"), then
	## `ttlMs`/`cacheScope` on cacheable results (the hint, else 0 and "private"), then
	## `_meta[serverInfo]`. A handler's `resultType` other than "complete" is kept only on
	## the methods that may answer `input_required`. A `tasks` capability is removed.
	encode_result : Str, JsonValue, List((Str, JsonValue)), Try({ ttl_ms : U64, scope : [Public, Private] }, [None]) -> Try(JsonValue, McpError)
	encode_result = |method, result, info, hint| match result {
		Object(fs0) => {
			fs = match result.get("capabilities") {
				Ok(Object(cs)) if cs.any(|(k, _)| k == "tasks") => Wire.put(fs0, "capabilities", Object(cs.drop_if(|(k, _)| k == "tasks")))
				_ => fs0
			}
			stamped = match result.get("resultType") {
				Err(_) => Ok(fs.append(("resultType", String("complete"))))
				Ok(String("complete")) => Ok(fs)
				Ok(_) =>
					if input_methods.contains(method) {
						Ok(fs)
					} else {
						# JS: the encoder throws "Handler for <method> returned resultType '<shown>', but
						# results of <method> only support 'complete' ...", logs it, and answers this.
						Err(McpError.internal("Internal error"))
					}
			}
			match stamped {
				Err(e) => Err(e)
				Ok(s) => {
					obj : JsonValue
					obj = Object(s)
					complete = obj.get("resultType") == Ok(String("complete"))
					cached =
						if complete and cacheable(method) {
							(ttl, scope) = match hint {
								Ok(h) => (h.ttl_ms, if (h.scope == Public) "public" else "private")
								Err(None) => (0, "private")
							}
							ttl_ok = match obj.get("ttlMs") {
								Ok(t) => t.to_u64().is_ok()
								Err(_) => Bool.False
							}
							scope_ok = match obj.get("cacheScope") {
								Ok(String("public")) | Ok(String("private")) => Bool.True
								_ => Bool.False
							}
							with_ttl = if (ttl_ok) s else Wire.put(s, "ttlMs", JsonValue.from_u64(ttl))
							if (scope_ok) with_ttl else Wire.put(with_ttl, "cacheScope", String(scope))
						} else {
							s
						}
					Ok(Object(stamp_server_info(cached, info)))
				}
			}
		}
		_ => Ok(result)
	}

	## The `server/discover` result (before `encode_result`).
	discover_result : List(Str), JsonValue, Try(Str, [None]) -> JsonValue
	discover_result = |versions, caps, instructions| {
		extra = match instructions {
			Ok(t) => [("instructions", String(t))]
			Err(None) => []
		}
		Object([("supportedVersions", Array(versions.map(|v| String(v)))), ("capabilities", caps)].concat(extra))
	}

	## `params.inputResponses` as answers. Only bare result objects are answers: an entry that is
	## not an object, or that wraps `method`/`result`, is dropped (JS), so its key reads `NotAsked`.
	input_responses : JsonValue -> List((Str, Input.Answer))
	input_responses = |params| match params.get_or_null("inputResponses") {
		Object(fs) =>
			fs.keep_oks(
				|(k, v)| match v {
					Object(entry) if !(entry.any(|(n, _)| n == "method" or n == "result")) => Ok((k, Answered(v)))
					_ => Err(Dropped)
				},
			)
		_ => []
	}

	## A handler's `NeedInput` as the 2026-07-28 result `{resultType: "input_required",
	## inputRequests?, requestState?}`. Each request must be covered by the request envelope's
	## client capabilities (-32021 with `requiredCapabilities`, the missing ones).
	input_required : Str, Input.Required, JsonValue -> Try(JsonValue, McpError)
	input_required = |method, req, caps| {
		requests = req.requests()
		if !(input_methods.contains(method)) {
			Err(McpError.internal("Handler for ${method} returned an input-required result, but only tools/call, prompts/get and resources/read support input_required (protocol revision 2026-07-28)"))
		} else if requests.is_empty() and req.request_state().is_err() {
			Err(McpError.internal("Handler for ${method} returned an input-required result with neither inputRequests nor requestState (every InputRequiredResult must include at least one of the two)"))
		} else {
			missing = requests.keep_oks(
				|(key, r)| match missing_capabilities(caps, r) {
					Ok(m) => Ok((key, r, m))
					Err(None) => Err(None)
				},
			)
			match missing.first() {
				Ok((key, r, m)) =>
					Err(
						McpError.new(-32021, "Cannot request input '${key}' (${r.method()}): the request's client capabilities do not declare the required capability")
							.with_data(Object([("requiredCapabilities", m)])),
					)
				Err(_) => {
					reqs = if (requests.is_empty()) [] else [("inputRequests", Object(requests.map(|(k, r)| (k, r.to_json()))))]
					st = match req.request_state() {
						Ok(s) => [("requestState", String(s))]
						Err(None) => []
					}
					Ok(Object([("resultType", String("input_required"))].concat(reqs).concat(st)))
				}
			}
		}
	}

	## The capabilities an input request needs that `caps` lacks, in the `ClientCapabilities`
	## shape; `Err(None)` when all are declared. A bare `elicitation: {}` declares form mode.
	missing_capabilities : JsonValue, Input.Request -> Try(JsonValue, [None])
	missing_capabilities = |caps, req| {
		(top, member) = match req {
			ListRoots => ("roots", Err(None))
			ElicitForm(_) => ("elicitation", Ok("form"))
			ElicitUrl(_) => ("elicitation", Ok("url"))
			CreateMessage(p) => ("sampling", if (p.get("tools").is_ok() or p.get("toolChoice").is_ok()) Ok("tools") else Err(None))
		}
		required = match member {
			Ok(m) => Object([(m, Object([]))])
			Err(None) => Object([])
		}
		match caps.get(top) {
			Err(_) => Ok(Object([(top, required)]))
			Ok(declared) =>
				match (member, declared) {
					(Ok(m), Object(fs)) => {
						implied = m == "form" and !(fs.any(|(k, _)| k == "form" or k == "url"))
						if (fs.any(|(k, _)| k == m) or implied) Err(None) else Ok(Object([(top, required)]))
					}
					_ => Err(None)
				}
		}
	}

	## A tools/call result on the 2026-07-28 wire: as the 2025 projection (the output-schema
	## check, the text block for a non-object `structuredContent`), but nothing is wrapped.
	tool_result : Str, Try(JsonValue, [None]), JsonValue -> JsonValue
	tool_result = |tool_name, output_schema, result| {
		is_error = result.get("isError") == Ok(Bool(Bool.True))
		match (output_schema, result.get("structuredContent")) {
			(Ok(_), Err(_)) if !is_error =>
				Object([
					("content", Array([Object([("type", String("text")), ("text", String("Output validation error: Tool ${tool_name} has an output schema but no structured content was provided"))])])),
					("isError", Bool(Bool.True)),
				])
			(_, Ok(Object(_))) | (_, Err(_)) => result
			(_, Ok(sc)) => {
				blocks = match result.get("content") {
					Ok(Array(bs)) => bs
					_ => []
				}
				if blocks.any(|b| b.get("type") == Ok(String("text"))) {
					result
				} else {
					Object(Wire.put(Wire.fields(result), "content", Array(blocks.append(Object([("type", String("text")), ("text", String(sc.to_str()))])))))
				}
			}
		}
	}

	## Serves one `subscriptions/listen` request: the new subscription and the stamped
	## `notifications/subscriptions/acknowledged` line, or the error line. The honoured filter
	## keeps the kinds the client asked for that the server's capabilities can deliver.
	listen : JsonValue, JsonValue, { capabilities : JsonValue, versions : List(Str), info : List((Str, JsonValue)), open : U64 } -> [Subscribed(JsonValue, Str), Refused(Str)]
	listen = |id, params, srv| {
		refuse = |e| Refused(Wire.error_line(id, e))
		meta = params.get_or_null("_meta")
		issue =
			if has_claim(params) {
				envelope_issues(meta).first()
			} else {
				Ok({ key: "_meta", problem: "the per-request envelope is required on protocol revision 2026-07-28" })
			}
		version = meta.get_or_null(version_key).as_str() ?? "unknown"
		match issue {
			Ok(i) => refuse(McpError.invalid_params("Invalid _meta envelope: ${i.key}: ${i.problem}"))
			Err(_) =>
				if !(srv.versions.contains(version)) {
					refuse(McpError.unsupported_version(srv.versions, version))
				} else if srv.open >= max_subscriptions {
					refuse(McpError.internal("Subscription limit reached"))
				} else {
					match filter(params.get_or_null("notifications")) {
						Err(_) => refuse(McpError.invalid_params("Invalid params: 'notifications' is required and must be a valid SubscriptionFilter"))
						Ok(f) => {
							honoured = honour(f, srv.capabilities)
							ack = notification_line("notifications/subscriptions/acknowledged", Object([("notifications", honoured)]), id)
							Subscribed(Object([("id", id), ("notifications", honoured), ("serverInfo", Object(srv.info))]), ack)
						}
					}
				}
		}
	}

	## The lines one outgoing notification becomes on a modern connection: the four change
	## notifications go to each subscription that asked for them, stamped with its id (none when
	## no subscription matches); any other notification goes out as is.
	route : List(JsonValue), Str, Try(JsonValue, [None]) -> [Passthrough, Lines(List(Str))]
	route = |subs, method, params| {
		uri = match params {
			Ok(p) => p.get_or_null("uri").as_str() ?? ""
			Err(None) => ""
		}
		wants = |f| match method {
			"notifications/tools/list_changed" => f.get("toolsListChanged") == Ok(Bool(Bool.True))
			"notifications/prompts/list_changed" => f.get("promptsListChanged") == Ok(Bool(Bool.True))
			"notifications/resources/list_changed" => f.get("resourcesListChanged") == Ok(Bool(Bool.True))
			_ =>
				match f.get("resourceSubscriptions") {
					Ok(Array(us)) => us.contains(String(uri))
					_ => Bool.False
				}
		}
		if ["notifications/tools/list_changed", "notifications/prompts/list_changed", "notifications/resources/list_changed", "notifications/resources/updated"].contains(method) {
			body = match params {
				Ok(p) => p
				Err(None) => Object([])
			}
			Lines(subs.keep_if(|s| wants(s.get_or_null("notifications"))).map(|s| notification_line(method, body, s.get_or_null("id"))))
		} else {
			Passthrough
		}
	}

	## The final `subscriptions/listen` results, one per open subscription (graceful close).
	final_results : List(JsonValue) -> List(Str)
	final_results = |subs|
		subs.map(
			|s| {
				id = s.get_or_null("id")
				info = match s.get_or_null("serverInfo") {
					Object(fs) => [(server_info_key, Object(fs))]
					_ => []
				}
				line : JsonValue
				line = Object([("jsonrpc", String("2.0")), ("id", id), ("result", Object([("resultType", String("complete")), ("_meta", Object([(subscription_key, id)].concat(info)))]))])
				line.to_str()
			},
		)
}

## `_meta[serverInfo]` added unless the result's `_meta` has it (or is not an object).
stamp_server_info : List((Str, JsonValue)), List((Str, JsonValue)) -> List((Str, JsonValue))
stamp_server_info = |fs, info| match fs.find_first(|(k, _)| k == "_meta") {
	Err(_) => fs.append(("_meta", Object([(Modern.server_info_key, Object(info))])))
	Ok((_, Object(m))) =>
		if m.any(|(k, _)| k == Modern.server_info_key) {
			fs
		} else {
			Wire.put(fs, "_meta", Object(m.append((Modern.server_info_key, Object(info)))))
		}
	Ok(_) => fs
}

## A notification line with `params._meta[subscriptionId]`.
notification_line : Str, JsonValue, JsonValue -> Str
notification_line = |method, params, sub_id| {
	fs = Wire.fields(params)
	meta = match fs.find_first(|(k, _)| k == "_meta") {
		Ok((_, Object(m))) => m
		_ => []
	}
	Wire.notification_line(method, Ok(Object(Wire.put(fs, "_meta", Object(Wire.put(meta, Modern.subscription_key, sub_id))))))
}

## A `SubscriptionFilter`: an object whose known members have the right types.
filter : JsonValue -> Try(JsonValue, [BadFilter])
filter = |f| match f {
	Object(fs) => {
		flags_ok = ["toolsListChanged", "promptsListChanged", "resourcesListChanged"].all(
			|k| match f.get(k) {
				Ok(Bool(_)) | Err(_) => Bool.True
				_ => Bool.False
			},
		)
		subs_ok = match f.get("resourceSubscriptions") {
			Err(_) => Bool.True
			Ok(Array(us)) => us.all(|u| u.as_str().is_ok())
			_ => Bool.False
		}
		if (flags_ok and subs_ok) Ok(Object(fs)) else Err(BadFilter)
	}
	_ => Err(BadFilter)
}

## The part of a filter the server honours: `true` flags whose `listChanged` capability is
## advertised, and a non-empty `resourceSubscriptions` when `resources.subscribe` is.
honour : JsonValue, JsonValue -> JsonValue
honour = |f, caps| {
	on = |k| f.get(k) == Ok(Bool(Bool.True))
	cap = |kind, bit| caps.get_or_null(kind).get_or_null(bit) == Bool(Bool.True)
	flag = |k, kind| if (on(k) and cap(kind, "listChanged")) [(k, Bool(Bool.True))] else []
	uris = match f.get("resourceSubscriptions") {
		Ok(Array(us)) if !(us.is_empty()) and cap("resources", "subscribe") => [("resourceSubscriptions", Array(us))]
		_ => []
	}
	Object(flag("toolsListChanged", "tools").concat(flag("promptsListChanged", "prompts")).concat(flag("resourcesListChanged", "resources")).concat(uris))
}

## The issues the JS envelope schema (zod) reports, in its key order. `with_token` also checks
## `progressToken` (the first message's check sees the whole `_meta`; later checks see only the
## reserved keys).
schema_issues : JsonValue, Bool -> List({ key : Str, problem : Str })
schema_issues = |meta, with_token| match meta {
	Object(_) => {
		token = match meta.get("progressToken") {
			Ok(String(_)) | Ok(Number(_)) | Err(_) => []
			Ok(_) => if (with_token) [{ key: "progressToken", problem: "Invalid input" }] else []
		}
		version = expect_type(Modern.version_key, meta.get(Modern.version_key), "string")
		info = match meta.get(Modern.info_key) {
			Err(_) => []
			Ok(Object(_)) =>
				["name", "version"].join_map(|k| expect_type("${Modern.info_key}.${k}", meta.get_or_null(Modern.info_key).get(k), "string"))
			Ok(v) => expect_type(Modern.info_key, Ok(v), "object")
		}
		caps = match meta.get(Modern.caps_key) {
			Ok(Object(_)) =>
				["roots", "sampling", "elicitation"].join_map(
					|k| match meta.get_or_null(Modern.caps_key).get(k) {
						Ok(Object(_)) | Err(_) => []
						Ok(v) => {
							first = { key: "${Modern.caps_key}.${k}", problem: "Invalid input: expected object, received ${type_name(Ok(v))}" }
							if (k == "elicitation") [first, { ..first, problem: "Invalid input: expected record, received ${type_name(Ok(v))}" }] else [first]
						}
					},
				)
			other => expect_type(Modern.caps_key, other, "object")
		}
		level = match meta.get(Modern.level_key) {
			Err(_) => []
			Ok(String(l)) if LogLevel.from_str(l).is_ok() => []
			Ok(_) => {
				names = Str.join_with(LogLevel.all.map(|l| "\"${l.to_str()}\""), "|")
				[{ key: Modern.level_key, problem: "Invalid option: expected one of ${names}" }]
			}
		}
		token.concat(version).concat(info).concat(caps).concat(level)
	}
	_ => [{ key: "_meta", problem: "Invalid input: expected object, received ${type_name(Ok(meta))}" }]
}

expect_type : Str, Try(JsonValue, [NotFound]), Str -> List({ key : Str, problem : Str })
expect_type = |key, value, want|
	if type_name(value) == want {
		[]
	} else {
		[{ key, problem: "Invalid input: expected ${want}, received ${type_name(value)}" }]
	}

## The JS name of a value's type, as zod reports it.
type_name : Try(JsonValue, [NotFound]) -> Str
type_name = |v| match v {
	Err(_) => "undefined"
	Ok(Null) => "null"
	Ok(Bool(_)) => "boolean"
	Ok(Number(_)) => "number"
	Ok(String(_)) => "string"
	Ok(Array(_)) => "array"
	Ok(Object(_)) => "object"
}

## `a < b`, comparing bytes.
bytes_before : List(U8), List(U8) -> Bool
bytes_before = |a, b| match (a, b) {
	(_, []) => Bool.False
	([], _) => Bool.True
	([x, .. as xs], [y, .. as ys]) => if (x == y) bytes_before(xs, ys) else x < y
}
