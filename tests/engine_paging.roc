app [main!] { pkg: "../package/main.roc" }

import pkg.JsonValue
import pkg.Tool
import pkg.ToolResult
import pkg.Resource
import pkg.ResourceContents
import pkg.ResourceTemplate
import pkg.Prompt
import pkg.Outcome
import pkg.Ctx
import pkg.Server
import pkg.Engine
import pkg.UriTemplate
import Support/Session

main! = |_args| Ok({})

## Pagination (DESIGN 5, row Pagination). Off by default: all items, cursor ignored (JS).
## With `with_page_size(n)` the cursor is the decimal offset.

any! : {}, Ctx, JsonValue => ({}, Outcome(ToolResult))
any! = |s, _c, _a| (s, Outcome.done(ToolResult.text("")))

read! : {}, Ctx, Str => ({}, Outcome(List(ResourceContents)))
read! = |s, _c, _u| (s, Outcome.done([]))

read_t! : {}, Ctx, Str, UriTemplate.Vars => ({}, Outcome(List(ResourceContents)))
read_t! = |s, _c, _u, _v| (s, Outcome.done([]))

list! : {}, Ctx => ({}, List(Resource))
list! = |s, _c| (s, [])

p! : {}, Ctx, {} => ({}, Outcome(Prompt.Result))
p! = |s, _c, _a| (s, Outcome.done({ description: Err(None), messages: [] }))

base : Server({})
base =
	Server.new({ name: "p", version: "1" })
		.tool_json(Tool.new("t1"), any!)
		.tool_json(Tool.new("t2"), any!)
		.tool_json(Tool.new("t3"), any!)
		.resource(Resource.new("file:///r1", "r1"), read!)
		.resource(Resource.new("file:///r2", "r2"), read!)
		.resource_template(ResourceTemplate.new("file:///a/{x}", "ta"), read_t!)
		.template_list("ta", list!)
		.resource_template(ResourceTemplate.new("file:///b/{x}", "tb"), read_t!)
		.resource_template(ResourceTemplate.new("file:///c/{x}", "tc"), read_t!)
		.prompt(Prompt.new("p1"), p!)
		.prompt(Prompt.new("p2"), p!)
		.prompt(Prompt.new("p3"), p!)

paged : Server({})
paged = base.with_page_size(2)

## resources/list: the template "ta" lists r3.
script : Engine.Call({}) -> Outcome(JsonValue)
script = |_call| Outcome.done(Array([Array([Resource.new("file:///a/3", "r3").to_json()])]))

list_req : Str, Str -> Str
list_req = |method, cursor| "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"${method}\",\"params\":{${cursor}}}"

names : List(Str), Str -> List(Str)
names = |out, key| match out {
	[line] =>
		match Session.json(line).get_or_null("result").get_or_null(key) {
			Array(items) => items.map(|i| i.get_or_null("name").as_str() ?? "?")
			_ => ["no items"]
		}
	_ => ["no line"]
}

next_cursor : List(Str) -> JsonValue
next_cursor = |out| match out {
	[line] => Session.json(line).get_or_null("result").get_or_null("nextCursor")
	_ => Null
}

# Off: everything, and any cursor is ignored.
expect names(Session.run(base, {}, [list_req("tools/list", "\"cursor\":\"zzz\"")], script), "tools") == ["t1", "t2", "t3"]
expect next_cursor(Session.run(base, {}, [list_req("tools/list", "")], script)) == Null

# On: pages of 2 with a decimal cursor.
expect {
	first = Session.run(paged, {}, [list_req("tools/list", "")], script)
	second = Session.run(paged, {}, [list_req("tools/list", "\"cursor\":\"2\"")], script)
	names(first, "tools") == ["t1", "t2"] and next_cursor(first) == String("2") and names(second, "tools") == ["t3"] and next_cursor(second) == Null
}
expect names(Session.run(paged, {}, [list_req("prompts/list", "\"cursor\":\"2\"")], script), "prompts") == ["p3"]
expect names(Session.run(paged, {}, [list_req("resources/templates/list", "")], script), "resourceTemplates") == ["ta", "tb"]

# resources/list pages the merged list (static, then template lists).
expect {
	second = Session.run(paged, {}, [list_req("resources/list", "\"cursor\":\"2\"")], script)
	names(second, "resources") == ["r3"] and next_cursor(second) == Null
}
expect next_cursor(Session.run(paged, {}, [list_req("resources/list", "")], script)) == String("2")

# Invalid cursors: -32602.
invalid_cursor : Str
invalid_cursor = "{\"jsonrpc\":\"2.0\",\"id\":1,\"error\":{\"code\":-32602,\"message\":\"Invalid cursor\"}}"

expect Session.run(paged, {}, [list_req("tools/list", "\"cursor\":\"abc\"")], script) == [invalid_cursor]
expect Session.run(paged, {}, [list_req("tools/list", "\"cursor\":\"9\"")], script) == [invalid_cursor]
expect Session.run(paged, {}, [list_req("tools/list", "\"cursor\":2")], script) == [invalid_cursor]
expect Session.run(paged, {}, [list_req("resources/list", "\"cursor\":\"-1\"")], script) == [invalid_cursor]
