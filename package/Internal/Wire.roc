import ../JsonValue
import ../McpError

## JSON-RPC framing: classifying an incoming message and writing outgoing lines.
## The key order of each written line is the one the JS SDK's stdio transport writes.
Wire :: [].{

	## What an incoming JSON value is.
	Message : [
		Request({ id : JsonValue, method : Str, params : JsonValue }),
		Notification({ method : Str, params : JsonValue }),
		Response({ id : JsonValue, answer : [Result(JsonValue), Error(JsonValue)] }),
		Invalid({ id : JsonValue, why : Str }),
	]

	## A line longer than this many bytes is refused (the JS stdio buffer limit).
	max_line_bytes : U64
	max_line_bytes = 10 * 1024 * 1024

	## Classifies one message. `params` is `Null` when absent. An invalid message keeps its
	## `id` when that id is usable (a string or an integer), else `Null`.
	classify : JsonValue -> Wire.Message
	classify = |msg| match msg {
		Array(_) => Invalid({ id: Null, why: "batches are not supported" })
		Object(_) => {
			raw_id = msg.get("id")
			usable_id = match raw_id {
				Ok(i) if valid_id(i) => i
				_ => Null
			}
			if msg.get("jsonrpc") != Ok(String("2.0")) {
				Invalid({ id: usable_id, why: "jsonrpc must be \"2.0\"" })
			} else {
				params = msg.get_or_null("params")
				params_ok = match params {
					Null | Object(_) => Bool.True
					_ => Bool.False
				}
				match msg.get("method") {
					Ok(String(m)) =>
						match raw_id {
							Err(NotFound) =>
								if params_ok {
									Notification({ method: m, params })
								} else {
									Invalid({ id: Null, why: "params must be an object" })
								}
							Ok(i) =>
								if !valid_id(i) {
									Invalid({ id: Null, why: "id must be a string or an integer" })
								} else if !params_ok {
									Invalid({ id: i, why: "params must be an object" })
								} else {
									Request({ id: i, method: m, params })
								}
						}
					Ok(_) => Invalid({ id: usable_id, why: "method must be a string" })
					Err(NotFound) =>
						match (raw_id, msg.get("result"), msg.get("error")) {
							(Ok(i), Ok(r), Err(_)) if valid_id(i) => Response({ id: i, answer: Result(r) })
							(Ok(i), Err(_), Ok(e)) if valid_id(i) => Response({ id: i, answer: Error(e) })
							_ => Invalid({ id: usable_id, why: "not a request, notification or response" })
						}
				}
			}
		}
		_ => Invalid({ id: Null, why: "a message must be a JSON object" })
	}

	## A string or an integer (JSON-RPC ids as MCP allows them).
	valid_id : JsonValue -> Bool
	valid_id = |v| match v {
		String(_) => Bool.True
		Number(_) => v.to_i64().is_ok() and !(v.to_str().contains(".")) and !(v.to_str().contains("e")) and !(v.to_str().contains("E"))
		_ => Bool.False
	}

	## `{"result":...,"jsonrpc":"2.0","id":...}`.
	result_line : JsonValue, JsonValue -> Str
	result_line = |id, result| {
		line : JsonValue
		line = Object([("result", result), ("jsonrpc", String("2.0")), ("id", id)])
		line.to_str()
	}

	## `{"jsonrpc":"2.0","id":...,"error":{code,message,data?}}`.
	error_line : JsonValue, McpError -> Str
	error_line = |id, err| {
		line : JsonValue
		line = Object([("jsonrpc", String("2.0")), ("id", id), ("error", err.to_json())])
		line.to_str()
	}

	## `{"jsonrpc":"2.0","method":...,"params":...}`, without `params` when it is `Err(None)`.
	notification_line : Str, Try(JsonValue, [None]) -> Str
	notification_line = |method, params| {
		p = match params {
			Ok(j) => [("params", j)]
			Err(None) => []
		}
		line : JsonValue
		line = Object([("jsonrpc", String("2.0")), ("method", String(method))].concat(p))
		line.to_str()
	}

	## A server-to-client request: `{"method":...,"params":...,"jsonrpc":"2.0","id":...}`.
	request_line : JsonValue, Str, JsonValue -> Str
	request_line = |id, method, params| {
		line : JsonValue
		line = Object([("method", String(method)), ("params", params), ("jsonrpc", String("2.0")), ("id", id)])
		line.to_str()
	}

	## `notifications/cancelled` for a request the server sent.
	cancelled_line : Str, Try(Str, [None]) -> Str
	cancelled_line = |out_id, reason| {
		r = match reason {
			Ok(s) => [("reason", String(s))]
			Err(None) => []
		}
		notification_line("notifications/cancelled", Ok(Object([("requestId", String(out_id))].concat(r))))
	}

	## The fields of an object, or `[]`.
	fields : JsonValue -> List((Str, JsonValue))
	fields = |v| match v {
		Object(fs) => fs
		_ => []
	}

	## Sets a key, keeping the position of an existing key (a JS object assignment).
	put : List((Str, JsonValue)), Str, JsonValue -> List((Str, JsonValue))
	put = |pairs, key, v|
		if pairs.any(|(k, _)| k == key) {
			pairs.map(|(k, old)| if (k == key) (k, v) else (k, old))
		} else {
			pairs.append((key, v))
		}

	## `{...a, ...b}`: the keys of `b` override those of `a` in place; new keys go last.
	spread : List((Str, JsonValue)), List((Str, JsonValue)) -> List((Str, JsonValue))
	spread = |a, b| b.fold(a, |acc, (k, v)| put(acc, k, v))
}
