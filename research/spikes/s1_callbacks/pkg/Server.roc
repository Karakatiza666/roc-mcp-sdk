## Spike: a generic server that stores effectful handlers and app state.
Server(state) :: {
	name : Str,
	tools : List({ name : Str, run! : state, Str => (state, Str) }),
}.{
	new : Str -> Server(state)
	new = |name| { name, tools: [] }

	tool : Server(state), Str, (state, Str => (state, Str)) -> Server(state)
	tool = |server, name, run!| { ..server, tools: server.tools.append({ name, run! }) }

	## Runs the loop over the injected IO record until read_line! returns Err.
	serve! : Server(state), state, { read_line! : () => Try(Str, [Eof]), write! : Str => {} } => state
	serve! = |server, init, io| {
		var $state = init
		var $go = Bool.True
		while $go {
			match (io.read_line!)() {
				Ok(line) => {
					match server.tools.find_first(|t| t.name == line) {
						Ok(t) => {
							(s2, out) = (t.run!)($state, line)
							$state = s2
							(io.write!)(out)
						}
						Err(_) => (io.write!)("unknown ${line}")
					}
				}
				Err(Eof) => {
					$go = Bool.False
				}
			}
		}
		$state
	}
}
