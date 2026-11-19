app [main!] { pkg: "../package/main.roc" }

import pkg.JsonValue
import pkg.Schema
import pkg.Tool
import pkg.ToolResult
import pkg.Outcome
import pkg.McpError
import pkg.Ctx
import pkg.Server
import pkg.Engine
import Support/Session

main! = |_args| Ok({})

## tools/list and tools/call (DESIGN 5, row tools/call). Expected lines are JS SDK 2.0.0
## transcripts (.tmp/s4/js/full1.in), compared byte for byte unless noted.

echo : Bool, Ctx, { text : Str } => (Bool, Outcome(ToolResult))
echo = |s, _c, args| (s, Outcome.done(ToolResult.text(args.text)))

any! : Bool, Ctx, JsonValue => (Bool, Outcome(ToolResult))
any! = |s, _c, _args| (s, Outcome.done(ToolResult.text("")))

## The state says whether the tool "hidden" is enabled.
server : Server(Bool)
server =
	Server.new({ name: "f", version: "2" })
		.tool(Tool.new("echo").with_description("Echo").with_input_schema(Schema.object([("text", Schema.Prop.required(Schema.string(Schema.none)))])), echo)
		.tool_json(Tool.new("noargs"), any!)
		.tool_json(Tool.new("outschema").with_output_schema(Schema.with_keywords(Schema.object([("n", Schema.Prop.required(Schema.number(Schema.none)))]), [("additionalProperties", Bool(Bool.False))])), any!)
		.tool_json(Tool.new("structnum").with_output_schema(Schema.number(Schema.none)), any!)
		.tool_json(Tool.new("hidden"), any!)
		.tool_enabled_when("hidden", |st| st)
		.tool_json(Tool.new("plain"), any!)

## The raw handler results, by tool name (what `ToolResult.to_json` gives).
script : Engine.Call(Bool) -> Outcome(JsonValue)
script = |call| match Session.tool_name(call) {
	"echo" => Session.text("hi")
	"outschema" => Session.text("no sc")
	"structnum" => Outcome.done(Session.json("{\"content\":[],\"structuredContent\":5}"))
	"plain" =>
		match call.message.get_or_null("params").get_or_null("arguments").get_or_null("case") {
			String("outerr") => Outcome.done(Session.json("{\"content\":[{\"type\":\"text\",\"text\":\"e\"}],\"isError\":true}"))
			String("structarr") => Outcome.done(Session.json("{\"content\":[{\"type\":\"text\",\"text\":\"x\"}],\"structuredContent\":[1,2]}"))
			String("structarr2") => Outcome.done(Session.json("{\"content\":[{\"type\":\"image\",\"data\":\"AA==\",\"mimeType\":\"image/png\"}],\"structuredContent\":[1,2]}"))
			String("structobj") => Outcome.done(Session.json("{\"content\":[],\"structuredContent\":{\"a\":1}}"))
			String("structnull") => Outcome.done(Session.json("{\"content\":[],\"structuredContent\":null}"))
			String("badb64") => Outcome.done(Session.json("{\"content\":[{\"type\":\"image\",\"data\":\"!!!\",\"mimeType\":\"image/png\"}]}"))
			String("badtime") => Outcome.done(Session.json("{\"content\":[{\"type\":\"text\",\"text\":\"t\",\"annotations\":{\"lastModified\":\"yesterday\"}}]}"))
			String("badblob") => Outcome.done(Session.json("{\"content\":[{\"type\":\"resource\",\"resource\":{\"uri\":\"u\",\"blob\":\"a\"}}]}"))
			String("fail") => Outcome.fail(McpError.invalid_params("bad thing").with_data(Object([("x", Number("1"))])))
			String("fail32002") => Outcome.fail(McpError.new(-32002, "gone"))
			String("text") => Outcome.done(ToolResult.from_content([]).with_structured(Object([])).to_json())
			_ => Session.text("ok")
		}
	_ => Session.text("ok")
}

call : Str, Str -> Str
call = |id, params| "{\"jsonrpc\":\"2.0\",\"id\":${id},\"method\":\"tools/call\",\"params\":${params}}"

run : List(Str) -> List(Str)
run = |lines| Session.run(server, Bool.False, lines, script)

