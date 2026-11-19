app [main!] { pkg: "../package/main.roc" }

import pkg.JsonValue
import pkg.Tool
import pkg.ToolResult
import pkg.Outcome
import pkg.McpError
import pkg.LogLevel
import pkg.Ctx
import pkg.Server
import pkg.Engine
import pkg.Input
import Support/Session

main! = |_args| Ok({})

## logging/setLevel and the Ctx sends (DESIGN 4.4; 5, rows logging and notifications in),
## on_notification and on_request. Notification lines are JS SDK 2.0.0 transcripts
## (.tmp/s4/js/full1.in), byte for byte. The sends themselves are effectful; tests check the
## pure `_line` functions they write with.

any! : U64, Ctx, JsonValue => (U64, Outcome(ToolResult))
any! = |s, _c, _a| (s, Outcome.done(ToolResult.text("")))

seen! : U64, Ctx, JsonValue => U64
seen! = |s, _c, _p| s + 1

custom! : U64, Ctx, JsonValue => (U64, Outcome(JsonValue))
custom! = |s, _c, p| (s, Outcome.done(p))

server : Server(U64)
server =
	Server.new({ name: "f", version: "2" })
		.with_logging()
		.tool_json(Tool.new("logs"), any!)
		.on_notification("notifications/roots/list_changed", seen!)
		.on_notification("notifications/initialized", seen!)
		.on_request("x/echo", custom!)

quiet : Server(U64)
quiet = Server.new({ name: "q", version: "1" }).tool_json(Tool.new("logs"), any!)

call_line : Str -> Str
call_line = |extra| "{\"jsonrpc\":\"2.0\",\"id\":19,\"method\":\"tools/call\",\"params\":{\"name\":\"logs\"${extra}}}"

set_level : Str -> Str
set_level = |l| "{\"jsonrpc\":\"2.0\",\"id\":20,\"method\":\"logging/setLevel\",\"params\":{\"level\":\"${l}\"}}"

## The Ctx of the tools/call after `lines`.
ctx_after : Server(U64), List(Str), Str -> Ctx
ctx_after = |srv, lines, extra| {
	r = Session.drive(srv, Engine.Session.new, 0, lines, Session.no_calls, 0)
	step = Engine.receive(srv, r.session, 0, call_line(extra))
	match step.calls {
		[c] => c.ctx
		_ => crash "no call"
	}
}

info : LogLevel
info = LogLevel.from_str("info") ?? Debug

err : LogLevel
err = LogLevel.from_str("error") ?? Debug

# With no level set, everything is sent.
expect {
	c = ctx_after(server, [], "")
	c.log_line(info, String("info msg")) == Ok("{\"jsonrpc\":\"2.0\",\"method\":\"notifications/message\",\"params\":{\"level\":\"info\",\"data\":\"info msg\"}}")
		and c.log_line(err, Object([("e", Number("1"))])) == Ok("{\"jsonrpc\":\"2.0\",\"method\":\"notifications/message\",\"params\":{\"level\":\"error\",\"data\":{\"e\":1}}}")
}

# logging/setLevel stores the level; lower levels are dropped.
expect Session.run(server, 0, [set_level("warning")], Session.no_calls) == ["{\"result\":{},\"jsonrpc\":\"2.0\",\"id\":20}"]
expect {
	c = ctx_after(server, [set_level("warning")], "")
	c.log_line(info, String("x")) == Err(Skip) and c.log_line(err, String("x")).is_ok()
}

# An unknown level: -32602 (JS: -32603 with zod's issue list); the level is unchanged.
expect Session.first_has(Session.run(server, 0, [set_level("loud")], Session.no_calls), "{\"jsonrpc\":\"2.0\",\"id\":20,\"error\":{\"code\":-32602,")
expect {
	c = ctx_after(server, [set_level("error"), set_level("loud")], "")
	c.log_line(LogLevel.from_str("warning") ?? Debug, String("x")) == Err(Skip)
}

# Without with_logging: logging/setLevel is -32601 and log! sends nothing.
expect Session.run(quiet, 0, [set_level("debug")], Session.no_calls) == ["{\"jsonrpc\":\"2.0\",\"id\":20,\"error\":{\"code\":-32601,\"message\":\"Method not found\"}}"]
expect (ctx_after(quiet, [], "")).log_line(err, String("x")) == Err(Skip)

