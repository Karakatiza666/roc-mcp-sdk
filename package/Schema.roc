import JsonValue

## JSON Schema (draft 2020-12) builders. Each returns a JsonValue with its keys in
## the order the JS SDK sends for the same zod schema, so tool lists match it byte for byte.
Schema :: [].{

	## `{"type":"object","properties":{...},"required":[...]}`. A property is required
	## unless wrapped in `Prop.optional`. `required` is left out when no property is required.
	object : List((Str, Schema.Prop)) -> JsonValue
	object = |props| {
		properties = props.map(|(k, p)| (k, prop_schema(p)))
		names = props.keep_if(|(_, p)| p.required).map(|(k, _)| String(k))
		base = [("type", String("object")), ("properties", Object(properties))]
		Object(if (names.is_empty()) base else base.append(("required", Array(names))))
	}

	Prop :: { schema : JsonValue, required : Bool }.{
		required : JsonValue -> Schema.Prop
		required = |s| { schema: s, required: Bool.True }

		## An optional property. Its `title` and `description` move to the front, as
		## zod writes `.optional().describe(...)`.
		optional : JsonValue -> Schema.Prop
		optional = |s| { schema: s, required: Bool.False }
	}

	string : Schema.Opts -> JsonValue
	string = |opts| leaf("string", [], opts)

	## `{"type":"integer"}`. zod's `int()` also adds the safe-integer bounds; add them with
	## `with_keywords` when you need the same text.
	integer : Schema.Opts -> JsonValue
	integer = |opts| leaf("integer", [], opts)

	number : Schema.Opts -> JsonValue
	number = |opts| leaf("number", [], opts)

	boolean : Schema.Opts -> JsonValue
	boolean = |opts| leaf("boolean", [], opts)

	## A string restricted to these values: `{"type":"string","enum":[...]}`.
	enum : List(Str), Schema.Opts -> JsonValue
	enum = |values, opts| leaf("string", [("enum", Array(values.map(|s| String(s))))], opts)

	## `{"type":"array","items":...}`.
	array : JsonValue, Schema.Opts -> JsonValue
	array = |items, opts| leaf("array", [("items", items)], opts)

	## `{"anyOf":[...]}`.
	any_of : List(JsonValue) -> JsonValue
	any_of = |alternatives| Object([("anyOf", Array(alternatives))])

	## Merge extra keywords (minItems, maxItems, pattern, default, ...) into a schema.
	## A keyword that is already there is replaced in place. A new one goes before
	## `title` and `description`, except `default`, and `minItems`/`maxItems` of an
	## array, which go before `type` (zod's order). A schema that is not an object is returned unchanged.
	with_keywords : JsonValue, List((Str, JsonValue)) -> JsonValue
	with_keywords = |s, extra| match s {
		Object(fields) => Object(extra.fold(fields, |acc, (k, x)| merge_keyword(acc, k, x)))
		_ => s
	}

	## The root of a tool's `inputSchema` as the JS SDK sends it: `type` first (`"object"`
	## when missing), then `"$schema":"https://json-schema.org/draft/2020-12/schema"`, then the rest.
	with_dialect : JsonValue -> JsonValue
	with_dialect = |s| match s {
		Object(fields) => {
			root_type = match fields.find_first(|(k, _)| k == "type") {
				Ok((_, t)) => t
				Err(_) => String("object")
			}
			rest = fields.drop_if(|(k, _)| k == "type" or k == "$schema")
			Object([("type", root_type), ("$schema", String(dialect))].concat(rest))
		}
		_ => s
	}

	## `description` and `title`, either may be empty (then omitted).
	Opts : { description : Str, title : Str }

	described : Str -> Schema.Opts
	described = |d| { description: d, title: "" }

	none : Schema.Opts
	none = { description: "", title: "" }
}

dialect : Str
dialect = "https://json-schema.org/draft/2020-12/schema"

leaf : Str, List((Str, JsonValue)), Schema.Opts -> JsonValue
leaf = |t, keywords, opts| {
	title = if (opts.title == "") [] else [("title", String(opts.title))]
	description = if (opts.description == "") [] else [("description", String(opts.description))]
	Object([("type", String(t))].concat(keywords).concat(title).concat(description))
}

is_annotation : Str -> Bool
is_annotation = |k| k == "title" or k == "description"

prop_schema : Schema.Prop -> JsonValue
prop_schema = |p|
	if p.required {
		p.schema
	} else {
		match p.schema {
			Object(fields) => {
				front = fields.keep_if(|(k, _)| is_annotation(k))
				Object(front.concat(fields.drop_if(|(k, _)| is_annotation(k))))
			}
			other => other
		}
	}

insert_before : List((Str, JsonValue)), (Str -> Bool), (Str, JsonValue) -> List((Str, JsonValue))
insert_before = |fields, at, field|
	match fields.find_first_index(|(k, _)| at(k)) {
		Ok(i) => fields.take_first(i).append(field).concat(fields.drop_first(i))
		Err(_) => fields.append(field)
	}

merge_keyword : List((Str, JsonValue)), Str, JsonValue -> List((Str, JsonValue))
merge_keyword = |fields, k, x|
	if fields.any(|(name, _)| name == k) {
		fields.map(|(name, old)| if (name == k) (name, x) else (name, old))
	} else {
		is_array = fields.any(|(name, t)| name == "type" and t == String("array"))
		goes_first = k == "default" or (is_array and (k == "minItems" or k == "maxItems"))
		if goes_first {
			insert_before(fields, |name| name == "type", (k, x))
		} else {
			insert_before(fields, is_annotation, (k, x))
		}
	}
