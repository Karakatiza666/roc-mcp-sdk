app [main!] { pkg: "../package/main.roc" }

import pkg.JsonValue
import pkg.LogLevel
import pkg.Ctx
import pkg.Server
import pkg.Engine
import pkg.Tool
import pkg.ToolResult
import pkg.Input
import pkg.Outcome
import Support/Session
import Support/Modern

main! = |_args| Ok({})

## The 2026-07-28 era (DESIGN 5, rows "input_required" and "subscriptions/listen"; 4.4, the
## routing of the Ctx sends). Expected lines are JS SDK 2.0.0 stdio transcripts of
## `.tmp/s5/js/l0.mjs` (see engine_modern.roc). The handler sends are effectful; tests check
## the pure `_lines` twins on the call's Ctx against the lines JS wrote.

run : Server({}), List(Str) -> List(Str)
run = |srv, lines| Session.run(srv, {}, lines, Modern.script)

drive : List(Str) -> Session.Run
drive = |lines| Session.drive(Modern.server, Engine.Session.new, {}, lines, Modern.script, 0)

## The Ctx of the call that `line` makes after `lines`.
ctx_after : List(Str), Str -> Ctx
ctx_after = |lines, line| {
	step = Engine.receive(Modern.server, drive(lines).session, {}, line)
	match step.calls {
		[c] => c.ctx
		_ => crash "ctx_after: no call"
	}
}

# input_required: the capability check (-32021 with the missing capabilities, first key first;
# a bare `elicitation: {}` declares form mode), the result with inputRequests and requestState,
# the retry whose inputResponses reach Ctx.input, the verifier (-32602 with data.reason, also for
# a non-string requestState), state-only results, wrapped responses dropped (the handler asks
# again), and retry fields ignored on other methods.
expect Session.same(run(Modern.server, input_in), input_out)
expect run(Modern.server, input_in.take_first(2)) == input_out.take_first(2)

# Without a verifier any string state is accepted; a non-string one is still refused.
expect Session.same(run(Modern.plain, plain_in), plain_out)

# A retry's Ctx: round 1, the answers, the verified state.
expect {
	c = ctx_after([], input_in.get(2) ?? "")
	c.round() == 1 and c.request_state() == Ok("good1") and c.input("confirm") == Answered(Session.json("{\"action\":\"accept\",\"content\":{}}")) and c.input("other") == NotAsked
}

# A first call: round 0, nothing answered.
expect {
	c = ctx_after([], input_in.get(1) ?? "")
	c.round() == 0 and c.input("roots") == NotAsked and c.request_state() == Err(None)
}

# The request's Ctx in the modern era: capabilities, client info and version from the envelope;
# `meta` without the reserved keys; no log line without `logLevel`.
expect {
	line = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"notify\",\"_meta\":{\"progressToken\":7,\"io.modelcontextprotocol/protocolVersion\":\"2026-07-28\",\"io.modelcontextprotocol/clientCapabilities\":{\"roots\":{}},\"io.modelcontextprotocol/clientInfo\":{\"name\":\"t\",\"version\":\"1\"}}}}"
	c = ctx_after([], line)
	info = LogLevel.from_str("emergency") ?? Debug
	c.era() == Modern
		and c.has_client_capability("roots")
		and !(c.has_client_capability("sampling"))
		and c.client_info() == Session.json("{\"name\":\"t\",\"version\":\"1\"}")
		and c.protocol_version() == "2026-07-28"
		and c.meta() == Session.json("{\"progressToken\":7}")
		and c.progress_token() == Ok(Number("7"))
		and c.log_line(info, String("x")) == Err(Skip)
}

# With `logLevel` in the envelope, log lines at that level and above go out (not routed).
expect {
	c = ctx_after([], listen_in.get(4) ?? "")
	info = LogLevel.from_str("info") ?? Debug
	debug = LogLevel.from_str("debug") ?? Debug
	[c.log_line(info, String("hello"))] == listen_sends.drop_first(2).map(|l| Ok(l)) and c.log_line(debug, String("x")) == Err(Skip)
}

# subscriptions/listen: the acknowledgement with the honoured subset (false flags dropped,
# unknown keys ignored), the call results, errors for a bad filter, a missing or invalid
# envelope and an unsupported version.
expect Session.same(run(Modern.server, listen_in), listen_out)
expect run(Modern.server, listen_in.take_first(2)) == listen_out.take_first(2)