case : Str -> List(Str)
case = |c| run([call("1", "{\"name\":\"plain\",\"arguments\":{\"case\":\"${c}\"}}")])

result : Str -> List(Str)
result = |r| ["{\"result\":${r},\"jsonrpc\":\"2.0\",\"id\":1}"]

# tools/list: the input schema gets "$schema" after "type"; no input schema is {type, properties};
# the output schema gets "$schema" first; a non-object output root is wrapped; disabled tools are hidden.
expect {
	out = run(["{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/list\",\"params\":{\"cursor\":\"abc\"}}"])
	out
		== [
			"{\"result\":{\"tools\":[{\"name\":\"echo\",\"description\":\"Echo\",\"inputSchema\":{\"type\":\"object\",\"$schema\":\"https://json-schema.org/draft/2020-12/schema\",\"properties\":{\"text\":{\"type\":\"string\"}},\"required\":[\"text\"]}},{\"name\":\"noargs\",\"inputSchema\":{\"type\":\"object\",\"properties\":{}}},{\"name\":\"outschema\",\"inputSchema\":{\"type\":\"object\",\"properties\":{}},\"outputSchema\":{\"$schema\":\"https://json-schema.org/draft/2020-12/schema\",\"type\":\"object\",\"properties\":{\"n\":{\"type\":\"number\"}},\"required\":[\"n\"],\"additionalProperties\":false}},{\"name\":\"structnum\",\"inputSchema\":{\"type\":\"object\",\"properties\":{}},\"outputSchema\":{\"$schema\":\"https://json-schema.org/draft/2020-12/schema\",\"type\":\"object\",\"properties\":{\"result\":{\"$schema\":\"https://json-schema.org/draft/2020-12/schema\",\"type\":\"number\"}},\"required\":[\"result\"]}},{\"name\":\"plain\",\"inputSchema\":{\"type\":\"object\",\"properties\":{}}}]},\"jsonrpc\":\"2.0\",\"id\":2}",
		]
}

# An enabled predicate shows the tool.
expect {
	out = Session.run(server, Bool.True, ["{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/list\"}"], script)
	Session.first_has(out, "\"name\":\"hidden\"")
}

# A typed call decodes the arguments and makes one Call; the outcome becomes the result.
expect run([call("3", "{\"name\":\"echo\",\"arguments\":{\"text\":\"hi\"}}")]) == ["{\"result\":{\"content\":[{\"type\":\"text\",\"text\":\"hi\"}]},\"jsonrpc\":\"2.0\",\"id\":3}"]
expect {
	step = Engine.receive(server, Engine.Session.new, Bool.False, call("3", "{\"name\":\"echo\",\"arguments\":{\"text\":\"hi\"},\"_meta\":{\"progressToken\":\"pt\"}}"))
	match step.calls {
		[c] => step.out == [] and c.ctx.method() == "tools/call" and c.ctx.request_id() == Ok(Number("3")) and c.ctx.progress_token() == Ok(String("pt")) and c.ctx.round() == 0 and c.ctx.input("x") == NotAsked
		_ => Bool.False
	}
}

# Undecodable arguments: an isError result, no call (JS: same, with zod's message).
expect Session.first_has(run([call("4", "{\"name\":\"echo\",\"arguments\":{}}")]), "{\"result\":{\"content\":[{\"type\":\"text\",\"text\":\"Input validation error: Invalid arguments for tool echo: ")
expect Session.first_has(run([call("5", "{\"name\":\"echo\"}")]), "\"isError\":true},\"jsonrpc\":\"2.0\",\"id\":5}")
expect Session.first_has(run([call("24", "{\"name\":\"echo\",\"arguments\":{\"text\":5}}")]), "Input validation error: Invalid arguments for tool echo: ")
expect (Engine.receive(server, Engine.Session.new, Bool.False, call("4", "{\"name\":\"echo\",\"arguments\":{}}"))).calls.is_empty()

# A JSON tool gets any object; extra arguments are fine.
expect run([call("23", "{\"name\":\"noargs\",\"arguments\":{\"x\":1}}")]) == ["{\"result\":{\"content\":[{\"type\":\"text\",\"text\":\"ok\"}]},\"jsonrpc\":\"2.0\",\"id\":23}"]

