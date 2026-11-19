app [main!] { pkg: "../package/main.roc" }

import pkg.JsonValue
import pkg.Input
import pkg.Outcome
import pkg.McpError
import pkg.ToolResult

main! = |_args| Ok({})

## L0 for Input, Outcome. The request goldens are what the JS SDK 2.0.0 sends (legacy shim)
## or embeds in `inputRequests` (2026-07-28), see tests/golden/js-sdk-types.jsonl.

json : Str -> JsonValue
json = |s| match JsonValue.parse(s) {
	Ok(v) => v
	Err(_) => crash "bad JSON in test: ${s}"
}

schema : JsonValue
schema = json("{\"type\":\"object\",\"properties\":{\"name\":{\"type\":\"string\"}},\"required\":[\"name\"]}")

form : Input.Request
form = ElicitForm({ message: "Name?", requested_schema: schema })

url : Input.Request
url = ElicitUrl({ message: "Go", url: "https://x/auth" })

roots_req : Input.Request
roots_req = ListRoots

sampling : Input.Request
sampling = CreateMessage(json("{\"messages\":[{\"role\":\"user\",\"content\":{\"type\":\"text\",\"text\":\"q\"}}],\"maxTokens\":10}"))

params_str : Try(JsonValue, [None]) -> Str
params_str = |p| match p {
	Ok(j) => j.to_str()
	Err(None) => "none"
}

# ---- Request: method and params ----

expect [roots_req, form, url, sampling].map(|r| r.method()) == ["roots/list", "elicitation/create", "elicitation/create", "sampling/createMessage"]
expect [roots_req, form, url, sampling].map(|r| r.capability()) == ["roots", "elicitation", "elicitation", "sampling"]

expect params_str(roots_req.params()) == "none"
expect params_str(form.params()) == "{\"message\":\"Name?\",\"requestedSchema\":{\"type\":\"object\",\"properties\":{\"name\":{\"type\":\"string\"}},\"required\":[\"name\"]},\"mode\":\"form\"}"
expect params_str(url.params()) == "{\"message\":\"Go\",\"url\":\"https://x/auth\",\"mode\":\"url\"}"
expect params_str(sampling.params()) == "{\"messages\":[{\"role\":\"user\",\"content\":{\"type\":\"text\",\"text\":\"q\"}}],\"maxTokens\":10}"

# Legacy: URL mode carries the shim's elicitationId (JS puts it before `_meta`).
expect params_str(url.legacy_params("c13d6b48")) == "{\"message\":\"Go\",\"url\":\"https://x/auth\",\"mode\":\"url\",\"elicitationId\":\"c13d6b48\"}"
expect params_str(form.legacy_params("id")) == params_str(form.params())
expect params_str(roots_req.legacy_params("id")) == "none"

# The 2026-07-28 `inputRequests` entries (JS `inputRequired.listRoots()` / `.elicit()` / `.elicitUrl()`).
expect roots_req.to_json().to_str() == "{\"method\":\"roots/list\"}"
expect form.to_json().to_str() == "{\"method\":\"elicitation/create\",\"params\":{\"message\":\"Name?\",\"requestedSchema\":{\"type\":\"object\",\"properties\":{\"name\":{\"type\":\"string\"}},\"required\":[\"name\"]},\"mode\":\"form\"}}"
expect url.to_json().to_str() == "{\"method\":\"elicitation/create\",\"params\":{\"message\":\"Go\",\"url\":\"https://x/auth\",\"mode\":\"url\"}}"

# ---- Required ----

expect {
	r = Input.Required.one("roots", ListRoots).also("name", form).with_state("s1").with_timeout_ms(2000)
	r.requests().map(|(k, _)| k) == ["roots", "name"] and r.request_state() == Ok("s1") and r.timeout_ms() == Ok(2000)
}

expect {
	r = Input.Required.one("roots", ListRoots)
	r.request_state() == Err(None) and r.timeout_ms() == Err(None)
}

# ---- roots ----

expect {
	got = Input.roots(json("{\"roots\":[{\"uri\":\"file:///a\",\"name\":\"A\"},{\"uri\":\"file:///b\"}]}"))
	got == Ok([{ uri: "file:///a", name: Ok("A") }, { uri: "file:///b", name: Err(None) }])
}
expect Input.roots(json("{\"roots\":[]}")) == Ok([])
expect Input.roots(json("{}")) == Err(BadAnswer("missing roots"))
expect Input.roots(json("{\"roots\":{}}")) == Err(BadAnswer("roots is not an array"))
expect Input.roots(json("{\"roots\":[{\"name\":\"x\"}]}")) == Err(BadAnswer("root without uri"))
expect Input.roots(json("{\"roots\":[{\"uri\":1}]}")) == Err(BadAnswer("root uri is not a string"))
expect Input.roots(json("{\"roots\":[{\"uri\":\"u\",\"name\":2}]}")) == Err(BadAnswer("root name is not a string"))
expect Input.roots(json("[]")) == Err(BadAnswer("missing roots"))

# ---- elicitation ----

expect Input.elicitation(json("{\"action\":\"accept\",\"content\":{\"name\":\"Bo\"}}")) == Ok(Accept(json("{\"name\":\"Bo\"}")))
expect Input.elicitation(json("{\"action\":\"accept\"}")) == Ok(Accept(json("{}")))
expect Input.elicitation(json("{\"action\":\"decline\"}")) == Ok(Decline)
expect Input.elicitation(json("{\"action\":\"cancel\"}")) == Ok(Cancel)
expect Input.elicitation(json("{\"action\":\"maybe\"}")) == Err(BadAnswer("unknown action: maybe"))
expect Input.elicitation(json("{}")) == Err(BadAnswer("missing action"))
expect Input.elicitation(json("{\"action\":1}")) == Err(BadAnswer("action is not a string"))
expect Input.elicitation(json("{\"action\":\"accept\",\"content\":[1]}")) == Err(BadAnswer("content is not an object"))

# ---- Outcome ----

text_of : Outcome(ToolResult) -> Str
text_of = |o| match o {
	Done(r) => r.to_json().to_str()
	NeedInput(req) => "need ${Str.join_with(req.requests().map(|(k, _)| k), ",")}"
	Fail(e) => "fail ${e.code().to_str()}"
}

expect text_of(Outcome.done(ToolResult.text("x"))) == "{\"content\":[{\"type\":\"text\",\"text\":\"x\"}]}"
expect text_of(Outcome.need_input(Input.Required.one("roots", ListRoots))) == "need roots"
expect text_of(Outcome.fail(McpError.internal("x"))) == "fail -32603"
expect text_of(Outcome.done("a").map(|s| ToolResult.text("${s}b"))) == "{\"content\":[{\"type\":\"text\",\"text\":\"ab\"}]}"
expect text_of(Outcome.fail(McpError.internal("x")).map(|s| ToolResult.text(s))) == "fail -32603"
