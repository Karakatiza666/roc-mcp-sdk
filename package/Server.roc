import JsonValue
import McpError
import Content
import Tool
import Resource
import ResourceContents
import ResourceTemplate
import ToolResult
import Prompt
import UriTemplate
import Outcome
import Ctx
import Internal/Wire

## A server definition, generic over the app's state. Pure: building it runs nothing.
##
## Mistakes in a definition crash when the server is built, which for a top-level constant is at
## compile time: a duplicate tool, resource, template or prompt; `tool_enabled_when`,
## `template_list`, `template_complete` or `prompt_complete` naming nothing registered; and
## `on_request` for a method the SDK serves itself.
Server(state) :: {
	info : List((Str, JsonValue)),
	instructions : Try(Str, [None]),
	logging : Bool,
	cap_order : List(Str),
	extra_capabilities : List((Str, JsonValue)),
	page_size : Try(U64, [None]),
	tools : List(Server.ToolEntry(state)),
	around_tools : List(Server.Middleware(state)),
	resources : List(Server.ResourceEntry(state)),
	templates : List(Server.TemplateEntry(state)),
	prompts : List(Server.PromptEntry(state)),
	notification_handlers : List((Str, (state, Ctx, JsonValue => state))),
	request_handlers : List((Str, (state, Ctx, JsonValue => (state, Outcome(JsonValue))))),
	subscribe : Try(Server.Subscribe(state), [NotSupported]),
	cache_hints : List((Str, { ttl_ms : U64, scope : [Public, Private] })),
	verify_request_state : Try((Ctx, Str -> Bool), [None]),
	versions : { legacy : List(Str), modern : List(Str) },
	input_failures : [ToHandler, FailRequest],
	input_validation : Bool,
	round_state : [Discard, Keep],
}.{

	## `completion/complete` callback: the partial value and the other arguments, to candidates.
	Completer(state) : state, Ctx, Str, Server.CompletionContext => (state, List(Str))

	CompletionContext : { arguments : List((Str, Str)) }

	## A tools/call middleware: gets the tool name and the call to run.
	Middleware(state) : state, Ctx, Str, (state => (state, Outcome(ToolResult))) => (state, Outcome(ToolResult))

	## A registered tool. `prepare` decodes the arguments; `Err` is the validation message.
	## `validate`: check the arguments against the input schema first (`tool_input_validation`).
	ToolEntry(state) : {
		tool : Tool,
		enabled : state -> Bool,
		prepare : JsonValue -> Try((state, Ctx => (state, Outcome(ToolResult))), Str),
		validate : Bool,
	}

	ResourceEntry(state) : {
		resource : Resource,
		enabled : state -> Bool,
		read! : state, Ctx, Str => (state, Outcome(List(ResourceContents))),
	}

	TemplateEntry(state) : {
		template : ResourceTemplate,
		read! : state, Ctx, Str, UriTemplate.Vars => (state, Outcome(List(ResourceContents))),
		list! : Try((state, Ctx => (state, List(Resource))), [NoList]),
		complete : List((Str, Server.Completer(state))),
	}

	PromptEntry(state) : {
		prompt : Prompt,
		enabled : state -> Bool,
		prepare : JsonValue -> Try((state, Ctx => (state, Outcome(Prompt.Result))), Str),
		complete : List((Str, Server.Completer(state))),
	}

	Subscribe(state) : {
		subscribe! : state, Ctx, Str => (state, Try({}, McpError)),
		unsubscribe! : state, Ctx, Str => (state, Try({}, McpError)),
	}

	## Everything the engine reads. Apps do not need it.
	Parts(state) : {
		info : List((Str, JsonValue)),
		instructions : Try(Str, [None]),
		logging : Bool,
		page_size : Try(U64, [None]),
		tools : List(Server.ToolEntry(state)),
		around_tools : List(Server.Middleware(state)),
		resources : List(Server.ResourceEntry(state)),
		templates : List(Server.TemplateEntry(state)),
		prompts : List(Server.PromptEntry(state)),
		notification_handlers : List((Str, (state, Ctx, JsonValue => state))),
		request_handlers : List((Str, (state, Ctx, JsonValue => (state, Outcome(JsonValue))))),
		subscribe : Try(Server.Subscribe(state), [NotSupported]),
		cache_hints : List((Str, { ttl_ms : U64, scope : [Public, Private] })),
		verify_request_state : Try((Ctx, Str -> Bool), [None]),
		versions : { legacy : List(Str), modern : List(Str) },
		input_failures : [ToHandler, FailRequest],
		input_validation : Bool,
		round_state : [Discard, Keep],
	}

	new : { name : Str, version : Str } -> Server(state)
	new = |i| {
		info: [("name", String(i.name)), ("version", String(i.version))],
		instructions: Err(None),
		logging: Bool.False,
		cap_order: [],
		extra_capabilities: [],
		page_size: Err(None),
		tools: [],
		around_tools: [],
		resources: [],
		templates: [],
		prompts: [],
		notification_handlers: [],
		request_handlers: [],
		subscribe: Err(NotSupported),
		cache_hints: [],
		verify_request_state: Err(None),
		versions: { legacy: ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05", "2024-10-07"], modern: ["2026-07-28"] },
		input_failures: ToHandler,
		input_validation: Bool.True,
		round_state: Discard,
	}

	## serverInfo.title / description / websiteUrl. serverInfo keeps the order of these calls.
	with_title : Server(state), Str -> Server(state)
	with_title = |s, v| { ..s, info: Wire.put(s.info, "title", String(v)) }

	with_description : Server(state), Str -> Server(state)
	with_description = |s, v| { ..s, info: Wire.put(s.info, "description", String(v)) }

	with_website_url : Server(state), Str -> Server(state)
	with_website_url = |s, v| { ..s, info: Wire.put(s.info, "websiteUrl", String(v)) }

	## Adds an icon to serverInfo.icons.
	with_icon : Server(state), Content.Icon -> Server(state)
	with_icon = |s, icon| {
		icons = match s.info.find_first(|(k, _)| k == "icons") {
			Ok((_, Array(xs))) => xs
			_ => []
		}
		{ ..s, info: Wire.put(s.info, "icons", Array(icons.append(Content.icon_to_json(icon)))) }
	}

	with_instructions : Server(state), Str -> Server(state)
	with_instructions = |s, v| { ..s, instructions: Ok(v) }

	## Declares the `logging` capability and serves logging/setLevel.
	with_logging : Server(state) -> Server(state)
	with_logging = |s| { ..note(s, "logging"), logging: Bool.True }

	## Adds a capability (`experimental`, `extensions`, ...). When the SDK also derives that
	## capability, the two objects are merged and the given keys win.
	with_capability : Server(state), Str, JsonValue -> Server(state)
	with_capability = |s, k, v| { ..note(s, k), extra_capabilities: s.extra_capabilities.append((k, v)) }

	## Paginate tools/list, resources/list, resources/templates/list and prompts/list. Off by default (JS parity).
	with_page_size : Server(state), U64 -> Server(state)
	with_page_size = |s, n| { ..s, page_size: Ok(n) }

	## 2026-07-28 `ttlMs` / `cacheScope` for a cacheable method.
	with_cache_hint : Server(state), Str, { ttl_ms : U64, scope : [Public, Private] } -> Server(state)
	with_cache_hint = |s, m, h| { ..s, cache_hints: s.cache_hints.append((m, h)) }

	## Checks the `requestState` a client echoes back (2026-07-28) or a handler asked to keep
	## (2025 shim). A refused state is answered with -32602 "Invalid or expired requestState".
	with_request_state_verifier : Server(state), (Ctx, Str -> Bool) -> Server(state)
	with_request_state_verifier = |s, f| { ..s, verify_request_state: Ok(f) }

	## Which revisions to serve. An empty `legacy` list refuses 2025 clients (JS `legacy: 'reject'`).
	with_protocol_versions : Server(state), { legacy : List(Str), modern : List(Str) } -> Server(state)
	with_protocol_versions = |s, v| { ..s, versions: v }

	## What the 2025 input shim does when a client answers an input request with an error, or does
	## not answer in time. `ToHandler` (the default) calls the handler again, and `Ctx.input` gives
	## `Failed(err)` or `TimedOut`, so the handler can fall back. `FailRequest` is the JS behaviour:
	## the request ends with "Fulfilling input required by '<method>' failed: <message>" (an
	## `isError` result for tools/call, else -32603) and the other requests of the round are cancelled.
	with_input_failures : Server(state), [ToHandler, FailRequest] -> Server(state)
	with_input_failures = |s, mode| { ..s, input_failures: mode }

	## What happens to the state a handler returns together with `NeedInput` (both eras).
	## `Discard` (the default): it is dropped, and the next round (or the next message) starts
	## from the state before that run, so a call changes the app state once, in its final round,
	## as a JS handler that awaits its server-to-client requests does. `Keep`: it is kept (the
	## 0.1 rule; then a change made before asking is made again in every round). To carry
	## results from one round to the next, use `Input.Required.with_state` / `Ctx.request_state`.
	with_input_round_state : Server(state), [Discard, Keep] -> Server(state)
	with_input_round_state = |s, mode| { ..s, round_state: mode }

	## A tool whose arguments decode into the app's record type `args` (Encoding.Json).
	##
	## The arguments are first checked against the tool's input schema (`SchemaCheck`), as JS
	## checks them with the tool's zod schema: a failure is the `isError` result
	## "Input validation error: Invalid arguments for tool <name>: <zod's messages>", and the
	## handler gets the checked value (unknown keys dropped, defaults filled in). A decode
	## failure after that (a schema looser than the record) is the same result with the
	## decoder's message.
	tool : Server(state), Tool, (state, Ctx, args => (state, Outcome(ToolResult))) -> Server(state)
		where [args.Json.Parseable(_)]
	tool = |s, def, handler!| {
		prepare = |raw| match Json.parse(raw.to_str()) {
			Ok(args) => Ok(|st, ctx| handler!(st, ctx, args))
			Err(e) => Err("Invalid arguments for tool ${def.name()}: ${decode_error(Str.inspect(e))}")
		}
		add_tool(s, { tool: def, enabled: |_| Bool.True, prepare, validate: Bool.True })
	}

	## A tool that takes its arguments as JSON (an object; `{}` when the client sent none),
	## checked against its input schema first, as for `tool`.
	tool_json : Server(state), Tool, (state, Ctx, JsonValue => (state, Outcome(ToolResult))) -> Server(state)
	tool_json = |s, def, handler!| {
		prepare = |raw| Ok(|st, ctx| handler!(st, ctx, raw))
		add_tool(s, { tool: def, enabled: |_| Bool.True, prepare, validate: Bool.True })
	}

	## Whether tools/call arguments and prompts/get arguments are checked against the input
	## schema (a tool's `with_input_schema`, a prompt's `with_argument` list) before the handler
	## runs. On by default (JS parity). See `SchemaCheck` for what is checked.
	with_input_validation : Server(state), Bool -> Server(state)
	with_input_validation = |s, on| { ..s, input_validation: on }

	## Turns the schema check off (or on again) for one tool, e.g. one whose JS original
	## preprocesses its arguments (`z.preprocess`), which no JSON Schema shows. Its handler then
	## gets the arguments as sent. Crashes when no tool has that name.
	tool_input_validation : Server(state), Str, Bool -> Server(state)
	tool_input_validation = |s, n, on|
		if s.tools.any(|t| t.tool.name() == n) {
			{ ..s, tools: s.tools.map(|t| if (t.tool.name() == n) { ..t, validate: on } else t) }
		} else {
			crash "Server.tool_input_validation: no tool named ${n}"
		}

	## Shows the named tool only while `pred(state)` holds (JS enable()/disable()). A call to a
	## hidden tool gets -32602 "Tool X disabled". A handler that changes the answer calls
	## `Ctx.list_changed!(ctx, Tools)`.
	tool_enabled_when : Server(state), Str, (state -> Bool) -> Server(state)
	tool_enabled_when = |s, n, pred|
		if s.tools.any(|t| t.tool.name() == n) {
			{ ..s, tools: s.tools.map(|t| if (t.tool.name() == n) { ..t, enabled: pred } else t) }
		} else {
			crash "Server.tool_enabled_when: no tool named ${n}"
		}

	## Middleware around every tools/call: gets the tool name and the call to run.
	## The first one registered is the outermost.
	##
	## It runs once per handler run, so a call that asks for input (`NeedInput`) passes through
	## it once per round: the outcome is `NeedInput` in every round but the last, and `Done` (or
	## `Fail`) in the last. A call refused before its handler (unknown tool, invalid arguments)
	## does not reach it. To change only the final result, use `map_tool_results`.
	around_tools : Server(state), (state, Ctx, Str, (state => (state, Outcome(ToolResult))) => (state, Outcome(ToolResult))) -> Server(state)
	around_tools = |s, mw!| { ..s, around_tools: s.around_tools.append(mw!) }

	## Changes the final result of every tools/call: runs only on a `Done` outcome (the last
	## round of a call that asked for input), with the tool name. A JS wrapper around each tool
	## callback, such as roc-syntax-mcp's note appended to the last text block, maps to this.
	## It is an `around_tools` middleware, in registration order with the others.
	map_tool_results : Server(state), (state, Ctx, Str, ToolResult => (state, ToolResult)) -> Server(state)
	map_tool_results = |s, f!|
		Server.around_tools(
			s,
			|st, ctx, n, next!| {
				(st1, out) = next!(st)
				match out {
					Done(result) => {
						(st2, mapped) = f!(st1, ctx, n, result)
						(st2, Outcome.done(mapped))
					}
					other => (st1, other)
				}
			},
		)

	## A static resource. Its URI must be unique.
	resource : Server(state), Resource, (state, Ctx, Str => (state, Outcome(List(ResourceContents)))) -> Server(state)
	resource = |s, r, read!|
		if s.resources.any(|e| e.resource.uri() == r.uri()) {
			crash "Server.resource: ${r.uri()} is already registered"
		} else {
			{ ..note(s, "resources"), resources: s.resources.append({ resource: r, enabled: |_| Bool.True, read! }) }
		}

	## A resource template. Its name must be unique. Templates are matched in registration order.
	resource_template : Server(state), ResourceTemplate, (state, Ctx, Str, UriTemplate.Vars => (state, Outcome(List(ResourceContents)))) -> Server(state)
	resource_template = |s, t, read!|
		if s.templates.any(|e| e.template.name() == t.name()) {
			crash "Server.resource_template: ${t.name()} is already registered"
		} else {
			{ ..note(s, "resources"), templates: s.templates.append({ template: t, read!, list!: Err(NoList), complete: [] }) }
		}

	## The template's `list` callback: its concrete resources for resources/list.
	template_list : Server(state), Str, (state, Ctx => (state, List(Resource))) -> Server(state)
	template_list = |s, n, list!|
		if s.templates.any(|t| t.template.name() == n) {
			{ ..s, templates: s.templates.map(|t| if (t.template.name() == n) { ..t, list!: Ok(list!) } else t) }
		} else {
			crash "Server.template_list: no template named ${n}"
		}

	## A completer for one variable of a template.
	template_complete : Server(state), Str, Str, Server.Completer(state) -> Server(state)
	template_complete = |s, n, variable, c|
		if s.templates.any(|t| t.template.name() == n) {
			{ ..note(s, "completions"), templates: s.templates.map(|t| if (t.template.name() == n) { ..t, complete: t.complete.append((variable, c)) } else t) }
		} else {
			crash "Server.template_complete: no template named ${n}"
		}

	## A prompt whose arguments (a string map; `{}` when the client sent none) decode into `args`.
	## A decode failure is -32602 "Invalid arguments for prompt X: ...".
	prompt : Server(state), Prompt, (state, Ctx, args => (state, Outcome(Prompt.Result))) -> Server(state)
		where [args.Json.Parseable(_)]
	prompt = |s, def, handler!| {
		prepare = |raw| match Json.parse(raw.to_str()) {
			Ok(args) => Ok(|st, ctx| handler!(st, ctx, args))
			Err(e) => Err("Invalid arguments for prompt ${def.name()}: ${decode_error(Str.inspect(e))}")
		}
		if s.prompts.any(|p| p.prompt.name() == def.name()) {
			crash "Server.prompt: ${def.name()} is already registered"
		} else {
			{ ..note(s, "prompts"), prompts: s.prompts.append({ prompt: def, enabled: |_| Bool.True, prepare, complete: [] }) }
		}
	}

	## A completer for one argument of a prompt.
	prompt_complete : Server(state), Str, Str, Server.Completer(state) -> Server(state)
	prompt_complete = |s, n, arg, c|
		if s.prompts.any(|p| p.prompt.name() == n) {
			{ ..note(s, "completions"), prompts: s.prompts.map(|p| if (p.prompt.name() == n) { ..p, complete: p.complete.append((arg, c)) } else p) }
		} else {
			crash "Server.prompt_complete: no prompt named ${n}"
		}

	## Runs on a client notification such as notifications/roots/list_changed or notifications/initialized.
	on_notification : Server(state), Str, (state, Ctx, JsonValue => state) -> Server(state)
	on_notification = |s, method, h!| { ..s, notification_handlers: s.notification_handlers.append((method, h!)) }

	## A request method that the SDK does not define. Its result is sent as the handler returns it.
	on_request : Server(state), Str, (state, Ctx, JsonValue => (state, Outcome(JsonValue))) -> Server(state)
	on_request = |s, method, h!|
		if spec_methods.contains(method) {
			crash "Server.on_request: ${method} is served by the SDK and cannot be overridden"
		} else {
			{ ..s, request_handlers: s.request_handlers.append((method, h!)) }
		}

	## Declares `resources.subscribe` and serves resources/subscribe and resources/unsubscribe.
	on_subscribe : Server(state), (state, Ctx, Str => (state, Try({}, McpError))), (state, Ctx, Str => (state, Try({}, McpError))) -> Server(state)
	on_subscribe = |s, sub!, unsub!| { ..note(s, "resources"), subscribe: Ok({ subscribe!: sub!, unsubscribe!: unsub! }) }

	## Problems that are not errors (tool names outside ^[A-Za-z0-9._-]{1,128}$). `Stdio.serve!` logs them at start.
	warnings : Server(state) -> List(Str)
	warnings = |s| s.tools.keep_oks(|t| tool_name_problem(t.tool.name()))

	## The `capabilities` object initialize and server/discover return, in the order the kinds
	## were first registered (as JS builds it): `logging`, `tools`, `resources`, `completions`,
	## `prompts` and the ones added with `with_capability`.
	capabilities : Server(state) -> JsonValue
	capabilities = |s|
		Object(
			s.cap_order.map(
				|k| {
					derived = match k {
						"logging" => Ok(Object([]))
						"tools" => if (s.tools.is_empty()) Err(None) else Ok(Object([("listChanged", Bool(Bool.True))]))
						"resources" => {
							listed = if (s.resources.is_empty() and s.templates.is_empty()) [] else [("listChanged", Bool(Bool.True))]
							sub = if (s.subscribe.is_ok()) [("subscribe", Bool(Bool.True))] else []
							Ok(Object(listed.concat(sub)))
						}
						"completions" => Ok(Object([]))
						"prompts" => if (s.prompts.is_empty()) Err(None) else Ok(Object([("listChanged", Bool(Bool.True))]))
						_ => Err(None)
					}
					value = s.extra_capabilities.fold(
						derived,
						|acc, (ek, ev)|
							if ek != k {
								acc
							} else {
								match (acc, ev) {
									(Ok(Object(a)), Object(b)) => Ok(Object(Wire.spread(a, b)))
									_ => Ok(ev)
								}
							},
					)
					(k, value ?? Object([]))
				},
			),
		)

	## Everything the engine reads. Apps do not need it.
	parts : Server(state) -> Server.Parts(state)
	parts = |s| {
		info: s.info,
		instructions: s.instructions,
		logging: s.logging,
		page_size: s.page_size,
		tools: s.tools,
		around_tools: s.around_tools,
		resources: s.resources,
		templates: s.templates,
		prompts: s.prompts,
		notification_handlers: s.notification_handlers,
		request_handlers: s.request_handlers,
		subscribe: s.subscribe,
		cache_hints: s.cache_hints,
		verify_request_state: s.verify_request_state,
		versions: s.versions,
		input_failures: s.input_failures,
		input_validation: s.input_validation,
		round_state: s.round_state,
	}
}

## The methods the SDK serves itself (2025 and 2026-07-28).
spec_methods : List(Str)
spec_methods = [
	"initialize",
	"ping",
	"tools/list",
	"tools/call",
	"resources/list",
	"resources/templates/list",
	"resources/read",
	"resources/subscribe",
	"resources/unsubscribe",
	"prompts/list",
	"prompts/get",
	"completion/complete",
	"logging/setLevel",
	"server/discover",
	"subscriptions/listen",
]

note : Server(state), Str -> Server(state)
note = |s, k| if (s.cap_order.contains(k)) s else { ..s, cap_order: s.cap_order.append(k) }

add_tool : Server(state), Server.ToolEntry(state) -> Server(state)
add_tool = |s, entry|
	if s.tools.any(|t| t.tool.name() == entry.tool.name()) {
		crash "Server.tool: ${entry.tool.name()} is already registered"
	} else {
		{ ..note(s, "tools"), tools: s.tools.append(entry) }
	}

## `InvalidJson("Missing field: text")` → `Missing field: text`.
decode_error : Str -> Str
decode_error = |inspected|
	if inspected.starts_with("InvalidJson(\"") and inspected.ends_with("\")") {
		inspected.drop_prefix("InvalidJson(\"").drop_suffix("\")")
	} else {
		inspected
	}

## The warning for a tool name outside ^[A-Za-z0-9._-]{1,128}$, if any.
tool_name_problem : Str -> Try(Str, [Fine])
tool_name_problem = |n| {
	bytes = n.to_utf8()
	allowed = |c| (c >= 'A' and c <= 'Z') or (c >= 'a' and c <= 'z') or (c >= '0' and c <= '9') or c == '_' or c == '-' or c == '.'
	bad = bytes.keep_if(|c| c < 128 and !(allowed(c))).fold([], |acc, c| if (acc.contains(c)) acc else acc.append(c))
	bad_chars = bad.map(|c| "\"${Str.from_utf8_lossy([c])}\"").concat(if (bytes.any(|c| c >= 128)) ["non-ASCII characters"] else [])
	problems =
		(if (bytes.is_empty()) ["it is empty"] else [])
			.concat(if (bytes.len() > 128) ["it is longer than 128 characters"] else [])
			.concat(
				if bad_chars.is_empty() {
					[]
				} else {
					[
						"it contains ${Str.join_with(bad_chars, ", ")}, but only A-Z, a-z, 0-9, _, - and . are allowed",
					]
				},
			)
	if problems.is_empty() {
		Err(Fine)
	} else {
		Ok("Tool name \"${n}\" does not follow the MCP naming rule: ${Str.join_with(problems, "; ")}. The tool is registered anyway, but some clients may refuse it.")
	}
}

expect tool_name_problem("get_roc_syntax") == Err(Fine)
expect tool_name_problem("bad name!").is_ok()
