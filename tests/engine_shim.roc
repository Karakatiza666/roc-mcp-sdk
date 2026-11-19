app [main!] { pkg: "../package/main.roc" }

import pkg.JsonValue
import pkg.Tool
import pkg.ToolResult
import pkg.Prompt
import pkg.Input
import pkg.Outcome
import pkg.McpError
import pkg.Ctx
import pkg.Server
import pkg.Engine
import Support/Session

main! = |_args| Ok({})

## The 2025 input shim (DESIGN 2, D3; 5, row input_required). Lines are JS SDK 2.0.0 transcripts
## (.tmp/s4/js/shim1.in, shim2.in): the handlers below ask `with_progress_token(Bool.True)`, the
## form of the JS `inputRequired` shim. The JS direct calls' form (the default) is tested at the end.

any! : {}, Ctx, JsonValue => ({}, Outcome(ToolResult))
any! = |s, _c, _a| (s, Outcome.done(ToolResult.text("")))

p! : {}, Ctx, {} => ({}, Outcome(Prompt.Result))
p! = |s, _c, _a| (s, Outcome.done({ description: Err(None), messages: [] }))

server : Server({})
server =
	["roots", "two", "url", "forever", "stateonly", "slow", "sample", "d_roots", "d_two", "d_form", "d_sample", "d_url"]
		.fold(Server.new({ name: "f", version: "2" }), |s, n| s.tool_json(Tool.new(n), any!))
		.prompt(Prompt.new("askp"), p!)

strict : Server({})
strict = server.with_input_failures(FailRequest)

form_schema : JsonValue
form_schema = Session.json("{\"type\":\"object\",\"properties\":{\"name\":{\"type\":\"string\"}}}")

describe : Input.Answer -> Str
describe = |a| match a {
	NotAsked => "not asked"
	Answered(j) => "answered ${j.to_str()}"
	Failed(e) => "failed ${e.code().to_str()} ${e.message()}"
	TimedOut => "timed out"
}

need : Input.Required -> Outcome(JsonValue)
need = |r| Outcome.need_input(r.with_progress_token(Bool.True))

## The handlers' behaviour, as a function of the round and the answers.
script : Engine.Call({}) -> Outcome(JsonValue)
script = |call| {
	c = call.ctx
	first = c.round() == 0
	if c.method() == "prompts/get" {
		if (first) need(Input.Required.one("roots", ListRoots)) else Outcome.done(Prompt.result_to_json({ description: Err(None), messages: [Prompt.user(describe(c.input("roots")))] }))
	} else {
		match Session.tool_name(call) {
			"roots" => if (first) need(Input.Required.one("roots", ListRoots)) else Session.text(describe(c.input("roots")))
			"two" =>
				if first {
					need(Input.Required.one("roots", ListRoots).also("form", ElicitForm({ message: "Name?", requested_schema: form_schema })))
				} else {
					Session.text("${describe(c.input("roots"))}; ${describe(c.input("form"))}")
				}
			"url" => if (first) need(Input.Required.one("u", ElicitUrl({ message: "Go", url: "https://x" }))) else Session.text(describe(c.input("u")))
			"sample" => if (first) need(Input.Required.one("s", CreateMessage(Session.json("{\"messages\":[],\"maxTokens\":5,\"tools\":[]}")))) else Session.text(describe(c.input("s")))
			"forever" => need(Input.Required.one("roots", ListRoots))
			"stateonly" => if (first) need(Input.Required.keep_state("s1")) else Session.text("state ${c.request_state() ?? "none"} round ${c.round().to_str()}")
			"slow" => if (first) need(Input.Required.one("roots", ListRoots).with_timeout_ms(2000)) else Session.text(describe(c.input("roots")))
			# The default form: the JS direct calls (no progress token).
			"d_roots" => if (first) Outcome.need_input(Input.Required.one("roots", ListRoots)) else Session.text(describe(c.input("roots")))
			"d_two" =>
				if first {
					Outcome.need_input(Input.Required.one("roots", ListRoots).also("form", ElicitForm({ message: "Name?", requested_schema: form_schema })))
				} else {
					Session.text("${describe(c.input("roots"))}; ${describe(c.input("form"))}")
				}
			"d_form" => if (first) Outcome.need_input(Input.Required.one("form", ElicitForm({ message: "Name?", requested_schema: form_schema }))) else Session.text(describe(c.input("form")))
			"d_sample" => if (first) Outcome.need_input(Input.Required.one("s", CreateMessage(Session.json("{\"messages\":[],\"maxTokens\":5,\"tools\":[]}")))) else Session.text(describe(c.input("s")))
			"d_url" => if (first) Outcome.need_input(Input.Required.one("u", ElicitUrl({ message: "Go", url: "https://x" }))) else Session.text(describe(c.input("u")))
			_ => Session.text("?")
		}
	}
}