# The change notifications of a handler go to the subscriptions that asked for them, stamped
# with the subscription id; none for a URI nobody listens to.
expect {
	c = ctx_after(listen_in.take_first(2), listen_in.get(2) ?? "")
	c.list_changed_lines(Tools).concat(c.resource_updated_lines("res://a")).concat(c.resource_updated_lines("res://b")) == listen_sends.take_first(2)
		and c.list_changed_lines(Prompts) == ["{\"jsonrpc\":\"2.0\",\"method\":\"notifications/prompts/list_changed\",\"params\":{\"_meta\":{\"io.modelcontextprotocol/subscriptionId\":1}}}"]
		and c.list_changed_lines(Resources) == ["{\"jsonrpc\":\"2.0\",\"method\":\"notifications/resources/list_changed\",\"params\":{\"_meta\":{\"io.modelcontextprotocol/subscriptionId\":\"two\"}}}"]
		and c.notify_lines("notifications/tools/list_changed", Object([])) == listen_sends.take_first(1)
		and c.notify_lines("x/other", Object([])) == ["{\"jsonrpc\":\"2.0\",\"method\":\"x/other\",\"params\":{}}"]
}

# notifications/cancelled for a listen id ends that subscription; close sends the final
# result of each one still open.
expect {
	c = ctx_after(listen_in.take_first(4), listen_in.get(4) ?? "")
	c.list_changed_lines(Tools) == [] and c.resource_updated_lines("res://a") == []
}
expect Engine.close(drive(listen_in).session) == listen_close
expect {
	s = drive(close_in).session
	run(Modern.server, close_in) == close_out and Engine.close(s) == close_close
}

# A 2025 session routes nothing: one line per send, as before.
expect {
	init = "{\"jsonrpc\":\"2.0\",\"id\":0,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2025-11-25\",\"capabilities\":{},\"clientInfo\":{\"name\":\"t\",\"version\":\"1\"}}}"
	c = ctx_after([init], "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"notify\"}}")
	c.list_changed_lines(Tools) == [c.list_changed_line(Tools)] and Engine.close(drive([init]).session) == []
}

# The subscription limit: the 1025th listen gets -32603 "Subscription limit reached".
expect {
	listen_line = |i| "{\"jsonrpc\":\"2.0\",\"id\":${i.to_str()},\"method\":\"subscriptions/listen\",\"params\":{\"notifications\":{},${Modern.envelope}}}"
	full : List(Str)
	full = (0.U64..<1024).iter().map(listen_line).collect()
	r = Session.drive(Modern.server, Engine.Session.new, {}, full, Modern.script, 0)
	more = Engine.receive(Modern.server, r.session, {}, listen_line(5000.U64))
	r.out.len() == 1024 and more.out == ["{\"jsonrpc\":\"2.0\",\"id\":5000,\"error\":{\"code\":-32603,\"message\":\"Subscription limit reached\"}}"]
}

