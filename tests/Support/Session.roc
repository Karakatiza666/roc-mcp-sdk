import pkg.JsonValue
import pkg.Outcome
import pkg.Server
import pkg.Engine
import pkg.ToolResult

## L0 helper: drives an `Engine` through a transcript without running any handler. Each
## `Engine.Call` is answered by a pure script that returns the handler's raw outcome.
Session :: [].{

	## What a transcript produced: every line written, every log line, and the final session.
	Run : { session : Engine.Session, out : List(Str), log : List(Str) }

	## Runs `lines` through a new session. Calls are finished at time 0.
	run : Server(s), s, List(Str), (Engine.Call(s) -> Outcome(JsonValue)) -> List(Str)
	run = |server, st, lines, script| drive(server, Engine.Session.new, st, lines, script, 0).out

	## Runs `lines` from `sess`; calls are finished at `now_ms`.
	drive : Server(s), Engine.Session, s, List(Str), (Engine.Call(s) -> Outcome(JsonValue)), U64 -> Session.Run
	drive = |server, sess, st, lines, script, now_ms|
		lines.fold(
			{ session: sess, out: [], log: [] },
			|acc, line| {
				step = Engine.receive(server, acc.session, st, line)
				done = settle(server, step, script, now_ms)
				{ session: done.session, out: acc.out.concat(done.out), log: acc.log.concat(done.log) }
			},
		)

	## Finishes every call of a step (and of the steps that follow) with the script.
	settle : Server(s), Engine.Step(s), (Engine.Call(s) -> Outcome(JsonValue)), U64 -> Session.Run
	settle = |server, step, script, now_ms| settle_n(server, step, script, now_ms, 50)

	## `expire` at `now_ms`, then settles the calls it made.
	expire : Server(s), Engine.Session, s, (Engine.Call(s) -> Outcome(JsonValue)), U64 -> Session.Run
	expire = |server, sess, st, script, now_ms| settle(server, Engine.expire(server, sess, st, now_ms), script, now_ms)

	## Parses JSON text; crashes on invalid text (test data is fixed).
	json : Str -> JsonValue
	json = |src| match JsonValue.parse(src) {
		Ok(v) => v
		Err(_) => crash "Session.json: invalid JSON: ${src}"
	}

	## True when the first line contains `part`.
	first_has : List(Str), Str -> Bool
	first_has = |lines, part| match lines.first() {
		Ok(l) => l.contains(part)
		Err(_) => Bool.False
	}

	## The same JSON values line by line, ignoring key order.
	same : List(Str), List(Str) -> Bool
	same = |actual, expected| actual.len() == expected.len() and actual.map2(expected, |a, e| JsonValue.equivalent(json(a), json(e))).all(|b| b)

	## The tool name of a tools/call call (`""` otherwise).
	tool_name : Engine.Call(s) -> Str
	tool_name = |call| call.message.get_or_null("params").get_or_null("name").as_str() ?? ""

	## A tools/call outcome with one text block.
	text : Str -> Outcome(JsonValue)
	text = |t| Outcome.done(ToolResult.text(t).to_json())

	## A script for transcripts that make no call.
	no_calls : Engine.Call(s) -> Outcome(JsonValue)
	no_calls = |_call| crash "Session.no_calls: the transcript made a call"
}

settle_n : Server(s), Engine.Step(s), (Engine.Call(s) -> Outcome(JsonValue)), U64, U64 -> Session.Run
settle_n = |server, step, script, now_ms, fuel|
	if fuel == 0 {
		crash "Session.settle: more than 50 rounds of calls"
	} else {
		step.calls.fold(
			{ session: step.session, out: step.out, log: step.log },
			|acc, call| {
				next = Engine.finish(server, acc.session, call, script(call), now_ms)
				done = settle_n(server, next, script, now_ms, fuel - 1)
				{ session: done.session, out: acc.out.concat(done.out), log: acc.log.concat(done.log) }
			},
		)
	}
