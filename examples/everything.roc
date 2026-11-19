app [main!] {
	mcp: "../package/main.roc",
	pf: platform "https://github.com/roc-lang/basic-cli/releases/download/0.28.1/7brgwR8YUqfeGrkdfF1V4GPPN7DnP7ftqub9KcrTEZtr.tar.zst",
}

import pf.Stdin
import pf.Stdout
import pf.Stderr
import pf.Utc
import mcp.JsonValue
import mcp.Schema
import mcp.McpError
import mcp.LogLevel
import mcp.Tool
import mcp.ToolResult
import mcp.Resource
import mcp.ResourceContents
import mcp.ResourceTemplate
import mcp.Prompt
import mcp.UriTemplate
import mcp.Input
import mcp.Outcome
import mcp.Ctx
import mcp.Server
import mcp.Stdio

# Every feature of the SDK in one server. It is the E2E target (tests/e2e) and has a
# behavioural twin on the JS SDK (tests/e2e/js/everything.mjs): keep the two in step.

## The app state, threaded through every handler.
State : {
	count : U64, # the `counter` tool
	tool_calls : U64, # counted by the middleware
	pokes : U64, # the custom notification `everything/poke`
	unlocked : Bool, # `secret` is listed only when unlocked
	roots : Try(List(Str), [NotYet]), # cached by `roots`, cleared by notifications/roots/list_changed
	subscribed : List(Str), # resources/subscribe
}

init : State
init = { count: 0, tool_calls: 0, pokes: 0, unlocked: Bool.False, roots: Err(NotYet), subscribed: [] }

notes : List(Str)
notes = ["alpha", "beta", "gamma"]

styles : List(Str)
styles = ["casual", "formal"]

# --- tools ---

EchoArgs : { text : Str, times : Try(U64, [Missing]) }

## Typed arguments: a missing `text` is an input validation error.
echo! : State, Ctx, EchoArgs => (State, Outcome(ToolResult))
echo! = |st, _ctx, args| {
	n = args.times ?? 1
	(st, Outcome.done(ToolResult.text(Str.join_with(List.repeat(args.text, n), " "))))
}

## JSON arguments and structured output (with an outputSchema).
add! : State, Ctx, JsonValue => (State, Outcome(ToolResult))
add! = |st, _ctx, args| {
	a = args.get_or_null("a").to_i64()
	b = args.get_or_null("b").to_i64()
	result =
		match (a, b) {
			(Ok(x), Ok(y)) => {
				sum = JsonValue.from_i64(x + y)
				ToolResult.text(sum.to_str()).with_structured(Object([("sum", sum)]))
			}
			_ => ToolResult.error("a and b must be integers")
		}
	(st, Outcome.done(result))
}

## State threading.
counter! : State, Ctx, {} => (State, Outcome(ToolResult))
counter! = |st, _ctx, {}| {
	n = st.count + 1
	({ ..st, count: n }, Outcome.done(ToolResult.text("count: ${n.to_str()}")))
}

## Turns on `secret` (tool_enabled_when) and announces the new list.
unlock! : State, Ctx, {} => (State, Outcome(ToolResult))
unlock! = |st, ctx, {}| {
	ctx.list_changed!(Tools)
	({ ..st, unlocked: Bool.True }, Outcome.done(ToolResult.text("unlocked")))
}

secret! : State, Ctx, {} => (State, Outcome(ToolResult))
secret! = |st, _ctx, {}| (st, Outcome.done(ToolResult.text("the secret is 42")))

## A tool failure that the model sees.
fail! : State, Ctx, {} => (State, Outcome(ToolResult))
fail! = |st, _ctx, {}| (st, Outcome.done(ToolResult.error("it failed")))

