app [main!] { pkg: "../package/main.roc" }

import pkg.JsonValue
import pkg.Server
import pkg.Engine
import Support/Session
import Support/Modern

main! = |_args| Ok({})

## The 2026-07-28 era (DESIGN 5, rows "Era selection" and "Modern methods"). Expected lines are
## JS SDK 2.0.0 stdio transcripts of `.tmp/s5/js/l0.mjs` (served by `serveStdio`, the twin of
## `Support/Modern`), made by `.tmp/s5/js/gen_l0.py` and `.tmp/s5/roc_consts.py`.

run : Server({}), List(Str) -> List(Str)
run = |srv, lines| Session.run(srv, {}, lines, Modern.script)

after : Server({}), List(Str) -> Engine.Session
after = |srv, lines| Session.drive(srv, Engine.Session.new, {}, lines, Modern.script, 0).session

# Every modern method, the removed ones (-32601), resultType, ttlMs/cacheScope on the cacheable
# results, serverInfo in _meta, the envelope checks of later requests, a custom result with a
# foreign resultType (-32603 "Internal error"), and a later request naming another version
# (served, as JS does).
expect Session.same(run(Modern.server, basics_in), basics_out)

# Byte for byte (JS's key order: the result's own keys, resultType, ttlMs, cacheScope, _meta).
expect run(Modern.server, [basics_in.first() ?? "", basics_in.get(11) ?? ""]) == [basics_out.first() ?? "", basics_out.get(11) ?? ""]

# Arguments are checked against the input schema in this era too (the same tools/call handler in JS).
expect
	run(Modern.server, ["{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/call\",\"params\":{\"name\":\"echo\",\"arguments\":{\"text\":1},\"_meta\":{\"io.modelcontextprotocol/protocolVersion\":\"2026-07-28\",\"io.modelcontextprotocol/clientCapabilities\":{},\"io.modelcontextprotocol/clientInfo\":{\"name\":\"t\",\"version\":\"1\"}}}}"])
		== ["{\"result\":{\"content\":[{\"type\":\"text\",\"text\":\"Input validation error: Invalid arguments for tool echo: text: Invalid input: expected string, received number\"}],\"isError\":true,\"resultType\":\"complete\",\"_meta\":{\"io.modelcontextprotocol/serverInfo\":{\"name\":\"m\",\"version\":\"1\"}}},\"jsonrpc\":\"2.0\",\"id\":3}"]

# The era: modern after a request with a valid envelope.
expect after(Modern.server, basics_in.take_first(1)).current_era() == Modern
expect after(Modern.server, basics_in.take_first(2)).negotiated_version() == "2026-07-28"

# server/discover makes a probe; a 2025 message (here a notification without envelope)
# replaces it, and initialize then negotiates 2025.
expect Session.same(run(Modern.server, probe_in), probe_out)
expect after(Modern.server, probe_in.take_first(2)).current_era() == Modern
expect after(Modern.server, probe_in).current_era() == Legacy

# A modern request after discover pins the era: initialize is then -32022 (with or without a
# protocolVersion), and discover is still served.
expect Session.same(run(Modern.server, pin_in), pin_out)

# An invalid envelope (-32602 with data.envelope) or an unsupported version (-32022) leaves
# the era undecided: initialize then gives 2025.
expect Session.same(run(Modern.server, badfirst_in), badfirst_out)
expect after(Modern.server, badfirst_in.take_first(3)).current_era() == Undecided

# A response before any request is logged and leaves the era undecided.
expect Session.same(run(Modern.server, respfirst_in), respfirst_out)
expect {
	r = Session.drive(Modern.server, Engine.Session.new, {}, respfirst_in.take_first(1), Modern.script, 0)
	r.session.current_era() == Undecided and r.log.len() == 1
}

# initialize with a valid modern envelope is a modern request: -32601.
expect Session.same(run(Modern.server, initclaim_in), initclaim_out)

# A notification with an envelope selects the era too; later requests need the envelope.
expect Session.same(run(Modern.server, notefirst_in), notefirst_out)
expect {
	step = Engine.receive(Modern.server, Engine.Session.new, {}, notefirst_in.first() ?? "")
	step.calls.len() == 1 and step.session.current_era() == Modern
}

# An empty legacy list (JS `legacy: "reject"`): -32022, with `requested` only for initialize.
expect Session.same(run(Modern.reject, reject_in), reject_out)
expect after(Modern.reject, reject_in.take_first(3)).current_era() == Undecided