init : Str -> Str
init = |caps| "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2025-11-25\",\"capabilities\":${caps},\"clientInfo\":{\"name\":\"c\",\"version\":\"1\"}}}"

all_caps : Str
all_caps = "{\"roots\":{},\"elicitation\":{\"form\":{},\"url\":{}},\"sampling\":{\"tools\":{}}}"

call : Str, Str -> Str
call = |id, tool| "{\"jsonrpc\":\"2.0\",\"id\":${id},\"method\":\"tools/call\",\"params\":{\"name\":\"${tool}\"}}"

answer : Str, Str -> Str
answer = |n, r| "{\"jsonrpc\":\"2.0\",\"id\":${n},\"result\":${r}}"

fail_answer : Str, Str -> Str
fail_answer = |n, e| "{\"jsonrpc\":\"2.0\",\"id\":${n},\"error\":${e}}"

## The out lines after initialize (whose response is dropped).
after_init : Server({}), Str, List(Str) -> Session.Run
after_init = |srv, caps, lines| {
	r = Session.drive(srv, Engine.Session.new, {}, [init(caps)].concat(lines), script, 1000)
	{ ..r, out: r.out.drop_first(1) }
}

roots_request : Str -> Str
roots_request = |n| "{\"method\":\"roots/list\",\"params\":{\"_meta\":{\"progressToken\":${n}}},\"jsonrpc\":\"2.0\",\"id\":${n}}"

text_result : Str, Str -> Str
text_result = |id, t| "{\"result\":{\"content\":[{\"type\":\"text\",\"text\":\"${t}\"}]},\"jsonrpc\":\"2.0\",\"id\":${id}}"

error_result : Str, Str -> Str
error_result = |id, t| "{\"result\":{\"content\":[{\"type\":\"text\",\"text\":\"${t}\"}],\"isError\":true},\"jsonrpc\":\"2.0\",\"id\":${id}}"

# Park: one roots/list request; a ping is served meanwhile; the answer re-runs the handler.
expect {
	r = after_init(server, all_caps, [call("2", "roots"), "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"ping\"}", answer("0", "{\"roots\":[{\"uri\":\"file:///r\"}]}")])
	r.out
		== [
			roots_request("0"),
			"{\"result\":{},\"jsonrpc\":\"2.0\",\"id\":3}",
			text_result("2", "answered {\\\"roots\\\":[{\\\"uri\\\":\\\"file:///r\\\"}]}"),
		]
		and r.session.waiting() == 0
}

# While parked: waiting, the deadline (default 600 000 ms after `finish`).
expect {
	r = after_init(server, all_caps, [call("2", "roots")])
	r.session.waiting() == 1 and Engine.next_deadline(r.session) == Ok(601_000) and Engine.next_deadline(Engine.Session.new) == Err(None)
}
expect Engine.next_deadline((after_init(server, all_caps, [call("2", "slow")])).session) == Ok(3000)

# Two requests in one round, in order, with their params as JS sends them.
expect {
	r = after_init(server, all_caps, [call("4", "two")])
	r.out
		== [
			roots_request("0"),
			"{\"method\":\"elicitation/create\",\"params\":{\"message\":\"Name?\",\"requestedSchema\":{\"type\":\"object\",\"properties\":{\"name\":{\"type\":\"string\"}}},\"mode\":\"form\",\"_meta\":{\"progressToken\":1}},\"jsonrpc\":\"2.0\",\"id\":1}",
		]
}

# Both answered (any order), the handler sees both.
expect {
	r = after_init(server, all_caps, [call("4", "two"), answer("1", "{\"action\":\"accept\",\"content\":{\"name\":\"x\"}}"), answer("0", "{\"roots\":[]}")])
	r.out.drop_first(2) == [text_result("4", "answered {\\\"roots\\\":[]}; answered {\\\"action\\\":\\\"accept\\\",\\\"content\\\":{\\\"name\\\":\\\"x\\\"}}")]
}