## One log line at each of four levels: logging/setLevel filters them.
log_levels! : State, Ctx, {} => (State, Outcome(ToolResult))
log_levels! = |st, ctx, {}| {
	ctx.log!(Debug, String("debug line"))
	ctx.log!(Info, String("info line"))
	ctx.log!(Warning, String("warning line"))
	ctx.log!(Error, Object([("detail", String("error line"))]))
	(st, Outcome.done(ToolResult.text("logged")))
}

SlowArgs : { steps : U64 }

## Progress notifications (sent only with a progress token).
slow! : State, Ctx, SlowArgs => (State, Outcome(ToolResult))
slow! = |st, ctx, args| {
	total = args.steps.to_dec()
	for i in (1.U64).to(args.steps) {
		ctx.progress!({ progress: i.to_dec(), total: Ok(total), message: Ok("step ${i.to_str()}") })
	}
	(st, Outcome.done(ToolResult.text("done ${args.steps.to_str()} steps")))
}

## Server-to-client roots/list (the input shim), cached in the state.
roots! : State, Ctx, {} => (State, Outcome(ToolResult))
roots! = |st, ctx, {}|
	match st.roots {
		Ok(uris) => (st, Outcome.done(ToolResult.text("cached roots: ${Str.join_with(uris, ", ")}")))
		Err(NotYet) =>
			if !ctx.has_client_capability("roots") {
				(st, Outcome.done(ToolResult.text("no roots capability")))
			} else {
				match ctx.input("roots") {
					NotAsked => (st, Outcome.need_input(Input.Required.one("roots", ListRoots)))
					Answered(answer) =>
						match Input.roots(answer) {
							Ok(list) => {
								uris = list.map(|r| r.uri)
								({ ..st, roots: Ok(uris) }, Outcome.done(ToolResult.text("roots: ${Str.join_with(uris, ", ")}")))
							}
							Err(BadAnswer(why)) => (st, Outcome.done(ToolResult.error("bad roots answer: ${why}")))
						}
					Failed(e) => (st, Outcome.done(ToolResult.error("roots failed: ${e.message()}")))
					TimedOut => (st, Outcome.done(ToolResult.error("roots timed out")))
				}
			}
	}

## Server-to-client elicitation/create (form mode, through the input shim).
confirm! : State, Ctx, {} => (State, Outcome(ToolResult))
confirm! = |st, ctx, {}| {
	ask = ElicitForm({
		message: "Proceed?",
		requested_schema: Object([
			("type", String("object")),
			("properties", Object([("ok", Object([("type", String("boolean"))]))])),
			("required", Array([String("ok")])),
		]),
	})
	text =
		match ctx.input("confirm") {
			NotAsked => Err(Ask)
			Answered(answer) =>
				match Input.elicitation(answer) {
					Ok(Accept(content)) => Ok("accepted: ok=${content.get_or_null("ok").to_str()}")
					Ok(Decline) => Ok("declined")
					Ok(Cancel) => Ok("cancelled")
					Err(BadAnswer(why)) => Ok("bad answer: ${why}")
				}
			Failed(e) => Ok("elicitation failed: ${e.message()}")
			TimedOut => Ok("elicitation timed out")
		}
	match text {
		Ok(t) => (st, Outcome.done(ToolResult.text(t)))
		Err(Ask) => (st, Outcome.need_input(Input.Required.one("confirm", ask)))
	}
}

## Sends notifications/resources/updated for each subscribed resource.
touch! : State, Ctx, {} => (State, Outcome(ToolResult))
touch! = |st, ctx, {}| {
	for uri in st.subscribed {
		ctx.resource_updated!(uri)
	}
	(st, Outcome.done(ToolResult.text("touched ${st.subscribed.len().to_str()}")))
}

## Middleware: counts every tools/call (each re-entry of the input shim counts too).
count_calls! : State, Ctx, Str, (State => (State, Outcome(ToolResult))) => (State, Outcome(ToolResult))
count_calls! = |st, _ctx, _name, next!| next!({ ..st, tool_calls: st.tool_calls + 1 })

# --- resources ---