# with_cache_hint fills ttlMs/cacheScope of its method; the others keep the defaults.
expect Session.same(run(Modern.hints, hints_in), hints_out)

# A first message naming a version the server does not list: -32022 with that list.
expect {
	only : Server({})
	only = Modern.server.with_protocol_versions({ legacy: ["2025-11-25"], modern: [] })
	Session.same(
		run(only, basics_in.take_first(1)),
		["{\"jsonrpc\":\"2.0\",\"id\":1,\"error\":{\"code\":-32022,\"message\":\"Unsupported protocol version: 2026-07-28\",\"data\":{\"supported\":[],\"requested\":\"2026-07-28\"}}}"],
	)
}

# The session JSON keeps the probe.
expect {
	s = after(Modern.server, probe_in.take_first(1))
	match Engine.Session.from_json(s.to_json()) {
		Ok(back) => back.to_json() == s.to_json() and back.current_era() == Modern
		Err(_) => Bool.False
	}
}

basics_in : List(Str)
basics_in = [
	"{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"server/discover\",\"params\":{\"_meta\":{\"io.modelcontextprotocol/protocolVersion\":\"2026-07-28\",\"io.modelcontextprotocol/clientCapabilities\":{},\"io.modelcontextprotocol/clientInfo\":{\"name\":\"t\",\"version\":\"1\"}}}}",
	"{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/list\",\"params\":{\"_meta\":{\"io.modelcontextprotocol/protocolVersion\":\"2026-07-28\",\"io.modelcontextprotocol/clientCapabilities\":{},\"io.modelcontextprotocol/clientInfo\":{\"name\":\"t\",\"version\":\"1\"}}}}",
	"{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/call\",\"params\":{\"name\":\"echo\",\"arguments\":{\"text\":\"hi\"},\"_meta\":{\"io.modelcontextprotocol/protocolVersion\":\"2026-07-28\",\"io.modelcontextprotocol/clientCapabilities\":{},\"io.modelcontextprotocol/clientInfo\":{\"name\":\"t\",\"version\":\"1\"}}}}",
	"{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"ping\",\"params\":{\"_meta\":{\"io.modelcontextprotocol/protocolVersion\":\"2026-07-28\",\"io.modelcontextprotocol/clientCapabilities\":{},\"io.modelcontextprotocol/clientInfo\":{\"name\":\"t\",\"version\":\"1\"}}}}",
	"{\"jsonrpc\":\"2.0\",\"id\":5,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2025-11-25\",\"capabilities\":{},\"clientInfo\":{\"name\":\"t\",\"version\":\"1\"}}}",
	"{\"jsonrpc\":\"2.0\",\"id\":6,\"method\":\"logging/setLevel\",\"params\":{\"level\":\"debug\",\"_meta\":{\"io.modelcontextprotocol/protocolVersion\":\"2026-07-28\",\"io.modelcontextprotocol/clientCapabilities\":{},\"io.modelcontextprotocol/clientInfo\":{\"name\":\"t\",\"version\":\"1\"}}}}",
	"{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"resources/subscribe\",\"params\":{\"uri\":\"res://a\",\"_meta\":{\"io.modelcontextprotocol/protocolVersion\":\"2026-07-28\",\"io.modelcontextprotocol/clientCapabilities\":{},\"io.modelcontextprotocol/clientInfo\":{\"name\":\"t\",\"version\":\"1\"}}}}",
	"{\"jsonrpc\":\"2.0\",\"id\":8,\"method\":\"tasks/get\",\"params\":{\"taskId\":\"x\",\"_meta\":{\"io.modelcontextprotocol/protocolVersion\":\"2026-07-28\",\"io.modelcontextprotocol/clientCapabilities\":{},\"io.modelcontextprotocol/clientInfo\":{\"name\":\"t\",\"version\":\"1\"}}}}",
	"{\"jsonrpc\":\"2.0\",\"id\":9,\"method\":\"x/echo\",\"params\":{\"v\":1,\"_meta\":{\"io.modelcontextprotocol/protocolVersion\":\"2026-07-28\",\"io.modelcontextprotocol/clientCapabilities\":{},\"io.modelcontextprotocol/clientInfo\":{\"name\":\"t\",\"version\":\"1\"}}}}",
	"{\"jsonrpc\":\"2.0\",\"id\":10,\"method\":\"tools/list\"}",
	"{\"jsonrpc\":\"2.0\",\"id\":11,\"method\":\"tools/list\",\"params\":{\"_meta\":{\"io.modelcontextprotocol/protocolVersion\":\"2026-07-28\"}}}",
	"{\"jsonrpc\":\"2.0\",\"id\":12,\"method\":\"resources/read\",\"params\":{\"uri\":\"res://a\",\"_meta\":{\"io.modelcontextprotocol/protocolVersion\":\"2026-07-28\",\"io.modelcontextprotocol/clientCapabilities\":{},\"io.modelcontextprotocol/clientInfo\":{\"name\":\"t\",\"version\":\"1\"}}}}",
	"{\"jsonrpc\":\"2.0\",\"id\":13,\"method\":\"prompts/get\",\"params\":{\"name\":\"p\",\"arguments\":{\"who\":\"Bo\"},\"_meta\":{\"io.modelcontextprotocol/protocolVersion\":\"2026-07-28\",\"io.modelcontextprotocol/clientCapabilities\":{},\"io.modelcontextprotocol/clientInfo\":{\"name\":\"t\",\"version\":\"1\"}}}}",
	"{\"jsonrpc\":\"2.0\",\"id\":14,\"method\":\"x/odd\",\"params\":{\"_meta\":{\"io.modelcontextprotocol/protocolVersion\":\"2026-07-28\",\"io.modelcontextprotocol/clientCapabilities\":{},\"io.modelcontextprotocol/clientInfo\":{\"name\":\"t\",\"version\":\"1\"}}}}",
	"{\"jsonrpc\":\"2.0\",\"id\":15,\"method\":\"completion/complete\",\"params\":{\"ref\":{\"type\":\"ref/prompt\",\"name\":\"p\"},\"argument\":{\"name\":\"who\",\"value\":\"\"},\"_meta\":{\"io.modelcontextprotocol/protocolVersion\":\"2026-07-28\",\"io.modelcontextprotocol/clientCapabilities\":{},\"io.modelcontextprotocol/clientInfo\":{\"name\":\"t\",\"version\":\"1\"}}}}",
	"{\"jsonrpc\":\"2.0\",\"id\":16,\"method\":\"tools/call\",\"params\":{\"name\":\"structured\",\"arguments\":{},\"_meta\":{\"io.modelcontextprotocol/protocolVersion\":\"2026-07-28\",\"io.modelcontextprotocol/clientCapabilities\":{},\"io.modelcontextprotocol/clientInfo\":{\"name\":\"t\",\"version\":\"1\"}}}}",
	"{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}",
	"{\"jsonrpc\":\"2.0\",\"id\":17,\"method\":\"resources/templates/list\",\"params\":{\"_meta\":{\"io.modelcontextprotocol/protocolVersion\":\"2026-07-28\",\"io.modelcontextprotocol/clientCapabilities\":{},\"io.modelcontextprotocol/clientInfo\":{\"name\":\"t\",\"version\":\"1\"}}}}",
	"{\"jsonrpc\":\"2.0\",\"id\":18,\"method\":\"nope/nope\",\"params\":{\"_meta\":{\"io.modelcontextprotocol/protocolVersion\":\"2026-07-28\",\"io.modelcontextprotocol/clientCapabilities\":{},\"io.modelcontextprotocol/clientInfo\":{\"name\":\"t\",\"version\":\"1\"}}}}",
	"{\"jsonrpc\":\"2.0\",\"id\":19,\"method\":\"x/echo\",\"params\":{\"v\":2,\"_meta\":{\"io.modelcontextprotocol/protocolVersion\":\"2099-01-01\",\"io.modelcontextprotocol/clientCapabilities\":{},\"io.modelcontextprotocol/clientInfo\":{\"name\":\"t\",\"version\":\"1\"}}}}",
	"{\"jsonrpc\":\"2.0\",\"id\":20,\"method\":\"tools/list\",\"params\":{\"_meta\":{\"io.modelcontextprotocol/protocolVersion\":\"2026-07-28\",\"io.modelcontextprotocol/clientCapabilities\":{},\"io.modelcontextprotocol/clientInfo\":{},\"io.modelcontextprotocol/logLevel\":\"loud\"}}}",
]

