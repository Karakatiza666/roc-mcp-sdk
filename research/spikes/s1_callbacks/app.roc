app [main!] { pf: platform "https://github.com/roc-lang/basic-cli/releases/download/0.28.1/7brgwR8YUqfeGrkdfF1V4GPPN7DnP7ftqub9KcrTEZtr.tar.zst", mcp: "pkg/main.roc" }

import pf.Stdout
import pf.Stdin
import mcp.Server

main! = |_args| {
	server = Server.new("demo")
		.tool("count", |n, _arg| (n + 1, "count=${n.to_str()}"))
		.tool("hello", |n, arg| {
			Stdout.line!("(effect inside handler)") ?? {}
			(n, "hello ${arg}")
		})
	io = {
		read_line!: || Stdin.line!().map_err(|_| Eof),
		write!: |s| Stdout.line!(s) ?? {},
	}
	final = server.serve!(0.U64, io)
	Stdout.line!("final=${final.to_str()}")?
	Ok({})
}
