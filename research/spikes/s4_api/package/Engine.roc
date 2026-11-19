import JsonValue
import Ctx
import Outcome
import Server

## The pure protocol core. Transports feed it messages and run the handler calls it returns.
Engine :: [].{
	## The state of one connection (stdio) or one session (HTTP).
	Session :: {
		era : [Undecided, Legacy, Modern],
		initialized : Bool,
		protocol_version : Str,
		client_capabilities : JsonValue,
		client_info : JsonValue,
		log_level : Str,
		next_out_id : U64,
		parked : List({ message : JsonValue, pending : List((Str, Str)), answers : List((Str, JsonValue)), deadline_ms : Try(U64, [None]) }),
		subscriptions : List(JsonValue),
	}.{
		new : Engine.Session
		new = { era: Undecided, initialized: Bool.False, protocol_version: "", client_capabilities: Object([]), client_info: Null, log_level: "", next_out_id: 0, parked: [], subscriptions: [] }

		## Requests parked on unanswered input requests.
		waiting : Engine.Session -> U64
		waiting = |s| s.parked.len()
	}

	latest_version : Str
	latest_version = "2025-11-25"

	legacy_versions : List(Str)
	legacy_versions = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05", "2024-10-07"]

	modern_versions : List(Str)
	modern_versions = ["2026-07-28"]

	## A handler call for the transport to run. `run!` already holds the decoded arguments.
	Call(state) : {
		request_id : Try(JsonValue, [Notification]),
		message : JsonValue,
		ctx : Ctx,
		run! : state, Ctx => (state, Outcome(JsonValue)),
	}

	Step(state) : { session : Engine.Session, out : List(Str), calls : List(Engine.Call(state)) }

	## One incoming line or message.
	receive : Server(state), Engine.Session, state, Str -> Engine.Step(state)
	receive = |_server, _session, _state, _line| crash "unimplemented"

	receive_json : Server(state), Engine.Session, state, JsonValue -> Engine.Step(state)
	receive_json = |_server, _session, _state, _msg| crash "unimplemented"

	## The outcome of a Call: a response, or (legacy) server-to-client requests and a parked request.
	finish : Server(state), Engine.Session, Engine.Call(state), Outcome(JsonValue), U64 -> Engine.Step(state)
	finish = |_server, _session, _call, _outcome, _now_ms| crash "unimplemented"

	## Re-runs parked requests whose input deadline passed, with `TimedOut` answers.
	expire : Server(state), Engine.Session, state, U64 -> Engine.Step(state)
	expire = |_server, _session, _state, _now_ms| crash "unimplemented"

	## The earliest input deadline, for a transport that can wait with a timeout.
	next_deadline : Engine.Session -> Try(U64, [None])
	next_deadline = |_session| crash "unimplemented"

	## Lines to send on graceful shutdown (2026 subscription results).
	close : Engine.Session -> List(Str)
	close = |_session| crash "unimplemented"
}