basics_out : List(Str)
basics_out = [
	"{\"result\":{\"supportedVersions\":[\"2026-07-28\"],\"capabilities\":{\"logging\":{},\"tools\":{\"listChanged\":true},\"resources\":{\"listChanged\":true,\"subscribe\":true},\"prompts\":{\"listChanged\":true}},\"instructions\":\"hi\",\"resultType\":\"complete\",\"ttlMs\":0,\"cacheScope\":\"private\",\"_meta\":{\"io.modelcontextprotocol/serverInfo\":{\"name\":\"m\",\"version\":\"1\"}}},\"jsonrpc\":\"2.0\",\"id\":1}",
	"{\"result\":{\"tools\":[{\"name\":\"echo\",\"inputSchema\":{\"type\":\"object\",\"$schema\":\"https://json-schema.org/draft/2020-12/schema\",\"properties\":{\"text\":{\"type\":\"string\"}},\"required\":[\"text\"]}},{\"name\":\"ask\",\"inputSchema\":{\"type\":\"object\",\"properties\":{}}},{\"name\":\"url\",\"inputSchema\":{\"type\":\"object\",\"properties\":{}}},{\"name\":\"sample\",\"inputSchema\":{\"type\":\"object\",\"properties\":{}}},{\"name\":\"stateonly\",\"inputSchema\":{\"type\":\"object\",\"properties\":{}}},{\"name\":\"notify\",\"inputSchema\":{\"type\":\"object\",\"properties\":{}}},{\"name\":\"structured\",\"inputSchema\":{\"type\":\"object\",\"properties\":{}},\"outputSchema\":{\"$schema\":\"https://json-schema.org/draft/2020-12/schema\",\"type\":\"array\",\"items\":{\"type\":\"number\"}}}],\"resultType\":\"complete\",\"ttlMs\":0,\"cacheScope\":\"private\",\"_meta\":{\"io.modelcontextprotocol/serverInfo\":{\"name\":\"m\",\"version\":\"1\"}}},\"jsonrpc\":\"2.0\",\"id\":2}",
	"{\"result\":{\"content\":[{\"type\":\"text\",\"text\":\"hi\"}],\"resultType\":\"complete\",\"_meta\":{\"io.modelcontextprotocol/serverInfo\":{\"name\":\"m\",\"version\":\"1\"}}},\"jsonrpc\":\"2.0\",\"id\":3}",
	"{\"jsonrpc\":\"2.0\",\"id\":4,\"error\":{\"code\":-32601,\"message\":\"Method not found\"}}",
	"{\"jsonrpc\":\"2.0\",\"id\":5,\"error\":{\"code\":-32022,\"message\":\"Unsupported protocol version: 2025-11-25\",\"data\":{\"supported\":[\"2026-07-28\"],\"requested\":\"2025-11-25\"}}}",
	"{\"jsonrpc\":\"2.0\",\"id\":6,\"error\":{\"code\":-32601,\"message\":\"Method not found\"}}",
	"{\"jsonrpc\":\"2.0\",\"id\":7,\"error\":{\"code\":-32601,\"message\":\"Method not found\"}}",
	"{\"jsonrpc\":\"2.0\",\"id\":8,\"error\":{\"code\":-32601,\"message\":\"Method not found\"}}",
	"{\"result\":{\"got\":null,\"resultType\":\"complete\",\"_meta\":{\"io.modelcontextprotocol/serverInfo\":{\"name\":\"m\",\"version\":\"1\"}}},\"jsonrpc\":\"2.0\",\"id\":9}",
	"{\"jsonrpc\":\"2.0\",\"id\":10,\"error\":{\"code\":-32602,\"message\":\"Request is missing the required _meta envelope for protocol revision 2026-07-28 (io.modelcontextprotocol/protocolVersion, io.modelcontextprotocol/clientCapabilities)\"}}",
	"{\"jsonrpc\":\"2.0\",\"id\":11,\"error\":{\"code\":-32602,\"message\":\"Invalid _meta envelope for protocol revision 2026-07-28: Invalid input: expected object, received undefined\"}}",
	"{\"result\":{\"contents\":[{\"uri\":\"res://a\",\"text\":\"A\"}],\"resultType\":\"complete\",\"ttlMs\":0,\"cacheScope\":\"private\",\"_meta\":{\"io.modelcontextprotocol/serverInfo\":{\"name\":\"m\",\"version\":\"1\"}}},\"jsonrpc\":\"2.0\",\"id\":12}",
	"{\"result\":{\"messages\":[{\"role\":\"user\",\"content\":{\"type\":\"text\",\"text\":\"hi Bo\"}}],\"resultType\":\"complete\",\"_meta\":{\"io.modelcontextprotocol/serverInfo\":{\"name\":\"m\",\"version\":\"1\"}}},\"jsonrpc\":\"2.0\",\"id\":13}",
	"{\"jsonrpc\":\"2.0\",\"id\":14,\"error\":{\"code\":-32603,\"message\":\"Internal error\"}}",
	"{\"jsonrpc\":\"2.0\",\"id\":15,\"error\":{\"code\":-32601,\"message\":\"Method not found\"}}",
	"{\"result\":{\"content\":[{\"type\":\"text\",\"text\":\"[1,2]\"}],\"structuredContent\":[1,2],\"resultType\":\"complete\",\"_meta\":{\"io.modelcontextprotocol/serverInfo\":{\"name\":\"m\",\"version\":\"1\"}}},\"jsonrpc\":\"2.0\",\"id\":16}",
	"{\"result\":{\"resourceTemplates\":[],\"resultType\":\"complete\",\"ttlMs\":0,\"cacheScope\":\"private\",\"_meta\":{\"io.modelcontextprotocol/serverInfo\":{\"name\":\"m\",\"version\":\"1\"}}},\"jsonrpc\":\"2.0\",\"id\":17}",
	"{\"jsonrpc\":\"2.0\",\"id\":18,\"error\":{\"code\":-32601,\"message\":\"Method not found\"}}",
	"{\"result\":{\"got\":null,\"resultType\":\"complete\",\"_meta\":{\"io.modelcontextprotocol/serverInfo\":{\"name\":\"m\",\"version\":\"1\"}}},\"jsonrpc\":\"2.0\",\"id\":19}",
	"{\"jsonrpc\":\"2.0\",\"id\":20,\"error\":{\"code\":-32602,\"message\":\"Invalid _meta envelope for protocol revision 2026-07-28: Invalid input: expected string, received undefined; Invalid input: expected string, received undefined; Invalid option: expected one of \\\"debug\\\"|\\\"info\\\"|\\\"notice\\\"|\\\"warning\\\"|\\\"error\\\"|\\\"critical\\\"|\\\"alert\\\"|\\\"emergency\\\"\"}}",
]

