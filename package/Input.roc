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
	##
	## Each request of one call needs its own key, in every round: `Ctx.input` gives only the
	## previous round's answers, and the handler runs again from the start, so a second roots
	## request in the same call (a later round) must use another key than the first, or the
	## handler would read the first answer again. A handler that needs answers of several rounds
	## keeps them in `with_state`.
	Required :: { requests : List((Str, Input.Request)), request_state : Try(Str, [None]), timeout_ms : Try(U64, [None]), progress_token : Bool }.{
		one : Str, Input.Request -> Input.Required
		one = |key, req| { requests: [(key, req)], request_state: Err(None), timeout_ms: Err(None), progress_token: Bool.False }

		## No request, only a state to keep: the handler runs again at once with
		## `Ctx.request_state` set (the 2025 shim), or the client gets `input_required` with only
		## `requestState` (2026-07-28).
		keep_state : Str -> Input.Required
		keep_state = |st| { requests: [], request_state: Ok(st), timeout_ms: Err(None), progress_token: Bool.False }

		also : Input.Required, Str, Input.Request -> Input.Required
		also = |r, key, req| { ..r, requests: r.requests.append((key, req)) }

		with_state : Input.Required, Str -> Input.Required
		with_state = |r, s| { ..r, request_state: Ok(s) }

		## Legacy shim only: give up after this long. Enforced when the transport can wait with a timeout.
		with_timeout_ms : Input.Required, U64 -> Input.Required
		with_timeout_ms = |r, ms| { ..r, timeout_ms: Ok(ms) }

		## 2025 connections only: the wire form of the server-to-client requests.
		##
		## `Bool.False` (the default) is the form of the JS SDK's direct calls, which is what a
		## server written against the 2025 API sends (`server.listRoots({})`, `elicitInput(...)`,
		## `createMessage(...)`): `{"method":"roots/list","params":{},"jsonrpc":"2.0","id":0}`.
		## The capability checks are those calls' too: roots/list and sampling without tools are
		## sent even when the client did not declare the capability; an elicitation or a sampling
		## request with tools that the client cannot take is not sent, and its key reads
		## `Failed` (-32603 "Client does not support form elicitation.", "... url elicitation.",
		## "Client does not support sampling tools capability.").
		##
		## `Bool.True` is the form of the JS `inputRequired` shim: every request carries
		## `params._meta.progressToken` (the request's id), and a request the client cannot take
		## ends the call with "Cannot request input '<key>' (<method>): ...".
		with_progress_token : Input.Required, Bool -> Input.Required
		with_progress_token = |r, b| { ..r, progress_token: b }

		progress_token : Input.Required -> Bool
		progress_token = |r| r.progress_token

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

	## Decodes a roots/list result `{roots: [{uri, name?}, ...]}`. As in the JS SDK, every root
	## URI must start with `file://`; a root that does not makes the whole answer
	## `BadAnswer("roots.<i>.uri: Invalid string: must start with \"file://\"")`.
	roots : JsonValue -> Try(List(Input.Root), [BadAnswer(Str)])
	roots = |answer| match answer.get("roots") {
		Ok(Array(items)) => items.map_with_index(|item, i| (item, i)).map_try(decode_root)
		Ok(_) => Err(BadAnswer("roots is not an array"))
		Err(NotFound) => Err(BadAnswer("missing roots"))
	}

	## The filesystem path of a `file://` URI, as Node's `fileURLToPath` gives it on POSIX: the
	## host must be empty or `localhost`, the query and fragment are dropped, `.` and `..`
	## segments are resolved, and percent escapes are decoded (UTF-8). `NotAFileUri` for any
	## other scheme, another host, an encoded `/` (`%2F`), a bad escape or bytes that are not
	## UTF-8. Unlike a WHATWG URL parser, it does not turn `\` into `/`, and it needs the `//`.
	file_uri_to_path : Str -> Try(Str, [NotAFileUri])
	file_uri_to_path = |uri| {
		bytes = uri.to_utf8()
		if ascii_lower(Str.from_utf8_lossy(bytes.take_first(7))) != "file://" {
			Err(NotAFileUri)
		} else {
			after_scheme = Str.from_utf8_lossy(bytes.drop_first(7))
			no_fragment = (after_scheme.split_first("#").map_ok(|x| x.before)) ?? after_scheme
			no_query = (no_fragment.split_first("?").map_ok(|x| x.before)) ?? no_fragment
			(host, path) = match no_query.split_first("/") {
				Ok({ before, after }) => (before, "/${after}")
				Err(_) => (no_query, "/")
			}
			if host != "" and ascii_lower(host) != "localhost" {
				Err(NotAFileUri)
			} else if path.contains("%2F") or path.contains("%2f") {
				Err(NotAFileUri)
			} else {
				percent_decode(resolve_dots(path))
			}
		}
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

decode_root : (JsonValue, U64) -> Try(Input.Root, [BadAnswer(Str)])
decode_root = |(item, i)| match item.get("uri") {
	Ok(String(u)) if !(u.starts_with("file://")) => Err(BadAnswer("roots.${i.to_str()}.uri: Invalid string: must start with \"file://\""))
	Ok(String(u)) =>
		match item.get("name") {
			Ok(String(n)) => Ok({ uri: u, name: Ok(n) })
			Err(NotFound) => Ok({ uri: u, name: Err(None) })
			Ok(_) => Err(BadAnswer("root name is not a string"))
		}
	Ok(_) => Err(BadAnswer("root uri is not a string"))
	Err(NotFound) => Err(BadAnswer("root without uri"))
}

ascii_lower : Str -> Str
ascii_lower = |s| Str.from_utf8_lossy(s.to_utf8().map(|c| if (c >= 'A' and c <= 'Z') c + 32 else c))

is_dot : Str -> Bool
is_dot = |seg| seg == "." or ascii_lower(seg) == "%2e"

is_dot_dot : Str -> Bool
is_dot_dot = |seg| {
	l = ascii_lower(seg)
	l == ".." or l == ".%2e" or l == "%2e." or l == "%2e%2e"
}

## Removes `.` and `..` segments of an absolute path (`/a/./b/../c` is `/a/c`), as URL parsing
## does. A last segment `.` or `..` leaves the path ending in `/`.
resolve_dots : Str -> Str
resolve_dots = |path| {
	segments = path.split_on("/").drop_first(1)
	last = segments.last() ?? ""
	kept = segments.fold(
		[],
		|acc, seg|
			if is_dot(seg) {
				acc
			} else if is_dot_dot(seg) {
				acc.drop_last(1)
			} else {
				acc.append(seg)
			},
	)
	joined = "/${Str.join_with(kept, "/")}"
	if ((is_dot(last) or is_dot_dot(last)) and !(kept.is_empty())) "${joined}/" else joined
}

hex_value : U8 -> Try(U8, [NotHex])
hex_value = |c|
	if c >= '0' and c <= '9' {
		Ok(c - '0')
	} else if c >= 'a' and c <= 'f' {
		Ok(c - 'a' + 10)
	} else if c >= 'A' and c <= 'F' {
		Ok(c - 'A' + 10)
	} else {
		Err(NotHex)
	}

## `decodeURIComponent`: every `%` must start a two-digit escape, and the result must be UTF-8.
percent_decode : Str -> Try(Str, [NotAFileUri])
percent_decode = |s| {
	bytes = s.to_utf8()
	var $out = []
	var $i = 0
	var $bad = Bool.False
	while $i < bytes.len() and !$bad {
		b = bytes.get($i) ?? 0
		if b == '%' {
			match (hex_value(bytes.get($i + 1) ?? 0), hex_value(bytes.get($i + 2) ?? 0)) {
				(Ok(h), Ok(l)) => {
					$out = $out.append(h * 16 + l)
					$i = $i + 3
				}
				_ => {
					$bad = Bool.True
				}
			}
		} else {
			$out = $out.append(b)
			$i = $i + 1
		}
	}
	if $bad {
		Err(NotAFileUri)
	} else {
		Str.from_utf8($out).map_err(|_| NotAFileUri)
	}
}