input_in : List(Str)
input_in = [
	"{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"ask\",\"arguments\":{},\"_meta\":{\"io.modelcontextprotocol/protocolVersion\":\"2026-07-28\",\"io.modelcontextprotocol/clientCapabilities\":{},\"io.modelcontextprotocol/clientInfo\":{\"name\":\"t\",\"version\":\"1\"}}}}",
	"{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"ask\",\"arguments\":{},\"_meta\":{\"io.modelcontextprotocol/protocolVersion\":\"2026-07-28\",\"io.modelcontextprotocol/clientCapabilities\":{\"roots\":{},\"elicitation\":{}},\"io.modelcontextprotocol/clientInfo\":{\"name\":\"t\",\"version\":\"1\"}}}}",
	"{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/call\",\"params\":{\"name\":\"ask\",\"arguments\":{},\"inputResponses\":{\"roots\":{\"roots\":[]},\"confirm\":{\"action\":\"accept\",\"content\":{}}},\"requestState\":\"good1\",\"_meta\":{\"io.modelcontextprotocol/protocolVersion\":\"2026-07-28\",\"io.modelcontextprotocol/clientCapabilities\":{\"roots\":{},\"elicitation\":{}},\"io.modelcontextprotocol/clientInfo\":{\"name\":\"t\",\"version\":\"1\"}}}}",
	"{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"tools/call\",\"params\":{\"name\":\"ask\",\"arguments\":{},\"inputResponses\":{\"roots\":{\"roots\":[]}},\"requestState\":\"bad\",\"_meta\":{\"io.modelcontextprotocol/protocolVersion\":\"2026-07-28\",\"io.modelcontextprotocol/clientCapabilities\":{\"roots\":{},\"elicitation\":{}},\"io.modelcontextprotocol/clientInfo\":{\"name\":\"t\",\"version\":\"1\"}}}}",
	"{\"jsonrpc\":\"2.0\",\"id\":5,\"method\":\"tools/call\",\"params\":{\"name\":\"url\",\"arguments\":{},\"_meta\":{\"io.modelcontextprotocol/protocolVersion\":\"2026-07-28\",\"io.modelcontextprotocol/clientCapabilities\":{\"elicitation\":{}},\"io.modelcontextprotocol/clientInfo\":{\"name\":\"t\",\"version\":\"1\"}}}}",
	"{\"jsonrpc\":\"2.0\",\"id\":6,\"method\":\"tools/call\",\"params\":{\"name\":\"url\",\"arguments\":{},\"_meta\":{\"io.modelcontextprotocol/protocolVersion\":\"2026-07-28\",\"io.modelcontextprotocol/clientCapabilities\":{\"elicitation\":{\"url\":{}}},\"io.modelcontextprotocol/clientInfo\":{\"name\":\"t\",\"version\":\"1\"}}}}",
	"{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"tools/call\",\"params\":{\"name\":\"sample\",\"arguments\":{},\"_meta\":{\"io.modelcontextprotocol/protocolVersion\":\"2026-07-28\",\"io.modelcontextprotocol/clientCapabilities\":{\"sampling\":{}},\"io.modelcontextprotocol/clientInfo\":{\"name\":\"t\",\"version\":\"1\"}}}}",
	"{\"jsonrpc\":\"2.0\",\"id\":8,\"method\":\"tools/call\",\"params\":{\"name\":\"stateonly\",\"arguments\":{},\"_meta\":{\"io.modelcontextprotocol/protocolVersion\":\"2026-07-28\",\"io.modelcontextprotocol/clientCapabilities\":{},\"io.modelcontextprotocol/clientInfo\":{\"name\":\"t\",\"version\":\"1\"}}}}",
	"{\"jsonrpc\":\"2.0\",\"id\":9,\"method\":\"tools/call\",\"params\":{\"name\":\"stateonly\",\"arguments\":{},\"requestState\":\"good-only\",\"_meta\":{\"io.modelcontextprotocol/protocolVersion\":\"2026-07-28\",\"io.modelcontextprotocol/clientCapabilities\":{},\"io.modelcontextprotocol/clientInfo\":{\"name\":\"t\",\"version\":\"1\"}}}}",
	"{\"jsonrpc\":\"2.0\",\"id\":10,\"method\":\"tools/call\",\"params\":{\"name\":\"ask\",\"arguments\":{},\"inputResponses\":{\"roots\":{\"method\":\"roots/list\",\"result\":{\"roots\":[]}}},\"requestState\":\"good1\",\"_meta\":{\"io.modelcontextprotocol/protocolVersion\":\"2026-07-28\",\"io.modelcontextprotocol/clientCapabilities\":{\"roots\":{},\"elicitation\":{}},\"io.modelcontextprotocol/clientInfo\":{\"name\":\"t\",\"version\":\"1\"}}}}",
	"{\"jsonrpc\":\"2.0\",\"id\":11,\"method\":\"tools/call\",\"params\":{\"name\":\"ask\",\"arguments\":{},\"requestState\":5,\"_meta\":{\"io.modelcontextprotocol/protocolVersion\":\"2026-07-28\",\"io.modelcontextprotocol/clientCapabilities\":{\"roots\":{},\"elicitation\":{}},\"io.modelcontextprotocol/clientInfo\":{\"name\":\"t\",\"version\":\"1\"}}}}",
	"{\"jsonrpc\":\"2.0\",\"id\":12,\"method\":\"tools/call\",\"params\":{\"name\":\"ask\",\"arguments\":{},\"_meta\":{\"io.modelcontextprotocol/protocolVersion\":\"2026-07-28\",\"io.modelcontextprotocol/clientCapabilities\":{\"roots\":{},\"elicitation\":{\"url\":{}}},\"io.modelcontextprotocol/clientInfo\":{\"name\":\"t\",\"version\":\"1\"}}}}",
	"{\"jsonrpc\":\"2.0\",\"id\":13,\"method\":\"x/echo\",\"params\":{\"requestState\":\"bad\",\"inputResponses\":{\"k\":{}},\"_meta\":{\"io.modelcontextprotocol/protocolVersion\":\"2026-07-28\",\"io.modelcontextprotocol/clientCapabilities\":{},\"io.modelcontextprotocol/clientInfo\":{\"name\":\"t\",\"version\":\"1\"}}}}",
]

