app [main!] { pkg: "pkg/main.roc" }

import pkg.JsonValue
import pkg.Server
import pkg.Engine

main! = |_args| Ok({})

## L0: the pure core drives a whole session; handler runs are scripted outcomes.
server : Server({})
server = Server.new({ name: "t", version: "1", instructions: "" })
	.tool({ name: "echo", description: "", input_schema: Object([]) }, |s, _ctx, args| (s, Text(args.text)))

init_line = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"1999-01-01\",\"capabilities\":{}}}"

expect {
	step = Engine.receive(server, Engine.Session.new, init_line)
	step.out.len() == 1 and step.out.first().map_ok(|l| l.contains("\"protocolVersion\":\"2025-11-25\"")) == Ok(Bool.True)
}

expect {
	s1 = Engine.receive(server, Engine.Session.new, init_line).session
	step = Engine.receive(server, s1, "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"echo\",\"arguments\":{\"text\":\"x\"}}}")
	match step.call {
		Ok(call) => {
			done = Engine.complete(step.session, call.request_id, call.message, InputRequired([("roots", Object([("method", String("roots/list"))]))]))
			done.out == ["{\"jsonrpc\":\"2.0\",\"id\":\"srv-0\",\"method\":\"roots/list\",\"params\":null}"]
			and done.session.waiting_count() == 1
			and {
				back = Engine.receive(server, done.session, "{\"jsonrpc\":\"2.0\",\"id\":\"srv-0\",\"result\":{\"roots\":[]}}")
				back.call.is_ok() and back.session.waiting_count() == 0
			}
		}
		Err(_) => Bool.False
	}
}

expect {
	step = Engine.receive(server, Engine.Session.new, "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/call\",\"params\":{\"name\":\"echo\",\"arguments\":{}}}")
	step.call.is_err() and step.out.first().map_ok(|l| l.contains("\"isError\":true")) == Ok(Bool.True)
}
