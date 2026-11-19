import Server
import Engine
import Ctx

## The stdio transport: newline-delimited JSON-RPC over effects that the app supplies.
##
## The loop is sequential: one handler runs at a time, and no input is read while it runs.
## Requests parked on server-to-client input (roots, elicitation, sampling) interleave with
## other traffic, and their deadlines fire when `read_line!` times out, or, on a platform
## that cannot wait with a timeout, when the next line arrives.
Stdio :: [].{

	## The effects. `read_line!` gets `Within(ms)` when a parked request has a deadline; a platform
	## that cannot wait with a timeout may ignore it and block (the deadline then fires late).
	Io : {
		read_line! : [Forever, Within(U64)] => Try(Str, [EndOfInput, TimedOut]),
		write_line! : Str => Try({}, [Closed]),
		log! : Str => {},
		now_ms! : () => U64,
	}

	Stopped : [InputEnded, OutputClosed]

	## Serves until stdin ends or stdout closes. Returns the final state.
	##
	## At start, each `Server.warnings` line goes to `log!`. At the end of input the lines of
	## `Engine.close` are written. A failed write stops the loop with `OutputClosed`.
	serve! : Server(state), state, Stdio.Io => { state : state, stopped : Stdio.Stopped }
	serve! = |server, init, io| {
		for w in server.warnings() {
			(io.log!)("mcp: warning: ${w}")
		}
		var $state = init
		var $session = Engine.Session.new
		var $stopped = Running
		while $stopped == Running {
			# 1. A deadline that has already passed fires before any read.
			wait = read_wait(Engine.next_deadline($session), (io.now_ms!)())
			step =
				match wait {
					Expired => Expire
					Forever => read_step!(io, Forever)
					Within(ms) => read_step!(io, Within(ms))
				}
			match step {
				Ended => {
					for l in Engine.close($session) {
						(io.write_line!)(l) ?? {}
					}
					n = $session.waiting()
					if n > 0 {
						(io.log!)("mcp: stdin closed; ${n.to_str()} request(s) still waited for client input")
					}
					$stopped = InputEnded
				}
				Skip => {}
				Expire => {
					now = (io.now_ms!)()
					match drive!(server, io, $state, Engine.expire(server, $session, $state, now)) {
						Ok((s, sess)) => {
							$state = s
							$session = sess
						}
						Err(Closed) => {
							$stopped = OutputClosed
						}
					}
				}
				Line(line) => {
					# 2. Without a timed read, a deadline that passed while blocked fires now,
					#    before the line that ended the wait.
					now = (io.now_ms!)()
					expired =
						match Engine.next_deadline($session) {
							Ok(d) if d <= now => drive!(server, io, $state, Engine.expire(server, $session, $state, now))
							_ => Ok(($state, $session))
						}
					match expired {
						Err(Closed) => {
							$stopped = OutputClosed
						}
						Ok((s1, sess1)) =>
							match drive!(server, io, s1, Engine.receive(server, sess1, s1, line)) {
								Ok((s, sess)) => {
									$state = s
									$session = sess
								}
								Err(Closed) => {
									$state = s1
									$stopped = OutputClosed
								}
							}
					}
				}
			}
		}
		stopped =
			match $stopped {
				OutputClosed => OutputClosed
				_ => InputEnded
			}
		{ state: $state, stopped }
	}
}

## How long to wait for the next line, given the earliest input deadline.
read_wait : Try(U64, [None]), U64 -> [Forever, Within(U64), Expired]
read_wait = |deadline, now|
	match deadline {
		Err(None) => Forever
		Ok(d) if d <= now => Expired
		Ok(d) => Within(d - now)
	}

## Reads one line and classifies it. An empty line is skipped.
read_step! : Stdio.Io, [Forever, Within(U64)] => [Ended, Expire, Skip, Line(Str)]
read_step! = |io, wait|
	match (io.read_line!)(wait) {
		Err(EndOfInput) => Ended
		Err(TimedOut) => Expire
		Ok(line) if line.trim().is_empty() => Skip
		Ok(line) => Line(line)
	}

## Sends a step's diagnostics to `log!`, writes its lines, then runs each of its calls and writes what `finish` returns
## (which may hold further calls). The state and session are threaded through in order.
drive! : Server(state), Stdio.Io, state, Engine.Step(state) => Try((state, Engine.Session), [Closed])
drive! = |server, io, state, step| {
	for l in step.log {
		(io.log!)("mcp: ${l}")
	}
	for l in step.out {
		(io.write_line!)(l)?
	}
	send! = |line| (io.write_line!)(line) ?? {}
	var $state = state
	var $session = step.session
	for call in step.calls {
		(s, outcome) = (call.run!)($state, call.ctx.with_sender(send!))
		kept = Engine.state_after(server, $state, s, outcome)
		done = Engine.finish(server, $session, call, outcome, (io.now_ms!)())
		(s2, sess2) = drive!(server, io, kept, done)?
		$state = s2
		$session = sess2
	}
	Ok(($state, $session))
}

expect read_wait(Err(None), 5) == Forever
expect read_wait(Ok(10), 4) == Within(6)
expect read_wait(Ok(10), 10) == Expired