probe_in : List(Str)
probe_in = [
	"{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"server/discover\",\"params\":{\"_meta\":{\"io.modelcontextprotocol/protocolVersion\":\"2026-07-28\",\"io.modelcontextprotocol/clientCapabilities\":{},\"io.modelcontextprotocol/clientInfo\":{\"name\":\"t\",\"version\":\"1\"}}}}",
	"{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"server/discover\",\"params\":{\"_meta\":{\"io.modelcontextprotocol/protocolVersion\":\"2026-07-28\",\"io.modelcontextprotocol/clientCapabilities\":{},\"io.modelcontextprotocol/clientInfo\":{\"name\":\"t\",\"version\":\"1\"}}}}",
	"{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}",
	"{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2025-11-25\",\"capabilities\":{},\"clientInfo\":{\"name\":\"t\",\"version\":\"1\"}}}",
	"{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"ping\"}",
]

probe_out : List(Str)
probe_out = [
	"{\"result\":{\"supportedVersions\":[\"2026-07-28\"],\"capabilities\":{\"logging\":{},\"tools\":{\"listChanged\":true},\"resources\":{\"listChanged\":true,\"subscribe\":true},\"prompts\":{\"listChanged\":true}},\"instructions\":\"hi\",\"resultType\":\"complete\",\"ttlMs\":0,\"cacheScope\":\"private\",\"_meta\":{\"io.modelcontextprotocol/serverInfo\":{\"name\":\"m\",\"version\":\"1\"}}},\"jsonrpc\":\"2.0\",\"id\":1}",
	"{\"result\":{\"supportedVersions\":[\"2026-07-28\"],\"capabilities\":{\"logging\":{},\"tools\":{\"listChanged\":true},\"resources\":{\"listChanged\":true,\"subscribe\":true},\"prompts\":{\"listChanged\":true}},\"instructions\":\"hi\",\"resultType\":\"complete\",\"ttlMs\":0,\"cacheScope\":\"private\",\"_meta\":{\"io.modelcontextprotocol/serverInfo\":{\"name\":\"m\",\"version\":\"1\"}}},\"jsonrpc\":\"2.0\",\"id\":2}",
	"{\"result\":{\"protocolVersion\":\"2025-11-25\",\"capabilities\":{\"logging\":{},\"tools\":{\"listChanged\":true},\"resources\":{\"listChanged\":true,\"subscribe\":true},\"prompts\":{\"listChanged\":true}},\"serverInfo\":{\"name\":\"m\",\"version\":\"1\"},\"instructions\":\"hi\"},\"jsonrpc\":\"2.0\",\"id\":3}",
	"{\"result\":{},\"jsonrpc\":\"2.0\",\"id\":4}",
]

