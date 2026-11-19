import JsonValue

## A JSON-RPC error that a handler or the SDK sends to the client.
McpError :: { code : I64, message : Str, data : Try(JsonValue, [None]) }.{
	is_eq : _

	new : I64, Str -> McpError
	new = |c, m| { code: c, message: m, data: Err(None) }

	with_data : McpError, JsonValue -> McpError
	with_data = |e, d| { ..e, data: Ok(d) }

	code : McpError -> I64
	code = |e| e.code

	message : McpError -> Str
	message = |e| e.message

	data : McpError -> Try(JsonValue, [None])
	data = |e| e.data

	## The JSON-RPC error object `{code, message, data?}`.
	to_json : McpError -> JsonValue
	to_json = |e| {
		d = match e.data {
			Ok(j) => [("data", j)]
			Err(None) => []
		}
		Object([("code", Number(e.code.to_str())), ("message", String(e.message))].concat(d))
	}

	## Reads the `error` object of a JSON-RPC error response (any code, -32002 included).
	from_json : JsonValue -> Try(McpError, [BadError])
	from_json = |j| match (j.get("code"), j.get("message")) {
		(Ok(c), Ok(String(m))) =>
			match c.to_i64() {
				Ok(n) =>
					match j.get("data") {
						Ok(d) => Ok({ code: n, message: m, data: Ok(d) })
						Err(_) => Ok({ code: n, message: m, data: Err(None) })
					}
				Err(_) => Err(BadError)
			}
		_ => Err(BadError)
	}

	invalid_params : Str -> McpError
	invalid_params = |m| new(-32602, m)

	internal : Str -> McpError
	internal = |m| new(-32603, m)

	method_not_found : Str -> McpError
	method_not_found = |_method| new(-32601, "Method not found")

	## JS SDK parity: -32602 with data {uri}. The spec's -32002 is accepted on input only.
	resource_not_found : Str -> McpError
	resource_not_found = |uri| new(-32602, "Resource not found: ${uri}").with_data(Object([("uri", String(uri))]))

	## -32042 with data {elicitations}.
	url_elicitation_required : List(JsonValue) -> McpError
	url_elicitation_required = |elicitations| {
		msg = if (elicitations.len() > 1) "URL elicitations required" else "URL elicitation required"
		new(-32042, msg).with_data(Object([("elicitations", Array(elicitations))]))
	}

	## -32022 with data {supported, requested}.
	unsupported_version : List(Str), Str -> McpError
	unsupported_version = |supported, requested|
		new(-32022, "Unsupported protocol version: ${requested}")
			.with_data(Object([("supported", Array(supported.map(|v| String(v)))), ("requested", String(requested))]))

	## -32021 with data {requiredCapabilities}. `required` is the object of missing capabilities.
	missing_capabilities : JsonValue -> McpError
	missing_capabilities = |required| {
		names = match required {
			Object(pairs) => Str.join_with(pairs.map(|(k, _)| k), ", ")
			_ => ""
		}
		new(-32021, "Missing required client capabilities: ${names}")
			.with_data(Object([("requiredCapabilities", required)]))
	}

	## -32600 with the given message.
	bad_request : Str -> McpError
	bad_request = |m| new(-32600, m)

	## -32700 with the given message.
	parse_failed : Str -> McpError
	parse_failed = |m| new(-32700, m)

	parse_error : I64
	parse_error = -32700

	invalid_request : I64
	invalid_request = -32600

	header_mismatch : I64
	header_mismatch = -32020

	missing_required_client_capability : I64
	missing_required_client_capability = -32021

	unsupported_protocol_version : I64
	unsupported_protocol_version = -32022

	method_not_found_code : I64
	method_not_found_code = -32601

	invalid_params_code : I64
	invalid_params_code = -32602

	internal_error : I64
	internal_error = -32603

	url_elicitation_required_code : I64
	url_elicitation_required_code = -32042

	## The spec's resource-not-found code. The SDK never sends it (JS parity) but accepts it on input.
	resource_not_found_code : I64
	resource_not_found_code = -32002
}
