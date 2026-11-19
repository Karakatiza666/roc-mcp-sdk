import Server
import Engine

## The stdio transport: newline-delimited JSON-RPC over effects that the app supplies.
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
	serve! : Server(state), state, Stdio.Io => { state : state, stopped : Stdio.Stopped }
	serve! = |_server, _init, _io| crash "unimplemented"
}
