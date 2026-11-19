app [main!] { pkg: "../package/main.roc" }

import pkg.JsonValue
import pkg.Resource
import pkg.ResourceContents
import pkg.ResourceTemplate
import pkg.UriTemplate
import pkg.Prompt
import pkg.Outcome
import pkg.McpError
import pkg.Ctx
import pkg.Server
import pkg.Engine
import Support/Session

main! = |_args| Ok({})

## resources, prompts and completion/complete (DESIGN 5, rows resources, completion/complete).
## Expected lines are JS SDK 2.0.0 transcripts (.tmp/s4/js/full2.in), byte for byte unless noted.

read! : {}, Ctx, Str => ({}, Outcome(List(ResourceContents)))
read! = |s, _c, _uri| (s, Outcome.done([]))

read_t! : {}, Ctx, Str, UriTemplate.Vars => ({}, Outcome(List(ResourceContents)))
read_t! = |s, _c, _uri, _vars| (s, Outcome.done([]))

list! : {}, Ctx => ({}, List(Resource))
list! = |s, _c| (s, [])

comp! : Server.Completer({})
comp! = |s, _c, _v, _cc| (s, [])

greet! : {}, Ctx, { who : Str, mood : Try(Str, [Missing]) } => ({}, Outcome(Prompt.Result))
greet! = |s, _c, _args| (s, Outcome.done({ description: Err(None), messages: [] }))

plain! : {}, Ctx, {} => ({}, Outcome(Prompt.Result))
plain! = |s, _c, _args| (s, Outcome.done({ description: Err(None), messages: [] }))

server : Server({})
server =
	Server.new({ name: "f", version: "2" })
		.resource(Resource.new("file:///a", "a").with_mime_type("text/plain"), read!)
		.resource(Resource.new("file:///boom", "boom"), read!)
		.resource_template(ResourceTemplate.new("file:///t/{name}", "tpl").with_title("TT").with_description("tdesc").with_mime_type("text/x"), read_t!)
		.template_list("tpl", list!)
		.template_complete("tpl", "name", comp!)
		.resource_template(ResourceTemplate.new("file:///{a}/{b}", "tpl2"), read_t!)
		.template_complete("tpl2", "b", comp!)
		.prompt(Prompt.new("greet").with_description("g").with_argument({ name: "who", description: "Who", required: Bool.True }).with_argument({ name: "mood", description: "", required: Bool.False }), greet!)
		.prompt_complete("greet", "mood", comp!)
		.prompt(Prompt.new("plain"), plain!)

script : Engine.Call({}) -> Outcome(JsonValue)
script = |call| {
	params = call.message.get_or_null("params")
	match call.ctx.method() {
		"resources/list" => Outcome.done(Array([Array([Resource.new("file:///t/one", "one").with_description("entry").with_title("T1").to_json()])]))
		"resources/read" =>
			match params.get_or_null("uri") {
				String("file:///boom") => Outcome.fail(McpError.internal("Unknown topic: x"))
				String("file:///x/bad") => Outcome.done(Session.json("{\"contents\":[{\"uri\":\"file:///x/bad\",\"blob\":\"%%\"}]}"))
				String(u) => Outcome.done(Object([("contents", Array([ResourceContents.text(u, "", "A").without_mime_type().to_json()]))]))
				_ => crash "no uri"
			}
		"prompts/get" =>
			match params.get_or_null("name") {
				String("greet") => Outcome.done(Prompt.result_to_json({ description: Err(None), messages: [Prompt.user("hi bob undefined")] }))
				_ => Outcome.done(Prompt.result_to_json({ description: Ok("pd"), messages: [Prompt.assistant("p")] }))
			}
		"completion/complete" =>
			match params.get_or_null("ref").get_or_null("uri") {
				String("file:///t/{name}") => Outcome.done(Array((0.U64..<150).iter().map(|i| String("v${i.to_str()}")).collect()))
				_ => Outcome.done(Array([String("happy"), String("hungry")]))
			}
		_ => crash "unexpected call"
	}
}

req : Str, Str, Str -> Str
req = |id, method, params| "{\"jsonrpc\":\"2.0\",\"id\":${id},\"method\":\"${method}\",\"params\":${params}}"

run : List(Str) -> List(Str)
run = |lines| Session.run(server, {}, lines, script)

