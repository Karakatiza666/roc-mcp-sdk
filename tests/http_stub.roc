app [main!] { pkg: "../package/main.roc" }

import pkg.JsonValue
import pkg.Server
import pkg.StreamableHttp

# L0 tests for the real (pure) parts of the Streamable HTTP stub. No test here calls `handle!` or
# `notify!`: they crash by design in this release.

main! = |_args| Ok({})

server : Server({})
server = Server.new({ name: "http-stub-test", version: "0.0.0" })

opts : StreamableHttp.Options
opts = StreamableHttp.default_options

expect opts.sessions == Stateful
expect opts.response_mode == Auto
expect opts.legacy == Serve
expect opts.allowed_hosts == []
expect opts.allowed_origins == []
expect opts.keep_alive_ms == 15000
expect opts.retry_ms == 0
expect opts.max_subscriptions == 1024

# `new` keeps the options it is given.
expect StreamableHttp.new(server, opts).options() == opts

expect {
	custom = { ..StreamableHttp.default_options, sessions: Stateless, response_mode: Json, legacy: Reject, allowed_hosts: ["localhost"] }
	got = StreamableHttp.new(server, custom).options()
	got.sessions == Stateless and got.response_mode == Json and got.legacy == Reject and got.allowed_hosts == ["localhost"]
}

# The pure security stubs fail closed with a 501 instead of crashing (DESIGN 12.3).
request : StreamableHttp.Request
request = { method: "POST", uri: "/mcp", headers: [("Host", "localhost:3000")], body: [] }

expect
	match StreamableHttp.validate_host(request, ["localhost"]) {
		Err(r) => r.status == 501
		Ok(_) => Bool.False
	}

expect
	match StreamableHttp.validate_origin(request, ["localhost"]) {
		Err(r) => r.status == 501
		Ok(_) => Bool.False
	}

# A constant argument must not break the build (DESIGN 12.3): this runs at compile time.
expect
	match JsonValue.parse("{\"resource\":\"https://example.com/mcp\"}") {
		Ok(meta) => StreamableHttp.oauth_metadata_response(meta).status == 501
		Err(_) => Bool.False
	}