pin_in : List(Str)
pin_in = [
	"{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"server/discover\",\"params\":{\"_meta\":{\"io.modelcontextprotocol/protocolVersion\":\"2026-07-28\",\"io.modelcontextprotocol/clientCapabilities\":{},\"io.modelcontextprotocol/clientInfo\":{\"name\":\"t\",\"version\":\"1\"}}}}",
	"{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"echo\",\"arguments\":{\"text\":\"a\"},\"_meta\":{\"io.modelcontextprotocol/protocolVersion\":\"2026-07-28\",\"io.modelcontextprotocol/clientCapabilities\":{},\"io.modelcontextprotocol/clientInfo\":{\"name\":\"t\",\"version\":\"1\"}}}}",
	"{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2025-11-25\",\"capabilities\":{},\"clientInfo\":{\"name\":\"t\",\"version\":\"1\"}}}",
	"{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"initialize\",\"params\":{\"capabilities\":{}}}",
	"{\"jsonrpc\":\"2.0\",\"id\":5,\"method\":\"server/discover\",\"params\":{\"_meta\":{\"io.modelcontextprotocol/protocolVersion\":\"2026-07-28\",\"io.modelcontextprotocol/clientCapabilities\":{},\"io.modelcontextprotocol/clientInfo\":{\"name\":\"t\",\"version\":\"1\"}}}}",
]