read_info! : State, Ctx, Str => (State, Outcome(List(ResourceContents)))
read_info! = |st, _ctx, uri| (st, Outcome.done([ResourceContents.text(uri, "text/plain", "everything server")]))

read_stats! : State, Ctx, Str => (State, Outcome(List(ResourceContents)))
read_stats! = |st, _ctx, uri| (st, Outcome.done([ResourceContents.text(uri, "application/json", stats_json(st).to_str())]))

read_note! : State, Ctx, Str, UriTemplate.Vars => (State, Outcome(List(ResourceContents)))
read_note! = |st, _ctx, uri, vars| {
	name = vars.get("name") ?? ""
	if notes.contains(name) {
		(st, Outcome.done([ResourceContents.text(uri, "text/plain", "note ${name}")]))
	} else {
		(st, Outcome.fail(McpError.resource_not_found(uri)))
	}
}

list_notes! : State, Ctx => (State, List(Resource))
list_notes! = |st, _ctx| (st, notes.map(|n| Resource.new("note://${n}", n)))

complete_note! : State, Ctx, Str, Server.CompletionContext => (State, List(Str))
complete_note! = |st, _ctx, prefix, _context| (st, notes.keep_if(|n| n.starts_with(prefix)))

read_file! : State, Ctx, Str, UriTemplate.Vars => (State, Outcome(List(ResourceContents)))
read_file! = |st, _ctx, uri, vars| (st, Outcome.done([ResourceContents.text(uri, "text/plain", "path=${vars.get("path") ?? ""}")]))

subscribe! : State, Ctx, Str => (State, Try({}, McpError))
subscribe! = |st, _ctx, uri| ({ ..st, subscribed: if (st.subscribed.contains(uri)) st.subscribed else st.subscribed.append(uri) }, Ok({}))

unsubscribe! : State, Ctx, Str => (State, Try({}, McpError))
unsubscribe! = |st, _ctx, uri| ({ ..st, subscribed: st.subscribed.drop_if(|u| u == uri) }, Ok({}))

# --- prompts ---

GreetArgs : { name : Str, style : Try(Str, [Missing]) }

greet! : State, Ctx, GreetArgs => (State, Outcome(Prompt.Result))
greet! = |st, _ctx, args| {
	text =
		match args.style {
			Ok("formal") => "Good day, ${args.name}."
			_ => "Hi ${args.name}!"
		}
	(st, Outcome.done({ description: Ok("A greeting"), messages: [Prompt.user(text)] }))
}

complete_style! : State, Ctx, Str, Server.CompletionContext => (State, List(Str))
complete_style! = |st, _ctx, prefix, context| {
	# The other arguments reach the completer: a name "Bob" only gets "formal".
	all = if (context.arguments.contains(("name", "Bob"))) ["formal"] else styles
	(st, all.keep_if(|s| s.starts_with(prefix)))
}

# --- custom methods ---

stats_json : State -> JsonValue
stats_json = |st|
	Object([
		("count", JsonValue.from_u64(st.count)),
		("toolCalls", JsonValue.from_u64(st.tool_calls)),
		("pokes", JsonValue.from_u64(st.pokes)),
	])

stats! : State, Ctx, JsonValue => (State, Outcome(JsonValue))
stats! = |st, _ctx, _params| (st, Outcome.done(stats_json(st)))

poke! : State, Ctx, JsonValue => State
poke! = |st, _ctx, _params| { ..st, pokes: st.pokes + 1 }

roots_changed! : State, Ctx, JsonValue => State
roots_changed! = |st, _ctx, _params| { ..st, roots: Err(NotYet) }

