app [main!] { pkg: "../package/main.roc" }

import pkg.JsonValue
import pkg.Server
import pkg.Engine
import Support/Session

main! = |_args| Ok({})

## Framing (DESIGN 5, row Framing; 6). JS stdio drops every malformed line silently; we answer
## per the JSON-RPC spec (open question Q1, default -32700) and log the reason.

empty : Server({})
empty = Server.new({ name: "e", version: "1" })

run : List(Str) -> List(Str)
run = |lines| Session.run(empty, {}, lines, Session.no_calls)

invalid : Str -> Str
invalid = |id| "{\"jsonrpc\":\"2.0\",\"id\":${id},\"error\":{\"code\":-32600,\"message\":\"Invalid Request\"}}"

# Not JSON: -32700 with id null, and a log line.
expect run(["not json"]) == ["{\"jsonrpc\":\"2.0\",\"id\":null,\"error\":{\"code\":-32700,\"message\":\"Parse error\"}}"]
expect {
	step = Engine.receive(empty, Engine.Session.new, {}, "{\"jsonrpc\":")
	step.out.len() == 1 and step.log.len() == 1 and step.calls.is_empty()
}

# A JSON array (batch) and other non-objects: -32600, id null.
expect run(["[{\"jsonrpc\":\"2.0\",\"id\":6,\"method\":\"ping\"}]"]) == [invalid("null")]
expect run(["[]", "\"str\"", "null", "5"]) == [invalid("null"), invalid("null"), invalid("null"), invalid("null")]

# Objects that are not JSON-RPC 2.0: -32600 with the id when it is usable.
expect run(["{\"foo\":1}"]) == [invalid("null")]
expect run(["{\"jsonrpc\":\"2.0\",\"id\":7}"]) == [invalid("7")]
expect run(["{\"id\":9,\"method\":\"ping\"}"]) == [invalid("9")]
expect run(["{\"jsonrpc\":\"1.0\",\"id\":10,\"method\":\"ping\"}"]) == [invalid("10")]
expect run(["{\"jsonrpc\":\"2.0\",\"id\":15,\"method\":5}"]) == [invalid("15")]
expect run(["{\"jsonrpc\":\"2.0\",\"id\":14,\"method\":\"ping\",\"params\":[]}"]) == [invalid("14")]

# Ids are strings or integers.
expect run(["{\"jsonrpc\":\"2.0\",\"id\":1.5,\"method\":\"ping\"}", "{\"jsonrpc\":\"2.0\",\"id\":null,\"method\":\"ping\"}", "{\"jsonrpc\":\"2.0\",\"id\":true,\"method\":\"ping\"}"]) == [invalid("null"), invalid("null"), invalid("null")]
expect run(["{\"jsonrpc\":\"2.0\",\"id\":12345678901234567,\"method\":\"ping\"}"]) == ["{\"result\":{},\"jsonrpc\":\"2.0\",\"id\":12345678901234567}"]
expect run(["{\"jsonrpc\":\"2.0\",\"id\":-3,\"method\":\"ping\"}"]) == ["{\"result\":{},\"jsonrpc\":\"2.0\",\"id\":-3}"]
expect run(["{\"jsonrpc\":\"2.0\",\"id\":\"a\\\"b\",\"method\":\"ping\"}"]) == ["{\"result\":{},\"jsonrpc\":\"2.0\",\"id\":\"a\\\"b\"}"]

# Whitespace around the value, a trailing \r, blank lines.
expect run(["   {\"jsonrpc\":\"2.0\",\"id\":19,\"method\":\"ping\"}   "]) == ["{\"result\":{},\"jsonrpc\":\"2.0\",\"id\":19}"]
expect run(["{\"jsonrpc\":\"2.0\",\"id\":18,\"method\":\"ping\"}\r"]) == ["{\"result\":{},\"jsonrpc\":\"2.0\",\"id\":18}"]
expect run(["", "  ", "\r"]) == []

# A response with an unknown id is logged and ignored.
expect {
	step = Engine.receive(empty, Engine.Session.new, {}, "{\"jsonrpc\":\"2.0\",\"id\":99,\"result\":{}}")
	step.out == [] and step.log.len() == 1
}
expect run(["{\"jsonrpc\":\"2.0\",\"id\":\"zz\",\"error\":{\"code\":1,\"message\":\"x\"}}"]) == []

# A notification with no handler is ignored; a notification never gets a response.
expect run(["{\"jsonrpc\":\"2.0\",\"method\":\"notifications/whatever\"}", "{\"jsonrpc\":\"2.0\",\"method\":\"foo/bar\",\"params\":{}}"]) == []

# A line over 10 MB is refused with -32600 (JS closes the transport; we keep serving).
expect {
	big = Str.repeat("x", 10 * 1024 * 1024 + 1)
	step = Engine.receive(empty, Engine.Session.new, {}, big)
	step.out == [invalid("null")] and step.log.len() == 1
}

# receive_json takes a parsed message.
expect (Engine.receive_json(empty, Engine.Session.new, {}, Object([("jsonrpc", String("2.0")), ("id", Number("1")), ("method", String("ping"))]))).out == ["{\"result\":{},\"jsonrpc\":\"2.0\",\"id\":1}"]
