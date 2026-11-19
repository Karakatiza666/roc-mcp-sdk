app [main!] { pkg: "../package/main.roc" }

import pkg.JsonValue
import pkg.Content
import pkg.Tool
import pkg.Resource
import pkg.ResourceContents
import pkg.ResourceTemplate
import pkg.Prompt
import pkg.Outcome
import pkg.Server
import pkg.Engine
import pkg.LogLevel
import pkg.Ctx
import pkg.ToolResult
import Support/Session

main! = |_args| Ok({})

## Lifecycle and negotiation (DESIGN 5, rows Versions, Era selection, Legacy methods).
## Expected lines are JS SDK 2.0.0 transcripts (.tmp/s4/js), compared byte for byte.

empty : Server({})
empty = Server.new({ name: "e", version: "1" })

full : Server({})
full =
	Server.new({ name: "f", version: "2" })
		.with_title("F")
		.with_description("d")
		.with_website_url("https://w")
		.with_icon(Content.icon("https://i"))
		.with_instructions("use it")
		.with_logging()
		.tool(Tool.new("echo"), echo)
		.resource(Resource.new("file:///a", "a"), |s, _c, _u| (s, Outcome.done([])))
		.resource_template(ResourceTemplate.new("file:///t/{name}", "tpl"), |s, _c, _u, _v| (s, Outcome.done([])))
		.template_complete("tpl", "name", |s, _c, _v, _cc| (s, []))
		.prompt(Prompt.new("plain"), plain)

echo : {}, Ctx, { text : Str } => ({}, Outcome(ToolResult))
echo = |s, _c, args| (s, Outcome.done(ToolResult.text(args.text)))

plain : {}, Ctx, {} => ({}, Outcome(Prompt.Result))
plain = |s, _c, _args| (s, Outcome.done({ description: Err(None), messages: [] }))

init : Str -> Str
init = |version| "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"${version}\",\"capabilities\":{},\"clientInfo\":{\"name\":\"c\",\"version\":\"1\"}}}"

# An unknown version gets the latest; a supported one is echoed; 2026-07-28 is not an initialize version.
expect Session.run(empty, {}, [init("1999-01-01")], Session.no_calls) == ["{\"result\":{\"protocolVersion\":\"2025-11-25\",\"capabilities\":{},\"serverInfo\":{\"name\":\"e\",\"version\":\"1\"}},\"jsonrpc\":\"2.0\",\"id\":1}"]
expect Session.run(empty, {}, [init("2024-10-07")], Session.no_calls) == ["{\"result\":{\"protocolVersion\":\"2024-10-07\",\"capabilities\":{},\"serverInfo\":{\"name\":\"e\",\"version\":\"1\"}},\"jsonrpc\":\"2.0\",\"id\":1}"]
expect Session.first_has(Session.run(empty, {}, [init("2025-06-18")], Session.no_calls), "\"protocolVersion\":\"2025-06-18\"")
expect Session.first_has(Session.run(empty, {}, [init("2026-07-28")], Session.no_calls), "\"protocolVersion\":\"2025-11-25\"")
expect Engine.latest_version == "2025-11-25" and Engine.legacy_versions.len() == 5 and Engine.modern_versions == ["2026-07-28"]

# serverInfo fields, icons, instructions and the derived capabilities in registration order.
expect {
	out = Session.run(full, {}, [init("2025-06-18")], Session.no_calls)
	out == ["{\"result\":{\"protocolVersion\":\"2025-06-18\",\"capabilities\":{\"logging\":{},\"tools\":{\"listChanged\":true},\"resources\":{\"listChanged\":true},\"completions\":{},\"prompts\":{\"listChanged\":true}},\"serverInfo\":{\"name\":\"f\",\"version\":\"2\",\"title\":\"F\",\"description\":\"d\",\"websiteUrl\":\"https://w\",\"icons\":[{\"src\":\"https://i\"}]},\"instructions\":\"use it\"},\"jsonrpc\":\"2.0\",\"id\":1}"]
}

# with_capability adds a capability, and merges into a derived one.
expect {
	s : Server({})
	s =
		empty
			.with_capability("experimental", Object([("x", Object([]))]))
			.tool_json(Tool.new("t"), |st, _c, _a| (st, Outcome.done(ToolResult.text(""))))
			.with_capability("tools", Object([("listChanged", Bool(Bool.False))]))
	s.capabilities().to_str() == "{\"experimental\":{\"x\":{}},\"tools\":{\"listChanged\":false}}"
}

# Requests before initialize are served (JS parity); ping is `{}`.
expect Session.run(empty, {}, ["{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"ping\"}"], Session.no_calls) == ["{\"result\":{},\"jsonrpc\":\"2.0\",\"id\":1}"]
expect Session.run(empty, {}, ["{\"jsonrpc\":\"2.0\",\"id\":\"s\",\"method\":\"ping\",\"params\":{\"_meta\":{\"x\":1}}}"], Session.no_calls) == ["{\"result\":{},\"jsonrpc\":\"2.0\",\"id\":\"s\"}"]