server : Server(State)
server =
	Server.new({ name: "everything", version: "1.0.0" })
		.with_title("Everything")
		.with_instructions("Exercises every feature of the SDK.")
		.with_logging()
		.tool(
			Tool.new("echo")
				.with_description("Echo text, optionally repeated")
				.with_input_schema(
					Schema.object([
						("text", Schema.Prop.required(Schema.string(Schema.described("Text to echo")))),
						("times", Schema.Prop.optional(Schema.number(Schema.none))),
					]),
				)
				.read_only(Bool.True),
			echo!,
		)
		.tool_json(
			Tool.new("add")
				.with_description("Add two integers")
				.with_input_schema(
					Schema.object([
						("a", Schema.Prop.required(Schema.number(Schema.none))),
						("b", Schema.Prop.required(Schema.number(Schema.none))),
					]),
				)
				# The JS SDK sends a zod output schema with `$schema` and `additionalProperties: false`.
				.with_output_schema(
					Schema.with_dialect(
						Schema.with_keywords(
							Schema.object([("sum", Schema.Prop.required(Schema.number(Schema.none)))]),
							[("additionalProperties", Bool(Bool.False))],
						),
					),
				),
			add!,
		)
		.tool(Tool.new("counter").with_description("Count calls"), counter!)
		.tool(Tool.new("unlock").with_description("Enable the secret tool"), unlock!)
		.tool(Tool.new("secret").with_description("Listed once unlocked"), secret!)
		.tool_enabled_when("secret", |st| st.unlocked)
		.tool(Tool.new("fail").with_description("Always fails"), fail!)
		.tool(Tool.new("log_levels").with_description("Log at four levels"), log_levels!)
		.tool(
			Tool.new("slow")
				.with_description("Report progress")
				.with_input_schema(Schema.object([("steps", Schema.Prop.required(Schema.number(Schema.none)))])),
			slow!,
		)
		.tool(Tool.new("roots").with_description("Ask the client for its roots"), roots!)
		.tool(Tool.new("confirm").with_description("Ask the user to confirm"), confirm!)
		.tool(Tool.new("touch").with_description("Notify subscribers"), touch!)
		.around_tools(count_calls!)
		.resource(Resource.new("info://server", "info").with_title("Server info").with_mime_type("text/plain"), read_info!)
		.resource(Resource.new("info://stats", "stats").with_mime_type("application/json"), read_stats!)
		.resource_template(ResourceTemplate.new("note://{name}", "note").with_description("A note").with_mime_type("text/plain"), read_note!)
		.template_list("note", list_notes!)
		.template_complete("note", "name", complete_note!)
		.resource_template(ResourceTemplate.new("file:///{+path}", "file"), read_file!)
		.on_subscribe(subscribe!, unsubscribe!)
		.prompt(
			Prompt.new("greet")
				.with_title("Greeting")
				.with_description("Greet someone")
				.with_argument({ name: "name", description: "Who to greet", required: Bool.True })
				.with_argument({ name: "style", description: "", required: Bool.False }),
			greet!,
		)
		.prompt_complete("greet", "style", complete_style!)
		.on_request("everything/stats", stats!)
		.on_notification("everything/poke", poke!)
		.on_notification("notifications/roots/list_changed", roots_changed!)

## The basic-cli adapter (DESIGN 4.9). basic-cli 0.28.1 has no timed read, so the wait is
## ignored and an input deadline fires when the next line arrives. A line that is not UTF-8
## is consumed by basic-cli; it becomes an empty line, which the loop skips.
io : Stdio.Io
io = {
	read_line!: |_wait|
		match Stdin.line!() {
			Ok(line) => Ok(line)
			Err(BadUtf8(_)) => Ok("")
			Err(_) => Err(EndOfInput)
		},
	write_line!: |line| Stdout.line!(line).map_err(|_| Closed),
	log!: |line| Stderr.line!(line) ?? {},
	now_ms!: || Utc.now!().to_millis_since_epoch().to_u64_wrap(),
}

main! = |_args| {
	end = Stdio.serve!(server, init, io)
	how =
		match end.stopped {
			InputEnded => "input ended"
			OutputClosed => "output closed"
		}
	Stderr.line!("everything: ${how}; ${end.state.tool_calls.to_str()} tool calls") ?? {}
	Ok({})
}