pin_out : List(Str)
pin_out = [
	"{\"result\":{\"supportedVersions\":[\"2026-07-28\"],\"capabilities\":{\"logging\":{},\"tools\":{\"listChanged\":true},\"resources\":{\"listChanged\":true,\"subscribe\":true},\"prompts\":{\"listChanged\":true}},\"instructions\":\"hi\",\"resultType\":\"complete\",\"ttlMs\":0,\"cacheScope\":\"private\",\"_meta\":{\"io.modelcontextprotocol/serverInfo\":{\"name\":\"m\",\"version\":\"1\"}}},\"jsonrpc\":\"2.0\",\"id\":1}",
	"{\"result\":{\"content\":[{\"type\":\"text\",\"text\":\"a\"}],\"resultType\":\"complete\",\"_meta\":{\"io.modelcontextprotocol/serverInfo\":{\"name\":\"m\",\"version\":\"1\"}}},\"jsonrpc\":\"2.0\",\"id\":2}",
	"{\"jsonrpc\":\"2.0\",\"id\":3,\"error\":{\"code\":-32022,\"message\":\"Unsupported protocol version: 2025-11-25\",\"data\":{\"supported\":[\"2026-07-28\"],\"requested\":\"2025-11-25\"}}}",
	"{\"jsonrpc\":\"2.0\",\"id\":4,\"error\":{\"code\":-32022,\"message\":\"Unsupported protocol version: the request did not name a protocol version\",\"data\":{\"supported\":[\"2026-07-28\"]}}}",
	"{\"result\":{\"supportedVersions\":[\"2026-07-28\"],\"capabilities\":{\"logging\":{},\"tools\":{\"listChanged\":true},\"resources\":{\"listChanged\":true,\"subscribe\":true},\"prompts\":{\"listChanged\":true}},\"instructions\":\"hi\",\"resultType\":\"complete\",\"ttlMs\":0,\"cacheScope\":\"private\",\"_meta\":{\"io.modelcontextprotocol/serverInfo\":{\"name\":\"m\",\"version\":\"1\"}}},\"jsonrpc\":\"2.0\",\"id\":5}",
]

badfirst_in : List(Str)
badfirst_in = [
	"{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/list\",\"params\":{\"_meta\":{\"io.modelcontextprotocol/protocolVersion\":\"2026-07-28\"}}}",
	"{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/list\",\"params\":{\"_meta\":{\"io.modelcontextprotocol/protocolVersion\":7,\"io.modelcontextprotocol/clientCapabilities\":[]}}}",
	"{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/list\",\"params\":{\"_meta\":{\"io.modelcontextprotocol/protocolVersion\":\"2025-11-25\",\"io.modelcontextprotocol/clientCapabilities\":{},\"io.modelcontextprotocol/clientInfo\":{\"name\":\"t\",\"version\":\"1\"}}}}",
	"{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2025-11-25\",\"capabilities\":{},\"clientInfo\":{\"name\":\"t\",\"version\":\"1\"}}}",
]

