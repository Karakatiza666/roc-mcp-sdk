app [main!] {
	mcp: "../../package/main.roc",
	pf: platform "https://github.com/roc-lang/basic-cli/releases/download/0.28.1/7brgwR8YUqfeGrkdfF1V4GPPN7DnP7ftqub9KcrTEZtr.tar.zst",
}

import pf.Stdin
import pf.Stdout
import mcp.Server
import mcp.Engine

# One Engine.receive on one stdin line, with a server that has no tools.
main! = |_args| {
	line = Stdin.line!() ?? ""
	server : Server({})
	server = Server.new({ name: "m", version: "0" })
	step = Engine.receive(server, Engine.Session.new, {}, line)
	for l in step.out {
		Stdout.line!(l) ?? {}
	}
	Ok({})
}
