import JsonValue

## Spike: bridge between JsonValue and typed records through Encoding.Json.
Typed :: [].{
	## Decodes tool arguments into the caller's record type.
	decode : JsonValue -> Try(a, [InvalidArgs(Str)])
		where [a.Json.Parseable(_)]
	decode = |value| Json.parse(value.to_str()).map_err(|e| InvalidArgs(Str.inspect(e)))

	encode : a -> JsonValue where [a.Json.Encodable([])]
	encode = |value| match JsonValue.parse(Json.to_str(value)) {
		Ok(v) => v
		Err(_) => crash "Json.to_str produced invalid JSON"
	}
}
