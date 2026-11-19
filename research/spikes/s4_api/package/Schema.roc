import JsonValue

## JSON Schema (draft 2020-12) builders. Each returns a JsonValue.
Schema :: [].{
	## `{"type":"object","properties":{...},"required":[...]}`. A property is required unless wrapped in `optional`.
	object : List((Str, Schema.Prop)) -> JsonValue
	object = |_props| Object([])

	Prop :: { schema : JsonValue, required : Bool }.{
		required : JsonValue -> Schema.Prop
		required = |schema| { schema, required: Bool.True }

		optional : JsonValue -> Schema.Prop
		optional = |schema| { schema, required: Bool.False }
	}

	string : Schema.Opts -> JsonValue
	string = |_opts| Object([])

	integer : Schema.Opts -> JsonValue
	integer = |_opts| Object([])

	number : Schema.Opts -> JsonValue
	number = |_opts| Object([])

	boolean : Schema.Opts -> JsonValue
	boolean = |_opts| Object([])

	## A string restricted to these values.
	enum : List(Str), Schema.Opts -> JsonValue
	enum = |_values, _opts| Object([])

	array : JsonValue, Schema.Opts -> JsonValue
	array = |_items, _opts| Object([])

	any_of : List(JsonValue) -> JsonValue
	any_of = |_alternatives| Object([])

	## Merge extra keywords (minItems, maxItems, pattern, default, ...) into a schema.
	with_keywords : JsonValue, List((Str, JsonValue)) -> JsonValue
	with_keywords = |_schema, _extra| Object([])

	## `description` and `title`, either may be empty (then omitted).
	Opts : { description : Str, title : Str }

	described : Str -> Schema.Opts
	described = |description| { description, title: "" }

	none : Schema.Opts
	none = { description: "", title: "" }
}
