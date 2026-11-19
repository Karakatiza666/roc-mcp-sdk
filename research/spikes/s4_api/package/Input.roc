import JsonValue
import McpError

## Server-to-client input: roots, elicitation, sampling. A handler asks by returning
## `Outcome.need_input`; the SDK obtains the answers and calls the handler again, which then
## reads them with `Ctx.input`. On 2025 connections the SDK sends real server-to-client
## requests (the JS legacy shim); on 2026-07-28 connections it returns `input_required`.
Input :: [].{
	Request := [
		ListRoots,
		ElicitForm({ message : Str, requested_schema : JsonValue }),
		ElicitUrl({ message : Str, url : Str }),
		CreateMessage(JsonValue),
	]

	## What `Outcome.need_input` carries.
	Required :: { requests : List((Str, Input.Request)), request_state : Try(Str, [None]), timeout_ms : Try(U64, [None]) }.{
		one : Str, Input.Request -> Input.Required
		one = |key, req| { requests: [(key, req)], request_state: Err(None), timeout_ms: Err(None) }

		also : Input.Required, Str, Input.Request -> Input.Required
		also = |r, key, req| { ..r, requests: r.requests.append((key, req)) }

		with_state : Input.Required, Str -> Input.Required
		with_state = |r, s| { ..r, request_state: Ok(s) }

		## Legacy shim only: give up after this long. Enforced when the transport can wait with a timeout.
		with_timeout_ms : Input.Required, U64 -> Input.Required
		with_timeout_ms = |r, ms| { ..r, timeout_ms: Ok(ms) }

		requests : Input.Required -> List((Str, Input.Request))
		requests = |r| r.requests
	}

	## The answer to one request, as `Ctx.input` gives it.
	Answer : [NotAsked, Answered(JsonValue), Failed(McpError), TimedOut]

	Root : { uri : Str, name : Try(Str, [None]) }

	roots : JsonValue -> Try(List(Input.Root), [BadAnswer(Str)])
	roots = |_answer| crash "unimplemented"

	Elicitation : [Accept(JsonValue), Decline, Cancel]

	elicitation : JsonValue -> Try(Input.Elicitation, [BadAnswer(Str)])
	elicitation = |_answer| crash "unimplemented"
}
