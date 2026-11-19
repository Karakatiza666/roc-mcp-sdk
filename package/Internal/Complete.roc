import ../JsonValue

## completion/complete results.
Complete :: [].{

	## At most this many values are returned.
	max_values : U64
	max_values = 100

	## `{completion: {values (first 100), total, hasMore}}`.
	result : List(Str) -> JsonValue
	result = |values| {
		completion : JsonValue
		completion = Object([
			("values", Array(values.take_first(max_values).map(|v| String(v)))),
			("total", JsonValue.from_u64(values.len())),
			("hasMore", Bool(values.len() > max_values)),
		])
		Object([("completion", completion)])
	}

	## The answer when no completer is registered: `{completion: {values: [], hasMore: false}}`.
	empty : JsonValue
	empty = Object([("completion", Object([("values", Array([])), ("hasMore", Bool(Bool.False))]))])
}