# Methods the server does not serve: -32601.
expect {
	out = Session.run(
		empty,
		{},
		[
			"{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/list\"}",
			"{\"jsonrpc\":\"2.0\",\"id\":8,\"method\":\"foo/bar\"}",
			"{\"jsonrpc\":\"2.0\",\"id\":11,\"method\":\"logging/setLevel\",\"params\":{\"level\":\"debug\"}}",
			"{\"jsonrpc\":\"2.0\",\"id\":12,\"method\":\"completion/complete\",\"params\":{}}",
			"{\"jsonrpc\":\"2.0\",\"id\":13,\"method\":\"resources/subscribe\",\"params\":{\"uri\":\"x\"}}",
			"{\"jsonrpc\":\"2.0\",\"id\":14,\"method\":\"prompts/list\"}",
			"{\"jsonrpc\":\"2.0\",\"id\":15,\"method\":\"resources/read\",\"params\":{\"uri\":\"file:///a\"}}",
		],
		Session.no_calls,
	)
	out
		== [
			"{\"jsonrpc\":\"2.0\",\"id\":2,\"error\":{\"code\":-32601,\"message\":\"Method not found\"}}",
			"{\"jsonrpc\":\"2.0\",\"id\":8,\"error\":{\"code\":-32601,\"message\":\"Method not found\"}}",
			"{\"jsonrpc\":\"2.0\",\"id\":11,\"error\":{\"code\":-32601,\"message\":\"Method not found\"}}",
			"{\"jsonrpc\":\"2.0\",\"id\":12,\"error\":{\"code\":-32601,\"message\":\"Method not found\"}}",
			"{\"jsonrpc\":\"2.0\",\"id\":13,\"error\":{\"code\":-32601,\"message\":\"Method not found\"}}",
			"{\"jsonrpc\":\"2.0\",\"id\":14,\"error\":{\"code\":-32601,\"message\":\"Method not found\"}}",
			"{\"jsonrpc\":\"2.0\",\"id\":15,\"error\":{\"code\":-32601,\"message\":\"Method not found\"}}",
		]
}

# initialize never fails: missing params give the latest version (JS: -32603 with a zod dump).
expect Session.run(empty, {}, ["{\"jsonrpc\":\"2.0\",\"id\":17,\"method\":\"initialize\"}"], Session.no_calls) == ["{\"result\":{\"protocolVersion\":\"2025-11-25\",\"capabilities\":{},\"serverInfo\":{\"name\":\"e\",\"version\":\"1\"}},\"jsonrpc\":\"2.0\",\"id\":17}"]

# The session: era, negotiated version, client info and capabilities, initialized.
expect {
	r = Session.drive(empty, Engine.Session.new, {}, [init("2025-03-26"), "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}"], Session.no_calls, 0)
	r.out.len() == 1 and r.session.current_era() == Legacy and r.session.negotiated_version() == "2025-03-26" and r.session.is_initialized()
}
expect Engine.Session.new.current_era() == Undecided and !(Engine.Session.new.is_initialized())

# initialize again re-negotiates (JS parity).
expect {
	r = Session.drive(empty, Engine.Session.new, {}, [init("2025-03-26"), init("2025-06-18")], Session.no_calls, 0)
	r.session.negotiated_version() == "2025-06-18"
}

# An empty legacy list refuses 2025 clients with -32022.
expect {
	modern_only : Server({})
	modern_only = empty.with_protocol_versions({ legacy: [], modern: ["2026-07-28"] })
	Session.same(
		Session.run(modern_only, {}, [init("2025-11-25")], Session.no_calls),
		["{\"jsonrpc\":\"2.0\",\"id\":1,\"error\":{\"code\":-32022,\"message\":\"Unsupported protocol version: 2025-11-25\",\"data\":{\"supported\":[\"2026-07-28\"],\"requested\":\"2025-11-25\"}}}"],
	)
}

# A custom legacy version list.
expect {
	only_old : Server({})
	only_old = empty.with_protocol_versions({ legacy: ["2025-03-26"], modern: [] })
	Session.first_has(Session.run(only_old, {}, [init("2025-11-25")], Session.no_calls), "\"protocolVersion\":\"2025-03-26\"")
}

# Session.to_json / from_json round trip.
expect {
	r = Session.drive(full, Engine.Session.new.with_session_id("abc"), {}, [init("2025-06-18"), "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}", "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"logging/setLevel\",\"params\":{\"level\":\"error\"}}"], Session.no_calls, 0)
	j = r.session.to_json()
	match Engine.Session.from_json(j) {
		Ok(back) => back.to_json() == j and back.logging_level() == Ok(LogLevel.from_str("error") ?? Debug) and back.negotiated_version() == "2025-06-18"
		Err(_) => Bool.False
	}
}
expect Engine.Session.from_json(Null).is_err()

# The auth and session id that a transport sets reach the Ctx.
expect {
	auth = { token: "t", client_id: "c", scopes: ["s"], expires_at: Err(None), resource: Err(None), extra: Null }
	sess = Engine.Session.new.with_auth(Ok(auth)).with_session_id("sid")
	step = Engine.receive(full, sess, {}, "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/call\",\"params\":{\"name\":\"echo\",\"arguments\":{\"text\":\"x\"}}}")
	match step.calls {
		[call] => call.ctx.auth().map_ok(|a| a.token) == Ok("t") and call.ctx.session_id() == Ok("sid") and call.ctx.era() == Legacy
		_ => Bool.False
	}
}

# Server.warnings: tool names outside ^[A-Za-z0-9._-]{1,128}$.
expect {
	s : Server({})
	s = empty.tool_json(Tool.new("ok_name-1.2"), |st, _c, _a| (st, Outcome.done(ToolResult.text("")))).tool_json(Tool.new("bad name!"), |st, _c, _a| (st, Outcome.done(ToolResult.text(""))))
	ws = s.warnings()
	ws.len() == 1 and Session.first_has(ws, "\" \", \"!\"")
}

# close sends nothing on a 2025 session.
expect Engine.close(Engine.Session.new) == []
