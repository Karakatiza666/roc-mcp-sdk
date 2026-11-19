import Server
import Engine
import Ctx

## Spike: the effectful stdio driver. The app supplies the effects.
Stdio :: [].{
	Io : {
		read_line! : () => Try(Str, [EndOfInput]),
		write_line! : Str => {},
		log! : Str => {},
	}

	serve! : Server(state), state, Stdio.Io => state
	serve! = |server, init, io| {
		var $state = init
		var $session = Engine.Session.new
		var $go = Bool.True
		while $go {
			match (io.read_line!)() {
				Err(EndOfInput) => {
					$go = Bool.False
				}
				Ok(line) if line.trim().is_empty() => {}
				Ok(line) => {
					step = Engine.receive(server, $session, line)
					for l in step.out {
						(io.write_line!)(l)
					}
					match step.call {
						Err(NoCall) => {
							$session = step.session
						}
						Ok(call) => {
							(s2, outcome) = (call.run!)($state, call.ctx.with_sender(io.write_line!))
							$state = s2
							done = Engine.complete(step.session, call.request_id, call.message, outcome)
							$session = done.session
							for l in done.out {
								(io.write_line!)(l)
							}
						}
					}
				}
			}
		}
		(io.log!)("stdin closed; ${$session.waiting_count().to_str()} requests still wait for input")
		$state
	}
}