# resources/list: the static resources, then each template's list with its metadata merged in.
expect run([req("2", "resources/list", "{}")]) == ["{\"result\":{\"resources\":[{\"uri\":\"file:///a\",\"name\":\"a\",\"mimeType\":\"text/plain\"},{\"uri\":\"file:///boom\",\"name\":\"boom\"},{\"title\":\"T1\",\"description\":\"entry\",\"mimeType\":\"text/x\",\"uri\":\"file:///t/one\",\"name\":\"one\"}]},\"jsonrpc\":\"2.0\",\"id\":2}"]

# Without list callbacks, resources/list is answered at once.
expect {
	statics : Server({})
	statics = Server.new({ name: "s", version: "1" }).resource(Resource.new("file:///a", "a"), read!)
	step = Engine.receive(statics, Engine.Session.new, {}, req("2", "resources/list", "{}"))
	step.calls.is_empty() and step.out == ["{\"result\":{\"resources\":[{\"uri\":\"file:///a\",\"name\":\"a\"}]},\"jsonrpc\":\"2.0\",\"id\":2}"]
}

expect run([req("3", "resources/templates/list", "{}")]) == ["{\"result\":{\"resourceTemplates\":[{\"name\":\"tpl\",\"uriTemplate\":\"file:///t/{name}\",\"title\":\"TT\",\"description\":\"tdesc\",\"mimeType\":\"text/x\"},{\"name\":\"tpl2\",\"uriTemplate\":\"file:///{a}/{b}\"}]},\"jsonrpc\":\"2.0\",\"id\":3}"]

# resources/read: static, template, invalid URI, no match, handler failure, bad params.
expect run([req("4", "resources/read", "{\"uri\":\"file:///a\"}")]) == ["{\"result\":{\"contents\":[{\"uri\":\"file:///a\",\"text\":\"A\"}]},\"jsonrpc\":\"2.0\",\"id\":4}"]
expect run([req("5", "resources/read", "{\"uri\":\"file:///t/xyz\"}")]) == ["{\"result\":{\"contents\":[{\"uri\":\"file:///t/xyz\",\"text\":\"A\"}]},\"jsonrpc\":\"2.0\",\"id\":5}"]
expect run([req("6", "resources/read", "{\"uri\":\"file:///p/q\"}")]) == ["{\"result\":{\"contents\":[{\"uri\":\"file:///p/q\",\"text\":\"A\"}]},\"jsonrpc\":\"2.0\",\"id\":6}"]
expect run([req("7", "resources/read", "{\"uri\":\"nope\"}")]) == ["{\"jsonrpc\":\"2.0\",\"id\":7,\"error\":{\"code\":-32602,\"message\":\"Resource URI nope is invalid\",\"data\":{\"uri\":\"nope\",\"reason\":\"invalid_uri\"}}}"]
expect run([req("8", "resources/read", "{\"uri\":\"file:///zz/y/z\"}")]) == ["{\"jsonrpc\":\"2.0\",\"id\":8,\"error\":{\"code\":-32602,\"message\":\"Resource not found: file:///zz/y/z\",\"data\":{\"uri\":\"file:///zz/y/z\"}}}"]
expect run([req("9", "resources/read", "{\"uri\":\"file:///boom\"}")]) == ["{\"jsonrpc\":\"2.0\",\"id\":9,\"error\":{\"code\":-32603,\"message\":\"Unknown topic: x\"}}"]
expect Session.first_has(run([req("10", "resources/read", "{}")]), "{\"jsonrpc\":\"2.0\",\"id\":10,\"error\":{\"code\":-32602,")
expect Session.first_has(run([req("11", "resources/read", "{\"uri\":\"file:///x/bad\"}")]), "\"message\":\"Invalid resources/read result: contents[0].blob: Invalid Base64 string\"")
expect (Engine.receive(server, Engine.Session.new, {}, req("4", "resources/read", "{\"uri\":\"file:///a\"}"))).calls.len() == 1