# Unknown and disabled tools; malformed params.
expect run([call("6", "{\"name\":\"nope\"}")]) == ["{\"jsonrpc\":\"2.0\",\"id\":6,\"error\":{\"code\":-32602,\"message\":\"Tool nope not found\"}}"]
expect run([call("7", "{\"name\":\"hidden\"}")]) == ["{\"jsonrpc\":\"2.0\",\"id\":7,\"error\":{\"code\":-32602,\"message\":\"Tool hidden disabled\"}}"]
expect Session.first_has(run([call("25", "{}")]), "{\"jsonrpc\":\"2.0\",\"id\":25,\"error\":{\"code\":-32602,\"message\":\"Invalid tools/call request: ")
expect Session.first_has(run(["{\"jsonrpc\":\"2.0\",\"id\":26,\"method\":\"tools/call\"}"]), "{\"jsonrpc\":\"2.0\",\"id\":26,\"error\":{\"code\":-32602,")
expect Session.first_has(run([call("27", "{\"name\":\"noargs\",\"arguments\":5}")]), "\"code\":-32602,\"message\":\"Invalid tools/call request: arguments must be an object\"")

# Output schema without structured content: isError (JS text); an error result is left alone.
expect run([call("1", "{\"name\":\"outschema\"}")]) == result("{\"content\":[{\"type\":\"text\",\"text\":\"Output validation error: Tool outschema has an output schema but no structured content was provided\"}],\"isError\":true}")
expect case("outerr") == result("{\"content\":[{\"type\":\"text\",\"text\":\"e\"}],\"isError\":true}")

# structuredContent on the 2025 wire: text fallback and {result} wrap.
expect run([call("1", "{\"name\":\"structnum\"}")]) == result("{\"content\":[{\"type\":\"text\",\"text\":\"5\"}],\"structuredContent\":{\"result\":5}}")
expect case("structarr") == result("{\"content\":[{\"type\":\"text\",\"text\":\"x\"}],\"structuredContent\":{\"result\":[1,2]}}")
expect case("structarr2") == result("{\"content\":[{\"type\":\"image\",\"data\":\"AA==\",\"mimeType\":\"image/png\"},{\"type\":\"text\",\"text\":\"[1,2]\"}],\"structuredContent\":{\"result\":[1,2]}}")
expect case("structobj") == result("{\"content\":[],\"structuredContent\":{\"a\":1}}")
expect case("structnull") == result("{\"content\":[{\"type\":\"text\",\"text\":\"null\"}],\"structuredContent\":{\"result\":null}}")
expect case("text") == result("{\"content\":[],\"structuredContent\":{}}")

# Invalid results: -32602 "Invalid tools/call result: ..." (JS parity; JS adds zod's issue list).
expect Session.first_has(case("badb64"), "{\"jsonrpc\":\"2.0\",\"id\":1,\"error\":{\"code\":-32602,\"message\":\"Invalid tools/call result: content[0].data: Invalid Base64 string\"}}")
expect Session.first_has(case("badtime"), "\"message\":\"Invalid tools/call result: content[0].annotations.lastModified: Invalid ISO datetime\"")
expect Session.first_has(case("badblob"), "\"message\":\"Invalid tools/call result: content[0].resource.blob: Invalid Base64 string\"")

# Fail is a JSON-RPC error (JS turns every thrown error into isError; we keep Fail for errors).
expect case("fail") == ["{\"jsonrpc\":\"2.0\",\"id\":1,\"error\":{\"code\":-32602,\"message\":\"bad thing\",\"data\":{\"x\":1}}}"]
expect case("fail32002") == ["{\"jsonrpc\":\"2.0\",\"id\":1,\"error\":{\"code\":-32602,\"message\":\"gone\"}}"]

# Middleware does not change the call's shape (its effects run in the transport).
expect {
	wrapped : Server(Bool)
	wrapped = server.around_tools(|s, _c, _n, next!| next!(s))
	(Engine.receive(wrapped, Engine.Session.new, Bool.False, call("1", "{\"name\":\"noargs\"}"))).calls.len() == 1
}
