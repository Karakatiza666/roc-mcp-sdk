import pkg.JsonValue
import pkg.Tool
import pkg.ToolResult
import pkg.Resource
import pkg.ResourceContents
import pkg.Prompt
import pkg.Schema
import pkg.Input
import pkg.Outcome
import pkg.McpError
import pkg.Ctx
import pkg.Server
import pkg.Engine
import Session

## L0 helper for the 2026-07-28 tests (`tests/engine_modern*.roc`): the Roc twin of the JS
## server `.tmp/s5/js/l0.mjs` whose stdio transcripts the expected lines come from, and a
## script that answers each call as the JS handlers do.
Modern :: [].{

	## The JS server with `requestState.verify` accepting states that start with "good".
	server : Server({})
	server = base.with_request_state_verifier(|_c, s| s.starts_with("good"))

	## The JS server with `cacheHints` for tools/list and resources/read.
	hints : Server({})
	hints =
		server
			.with_cache_hint("tools/list", { ttl_ms: 5000, scope: Public })
			.with_cache_hint("resources/read", { ttl_ms: 7, scope: Private })

	## The JS server without a verifier.
	plain : Server({})
	plain = base

	## `serveStdio(..., { legacy: "reject" })`.
	reject : Server({})
	reject = server.with_protocol_versions({ legacy: [], modern: ["2026-07-28"] })

	## The handlers of l0.mjs, as scripted outcomes.
	script : Engine.Call({}) -> Outcome(JsonValue)
	script = |call| {
		c = call.ctx
		match c.method() {
			"tools/call" =>
				match Session.tool_name(call) {
					"echo" => Session.text(call.message.get_or_null("params").get_or_null("arguments").get_or_null("text").as_str() ?? "")
					"ask" => {
						answers = ["roots", "confirm"].keep_oks(
							|k| match c.input(k) {
								Answered(j) => Ok((k, j))
								_ => Err(NotAnswered)
							},
						)
						if answers.is_empty() {
							form = Session.json("{\"type\":\"object\",\"properties\":{}}")
							Outcome.need_input(Input.Required.one("roots", ListRoots).also("confirm", ElicitForm({ message: "Go?", requested_schema: form })).with_state("good1"))
						} else {
							shown : JsonValue
							shown = Object(answers)
							Session.text("answers ${shown.to_str()} state ${c.request_state() ?? "none"}")
						}
					}
					"url" => Outcome.need_input(Input.Required.one("open", ElicitUrl({ message: "Open", url: "https://x.test/a" })))
					"sample" => Outcome.need_input(Input.Required.one("s", CreateMessage(Session.json("{\"messages\":[],\"maxTokens\":5,\"tools\":[]}"))))
					"stateonly" =>
						match c.request_state() {
							Ok(s) => Session.text("state ${s}")
							Err(None) => Outcome.need_input(Input.Required.keep_state("good-only"))
						}
					"notify" => Session.text("notified")
					"structured" => Outcome.done(Session.json("{\"content\":[],\"structuredContent\":[1,2]}"))
					_ => crash "Modern.script: unknown tool"
				}
			"resources/read" => Outcome.done(Session.json("{\"contents\":[{\"uri\":\"res://a\",\"text\":\"A\"}]}"))
			"prompts/get" => Outcome.done(Session.json("{\"messages\":[{\"role\":\"user\",\"content\":{\"type\":\"text\",\"text\":\"hi Bo\"}}]}"))
			# The JS twin's handler reads `params.v` after zod stripped it: always null.
			"x/echo" => Outcome.done(Session.json("{\"got\":null}"))
			"x/odd" => Outcome.done(Session.json("{\"resultType\":\"weird\"}"))
			_ => Outcome.done(Null)
		}
	}

	## The envelope of the transcripts, as a `_meta` value.
	envelope : Str
	envelope = "\"_meta\":{\"io.modelcontextprotocol/protocolVersion\":\"2026-07-28\",\"io.modelcontextprotocol/clientCapabilities\":{},\"io.modelcontextprotocol/clientInfo\":{\"name\":\"t\",\"version\":\"1\"}}"
}

echo! : {}, Ctx, { text : Str } => ({}, Outcome(ToolResult))
echo! = |s, _c, a| (s, Outcome.done(ToolResult.text(a.text)))

any! : {}, Ctx, JsonValue => ({}, Outcome(ToolResult))
any! = |s, _c, _a| (s, Outcome.done(ToolResult.text("")))

read! : {}, Ctx, Str => ({}, Outcome(List(ResourceContents)))
read! = |s, _c, _uri| (s, Outcome.done([]))

greet! : {}, Ctx, { who : Str } => ({}, Outcome(Prompt.Result))
greet! = |s, _c, _a| (s, Outcome.done({ description: Err(None), messages: [] }))

sub! : {}, Ctx, Str => ({}, Try({}, McpError))
sub! = |s, _c, _uri| (s, Ok({}))

custom! : {}, Ctx, JsonValue => ({}, Outcome(JsonValue))
custom! = |s, _c, _p| (s, Outcome.done(Null))

poke! : {}, Ctx, JsonValue => {}
poke! = |s, _c, _p| s

base : Server({})
base =
	Server.new({ name: "m", version: "1" })
		.with_logging()
		.with_instructions("hi")
		.tool(Tool.new("echo").with_input_schema(Schema.object([("text", Schema.Prop.required(Schema.string(Schema.none)))])), echo!)
		.tool_json(Tool.new("ask"), any!)
		.tool_json(Tool.new("url"), any!)
		.tool_json(Tool.new("sample"), any!)
		.tool_json(Tool.new("stateonly"), any!)
		.tool_json(Tool.new("notify"), any!)
		.tool_json(Tool.new("structured").with_output_schema(Schema.array(Schema.number(Schema.none), Schema.none)), any!)
		.resource(Resource.new("res://a", "a").with_mime_type("text/plain"), read!)
		.prompt(Prompt.new("p").with_argument({ name: "who", description: "", required: Bool.True }), greet!)
		.on_subscribe(sub!, sub!)
		.on_request("x/echo", custom!)
		.on_request("x/odd", custom!)
		.on_notification("x/poke", poke!)