input_out : List(Str)
input_out = [
	"{\"jsonrpc\":\"2.0\",\"id\":1,\"error\":{\"code\":-32021,\"message\":\"Cannot request input 'roots' (roots/list): the request's client capabilities do not declare the required capability\",\"data\":{\"requiredCapabilities\":{\"roots\":{}}}}}",
	"{\"result\":{\"resultType\":\"input_required\",\"inputRequests\":{\"roots\":{\"method\":\"roots/list\"},\"confirm\":{\"method\":\"elicitation/create\",\"params\":{\"message\":\"Go?\",\"requestedSchema\":{\"type\":\"object\",\"properties\":{}},\"mode\":\"form\"}}},\"requestState\":\"good1\",\"_meta\":{\"io.modelcontextprotocol/serverInfo\":{\"name\":\"m\",\"version\":\"1\"}}},\"jsonrpc\":\"2.0\",\"id\":2}",
	"{\"result\":{\"content\":[{\"type\":\"text\",\"text\":\"answers {\\\"roots\\\":{\\\"roots\\\":[]},\\\"confirm\\\":{\\\"action\\\":\\\"accept\\\",\\\"content\\\":{}}} state good1\"}],\"resultType\":\"complete\",\"_meta\":{\"io.modelcontextprotocol/serverInfo\":{\"name\":\"m\",\"version\":\"1\"}}},\"jsonrpc\":\"2.0\",\"id\":3}",
	"{\"jsonrpc\":\"2.0\",\"id\":4,\"error\":{\"code\":-32602,\"message\":\"Invalid or expired requestState\",\"data\":{\"reason\":\"invalid_request_state\"}}}",
	"{\"jsonrpc\":\"2.0\",\"id\":5,\"error\":{\"code\":-32021,\"message\":\"Cannot request input 'open' (elicitation/create): the request's client capabilities do not declare the required capability\",\"data\":{\"requiredCapabilities\":{\"elicitation\":{\"url\":{}}}}}}",
	"{\"result\":{\"resultType\":\"input_required\",\"inputRequests\":{\"open\":{\"method\":\"elicitation/create\",\"params\":{\"message\":\"Open\",\"url\":\"https://x.test/a\",\"mode\":\"url\"}}},\"_meta\":{\"io.modelcontextprotocol/serverInfo\":{\"name\":\"m\",\"version\":\"1\"}}},\"jsonrpc\":\"2.0\",\"id\":6}",
	"{\"jsonrpc\":\"2.0\",\"id\":7,\"error\":{\"code\":-32021,\"message\":\"Cannot request input 's' (sampling/createMessage): the request's client capabilities do not declare the required capability\",\"data\":{\"requiredCapabilities\":{\"sampling\":{\"tools\":{}}}}}}",
	"{\"result\":{\"resultType\":\"input_required\",\"requestState\":\"good-only\",\"_meta\":{\"io.modelcontextprotocol/serverInfo\":{\"name\":\"m\",\"version\":\"1\"}}},\"jsonrpc\":\"2.0\",\"id\":8}",
	"{\"result\":{\"content\":[{\"type\":\"text\",\"text\":\"state good-only\"}],\"resultType\":\"complete\",\"_meta\":{\"io.modelcontextprotocol/serverInfo\":{\"name\":\"m\",\"version\":\"1\"}}},\"jsonrpc\":\"2.0\",\"id\":9}",
	"{\"result\":{\"resultType\":\"input_required\",\"inputRequests\":{\"roots\":{\"method\":\"roots/list\"},\"confirm\":{\"method\":\"elicitation/create\",\"params\":{\"message\":\"Go?\",\"requestedSchema\":{\"type\":\"object\",\"properties\":{}},\"mode\":\"form\"}}},\"requestState\":\"good1\",\"_meta\":{\"io.modelcontextprotocol/serverInfo\":{\"name\":\"m\",\"version\":\"1\"}}},\"jsonrpc\":\"2.0\",\"id\":10}",
	"{\"jsonrpc\":\"2.0\",\"id\":11,\"error\":{\"code\":-32602,\"message\":\"Invalid or expired requestState\",\"data\":{\"reason\":\"invalid_request_state\"}}}",
	"{\"jsonrpc\":\"2.0\",\"id\":12,\"error\":{\"code\":-32021,\"message\":\"Cannot request input 'confirm' (elicitation/create): the request's client capabilities do not declare the required capability\",\"data\":{\"requiredCapabilities\":{\"elicitation\":{\"form\":{}}}}}}",
	"{\"result\":{\"got\":null,\"resultType\":\"complete\",\"_meta\":{\"io.modelcontextprotocol/serverInfo\":{\"name\":\"m\",\"version\":\"1\"}}},\"jsonrpc\":\"2.0\",\"id\":13}",
]

