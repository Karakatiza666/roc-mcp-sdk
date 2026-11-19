app [main!] {
	mcp: "../package/main.roc",
	pf: platform "https://github.com/roc-lang/basic-cli/releases/download/0.28.1/7brgwR8YUqfeGrkdfF1V4GPPN7DnP7ftqub9KcrTEZtr.tar.zst",
}

import pf.Stdin
import pf.Stdout
import pf.Stderr
import pf.Utc
import mcp.Server
import mcp.Ctx
import mcp.Stdio
import mcp.Tool
import mcp.ToolResult
import mcp.Outcome
import mcp.Schema

# The smallest MCP server: one tool that greets. Build it with
# `roc build examples/hello.roc`, then point an MCP client at the binary.

GreetArgs : { name : Str }

greet! : {}, Ctx, GreetArgs => ({}, Outcome(ToolResult))
greet! = |st, _ctx, args| (st, Outcome.done(ToolResult.text("Hello, ${args.name}!")))

server : Server({})
server =
	Server.new({ name: "hello", version: "0.1.0" })
		.tool(
			Tool.new("greet")
				.with_description("Say hello")
				.with_input_schema(Schema.object([("name", Schema.Prop.required(Schema.string(Schema.described("Who to greet"))))])),
			greet!,
		)

## The basic-cli adapter (DESIGN 4.9). basic-cli 0.28.1 cannot wait with a timeout, so the
## wait is ignored. A line that is not UTF-8 is consumed by basic-cli; it becomes an empty
## line, which the loop skips.
io : Stdio.Io
io = {
	read_line!: |_wait|
		match Stdin.line!() {
			Ok(line) => Ok(line)
			Err(BadUtf8(_)) => Ok("")
			Err(_) => Err(EndOfInput)
		},
	write_line!: |line| Stdout.line!(line).map_err(|_| Closed),
	log!: |line| Stderr.line!(line) ?? {},
	now_ms!: || Utc.now!().to_millis_since_epoch().to_u64_wrap(),
}

main! = |_args| {
	_ = Stdio.serve!(server, {}, io)
	Ok({})
}
