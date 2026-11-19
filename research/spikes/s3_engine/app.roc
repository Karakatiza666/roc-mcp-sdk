app [main!] { pf: platform "https://github.com/roc-lang/basic-cli/releases/download/0.28.1/7brgwR8YUqfeGrkdfF1V4GPPN7DnP7ftqub9KcrTEZtr.tar.zst", mcp: "pkg/main.roc" }

import pf.Stdout
import pf.Stdin
import pf.Stderr
import mcp.JsonValue
import mcp.Ctx
import mcp.Server
import mcp.Stdio

## App state, as in roc-syntax-mcp: a detection cache that a notification clears.
State : { detected : Try(Str, [NotYet]), detections : U64 }

EchoArgs : { text : Str, times : Try(U64, [Missing]) }

echo_tool! : State, Ctx, EchoArgs => (State, Server.Reply)
echo_tool! = |state, ctx, args| {
	ctx.log!("info", "echo called")
	n = args.times ?? 1
	(state, Text(Str.join_with(List.repeat(args.text, n), " ")))
}

## Asks the client for its roots once, then serves from the cache.
where_tool! : State, Ctx, {} => (State, Server.Reply)
where_tool! = |state, ctx, {}| match state.detected {
	Ok(root) => (state, Text("cached: ${root}"))
	Err(NotYet) =>
		if !ctx.has_client_capability("roots") {
			({ ..state, detected: Ok("env"), detections: state.detections + 1 }, Text("from env"))
		} else {
			match ctx.input_response("roots") {
				Err(NotAnswered) => {
					req : JsonValue
					req = Object([("method", String("roots/list")), ("params", Object([]))])
					(state, NeedInput([("roots", req)]))
				}
				Ok(answer) => {
					root = match answer.get_or_null("roots") {
						Array([first, ..]) => first.get_or_null("uri").as_str() ?? "?"
						_ => "no roots"
					}
					({ ..state, detected: Ok(root), detections: state.detections + 1 }, Text("from roots: ${root}"))
				}
			}
		}
}

main! = |_args| {
	server =
		Server.new({ name: "spike", version: "0.0.1", instructions: "Spike server." })
			.tool({ name: "echo", description: "Echo text", input_schema: Object([("type", String("object"))]) }, echo_tool!)
			.tool({ name: "where", description: "Where am I", input_schema: Object([("type", String("object"))]) }, where_tool!)
			.on_notification("notifications/roots/list_changed", |state, _ctx, _params| { ..state, detected: Err(NotYet) })
	io = {
		read_line!: || Stdin.line!().map_err(|_| EndOfInput),
		write_line!: |line| Stdout.line!(line) ?? {},
		log!: |line| Stderr.line!(line) ?? {},
	}
	final = Stdio.serve!(server, { detected: Err(NotYet), detections: 0 }, io)
	Stderr.line!("detections=${final.detections.to_str()}")?
	Ok({})
}
