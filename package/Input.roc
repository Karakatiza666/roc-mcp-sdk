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
	].{

		## The JSON-RPC method: `roots/list`, `elicitation/create` or `sampling/createMessage`.
		method : Input.Request -> Str
		method = |r| match r {
			ListRoots => "roots/list"
			ElicitForm(_) | ElicitUrl(_) => "elicitation/create"
			CreateMessage(_) => "sampling/createMessage"
		}

		## The request params as the JS SDK sends them, without `_meta`. `roots/list` has none.
		## Form: `{message, requestedSchema, mode: "form"}`. URL: `{message, url, mode: "url"}`.
		## Sampling: the given params unchanged.
		params : Input.Request -> Try(JsonValue, [None])
		params = |r| match r {
			ListRoots => Err(None)
			ElicitForm(f) => Ok(Object([("message", String(f.message)), ("requestedSchema", f.requested_schema), ("mode", String("form"))]))
			ElicitUrl(u) => Ok(Object([("message", String(u.message)), ("url", String(u.url)), ("mode", String("url"))]))
			CreateMessage(j) => Ok(j)
		}

		## `params` for a 2025 connection: URL mode also carries `elicitationId` (the legacy shim's id).
		legacy_params : Input.Request, Str -> Try(JsonValue, [None])
		legacy_params = |r, elicitation_id| match r {
			ElicitUrl(u) => Ok(Object([("message", String(u.message)), ("url", String(u.url)), ("mode", String("url")), ("elicitationId", String(elicitation_id))]))
			_ => params(r)
		}

		## `{method, params?}`: an entry of a 2026-07-28 `inputRequests` object.
		to_json : Input.Request -> JsonValue
		to_json = |r| match params(r) {
			Ok(p) => Object([("method", String(method(r))), ("params", p)])
			Err(None) => Object([("method", String(method(r)))])
		}

		## The client capability the request needs: `roots`, `elicitation` or `sampling`.
		capability : Input.Request -> Str
		capability = |r| match r {
			ListRoots => "roots"
			ElicitForm(_) | ElicitUrl(_) => "elicitation"
			CreateMessage(_) => "sampling"
		}
	}

	## What `Outcome.need_input` carries.
	Required :: { requests : List((Str, Input.Request)), request_state : Try(Str, [None]), timeout_ms : Try(U64, [None]) }.{
		one : Str, Input.Request -> Input.Required
		one = |key, req| { requests: [(key, req)], request_state: Err(None), timeout_ms: Err(None) }

		## No request, only a state to keep: the handler runs again at once with
		## `Ctx.request_state` set (the 2025 shim), or the client gets `input_required` with only
		## `requestState` (2026-07-28).
		keep_state : Str -> Input.Required
		keep_state = |st| { requests: [], request_state: Ok(st), timeout_ms: Err(None) }

		also : Input.Required, Str, Input.Request -> Input.Required
		also = |r, key, req| { ..r, requests: r.requests.append((key, req)) }

		with_state : Input.Required, Str -> Input.Required
		with_state = |r, s| { ..r, request_state: Ok(s) }

		## Legacy shim only: give up after this long. Enforced when the transport can wait with a timeout.
		with_timeout_ms : Input.Required, U64 -> Input.Required
		with_timeout_ms = |r, ms| { ..r, timeout_ms: Ok(ms) }

		requests : Input.Required -> List((Str, Input.Request))
		requests = |r| r.requests

		request_state : Input.Required -> Try(Str, [None])
		request_state = |r| r.request_state

		timeout_ms : Input.Required -> Try(U64, [None])
		timeout_ms = |r| r.timeout_ms
	}

	## The answer to one request, as `Ctx.input` gives it.
	Answer : [NotAsked, Answered(JsonValue), Failed(McpError), TimedOut]

	Root : { uri : Str, name : Try(Str, [None]) }

	## Decodes a roots/list result `{roots: [{uri, name?}, ...]}`.
	roots : JsonValue -> Try(List(Input.Root), [BadAnswer(Str)])
	roots = |answer| match answer.get("roots") {
		Ok(Array(items)) => items.map_try(decode_root)
		Ok(_) => Err(BadAnswer("roots is not an array"))
		Err(NotFound) => Err(BadAnswer("missing roots"))
	}

	Elicitation : [Accept(JsonValue), Decline, Cancel]

	## Decodes an elicitation/create result `{action, content?}`. An `accept` without
	## `content` (URL mode) gives `Accept({})`.
	elicitation : JsonValue -> Try(Input.Elicitation, [BadAnswer(Str)])
	elicitation = |answer| match answer.get("action") {
		Ok(String("accept")) =>
			match answer.get("content") {
				Ok(Object(c)) => Ok(Accept(Object(c)))
				Ok(_) => Err(BadAnswer("content is not an object"))
				Err(NotFound) => Ok(Accept(Object([])))
			}
		Ok(String("decline")) => Ok(Decline)
		Ok(String("cancel")) => Ok(Cancel)
		Ok(String(other)) => Err(BadAnswer("unknown action: ${other}"))
		Ok(_) => Err(BadAnswer("action is not a string"))
		Err(NotFound) => Err(BadAnswer("missing action"))
	}
}

decode_root : JsonValue -> Try(Input.Root, [BadAnswer(Str)])
decode_root = |item| match item.get("uri") {
	Ok(String(u)) =>
		match item.get("name") {
			Ok(String(n)) => Ok({ uri: u, name: Ok(n) })
			Err(NotFound) => Ok({ uri: u, name: Err(None) })
			Ok(_) => Err(BadAnswer("root name is not a string"))
		}
	Ok(_) => Err(BadAnswer("root uri is not a string"))
	Err(NotFound) => Err(BadAnswer("root without uri"))
}