badfirst_out : List(Str)
badfirst_out = [
	"{\"jsonrpc\":\"2.0\",\"id\":1,\"error\":{\"code\":-32602,\"message\":\"Invalid _meta envelope for protocol revision 2026-07-28: io.modelcontextprotocol/clientCapabilities: missing\",\"data\":{\"envelope\":{\"key\":\"io.modelcontextprotocol/clientCapabilities\",\"problem\":\"missing\"}}}}",
	"{\"jsonrpc\":\"2.0\",\"id\":2,\"error\":{\"code\":-32602,\"message\":\"Invalid _meta envelope for protocol revision 2026-07-28: io.modelcontextprotocol/protocolVersion: Invalid input: expected string, received number\",\"data\":{\"envelope\":{\"key\":\"io.modelcontextprotocol/protocolVersion\",\"problem\":\"Invalid input: expected string, received number\"}}}}",
	"{\"jsonrpc\":\"2.0\",\"id\":3,\"error\":{\"code\":-32022,\"message\":\"Unsupported protocol version: 2025-11-25\",\"data\":{\"supported\":[\"2026-07-28\"],\"requested\":\"2025-11-25\"}}}",
	"{\"result\":{\"protocolVersion\":\"2025-11-25\",\"capabilities\":{\"logging\":{},\"tools\":{\"listChanged\":true},\"resources\":{\"listChanged\":true,\"subscribe\":true},\"prompts\":{\"listChanged\":true}},\"serverInfo\":{\"name\":\"m\",\"version\":\"1\"},\"instructions\":\"hi\"},\"jsonrpc\":\"2.0\",\"id\":4}",
]

respfirst_in : List(Str)
respfirst_in = [
	"{\"jsonrpc\":\"2.0\",\"id\":\"x\",\"result\":{}}",
	"{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"x/echo\",\"params\":{\"v\":3,\"_meta\":{\"io.modelcontextprotocol/protocolVersion\":\"2026-07-28\",\"io.modelcontextprotocol/clientCapabilities\":{},\"io.modelcontextprotocol/clientInfo\":{\"name\":\"t\",\"version\":\"1\"}}}}",
]

respfirst_out : List(Str)
respfirst_out = [
	"{\"result\":{\"got\":null,\"resultType\":\"complete\",\"_meta\":{\"io.modelcontextprotocol/serverInfo\":{\"name\":\"m\",\"version\":\"1\"}}},\"jsonrpc\":\"2.0\",\"id\":1}",
]

initclaim_in : List(Str)
initclaim_in = [
	"{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2025-11-25\",\"capabilities\":{},\"clientInfo\":{\"name\":\"t\",\"version\":\"1\"},\"_meta\":{\"io.modelcontextprotocol/protocolVersion\":\"2026-07-28\",\"io.modelcontextprotocol/clientCapabilities\":{},\"io.modelcontextprotocol/clientInfo\":{\"name\":\"t\",\"version\":\"1\"}}}}",
	"{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"x/echo\",\"params\":{\"v\":4,\"_meta\":{\"io.modelcontextprotocol/protocolVersion\":\"2026-07-28\",\"io.modelcontextprotocol/clientCapabilities\":{},\"io.modelcontextprotocol/clientInfo\":{\"name\":\"t\",\"version\":\"1\"}}}}",
]

initclaim_out : List(Str)
initclaim_out = [
	"{\"jsonrpc\":\"2.0\",\"id\":1,\"error\":{\"code\":-32601,\"message\":\"Method not found\"}}",
	"{\"result\":{\"got\":null,\"resultType\":\"complete\",\"_meta\":{\"io.modelcontextprotocol/serverInfo\":{\"name\":\"m\",\"version\":\"1\"}}},\"jsonrpc\":\"2.0\",\"id\":2}",
]

notefirst_in : List(Str)
notefirst_in = [
	"{\"jsonrpc\":\"2.0\",\"method\":\"x/poke\",\"params\":{\"_meta\":{\"io.modelcontextprotocol/protocolVersion\":\"2026-07-28\",\"io.modelcontextprotocol/clientCapabilities\":{},\"io.modelcontextprotocol/clientInfo\":{\"name\":\"t\",\"version\":\"1\"}}}}",
	"{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"x/echo\",\"params\":{\"v\":5}}",
]

notefirst_out : List(Str)
notefirst_out = [
	"{\"jsonrpc\":\"2.0\",\"id\":1,\"error\":{\"code\":-32602,\"message\":\"Request is missing the required _meta envelope for protocol revision 2026-07-28 (io.modelcontextprotocol/protocolVersion, io.modelcontextprotocol/clientCapabilities)\"}}",
]