plain_in : List(Str)
plain_in = [
	"{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"stateonly\",\"arguments\":{},\"requestState\":\"anything\",\"_meta\":{\"io.modelcontextprotocol/protocolVersion\":\"2026-07-28\",\"io.modelcontextprotocol/clientCapabilities\":{},\"io.modelcontextprotocol/clientInfo\":{\"name\":\"t\",\"version\":\"1\"}}}}",
	"{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"stateonly\",\"arguments\":{},\"requestState\":7,\"_meta\":{\"io.modelcontextprotocol/protocolVersion\":\"2026-07-28\",\"io.modelcontextprotocol/clientCapabilities\":{},\"io.modelcontextprotocol/clientInfo\":{\"name\":\"t\",\"version\":\"1\"}}}}",
]

plain_out : List(Str)
plain_out = [
	"{\"result\":{\"content\":[{\"type\":\"text\",\"text\":\"state anything\"}],\"resultType\":\"complete\",\"_meta\":{\"io.modelcontextprotocol/serverInfo\":{\"name\":\"m\",\"version\":\"1\"}}},\"jsonrpc\":\"2.0\",\"id\":1}",
	"{\"jsonrpc\":\"2.0\",\"id\":2,\"error\":{\"code\":-32602,\"message\":\"Invalid or expired requestState\",\"data\":{\"reason\":\"invalid_request_state\"}}}",
]

listen_in : List(Str)
listen_in = [
	"{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"subscriptions/listen\",\"params\":{\"notifications\":{\"toolsListChanged\":true,\"promptsListChanged\":true,\"resourcesListChanged\":false,\"resourceSubscriptions\":[\"res://a\"]},\"_meta\":{\"io.modelcontextprotocol/protocolVersion\":\"2026-07-28\",\"io.modelcontextprotocol/clientCapabilities\":{},\"io.modelcontextprotocol/clientInfo\":{\"name\":\"t\",\"version\":\"1\"}}}}",
	"{\"jsonrpc\":\"2.0\",\"id\":\"two\",\"method\":\"subscriptions/listen\",\"params\":{\"notifications\":{\"resourcesListChanged\":true,\"extra\":1},\"_meta\":{\"io.modelcontextprotocol/protocolVersion\":\"2026-07-28\",\"io.modelcontextprotocol/clientCapabilities\":{},\"io.modelcontextprotocol/clientInfo\":{\"name\":\"t\",\"version\":\"1\"}}}}",
	"{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/call\",\"params\":{\"name\":\"notify\",\"arguments\":{},\"_meta\":{\"io.modelcontextprotocol/protocolVersion\":\"2026-07-28\",\"io.modelcontextprotocol/clientCapabilities\":{},\"io.modelcontextprotocol/clientInfo\":{\"name\":\"t\",\"version\":\"1\"}}}}",
	"{\"jsonrpc\":\"2.0\",\"method\":\"notifications/cancelled\",\"params\":{\"requestId\":1}}",
	"{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"tools/call\",\"params\":{\"name\":\"notify\",\"arguments\":{},\"_meta\":{\"io.modelcontextprotocol/protocolVersion\":\"2026-07-28\",\"io.modelcontextprotocol/clientCapabilities\":{},\"io.modelcontextprotocol/clientInfo\":{\"name\":\"t\",\"version\":\"1\"},\"io.modelcontextprotocol/logLevel\":\"info\"}}}",
	"{\"jsonrpc\":\"2.0\",\"id\":5,\"method\":\"subscriptions/listen\",\"params\":{\"_meta\":{\"io.modelcontextprotocol/protocolVersion\":\"2026-07-28\",\"io.modelcontextprotocol/clientCapabilities\":{},\"io.modelcontextprotocol/clientInfo\":{\"name\":\"t\",\"version\":\"1\"}}}}",
	"{\"jsonrpc\":\"2.0\",\"id\":6,\"method\":\"subscriptions/listen\",\"params\":{\"notifications\":{}}}",
	"{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"subscriptions/listen\",\"params\":{\"notifications\":{},\"_meta\":{\"io.modelcontextprotocol/protocolVersion\":\"2099-01-01\",\"io.modelcontextprotocol/clientCapabilities\":{},\"io.modelcontextprotocol/clientInfo\":{\"name\":\"t\",\"version\":\"1\"}}}}",
	"{\"jsonrpc\":\"2.0\",\"id\":8,\"method\":\"subscriptions/listen\",\"params\":{\"notifications\":{},\"_meta\":{\"io.modelcontextprotocol/protocolVersion\":\"2026-07-28\"}}}",
	"{\"jsonrpc\":\"2.0\",\"id\":9,\"method\":\"subscriptions/listen\",\"params\":{\"notifications\":{\"toolsListChanged\":\"yes\"},\"_meta\":{\"io.modelcontextprotocol/protocolVersion\":\"2026-07-28\",\"io.modelcontextprotocol/clientCapabilities\":{},\"io.modelcontextprotocol/clientInfo\":{\"name\":\"t\",\"version\":\"1\"}}}}",
]