# An error answer (default ToHandler): the handler gets Failed once all are answered.
expect {
	r = after_init(server, all_caps, [call("4", "two"), fail_answer("1", "{\"code\":-32601,\"message\":\"nah\",\"data\":{\"z\":1}}"), answer("0", "{\"roots\":[]}")])
	r.out.drop_first(2) == [text_result("4", "answered {\\\"roots\\\":[]}; failed -32601 nah")]
}

# FailRequest (JS): the first error ends the request; the other requests are cancelled.
expect {
	r = after_init(strict, all_caps, [call("4", "two"), fail_answer("1", "{\"code\":-32601,\"message\":\"nah\",\"data\":{\"z\":1}}"), answer("0", "{\"roots\":[]}")])
	r.out.drop_first(2)
		== [
			"{\"jsonrpc\":\"2.0\",\"method\":\"notifications/cancelled\",\"params\":{\"requestId\":0,\"reason\":\"ProtocolError: nah\"}}",
			error_result("4", "Fulfilling input required by 'tools/call' failed: nah"),
		]
		and r.log.len() == 1
}

# FailRequest for other methods: -32603.
expect {
	r = after_init(strict, all_caps, ["{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"prompts/get\",\"params\":{\"name\":\"askp\"}}", fail_answer("0", "{\"code\":-32000,\"message\":\"denied\"}")])
	r.out == [roots_request("0"), "{\"jsonrpc\":\"2.0\",\"id\":7,\"error\":{\"code\":-32603,\"message\":\"Fulfilling input required by 'prompts/get' failed: denied\"}}"]
}

# prompts/get with ToHandler: the prompt runs again.
expect {
	r = after_init(server, all_caps, ["{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"prompts/get\",\"params\":{\"name\":\"askp\"}}", answer("0", "{\"roots\":[]}")])
	r.out.drop_first(1) == ["{\"result\":{\"messages\":[{\"role\":\"user\",\"content\":{\"type\":\"text\",\"text\":\"answered {\\\"roots\\\":[]}\"}}]},\"jsonrpc\":\"2.0\",\"id\":7}"]
}

# URL elicitation carries an elicitationId; sampling params pass unchanged.
expect {
	r = after_init(server, all_caps, [call("6", "url")])
	r.out == ["{\"method\":\"elicitation/create\",\"params\":{\"message\":\"Go\",\"url\":\"https://x\",\"mode\":\"url\",\"elicitationId\":\"mcp-sdk-0\",\"_meta\":{\"progressToken\":0}},\"jsonrpc\":\"2.0\",\"id\":0}"]
}
expect {
	r = after_init(server, all_caps, [call("6", "sample")])
	r.out == ["{\"method\":\"sampling/createMessage\",\"params\":{\"messages\":[],\"maxTokens\":5,\"tools\":[],\"_meta\":{\"progressToken\":0}},\"jsonrpc\":\"2.0\",\"id\":0}"]
}

# The capability gate: a request the client did not declare fails at once (JS text).
expect {
	r = after_init(server, "{\"roots\":{}}", [call("3", "two")])
	r.out == [error_result("3", "Cannot request input 'form' (elicitation/create): the client on this 2025-era connection did not declare the required capability")]
}
expect (after_init(server, "{\"roots\":{},\"elicitation\":{}}", [call("3", "two")])).out.len() == 2
expect (after_init(server, "{\"elicitation\":{}}", [call("6", "url")])).out == [error_result("6", "Cannot request input 'u' (elicitation/create): the client on this 2025-era connection did not declare the required capability")]
expect (after_init(server, "{\"sampling\":{}}", [call("6", "sample")])).out == [error_result("6", "Cannot request input 's' (sampling/createMessage): the client on this 2025-era connection did not declare the required capability")]
expect (Session.run(server, {}, [call("2", "roots")], script)) == [error_result("2", "Cannot request input 'roots' (roots/list): the client on this 2025-era connection did not declare the required capability")]

# At most 8 rounds.
expect {
	answers = (0.U64..<8).iter().map(|i| answer(i.to_str(), "{\"roots\":[]}")).collect()
	r = after_init(server, all_caps, [call("2", "forever")].concat(answers))
	r.out.len() == 9 and r.out.last() == Ok(error_result("2", "Multi-round-trip request 'tools/call' still required input after 8 rounds (inputRequired.maxRounds)")) and r.out.get(7) == Ok(roots_request("7"))
}

