import JsonValue

## A JSON-RPC error that a handler or the SDK sends to the client.
McpError :: { code : I64, message : Str, data : Try(JsonValue, [None]) }.{
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

	to_json : McpError -> JsonValue
	to_json = |_e| crash "unimplemented"

	invalid_params : Str -> McpError
	invalid_params = |m| new(-32602, m)

	internal : Str -> McpError
	internal = |m| new(-32603, m)

	method_not_found : Str -> McpError
	method_not_found = |_method| new(-32601, "Method not found")

	## JS SDK parity: -32602 with data {uri}. The spec's -32002 is accepted on input only.
	resource_not_found : Str -> McpError
	resource_not_found = |uri| new(-32602, "Resource ${uri} not found").with_data(Object([("uri", String(uri))]))

	## -32042 with data {elicitations}.
	url_elicitation_required : List(JsonValue) -> McpError
	url_elicitation_required = |elicitations| new(-32042, "URL elicitation required").with_data(Object([("elicitations", Array(elicitations))]))

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
}