listen_out : List(Str)
listen_out = [
	"{\"jsonrpc\":\"2.0\",\"method\":\"notifications/subscriptions/acknowledged\",\"params\":{\"notifications\":{\"toolsListChanged\":true,\"promptsListChanged\":true,\"resourceSubscriptions\":[\"res://a\"]},\"_meta\":{\"io.modelcontextprotocol/subscriptionId\":1}}}",
	"{\"jsonrpc\":\"2.0\",\"method\":\"notifications/subscriptions/acknowledged\",\"params\":{\"notifications\":{\"resourcesListChanged\":true},\"_meta\":{\"io.modelcontextprotocol/subscriptionId\":\"two\"}}}",
	"{\"result\":{\"content\":[{\"type\":\"text\",\"text\":\"notified\"}],\"resultType\":\"complete\",\"_meta\":{\"io.modelcontextprotocol/serverInfo\":{\"name\":\"m\",\"version\":\"1\"}}},\"jsonrpc\":\"2.0\",\"id\":3}",
	"{\"result\":{\"content\":[{\"type\":\"text\",\"text\":\"notified\"}],\"resultType\":\"complete\",\"_meta\":{\"io.modelcontextprotocol/serverInfo\":{\"name\":\"m\",\"version\":\"1\"}}},\"jsonrpc\":\"2.0\",\"id\":4}",
	"{\"jsonrpc\":\"2.0\",\"id\":5,\"error\":{\"code\":-32602,\"message\":\"Invalid params: 'notifications' is required and must be a valid SubscriptionFilter\"}}",
	"{\"jsonrpc\":\"2.0\",\"id\":6,\"error\":{\"code\":-32602,\"message\":\"Invalid _meta envelope: _meta: the per-request envelope is required on protocol revision 2026-07-28\"}}",
	"{\"jsonrpc\":\"2.0\",\"id\":7,\"error\":{\"code\":-32022,\"message\":\"Unsupported protocol version: 2099-01-01\",\"data\":{\"supported\":[\"2026-07-28\"],\"requested\":\"2099-01-01\"}}}",
	"{\"jsonrpc\":\"2.0\",\"id\":8,\"error\":{\"code\":-32602,\"message\":\"Invalid _meta envelope: io.modelcontextprotocol/clientCapabilities: missing\"}}",
	"{\"jsonrpc\":\"2.0\",\"id\":9,\"error\":{\"code\":-32602,\"message\":\"Invalid params: 'notifications' is required and must be a valid SubscriptionFilter\"}}",
]

listen_sends : List(Str)
listen_sends = [
	"{\"jsonrpc\":\"2.0\",\"method\":\"notifications/tools/list_changed\",\"params\":{\"_meta\":{\"io.modelcontextprotocol/subscriptionId\":1}}}",
	"{\"jsonrpc\":\"2.0\",\"method\":\"notifications/resources/updated\",\"params\":{\"uri\":\"res://a\",\"_meta\":{\"io.modelcontextprotocol/subscriptionId\":1}}}",
	"{\"jsonrpc\":\"2.0\",\"method\":\"notifications/message\",\"params\":{\"level\":\"info\",\"data\":\"hello\"}}",
]

listen_close : List(Str)
listen_close = [
	"{\"jsonrpc\":\"2.0\",\"id\":\"two\",\"result\":{\"resultType\":\"complete\",\"_meta\":{\"io.modelcontextprotocol/subscriptionId\":\"two\",\"io.modelcontextprotocol/serverInfo\":{\"name\":\"m\",\"version\":\"1\"}}}}",
]

