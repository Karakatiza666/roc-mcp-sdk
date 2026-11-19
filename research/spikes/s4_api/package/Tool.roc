import JsonValue
import Content

## A tool definition: what tools/list shows. Built with `Tool.new(name)` and the `with_` methods.
Tool :: {
	name : Str,
	title : Try(Str, [None]),
	description : Try(Str, [None]),
	input_schema : JsonValue,
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

	## Must be a JSON Schema whose root is `type: object`.
	with_input_schema : Tool, JsonValue -> Tool
	with_input_schema = |t, s| { ..t, input_schema: s }

	## When set, a non-error result must carry `structured` content that matches it.
	with_output_schema : Tool, JsonValue -> Tool
	with_output_schema = |t, s| { ..t, output_schema: Ok(s) }

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
	annotation_title = |t, s| { ..t, annotations: t.annotations.append(("title", String(s))) }

	with_icon : Tool, Content.Icon -> Tool
	with_icon = |t, i| { ..t, icons: t.icons.append(i) }

	with_meta : Tool, JsonValue -> Tool
	with_meta = |t, m| { ..t, meta: Ok(m) }

	to_json : Tool -> JsonValue
	to_json = |_t| crash "unimplemented"
}

set_hint : Tool, Str, Bool -> Tool
set_hint = |t, key, b| {
	others = t.annotations.drop_if(|(k, _)| k == key)
	{ ..t, annotations: others.append((key, Bool(b))) }
}
