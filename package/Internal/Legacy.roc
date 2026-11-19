import ../JsonValue
import ../McpError
import ../Input
import Wire

## The 2025-era wire rules: the input_required shim (server-to-client requests) and the
## projection of tools/call results and output schemas.
Legacy :: [].{

	## A request may return `NeedInput` at most this many rounds (JS parity).
	max_rounds : U64
	max_rounds = 8

	## The default time to wait for the answers of one round, in milliseconds (JS parity).
	default_round_timeout_ms : U64
	default_round_timeout_ms = 600_000

	## Methods that may return `NeedInput`.
	input_methods : List(Str)
	input_methods = ["tools/call", "prompts/get", "resources/read"]

	## How a shim failure reaches the client: an `isError` result for tools/call, else -32603.
	failure : Str, Str -> [Result(JsonValue), Error(McpError)]
	failure = |method, text|
		if method == "tools/call" {
			Result(error_result(text))
		} else {
			Error(McpError.internal(text))
		}

	## `{content: [{type: "text", text}], isError: true}`.
	error_result : Str -> JsonValue
	error_result = |text| Object([("content", Array([text_block(text)])), ("isError", Bool(Bool.True))])

	rounds_exceeded : Str -> Str
	rounds_exceeded = |method| "Multi-round-trip request '${method}' still required input after ${max_rounds.to_str()} rounds (inputRequired.maxRounds)"

	fulfil_failed : Str, Str -> Str
	fulfil_failed = |method, why| "Fulfilling input required by '${method}' failed: ${why}"

	cannot_request : Str, Str -> Str
	cannot_request = |key, method| "Cannot request input '${key}' (${method}): the client on this 2025-era connection did not declare the required capability"

	## True when the client capabilities lack what the request needs. A bare `elicitation: {}`
	## counts as form support; URL elicitation needs `elicitation.url`, sampling with tools
	## needs `sampling.tools`.
	missing_capability : JsonValue, Input.Request -> Bool
	missing_capability = |caps, req| {
		top = req.capability()
		match caps.get(top) {
			Err(NotFound) => Bool.True
			Ok(declared) =>
				match req {
					ElicitUrl(_) => declared.get("url").is_err()
					ElicitForm(_) =>
						match declared {
							Object([]) => Bool.False
							Object(fs) => !(fs.any(|(k, _)| k == "form")) and fs.any(|(k, _)| k == "url")
							_ => Bool.False
						}
					CreateMessage(p) =>
						if p.get("tools").is_ok() or p.get("toolChoice").is_ok() {
							declared.get("tools").is_err()
						} else {
							Bool.False
						}
					ListRoots => Bool.False
				}
		}
	}

	## The params of a server-to-client request, with `_meta.progressToken` (a counter, as JS sends).
	request_params : Input.Request, U64, Str -> JsonValue
	request_params = |req, token, elicitation_id| {
		base = Wire.fields(req.legacy_params(elicitation_id) ?? Object([]))
		meta = match base.find_first(|(k, _)| k == "_meta") {
			Ok((_, m)) => Wire.put(Wire.fields(m), "progressToken", JsonValue.from_u64(token))
			Err(_) => [("progressToken", JsonValue.from_u64(token))]
		}
		Object(Wire.put(base, "_meta", Object(meta)))
	}

	## The tools/call result as the 2025 wire carries it:
	## 1. with an output schema, a non-error result without `structuredContent` becomes an
	##    `isError` result "Output validation error: ...";
	## 2. a non-object `structuredContent` gets a text block with its JSON when there is none;
	## 3. a non-object `structuredContent`, or any one when the output schema's root is not an
	##    object, is wrapped as `{result: ...}`.
	project_tool_result : Str, Try(JsonValue, [None]), JsonValue -> JsonValue
	project_tool_result = |tool_name, output_schema, result| {
		is_error = result.get("isError") == Ok(Bool(Bool.True))
		structured = result.get("structuredContent")
		match (output_schema, structured) {
			(Ok(_), Err(NotFound)) if !is_error =>
				error_result("Output validation error: Tool ${tool_name} has an output schema but no structured content was provided")
			(_, Err(NotFound)) => result
			(_, Ok(sc)) => {
				sc_is_object = match sc {
					Object(_) => Bool.True
					_ => Bool.False
				}
				fs = Wire.fields(result)
				with_text =
					if sc_is_object {
						fs
					} else {
						blocks = match result.get("content") {
							Ok(Array(bs)) => bs
							_ => []
						}
						has_text = blocks.any(|b| b.get("type") == Ok(String("text")))
						if (has_text) fs else Wire.put(fs, "content", Array(blocks.append(text_block(sc.to_str()))))
					}
				schema_wraps = match output_schema {
					Ok(s) => s.get("type") != Ok(String("object"))
					Err(None) => Bool.False
				}
				if sc_is_object and !schema_wraps {
					Object(with_text)
				} else {
					Object(Wire.put(with_text, "structuredContent", Object([("result", sc)])))
				}
			}
		}
	}

	## A tools/list `outputSchema` whose root is not an object, as the 2025 wire needs it:
	## `{$schema?, type: "object", properties: {result: <schema>}, required: ["result"]}`.
	## Same-document `$ref`s inside are moved under `#/properties/result`.
	wrap_output_schema : JsonValue -> JsonValue
	wrap_output_schema = |schema|
		if schema.get("type") == Ok(String("object")) {
			schema
		} else {
			dialect = match schema.get("$schema") {
				Ok(d) => [("$schema", d)]
				Err(_) => []
			}
			Object(
				dialect.concat([
					("type", String("object")),
					("properties", Object([("result", rewrite_refs(schema))])),
					("required", Array([String("result")])),
				]),
			)
		}
}

text_block : Str -> JsonValue
text_block = |t| Object([("type", String("text")), ("text", String(t))])

## Rewrites same-document `$ref`/`$dynamicRef` pointers for a schema moved to `#/properties/result`.
## Values under `const`, `enum`, `default` and `examples` are data and are left alone.
rewrite_refs : JsonValue -> JsonValue
rewrite_refs = |v| match v {
	Object(fs) =>
		Object(
			fs.map(
				|(k, x)|
					if k == "$ref" or k == "$dynamicRef" {
						match x {
							String("#") => (k, String("#/properties/result"))
							String(s) if s.starts_with("#/") => (k, String("#/properties/result/${s.drop_prefix("#/")}"))
							_ => (k, x)
						}
					} else if k == "const" or k == "enum" or k == "default" or k == "examples" {
						(k, x)
					} else {
						(k, rewrite_refs(x))
					},
			),
		)
	Array(xs) => Array(xs.map(rewrite_refs))
	_ => v
}