close_in : List(Str)
close_in = [
	"{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"subscriptions/listen\",\"params\":{\"notifications\":{\"toolsListChanged\":true},\"_meta\":{\"io.modelcontextprotocol/protocolVersion\":\"2026-07-28\",\"io.modelcontextprotocol/clientCapabilities\":{},\"io.modelcontextprotocol/clientInfo\":{\"name\":\"t\",\"version\":\"1\"}}}}",
	"{\"jsonrpc\":\"2.0\",\"id\":\"b\",\"method\":\"subscriptions/listen\",\"params\":{\"notifications\":{},\"_meta\":{\"io.modelcontextprotocol/protocolVersion\":\"2026-07-28\",\"io.modelcontextprotocol/clientCapabilities\":{},\"io.modelcontextprotocol/clientInfo\":{\"name\":\"t\",\"version\":\"1\"}}}}",
]

close_out : List(Str)
close_out = [
	"{\"jsonrpc\":\"2.0\",\"method\":\"notifications/subscriptions/acknowledged\",\"params\":{\"notifications\":{\"toolsListChanged\":true},\"_meta\":{\"io.modelcontextprotocol/subscriptionId\":1}}}",
	"{\"jsonrpc\":\"2.0\",\"method\":\"notifications/subscriptions/acknowledged\",\"params\":{\"notifications\":{},\"_meta\":{\"io.modelcontextprotocol/subscriptionId\":\"b\"}}}",
]

close_close : List(Str)
close_close = [
	"{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"resultType\":\"complete\",\"_meta\":{\"io.modelcontextprotocol/subscriptionId\":1,\"io.modelcontextprotocol/serverInfo\":{\"name\":\"m\",\"version\":\"1\"}}}}",
	"{\"jsonrpc\":\"2.0\",\"id\":\"b\",\"result\":{\"resultType\":\"complete\",\"_meta\":{\"io.modelcontextprotocol/subscriptionId\":\"b\",\"io.modelcontextprotocol/serverInfo\":{\"name\":\"m\",\"version\":\"1\"}}}}",
]

# ---- Answers accumulate over the retries of one call (DESIGN 5, row input_required). The
# client sends inputResponses only for the latest inputRequests (spec, "InputResponses": the
# keys of the InputRequests map), and requestState is the server's place for context across
# retries, so the engine carries the earlier answers there ("mcp-sdk-carry:...", Modern.carry).

acc_server : Server({})
acc_server =
	Modern.server
		.tool_json(Tool.new("acc"), |s, _c, _a| (s, Outcome.done(ToolResult.text(""))))
		.tool_json(Tool.new("again"), |s, _c, _a| (s, Outcome.done(ToolResult.text(""))))

shown : Input.Answer -> Str
shown = |a| match a {
	Answered(j) => j.to_str()
	_ => "-"
}

## "acc" asks "roots", then "roots2" (with a state), then answers with both; "again" asks
## "roots" every time (the loop the diagnostic is for).
acc_script : Engine.Call({}) -> Outcome(JsonValue)
acc_script = |call| {
	c = call.ctx
	match Session.tool_name(call) {
		"acc" =>
			match (c.input("roots"), c.input("roots2")) {
				(NotAsked, _) => Outcome.need_input(Input.Required.one("roots", ListRoots))
				(_, NotAsked) => Outcome.need_input(Input.Required.one("roots2", ListRoots).with_state("good2"))
				(a, b) => Session.text("${shown(a)} | ${shown(b)} | ${c.request_state() ?? "none"}")
			}
		"again" => Outcome.need_input(Input.Required.one("roots", ListRoots))
		_ => Modern.script(call)
	}
}

acc_call : Str, Str, Str -> Str
acc_call = |id, tool, retry| "{\"jsonrpc\":\"2.0\",\"id\":${id},\"method\":\"tools/call\",\"params\":{\"name\":\"${tool}\",\"arguments\":{}${retry},\"_meta\":{\"io.modelcontextprotocol/protocolVersion\":\"2026-07-28\",\"io.modelcontextprotocol/clientCapabilities\":{\"roots\":{}},\"io.modelcontextprotocol/clientInfo\":{\"name\":\"t\",\"version\":\"1\"}}}}"

acc_run : List(Str) -> Session.Run
acc_run = |lines| Session.drive(acc_server, Engine.Session.new, {}, lines, acc_script, 0)

## `,"requestState":<the requestState of the first line of `out`>`, as the client echoes it.
state_of : List(Str) -> Str
state_of = |out| ",\"requestState\":${(Session.json(out.first() ?? "{}").get_or_null("result").get_or_null("requestState")).to_str()}"

roots_answer : Str
roots_answer = ",\"inputResponses\":{\"roots\":{\"roots\":[]}}"