reject_in : List(Str)
reject_in = [
	"{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2025-11-25\",\"capabilities\":{},\"clientInfo\":{\"name\":\"t\",\"version\":\"1\"}}}",
	"{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/list\"}",
	"{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}",
	"{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"x/echo\",\"params\":{\"v\":6,\"_meta\":{\"io.modelcontextprotocol/protocolVersion\":\"2026-07-28\",\"io.modelcontextprotocol/clientCapabilities\":{},\"io.modelcontextprotocol/clientInfo\":{\"name\":\"t\",\"version\":\"1\"}}}}",
]

reject_out : List(Str)
reject_out = [
	"{\"jsonrpc\":\"2.0\",\"id\":1,\"error\":{\"code\":-32022,\"message\":\"Unsupported protocol version: 2025-11-25\",\"data\":{\"supported\":[\"2026-07-28\"],\"requested\":\"2025-11-25\"}}}",
	"{\"jsonrpc\":\"2.0\",\"id\":2,\"error\":{\"code\":-32022,\"message\":\"Unsupported protocol version: the request did not name a protocol version\",\"data\":{\"supported\":[\"2026-07-28\"]}}}",
	"{\"result\":{\"got\":null,\"resultType\":\"complete\",\"_meta\":{\"io.modelcontextprotocol/serverInfo\":{\"name\":\"m\",\"version\":\"1\"}}},\"jsonrpc\":\"2.0\",\"id\":3}",
]

hints_in : List(Str)
hints_in = [
	"{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/list\",\"params\":{\"_meta\":{\"io.modelcontextprotocol/protocolVersion\":\"2026-07-28\",\"io.modelcontextprotocol/clientCapabilities\":{},\"io.modelcontextprotocol/clientInfo\":{\"name\":\"t\",\"version\":\"1\"}}}}",
	"{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"resources/read\",\"params\":{\"uri\":\"res://a\",\"_meta\":{\"io.modelcontextprotocol/protocolVersion\":\"2026-07-28\",\"io.modelcontextprotocol/clientCapabilities\":{},\"io.modelcontextprotocol/clientInfo\":{\"name\":\"t\",\"version\":\"1\"}}}}",
	"{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"prompts/list\",\"params\":{\"_meta\":{\"io.modelcontextprotocol/protocolVersion\":\"2026-07-28\",\"io.modelcontextprotocol/clientCapabilities\":{},\"io.modelcontextprotocol/clientInfo\":{\"name\":\"t\",\"version\":\"1\"}}}}",
]

hints_out : List(Str)
hints_out = [
	"{\"result\":{\"tools\":[{\"name\":\"echo\",\"inputSchema\":{\"type\":\"object\",\"$schema\":\"https://json-schema.org/draft/2020-12/schema\",\"properties\":{\"text\":{\"type\":\"string\"}},\"required\":[\"text\"]}},{\"name\":\"ask\",\"inputSchema\":{\"type\":\"object\",\"properties\":{}}},{\"name\":\"url\",\"inputSchema\":{\"type\":\"object\",\"properties\":{}}},{\"name\":\"sample\",\"inputSchema\":{\"type\":\"object\",\"properties\":{}}},{\"name\":\"stateonly\",\"inputSchema\":{\"type\":\"object\",\"properties\":{}}},{\"name\":\"notify\",\"inputSchema\":{\"type\":\"object\",\"properties\":{}}},{\"name\":\"structured\",\"inputSchema\":{\"type\":\"object\",\"properties\":{}},\"outputSchema\":{\"$schema\":\"https://json-schema.org/draft/2020-12/schema\",\"type\":\"array\",\"items\":{\"type\":\"number\"}}}],\"resultType\":\"complete\",\"ttlMs\":5000,\"cacheScope\":\"public\",\"_meta\":{\"io.modelcontextprotocol/serverInfo\":{\"name\":\"m\",\"version\":\"1\"}}},\"jsonrpc\":\"2.0\",\"id\":1}",
	"{\"result\":{\"contents\":[{\"uri\":\"res://a\",\"text\":\"A\"}],\"resultType\":\"complete\",\"ttlMs\":7,\"cacheScope\":\"private\",\"_meta\":{\"io.modelcontextprotocol/serverInfo\":{\"name\":\"m\",\"version\":\"1\"}}},\"jsonrpc\":\"2.0\",\"id\":2}",
	"{\"result\":{\"prompts\":[{\"name\":\"p\",\"arguments\":[{\"name\":\"who\",\"required\":true}]}],\"resultType\":\"complete\",\"ttlMs\":0,\"cacheScope\":\"private\",\"_meta\":{\"io.modelcontextprotocol/serverInfo\":{\"name\":\"m\",\"version\":\"1\"}}},\"jsonrpc\":\"2.0\",\"id\":3}",
]