# Progress only with a progress token.
expect {
	c = ctx_after(server, [], ",\"_meta\":{\"progressToken\":\"pt\"}")
	c.progress_line({ progress: 1, total: Ok(2), message: Ok("half") }) == Ok("{\"jsonrpc\":\"2.0\",\"method\":\"notifications/progress\",\"params\":{\"progressToken\":\"pt\",\"progress\":1,\"total\":2,\"message\":\"half\"}}")
		and c.progress_line({ progress: 0.5, total: Err(None), message: Err(None) }) == Ok("{\"jsonrpc\":\"2.0\",\"method\":\"notifications/progress\",\"params\":{\"progressToken\":\"pt\",\"progress\":0.5}}")
}
expect (ctx_after(server, [], "")).progress_line({ progress: 1, total: Err(None), message: Err(None) }) == Err(Skip)
expect (ctx_after(server, [], ",\"_meta\":{\"progressToken\":7}")).progress_token() == Ok(Number("7"))

# list_changed, resources/updated and custom notifications.
expect {
	c = ctx_after(server, [], "")
	c.list_changed_line(Tools) == "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/tools/list_changed\"}"
		and c.list_changed_line(Resources) == "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/resources/list_changed\"}"
		and c.list_changed_line(Prompts) == "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/prompts/list_changed\"}"
		and c.resource_updated_line("file:///a") == "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/resources/updated\",\"params\":{\"uri\":\"file:///a\"}}"
		and c.notify_line("notifications/elicitation/complete", Object([("elicitationId", String("e"))])) == "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/elicitation/complete\",\"params\":{\"elicitationId\":\"e\"}}"
}

# Client info and capabilities from initialize reach the Ctx.
expect {
	init = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2025-06-18\",\"capabilities\":{\"roots\":{}},\"clientInfo\":{\"name\":\"c\",\"version\":\"9\"}}}"
	c = ctx_after(server, [init], "")
	c.has_client_capability("roots") and !(c.has_client_capability("sampling")) and c.client_info().get_or_null("version") == String("9") and c.protocol_version() == "2025-06-18" and c.meta() == Null
}

# Notifications with a handler become calls with no request id; finishing them writes nothing.
expect {
	step = Engine.receive(server, Engine.Session.new, 0, "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/roots/list_changed\",\"params\":{}}")
	match step.calls {
		[c] => c.request_id == Err(Notification) and c.ctx.request_id() == Err(Notification) and (Engine.finish(server, step.session, c, Outcome.done(Null), 0)).out == []
		_ => Bool.False
	}
}

# notifications/initialized marks the session and also reaches its handler.
expect {
	step = Engine.receive(server, Engine.Session.new, 0, "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}")
	step.session.is_initialized() and step.calls.len() == 1
}

# Notifications without a handler, and client progress notifications, are ignored.
expect (Engine.receive(server, Engine.Session.new, 0, "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/progress\",\"params\":{\"progressToken\":1,\"progress\":1}}")).calls.is_empty()

# on_request: a custom method; its result is sent as returned; errors pass through.
expect Session.run(server, 0, ["{\"jsonrpc\":\"2.0\",\"id\":5,\"method\":\"x/echo\",\"params\":{\"a\":[1]}}"], |c| Outcome.done(c.message.get_or_null("params"))) == ["{\"result\":{\"a\":[1]},\"jsonrpc\":\"2.0\",\"id\":5}"]
expect Session.run(server, 0, ["{\"jsonrpc\":\"2.0\",\"id\":5,\"method\":\"x/echo\"}"], |_| Outcome.fail(McpError.new(-32000, "custom"))) == ["{\"jsonrpc\":\"2.0\",\"id\":5,\"error\":{\"code\":-32000,\"message\":\"custom\"}}"]

# A custom method may not ask for input (only tools/call, prompts/get and resources/read may).
expect Session.first_has(Session.run(server, 0, ["{\"jsonrpc\":\"2.0\",\"id\":5,\"method\":\"x/echo\"}"], |_| Outcome.need_input(Input.Required.one("r", ListRoots))), "{\"jsonrpc\":\"2.0\",\"id\":5,\"error\":{\"code\":-32603,")