# A state-only round runs the handler again at once with the state.
expect (after_init(server, all_caps, [call("8", "stateonly")])).out == [text_result("8", "state s1 round 1")]

# The request state verifier refuses: -32602.
expect {
	verified : Server({})
	verified = server.with_request_state_verifier(|_c, st| st == "ok")
	(after_init(verified, all_caps, [call("8", "stateonly")])).out == ["{\"jsonrpc\":\"2.0\",\"id\":8,\"error\":{\"code\":-32602,\"message\":\"Invalid or expired requestState\"}}"]
}

# Cancelling a parked request: its requests are cancelled, it gets no response, a late answer is logged.
expect {
	r = after_init(server, all_caps, [call("9", "roots"), "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/cancelled\",\"params\":{\"requestId\":9,\"reason\":\"user\"}}", answer("0", "{\"roots\":[]}")])
	r.out == [roots_request("0"), "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/cancelled\",\"params\":{\"requestId\":0,\"reason\":\"user\"}}"] and r.session.waiting() == 0 and r.log.len() == 1
}
expect {
	r = after_init(server, all_caps, [call("9", "roots"), "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/cancelled\",\"params\":{\"requestId\":9}}"])
	r.out.last() == Ok("{\"jsonrpc\":\"2.0\",\"method\":\"notifications/cancelled\",\"params\":{\"requestId\":0,\"reason\":\"AbortError: This operation was aborted\"}}")
}
# Cancelling something that is not parked does nothing.
expect (after_init(server, all_caps, ["{\"jsonrpc\":\"2.0\",\"method\":\"notifications/cancelled\",\"params\":{\"requestId\":42}}"])).out == []

# Deadlines: expire cancels the request and re-runs the handler with TimedOut (ToHandler)...
expect {
	r = after_init(server, all_caps, [call("10", "roots")])
	early = Session.expire(server, r.session, {}, script, 600_999)
	late = Session.expire(server, r.session, {}, script, 601_000)
	early.out == [] and late.out == ["{\"jsonrpc\":\"2.0\",\"method\":\"notifications/cancelled\",\"params\":{\"requestId\":0,\"reason\":\"SdkError: Request timed out\"}}", text_result("10", "timed out")] and late.session.waiting() == 0
}
# ... or fails it (FailRequest, JS).
expect {
	r = after_init(strict, all_caps, [call("10", "roots")])
	late = Session.expire(strict, r.session, {}, script, 700_000)
	late.out == ["{\"jsonrpc\":\"2.0\",\"method\":\"notifications/cancelled\",\"params\":{\"requestId\":0,\"reason\":\"SdkError: Request timed out\"}}", error_result("10", "Fulfilling input required by 'tools/call' failed: Request timed out")]
}
# A partly answered round keeps its answers; only the missing ones time out.
expect {
	r = after_init(server, all_caps, [call("4", "two"), answer("0", "{\"roots\":[]}")])
	late = Session.expire(server, r.session, {}, script, 601_000)
	late.out == ["{\"jsonrpc\":\"2.0\",\"method\":\"notifications/cancelled\",\"params\":{\"requestId\":1,\"reason\":\"SdkError: Request timed out\"}}", text_result("4", "answered {\\\"roots\\\":[]}; timed out")]
}

# A parked request survives Session.to_json / from_json and continues.
expect {
	r = after_init(server, all_caps, [call("2", "roots")])
	match Engine.Session.from_json(r.session.to_json()) {
		Ok(back) => {
			cont = Session.drive(server, back, {}, [answer("0", "{\"roots\":[]}")], script, 2000)
			back.to_json() == r.session.to_json() and cont.out == [text_result("2", "answered {\\\"roots\\\":[]}")]
		}
		Err(_) => Bool.False
	}
}

# A Failed answer survives the round trip too.
expect {
	r = after_init(server, all_caps, [call("4", "two"), fail_answer("1", "{\"code\":-32601,\"message\":\"nah\"}")])
	match Engine.Session.from_json(r.session.to_json()) {
		Ok(back) => back.to_json() == r.session.to_json() and back.waiting() == 1
		Err(_) => Bool.False
	}
}