# Subscriptions: only with on_subscribe, which also declares resources.subscribe.
expect {
	sub! : {}, Ctx, Str => ({}, Try({}, McpError))
	sub! = |s, _c, uri| (s, if (uri == "file:///no") Err(McpError.invalid_params("no")) else Ok({}))
	subs : Server({})
	subs = server.on_subscribe(sub!, sub!)
	out = Session.run(subs, {}, [req("1", "resources/subscribe", "{\"uri\":\"file:///a\"}"), req("2", "resources/unsubscribe", "{\"uri\":\"file:///a\"}")], |_| Outcome.done(Object([])))
	failed = Session.run(subs, {}, [req("3", "resources/subscribe", "{\"uri\":\"file:///no\"}")], |_| Outcome.fail(McpError.invalid_params("no")))
	caps = subs.capabilities().get_or_null("resources").to_str()
	out == ["{\"result\":{},\"jsonrpc\":\"2.0\",\"id\":1}", "{\"result\":{},\"jsonrpc\":\"2.0\",\"id\":2}"] and failed == ["{\"jsonrpc\":\"2.0\",\"id\":3,\"error\":{\"code\":-32602,\"message\":\"no\"}}"] and caps == "{\"listChanged\":true,\"subscribe\":true}"
}
expect run([req("1", "resources/subscribe", "{\"uri\":\"file:///a\"}")]) == ["{\"jsonrpc\":\"2.0\",\"id\":1,\"error\":{\"code\":-32601,\"message\":\"Method not found\"}}"]

# Prompts.
expect run([req("11", "prompts/list", "{}")]) == ["{\"result\":{\"prompts\":[{\"name\":\"greet\",\"description\":\"g\",\"arguments\":[{\"name\":\"who\",\"description\":\"Who\",\"required\":true},{\"name\":\"mood\",\"required\":false}]},{\"name\":\"plain\"}]},\"jsonrpc\":\"2.0\",\"id\":11}"]
expect run([req("12", "prompts/get", "{\"name\":\"greet\",\"arguments\":{\"who\":\"bob\"}}")]) == ["{\"result\":{\"messages\":[{\"role\":\"user\",\"content\":{\"type\":\"text\",\"text\":\"hi bob undefined\"}}]},\"jsonrpc\":\"2.0\",\"id\":12}"]
# Arguments are checked against the declared ones (JS: the argsSchema of strings).
expect run([req("13", "prompts/get", "{\"name\":\"greet\"}")]) == ["{\"jsonrpc\":\"2.0\",\"id\":13,\"error\":{\"code\":-32602,\"message\":\"Invalid arguments for prompt greet: Invalid input: expected object, received undefined\"}}"]
expect run([req("16", "prompts/get", "{\"name\":\"greet\",\"arguments\":{\"mood\":\"x\"}}")]) == ["{\"jsonrpc\":\"2.0\",\"id\":16,\"error\":{\"code\":-32602,\"message\":\"Invalid arguments for prompt greet: who: Invalid input: expected string, received undefined\"}}"]
# A prompt without declared arguments takes anything (JS: no argsSchema).
expect run([req("17", "prompts/get", "{\"name\":\"plain\",\"arguments\":{\"x\":\"y\"}}")]) == ["{\"result\":{\"description\":\"pd\",\"messages\":[{\"role\":\"assistant\",\"content\":{\"type\":\"text\",\"text\":\"p\"}}]},\"jsonrpc\":\"2.0\",\"id\":17}"]
expect run([req("14", "prompts/get", "{\"name\":\"nope\"}")]) == ["{\"jsonrpc\":\"2.0\",\"id\":14,\"error\":{\"code\":-32602,\"message\":\"Prompt nope not found\"}}"]
expect run([req("15", "prompts/get", "{\"name\":\"plain\"}")]) == ["{\"result\":{\"description\":\"pd\",\"messages\":[{\"role\":\"assistant\",\"content\":{\"type\":\"text\",\"text\":\"p\"}}]},\"jsonrpc\":\"2.0\",\"id\":15}"]
# Malformed params: JS answers -32603 with zod's issue list of its request schema.
internal : Str, Str -> List(Str)
internal = |id, issues| {
	line : JsonValue
	line = Object([("jsonrpc", String("2.0")), ("id", Number(id)), ("error", Object([("code", Number("-32603")), ("message", String(issues))]))])
	[line.to_str()]
}
expect run([req("26", "prompts/get", "{\"name\":\"greet\",\"arguments\":{\"who\":5,\"mood\":true}}")]) == internal("26", "[\n  {\n    \"expected\": \"string\",\n    \"code\": \"invalid_type\",\n    \"path\": [\n      \"params\",\n      \"arguments\",\n      \"who\"\n    ],\n    \"message\": \"Invalid input: expected string, received number\"\n  },\n  {\n    \"expected\": \"string\",\n    \"code\": \"invalid_type\",\n    \"path\": [\n      \"params\",\n      \"arguments\",\n      \"mood\"\n    ],\n    \"message\": \"Invalid input: expected string, received boolean\"\n  }\n]")
expect run([req("27", "prompts/get", "{\"name\":5}")]) == internal("27", "[\n  {\n    \"expected\": \"string\",\n    \"code\": \"invalid_type\",\n    \"path\": [\n      \"params\",\n      \"name\"\n    ],\n    \"message\": \"Invalid input: expected string, received number\"\n  }\n]")
expect run([req("28", "prompts/get", "{\"name\":\"nope\",\"arguments\":null}")]) == internal("28", "[\n  {\n    \"expected\": \"record\",\n    \"code\": \"invalid_type\",\n    \"path\": [\n      \"params\",\n      \"arguments\"\n    ],\n    \"message\": \"Invalid input: expected record, received null\"\n  }\n]")