# Three requests of one call: the second round's result carries the first answer (and the
# app's state) in requestState; the third request answers only roots2 and the handler sees both.
expect {
	r1 = acc_run([acc_call("1", "acc", "")])
	r2 = acc_run([acc_call("2", "acc", roots_answer)])
	r3 = acc_run([acc_call("3", "acc", ",\"inputResponses\":{\"roots2\":{\"roots\":[{\"uri\":\"file:///b\"}]}}${state_of(r2.out)}")])
	r1.out == ["{\"result\":{\"resultType\":\"input_required\",\"inputRequests\":{\"roots\":{\"method\":\"roots/list\"}},\"_meta\":{\"io.modelcontextprotocol/serverInfo\":{\"name\":\"m\",\"version\":\"1\"}}},\"jsonrpc\":\"2.0\",\"id\":1}"]
		and r2.out == ["{\"result\":{\"resultType\":\"input_required\",\"inputRequests\":{\"roots2\":{\"method\":\"roots/list\"}},\"requestState\":\"mcp-sdk-carry:{\\\"answers\\\":{\\\"roots\\\":{\\\"roots\\\":[]}},\\\"state\\\":\\\"good2\\\"}\",\"_meta\":{\"io.modelcontextprotocol/serverInfo\":{\"name\":\"m\",\"version\":\"1\"}}},\"jsonrpc\":\"2.0\",\"id\":2}"]
		and r3.out == ["{\"result\":{\"content\":[{\"type\":\"text\",\"text\":\"{\\\"roots\\\":[]} | {\\\"roots\\\":[{\\\"uri\\\":\\\"file:///b\\\"}]} | good2\"}],\"resultType\":\"complete\",\"_meta\":{\"io.modelcontextprotocol/serverInfo\":{\"name\":\"m\",\"version\":\"1\"}}},\"jsonrpc\":\"2.0\",\"id\":3}"]
		and r1.log == []
		and r2.log == []
		and r3.log == []
}

# The retry's own answer for a carried key wins; the app's state is unwrapped for Ctx.
expect {
	r2 = acc_run([acc_call("2", "acc", roots_answer)])
	line = acc_call("3", "acc", ",\"inputResponses\":{\"roots\":{\"roots\":[{\"uri\":\"file:///c\"}]},\"roots2\":{\"roots\":[]}}${state_of(r2.out)}")
	match Engine.receive(acc_server, Engine.Session.new, {}, line).calls {
		[call] =>
			call.ctx.input("roots") == Answered(Session.json("{\"roots\":[{\"uri\":\"file:///c\"}]}"))
				and call.ctx.input("roots2") == Answered(Session.json("{\"roots\":[]}"))
				and call.ctx.request_state() == Ok("good2")
				and call.ctx.round() == 1
		_ => Bool.False
	}
}

# A carried app state goes through the verifier (refused: -32602); a carried state that does
# not decode is refused too; a carry without an app state needs no verifier.
expect {
	bad = acc_run([acc_call("4", "acc", ",\"requestState\":\"mcp-sdk-carry:{\\\"answers\\\":{},\\\"state\\\":\\\"bad\\\"}\"")])
	broken = acc_run([acc_call("5", "acc", ",\"requestState\":\"mcp-sdk-carry:{\\\"answers\\\":[]}\"")])
	bare = acc_run([acc_call("6", "acc", ",\"requestState\":\"mcp-sdk-carry:{\\\"answers\\\":{\\\"roots\\\":{\\\"roots\\\":[]}}}\"")])
	refused = |id| "{\"jsonrpc\":\"2.0\",\"id\":${id},\"error\":{\"code\":-32602,\"message\":\"Invalid or expired requestState\",\"data\":{\"reason\":\"invalid_request_state\"}}}"
	bad.out == [refused("4")] and broken.out == [refused("5")] and Session.first_has(bare.out, "\"inputRequests\":{\"roots2\"")
}

# Asking again for a key the call has an answer for: one diagnostic for the transport's log,
# naming the key; the carried state remembers it, so the next retry logs nothing.
expect {
	r2 = acc_run([acc_call("2", "again", roots_answer)])
	r3 = acc_run([acc_call("3", "again", "${roots_answer}${state_of(r2.out)}")])
	r2.log.len() == 1
		and Session.first_has(r2.log, "asked again for input 'roots'")
		and Session.first_has(r2.out, "\\\"noted\\\":true")
		and r3.log == []
		and Session.first_has(r3.out, "input_required")
}