# Ids keep counting across requests.
expect {
	r = after_init(server, all_caps, [call("2", "roots"), call("3", "roots")])
	r.out == [roots_request("0"), roots_request("1")]
}

# ---- The default form: the JS direct calls (`server.listRoots({})`, `elicitInput`,
# `createMessage`), captured from JS SDK 2.0.0: no progress token, one id counter from 0. ----

direct_roots : Str -> Str
direct_roots = |n| "{\"method\":\"roots/list\",\"params\":{},\"jsonrpc\":\"2.0\",\"id\":${n}}"

expect {
	r = after_init(server, all_caps, [call("2", "d_roots"), answer("0", "{\"roots\":[]}")])
	r.out == [direct_roots("0"), text_result("2", "answered {\\\"roots\\\":[]}")]
}
expect (after_init(server, all_caps, [call("2", "d_form")])).out == ["{\"method\":\"elicitation/create\",\"params\":{\"message\":\"Name?\",\"requestedSchema\":{\"type\":\"object\",\"properties\":{\"name\":{\"type\":\"string\"}}},\"mode\":\"form\"},\"jsonrpc\":\"2.0\",\"id\":0}"]
expect (after_init(server, all_caps, [call("2", "d_sample")])).out == ["{\"method\":\"sampling/createMessage\",\"params\":{\"messages\":[],\"maxTokens\":5,\"tools\":[]},\"jsonrpc\":\"2.0\",\"id\":0}"]
expect (after_init(server, all_caps, [call("2", "d_url")])).out == ["{\"method\":\"elicitation/create\",\"params\":{\"message\":\"Go\",\"url\":\"https://x\",\"mode\":\"url\",\"elicitationId\":\"mcp-sdk-0\"},\"jsonrpc\":\"2.0\",\"id\":0}"]

# The two forms share the counter (JS: one `_requestMessageId`).
expect (after_init(server, all_caps, [call("2", "roots"), call("3", "d_roots")])).out == [roots_request("0"), direct_roots("1")]

# JS matches a response by `Number(id)`: the string "0" answers request 0; "mcp-sdk-0" answers nothing.
expect (after_init(server, all_caps, [call("2", "d_roots"), answer("\"0\"", "{\"roots\":[]}")])).out.len() == 2
expect {
	r = after_init(server, all_caps, [call("2", "d_roots"), answer("\"mcp-sdk-0\"", "{\"roots\":[]}")])
	r.out == [direct_roots("0")] and r.log.len() == 1 and r.session.waiting() == 1
}

# Direct calls check capabilities as JS does: roots/list is sent without the capability ...
expect (after_init(server, "{}", [call("2", "d_roots")])).out == [direct_roots("0")]
# ... an elicitation the client cannot take is not sent, and the handler reads Failed ...
expect {
	r = after_init(server, "{\"roots\":{}}", [call("4", "d_two"), answer("0", "{\"roots\":[]}")])
	r.out == [direct_roots("0"), text_result("4", "answered {\\\"roots\\\":[]}; failed -32603 Client does not support form elicitation.")]
}
expect (after_init(server, "{\"elicitation\":{\"form\":{}}}", [call("6", "d_url")])).out == [text_result("6", "failed -32603 Client does not support url elicitation.")]
expect (after_init(server, "{\"sampling\":{}}", [call("6", "d_sample")])).out == [text_result("6", "failed -32603 Client does not support sampling tools capability.")]
# ... or, with FailRequest, ends the call before anything is sent.
expect (after_init(strict, "{\"roots\":{}}", [call("4", "d_two")])).out == [error_result("4", "Fulfilling input required by 'tools/call' failed: Client does not support form elicitation.")]

# A session stored by release 0.1 ("outId":"mcp-sdk-0") still resumes.
expect {
	r = after_init(server, all_caps, [call("2", "d_roots")])
	old = r.session.to_json().to_str().replace_each("\"outId\":0", "\"outId\":\"mcp-sdk-0\"")
	match JsonValue.parse(old) {
		Ok(j) =>
			match Engine.Session.from_json(j) {
				Ok(back) => (Session.drive(server, back, {}, [answer("0", "{\"roots\":[]}")], script, 2000)).out == [text_result("2", "answered {\\\"roots\\\":[]}")]
				Err(_) => Bool.False
			}
		Err(_) => Bool.False
	}
}
