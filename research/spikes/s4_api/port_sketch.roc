app [main!] { pf: platform "https://github.com/roc-lang/basic-cli/releases/download/0.28.1/7brgwR8YUqfeGrkdfF1V4GPPN7DnP7ftqub9KcrTEZtr.tar.zst", mcp: "package/main.roc" }

# A type-checked sketch of how roc-syntax-mcp's src/server.ts maps onto the API. Bodies are stubs.
import pf.Stdin
import pf.Stdout
import pf.Stderr
import pf.Utc
import mcp.JsonValue
import mcp.Schema
import mcp.Tool
import mcp.ToolResult
import mcp.Resource
import mcp.ResourceContents
import mcp.ResourceTemplate
import mcp.UriTemplate
import mcp.Input
import mcp.Outcome
import mcp.Ctx
import mcp.Server
import mcp.Stdio
import mcp.McpError as McpErrorAlias

## Mutable state of createServer(): detection cache, stalled fetch, once-only notes.
App : {
	detected : Try(Str, [NotYet]),
	still_fetching : List(Str),
	still_fetching_told : Bool,
	plugin_problems_shown : Bool,
}

## `detectionRoot()`: --workspace, then roots/list (2 s), then the environment.
detection_root : App, Ctx -> [Root(Str), Ask(Input.Required)]
detection_root = |_app, ctx|
	if ctx.has_client_capability("roots") {
		match ctx.input("roots") {
			NotAsked => Ask(Input.Required.one("roots", ListRoots).with_timeout_ms(2000))
			Answered(answer) =>
				match Input.roots(answer) {
					Ok([first, ..]) if first.uri.starts_with("file://") => Root(first.uri.drop_prefix("file://"))
					_ => Root("env")
				}
			Failed(_) | TimedOut => Root("env")
		}
	} else {
		Root("env")
	}

## `ensureDetection()` at the top of each tool: either the detected root, or the input request to make.
ensure_detection! : App, Ctx => Try(App, Input.Required)
ensure_detection! = |st, ctx| match st.detected {
	Ok(_) => Ok(st)
	Err(NotYet) =>
		match detection_root(st, ctx) {
			Ask(req) => Err(req)
			Root(root) => Ok({ ..st, detected: Ok(root) })
		}
}

read_only_fetches : Tool -> Tool
read_only_fetches = |t| t.read_only(Bool.True).open_world(Bool.True)

SyntaxArgs : { topic : Try(Str, [Missing]), scope : Try(Str, [Missing]) }

get_roc_syntax! : App, Ctx, SyntaxArgs => (App, Outcome(ToolResult))
get_roc_syntax! = |st0, ctx, args| match ensure_detection!(st0, ctx) {
	Err(req) => (st0, Outcome.need_input(req))
	Ok(st) => {
		text = match args.topic {
			Ok(topic) => "topic ${topic}"
			Err(Missing) => "overview"
		}
		(st, Outcome.done(ToolResult.text(text)))
	}
}

## `search_symbols` takes `query` as a string or a list: decoded by hand from JSON.
search_symbols! : App, Ctx, JsonValue => (App, Outcome(ToolResult))
search_symbols! = |st, _ctx, args| {
	queries = match args.get("query") {
		Ok(String(q)) => [q]
		Ok(Array(items)) => items.keep_oks(|i| i.as_str())
		_ => []
	}
	if queries.is_empty() or queries.len() > 8 {
		(st, Outcome.done(ToolResult.error("Input validation error: query must be 1 to 8 strings")))
	} else {
		(st, Outcome.done(ToolResult.text("results for ${Str.join_with(queries, ", ")}")))
	}
}

## The registerTool wrapper: append the stalled-fetch note once to the last text block.
still_fetching_note! : App, Ctx, Str, (App => (App, Outcome(ToolResult))) => (App, Outcome(ToolResult))
still_fetching_note! = |st0, _ctx, _name, next!| {
	(st, outcome) = next!(st0)
	if st.still_fetching.is_empty() or st.still_fetching_told {
		(st, outcome)
	} else {
		note = "\n\nNote: `roc deps` is still downloading ${Str.join_with(st.still_fetching, ", ")}."
		({ ..st, still_fetching_told: Bool.True }, outcome.map(|r| r.map_last_text(|t| Str.concat(t, note))))
	}
}

topics : List(Str)
topics = ["effects", "json", "opaque"]

make_server : {} -> Server(App)
make_server = |{}|
	Server.new({ name: "roc-syntax", version: "0.0.0" })
		.with_description("Roc syntax, builtins, and language reference for the Zig-based compiler.")
		.with_website_url("https://github.com/Karakatiza666/roc-syntax-mcp")
		.with_instructions("Roc language reference ... call `get_roc_syntax` once with no arguments.")
		.around_tools(still_fetching_note!)
		.tool(
			Tool.new("get_roc_syntax")
				.with_title("Roc Overview and Syntax Topics (start here)")
				.with_description("Call with no arguments before ...")
				.with_input_schema(
					Schema.object([
						("topic", Schema.Prop.optional(Schema.string(Schema.described("Omit for the overview.")))),
						("scope", Schema.Prop.optional(Schema.enum(["language", "builtin", "basic-cli"], Schema.described("One corpus only.")))),
					]),
				)
				|> read_only_fetches,
			get_roc_syntax!,
		)
		.tool_json(Tool.new("search_symbols") |> read_only_fetches, search_symbols!)
		.resource(
			Resource.new("roc-syntax://overview", "roc-overview").with_title("Roc Overview (start here)").with_mime_type("text/markdown"),
			|st, _ctx, uri| (st, Outcome.done([ResourceContents.text(uri, "text/markdown", "overview text")])),
		)
		.resource_template(
			ResourceTemplate.new("roc-syntax://topic/{name}", "roc-topic").with_title("Roc Syntax Topic").with_mime_type("text/x-roc"),
			|st, _ctx, uri, vars| match vars.get("name") {
				Ok(name) if topics.contains(name) => (st, Outcome.done([ResourceContents.text(uri, "text/x-roc", "topic ${name}")]))
				_ => (st, Outcome.fail(mcp_unknown_topic(uri)))
			},
		)
		.template_list("roc-topic", |st, _ctx| (st, topics.map(|t| Resource.new("roc-syntax://topic/${t}", "roc-topic-${t}").with_title(t))))
		.template_complete("roc-topic", "name", |st, _ctx, value, _context| (st, topics.keep_if(|t| t.starts_with(value.with_ascii_lowercased()))))
		.on_notification("notifications/roots/list_changed", |st, _ctx, _params| { ..st, detected: Err(NotYet) })

mcp_unknown_topic = |uri| McpErrorAlias.invalid_params("Unknown topic: ${uri}")

main! = |_args| {
	io : Stdio.Io
	io = {
		read_line!: |_wait| Stdin.line!().map_err(|_| EndOfInput),
		write_line!: |line| Stdout.line!(line).map_err(|_| Closed),
		log!: |line| Stderr.line!(line) ?? {},
		now_ms!: || Utc.now!().to_millis_since_epoch().to_u64_wrap(),
	}
	end = Stdio.serve!(make_server({}), { detected: Err(NotYet), still_fetching: [], still_fetching_told: Bool.False, plugin_problems_shown: Bool.False }, io)
	Stderr.line!("roc-syntax-mcp: stopped (${Str.inspect(end.stopped)})")?
	Ok({})
}
