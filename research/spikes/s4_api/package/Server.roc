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

## A server definition, generic over the app's state. Pure: building it runs nothing.
Server(state) :: {
	info : List((Str, JsonValue)),
	instructions : Try(Str, [None]),
	logging : Bool,
	extra_capabilities : List((Str, JsonValue)),
	page_size : Try(U64, [None]),
	tools : List(
		{
			tool : Tool,
			enabled : state -> Bool,
			prepare : JsonValue -> Try((state, Ctx => (state, Outcome(ToolResult))), Str),
		},
	),
	around_tools : List((state, Ctx, Str, (state => (state, Outcome(ToolResult))) => (state, Outcome(ToolResult)))),
	resources : List({ resource : Resource, enabled : state -> Bool, read! : state, Ctx, Str => (state, Outcome(List(ResourceContents))) }),
	templates : List(
		{
			template : ResourceTemplate,
			read! : state, Ctx, Str, UriTemplate.Vars => (state, Outcome(List(ResourceContents))),
			list! : Try((state, Ctx => (state, List(Resource))), [NoList]),
			complete : List((Str, Server.Completer(state))),
		},
	),
	prompts : List(
		{
			prompt : Prompt,
			enabled : state -> Bool,
			prepare : JsonValue -> Try((state, Ctx => (state, Outcome(Prompt.Result))), Str),
			complete : List((Str, Server.Completer(state))),
		},
	),
	notification_handlers : List((Str, (state, Ctx, JsonValue => state))),
	request_handlers : List((Str, (state, Ctx, JsonValue => (state, Outcome(JsonValue))))),
	subscribe : Try({ subscribe! : state, Ctx, Str => (state, Try({}, McpError)), unsubscribe! : state, Ctx, Str => (state, Try({}, McpError)) }, [NotSupported]),
	cache_hints : List((Str, { ttl_ms : U64, scope : [Public, Private] })),
	verify_request_state : Try((Ctx, Str -> Bool), [None]),
	versions : { legacy : List(Str), modern : List(Str) },
}.{
	## `completion/complete` callback: the partial value and the other arguments, to candidates.
	Completer(state) : state, Ctx, Str, Server.CompletionContext => (state, List(Str))

	CompletionContext : { arguments : List((Str, Str)) }

	new : { name : Str, version : Str } -> Server(state)
	new = |i| {
		info: [("name", String(i.name)), ("version", String(i.version))],
		instructions: Err(None),
		logging: Bool.False,
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
	}

	## serverInfo.title / description / websiteUrl.
	with_title : Server(state), Str -> Server(state)
	with_title = |s, v| { ..s, info: s.info.append(("title", String(v))) }

	with_description : Server(state), Str -> Server(state)
	with_description = |s, v| { ..s, info: s.info.append(("description", String(v))) }

	with_website_url : Server(state), Str -> Server(state)
	with_website_url = |s, v| { ..s, info: s.info.append(("websiteUrl", String(v))) }

	with_icon : Server(state), Content.Icon -> Server(state)
	with_icon = |_s, _icon| crash "unimplemented"

	with_instructions : Server(state), Str -> Server(state)
	with_instructions = |s, v| { ..s, instructions: Ok(v) }

	## Declares the `logging` capability and serves logging/setLevel.
	with_logging : Server(state) -> Server(state)
	with_logging = |s| { ..s, logging: Bool.True }

	## `experimental` / `extensions` capabilities.
	with_capability : Server(state), Str, JsonValue -> Server(state)
	with_capability = |s, k, v| { ..s, extra_capabilities: s.extra_capabilities.append((k, v)) }

	## Paginate tools/list, resources/list, resources/templates/list and prompts/list. Off by default (JS parity).
	with_page_size : Server(state), U64 -> Server(state)
	with_page_size = |s, n| { ..s, page_size: Ok(n) }

	## 2026-07-28 `ttlMs` / `cacheScope` for a cacheable method.
	with_cache_hint : Server(state), Str, { ttl_ms : U64, scope : [Public, Private] } -> Server(state)
	with_cache_hint = |s, m, h| { ..s, cache_hints: s.cache_hints.append((m, h)) }

	with_request_state_verifier : Server(state), (Ctx, Str -> Bool) -> Server(state)
	with_request_state_verifier = |s, f| { ..s, verify_request_state: Ok(f) }

	## Which revisions to serve. An empty `legacy` list refuses 2025 clients (JS `legacy: 'reject'`).
	with_protocol_versions : Server(state), { legacy : List(Str), modern : List(Str) } -> Server(state)
	with_protocol_versions = |s, v| { ..s, versions: v }

	## A tool whose arguments decode into the app's record type `args` (Encoding.Json).
	## A decode failure is an `isError` result "Input validation error: ...", as in JS.
	tool : Server(state), Tool, (state, Ctx, args => (state, Outcome(ToolResult))) -> Server(state)
		where [args.Json.Parseable(_)]
	tool = |s, def, handler!| {
		prepare = |raw| match Json.parse(raw.to_str()) {
			Ok(args) => Ok(|state, ctx| handler!(state, ctx, args))
			Err(e) => Err("Invalid arguments for tool ${def.name()}: ${Str.inspect(e)}")
		}
		{ ..s, tools: s.tools.append({ tool: def, enabled: |_| Bool.True, prepare }) }
	}

	## A tool that takes its arguments as JSON.
	tool_json : Server(state), Tool, (state, Ctx, JsonValue => (state, Outcome(ToolResult))) -> Server(state)
	tool_json = |s, def, handler!| {
		prepare = |raw| Ok(|state, ctx| handler!(state, ctx, raw))
		{ ..s, tools: s.tools.append({ tool: def, enabled: |_| Bool.True, prepare }) }
	}

	## Shows the named tool only while `pred(state)` holds (JS enable()/disable()).
	## A handler that changes the answer calls `Ctx.list_changed!(ctx, Tools)`.
	tool_enabled_when : Server(state), Str, (state -> Bool) -> Server(state)
	tool_enabled_when = |s, name, pred| { ..s, tools: s.tools.map(|t| if t.tool.name() == name { ..t, enabled: pred } else t) }

	## Middleware around every tools/call: gets the tool name and the call to run.
	around_tools : Server(state), (state, Ctx, Str, (state => (state, Outcome(ToolResult))) => (state, Outcome(ToolResult))) -> Server(state)
	around_tools = |s, mw!| { ..s, around_tools: s.around_tools.append(mw!) }

	resource : Server(state), Resource, (state, Ctx, Str => (state, Outcome(List(ResourceContents)))) -> Server(state)
	resource = |s, r, read!| { ..s, resources: s.resources.append({ resource: r, enabled: |_| Bool.True, read! }) }

	resource_template : Server(state), ResourceTemplate, (state, Ctx, Str, UriTemplate.Vars => (state, Outcome(List(ResourceContents)))) -> Server(state)
	resource_template = |s, t, read!| { ..s, templates: s.templates.append({ template: t, read!, list!: Err(NoList), complete: [] }) }

	## The template's `list` callback: its concrete resources for resources/list.
	template_list : Server(state), Str, (state, Ctx => (state, List(Resource))) -> Server(state)
	template_list = |s, name, list!| { ..s, templates: s.templates.map(|t| if t.template.name() == name { ..t, list!: Ok(list!) } else t) }

	## A completer for one variable of a template.
	template_complete : Server(state), Str, Str, Server.Completer(state) -> Server(state)
	template_complete = |s, name, variable, c| { ..s, templates: s.templates.map(|t| if t.template.name() == name { ..t, complete: t.complete.append((variable, c)) } else t) }

	## A prompt whose arguments (a string map) decode into `args`.
	prompt : Server(state), Prompt, (state, Ctx, args => (state, Outcome(Prompt.Result))) -> Server(state)
		where [args.Json.Parseable(_)]
	prompt = |s, def, handler!| {
		prepare = |raw| match Json.parse(raw.to_str()) {
			Ok(args) => Ok(|state, ctx| handler!(state, ctx, args))
			Err(e) => Err("Invalid arguments for prompt ${def.name()}: ${Str.inspect(e)}")
		}
		{ ..s, prompts: s.prompts.append({ prompt: def, enabled: |_| Bool.True, prepare, complete: [] }) }
	}

	prompt_complete : Server(state), Str, Str, Server.Completer(state) -> Server(state)
	prompt_complete = |s, name, arg, c| { ..s, prompts: s.prompts.map(|p| if p.prompt.name() == name { ..p, complete: p.complete.append((arg, c)) } else p) }

	## Runs on a client notification such as notifications/roots/list_changed or notifications/initialized.
	on_notification : Server(state), Str, (state, Ctx, JsonValue => state) -> Server(state)
	on_notification = |s, method, h!| { ..s, notification_handlers: s.notification_handlers.append((method, h!)) }

	## A request method that the SDK does not define.
	on_request : Server(state), Str, (state, Ctx, JsonValue => (state, Outcome(JsonValue))) -> Server(state)
	on_request = |s, method, h!| { ..s, request_handlers: s.request_handlers.append((method, h!)) }

	## Declares `resources.subscribe` and serves resources/subscribe and resources/unsubscribe.
	on_subscribe : Server(state), (state, Ctx, Str => (state, Try({}, McpError))), (state, Ctx, Str => (state, Try({}, McpError))) -> Server(state)
	on_subscribe = |s, sub!, unsub!| { ..s, subscribe: Ok({ subscribe!: sub!, unsubscribe!: unsub! }) }

	## Problems that are not errors (tool names outside ^[A-Za-z0-9._-]{1,128}$). `Stdio.serve!` logs them at start.
	warnings : Server(state) -> List(Str)
	warnings = |_s| crash "unimplemented"

	## The `capabilities` object initialize and server/discover return.
	capabilities : Server(state) -> JsonValue
	capabilities = |_s| crash "unimplemented"
}

## Wraps a tool call in the middlewares, outermost first (feasibility check for the engine).
compose_tool : List((state, Ctx, Str, (state => (state, Outcome(ToolResult))) => (state, Outcome(ToolResult)))), Str, (state, Ctx => (state, Outcome(ToolResult))) -> (state, Ctx => (state, Outcome(ToolResult)))
compose_tool = |middlewares, name, inner!|
	middlewares.fold_rev(inner!, |mw!, next!| |state, ctx| mw!(state, ctx, name, |s| next!(s, ctx)))

expect {
	run! = compose_tool([], "t", |s, _ctx| (s, Outcome.done(ToolResult.text("x"))))
	_unused = run!
	Bool.True
}