# completion/complete.
complete : Str, Str -> Str
complete = |id, params| req(id, "completion/complete", params)

empty_completion : Str -> Str
empty_completion = |id| "{\"result\":{\"completion\":{\"values\":[],\"hasMore\":false}},\"jsonrpc\":\"2.0\",\"id\":${id}}"

expect run([complete("16", "{\"ref\":{\"type\":\"ref/prompt\",\"name\":\"greet\"},\"argument\":{\"name\":\"mood\",\"value\":\"h\"}}")]) == ["{\"result\":{\"completion\":{\"values\":[\"happy\",\"hungry\"],\"total\":2,\"hasMore\":false}},\"jsonrpc\":\"2.0\",\"id\":16}"]
expect run([complete("17", "{\"ref\":{\"type\":\"ref/prompt\",\"name\":\"greet\"},\"argument\":{\"name\":\"who\",\"value\":\"h\"}}")]) == [empty_completion("17")]
expect run([complete("18", "{\"ref\":{\"type\":\"ref/prompt\",\"name\":\"nope\"},\"argument\":{\"name\":\"who\",\"value\":\"h\"}}")]) == ["{\"jsonrpc\":\"2.0\",\"id\":18,\"error\":{\"code\":-32602,\"message\":\"Prompt nope not found\"}}"]
expect {
	values = (0.U64..<100).iter().map(|i| "\"v${i.to_str()}\"").collect()
	run([complete("19", "{\"ref\":{\"type\":\"ref/resource\",\"uri\":\"file:///t/{name}\"},\"argument\":{\"name\":\"name\",\"value\":\"v\"}}")]) == ["{\"result\":{\"completion\":{\"values\":[${Str.join_with(values, ",")}],\"total\":150,\"hasMore\":true}},\"jsonrpc\":\"2.0\",\"id\":19}"]
}
expect (Engine.receive(server, Engine.Session.new, {}, complete("20", "{\"ref\":{\"type\":\"ref/resource\",\"uri\":\"file:///{a}/{b}\"},\"argument\":{\"name\":\"b\",\"value\":\"q\"},\"context\":{\"arguments\":{\"a\":\"x\"}}}"))).calls.len() == 1
expect run([complete("21", "{\"ref\":{\"type\":\"ref/resource\",\"uri\":\"file:///a\"},\"argument\":{\"name\":\"b\",\"value\":\"q\"}}")]) == [empty_completion("21")]
expect run([complete("22", "{\"ref\":{\"type\":\"ref/resource\",\"uri\":\"file:///none\"},\"argument\":{\"name\":\"b\",\"value\":\"q\"}}")]) == ["{\"jsonrpc\":\"2.0\",\"id\":22,\"error\":{\"code\":-32602,\"message\":\"Resource template file:///none not found\"}}"]
expect Session.first_has(run([complete("23", "{\"ref\":{\"type\":\"ref/bogus\"},\"argument\":{\"name\":\"b\",\"value\":\"q\"}}")]), "{\"jsonrpc\":\"2.0\",\"id\":23,\"error\":{\"code\":-32602,")
expect run([complete("24", "{\"ref\":{\"type\":\"ref/resource\",\"uri\":\"file:///{a}/{b}\"},\"argument\":{\"name\":\"a\",\"value\":\"q\"}}")]) == [empty_completion("24")]
expect run([complete("25", "{\"ref\":{\"type\":\"ref/prompt\",\"name\":\"plain\"},\"argument\":{\"name\":\"x\",\"value\":\"q\"}}")]) == [empty_completion("25")]
