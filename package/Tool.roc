import JsonValue
import Content
import Schema

## A tool definition: what tools/list shows. Built with `Tool.new(name)` and the `with_` methods.
Tool :: {
	name : Str,
	title : Try(Str, [None]),
	description : Try(Str, [None]),
	input_schema : JsonValue,
	input_schema_given : Bool,
	output_schema : Try(JsonValue, [None]),
	annotations : List((Str, JsonValue)),
	icons : List(Content.Icon),
	meta : Try(JsonValue, [None]),
}.{
	new : Str -> Tool
	new = |n| {
		name: n,
		title: Err(None),
		description: Err(None),
		input_schema: Object([("type", String("object")), ("properties", Object([]))]),
		input_schema_given: Bool.False,
		output_schema: Err(None),
		annotations: [],
		icons: [],
		meta: Err(None),
	}

	name : Tool -> Str
	name = |t| t.name

	with_title : Tool, Str -> Tool
	with_title = |t, s| { ..t, title: Ok(s) }

	with_description : Tool, Str -> Tool
	with_description = |t, s| { ..t, description: Ok(s) }

	## Must be a JSON Schema whose root is `type: object`; anything else crashes (a programming error).
	## Without a `$schema` keyword, the root gets `"$schema":"https://json-schema.org/draft/2020-12/schema"`
	## right after `type` (`Schema.with_dialect`), as the JS SDK sends a zod schema. A root that
	## has `$schema` is sent unchanged. A tool without an input schema sends
	## `{"type":"object","properties":{}}`, as JS does.
	with_input_schema : Tool, JsonValue -> Tool
	with_input_schema = |t, s| match s.get("type") {
		Ok(String("object")) => { ..t, input_schema: if (s.get("$schema").is_ok()) s else Schema.with_dialect(s), input_schema_given: Bool.True }
		_ => crash "Tool ${t.name}: the input schema's root must be `type: object`"
	}

	## When set, a non-error result must carry `structured` content (else the call gets an
	## `isError` result "Output validation error: ..."). Without a `$schema` keyword, the schema
	## gets `"$schema":"https://json-schema.org/draft/2020-12/schema"` first, as JS sends a zod
	## schema. On a 2025 connection a root that is not `type: object` is sent wrapped as
	## `{type: "object", properties: {result: <schema>}, required: ["result"]}`, and the
	## result's `structuredContent` as `{result: ...}`.
	with_output_schema : Tool, JsonValue -> Tool
	with_output_schema = |t, s| match s {
		Object(fields) if s.get("$schema").is_err() => { ..t, output_schema: Ok(Object([("$schema", String("https://json-schema.org/draft/2020-12/schema"))].concat(fields))) }
		_ => { ..t, output_schema: Ok(s) }
	}

	## Annotation hints. Each one is sent only when set.
	read_only : Tool, Bool -> Tool
	read_only = |t, b| set_hint(t, "readOnlyHint", b)

	destructive : Tool, Bool -> Tool
	destructive = |t, b| set_hint(t, "destructiveHint", b)

	idempotent : Tool, Bool -> Tool
	idempotent = |t, b| set_hint(t, "idempotentHint", b)

	open_world : Tool, Bool -> Tool
	open_world = |t, b| set_hint(t, "openWorldHint", b)

	## `annotations.title`.
	annotation_title : Tool, Str -> Tool
	annotation_title = |t, s| { ..t, annotations: put(t.annotations, "title", String(s)) }

	with_icon : Tool, Content.Icon -> Tool
	with_icon = |t, i| { ..t, icons: t.icons.append(i) }

	with_meta : Tool, JsonValue -> Tool
	with_meta = |t, m| { ..t, meta: Ok(m) }

	## The tools/list entry: `name`, `title`, `description`, `inputSchema`, `annotations`, `icons`,
	## `_meta`, `outputSchema`, each optional one only when set (the JS key order).
	to_json : Tool -> JsonValue
	to_json = |t| {
		title = opt_str("title", t.title)
		description = opt_str("description", t.description)
		annotations = if (t.annotations.is_empty()) [] else [("annotations", Object(t.annotations))]
		meta = opt_json("_meta", t.meta)
		output = opt_json("outputSchema", t.output_schema)
		Object(
			[("name", String(t.name))]
				.concat(title)
				.concat(description)
				.append(("inputSchema", t.input_schema))
				.concat(annotations)
				.concat(Content.icons_field(t.icons))
				.concat(meta)
				.concat(output),
		)
	}

	input_schema : Tool -> JsonValue
	input_schema = |t| t.input_schema

	## True once `with_input_schema` was called. Only such a tool's arguments are validated
	## (JS validates only a tool registered with an `inputSchema`).
	has_input_schema : Tool -> Bool
	has_input_schema = |t| t.input_schema_given

	output_schema : Tool -> Try(JsonValue, [None])
	output_schema = |t| t.output_schema
}

opt_str : Str, Try(Str, [None]) -> List((Str, JsonValue))
opt_str = |k, v| match v {
	Ok(s) => [(k, String(s))]
	Err(None) => []
}

opt_json : Str, Try(JsonValue, [None]) -> List((Str, JsonValue))
opt_json = |k, v| match v {
	Ok(j) => [(k, j)]
	Err(None) => []
}

set_hint : Tool, Str, Bool -> Tool
set_hint = |t, key, b| { ..t, annotations: put(t.annotations, key, Bool(b)) }

## Sets a key, keeping its first position when it is set again (like a JS object).
put : List((Str, JsonValue)), Str, JsonValue -> List((Str, JsonValue))
put = |pairs, key, v|
	if pairs.any(|(k, _)| k == key) {
		pairs.map(|(k, old)| if (k == key) (k, v) else (k, old))
	} else {
		pairs.append((key, v))
	}
