app [main!] { pkg: "../package/main.roc" }

import pkg.JsonValue
import pkg.Schema

main! = |_args| Ok({})

str : JsonValue -> Str
str = |v| v.to_str()

opt : JsonValue -> Schema.Prop
opt = |s| Schema.Prop.optional(s)

req : JsonValue -> Schema.Prop
req = |s| Schema.Prop.required(s)

d : Str -> Schema.Opts
d = |text| Schema.described(text)

none : Schema.Opts
none = Schema.none

# ── Leaves. Expected texts are zod 4.4.3's toJSONSchema output (draft 2020-12, io input)
# ── for the zod schema in the comment, without zod's root `$schema`.

# z.string()
expect str(Schema.string(none)) == "{\"type\":\"string\"}"
# z.string().describe("d")
expect str(Schema.string(d("d"))) == "{\"type\":\"string\",\"description\":\"d\"}"
# z.string().meta({ title: "T", description: "d" })
expect str(Schema.string({ title: "T", description: "d" })) == "{\"type\":\"string\",\"title\":\"T\",\"description\":\"d\"}"
expect str(Schema.string({ title: "T", description: "" })) == "{\"type\":\"string\",\"title\":\"T\"}"
# z.number(), z.boolean()
expect str(Schema.number(none)) == "{\"type\":\"number\"}"
expect str(Schema.boolean(none)) == "{\"type\":\"boolean\"}"
expect str(Schema.integer(none)) == "{\"type\":\"integer\"}"
# z.number().int().positive()
expect str(Schema.integer(none) |> Schema.with_keywords([("exclusiveMinimum", Number("0")), ("maximum", Number("9007199254740991"))])) == "{\"type\":\"integer\",\"exclusiveMinimum\":0,\"maximum\":9007199254740991}"
# z.number().min(0).max(10)
expect str(Schema.number(none) |> Schema.with_keywords([("minimum", Number("0")), ("maximum", Number("10"))])) == "{\"type\":\"number\",\"minimum\":0,\"maximum\":10}"
# z.enum(["a","b"]), with .describe("d")
expect str(Schema.enum(["a", "b"], none)) == "{\"type\":\"string\",\"enum\":[\"a\",\"b\"]}"
expect str(Schema.enum(["a", "b"], d("d"))) == "{\"type\":\"string\",\"enum\":[\"a\",\"b\"],\"description\":\"d\"}"
# z.array(z.string())
expect str(Schema.array(Schema.string(none), none)) == "{\"type\":\"array\",\"items\":{\"type\":\"string\"}}"
# z.array(z.string()).min(1).max(8).describe("d")
expect str(Schema.array(Schema.string(none), d("d")) |> Schema.with_keywords([("minItems", Number("1")), ("maxItems", Number("8"))])) == "{\"minItems\":1,\"maxItems\":8,\"type\":\"array\",\"items\":{\"type\":\"string\"},\"description\":\"d\"}"
# z.union([z.string(), z.number()])
expect str(Schema.any_of([Schema.string(none), Schema.number(none)])) == "{\"anyOf\":[{\"type\":\"string\"},{\"type\":\"number\"}]}"
# z.string().min(1).max(3).regex(/^a/)
expect str(Schema.string(none) |> Schema.with_keywords([("minLength", Number("1")), ("maxLength", Number("3")), ("pattern", String("^a"))])) == "{\"type\":\"string\",\"minLength\":1,\"maxLength\":3,\"pattern\":\"^a\"}"
# z.string().default("x")
expect str(Schema.string(none) |> Schema.with_keywords([("default", String("x"))])) == "{\"default\":\"x\",\"type\":\"string\"}"
# z.literal("x")
expect str(Schema.string(none) |> Schema.with_keywords([("const", String("x"))])) == "{\"type\":\"string\",\"const\":\"x\"}"
# A keyword goes before the annotations; an existing keyword is replaced in place.
expect str(Schema.string(d("d")) |> Schema.with_keywords([("minLength", Number("1"))])) == "{\"type\":\"string\",\"minLength\":1,\"description\":\"d\"}"
expect str(Schema.string(d("d")) |> Schema.with_keywords([("type", String("number"))])) == "{\"type\":\"number\",\"description\":\"d\"}"
expect str(Schema.string(none) |> Schema.with_keywords([("minLength", Number("1"))]) |> Schema.with_keywords([("minLength", Number("2"))])) == "{\"type\":\"string\",\"minLength\":2}"
# minItems before type only for an array.
expect str(Schema.string(none) |> Schema.with_keywords([("minItems", Number("1"))])) == "{\"type\":\"string\",\"minItems\":1}"
expect Schema.with_keywords(Bool(Bool.True), [("a", Null)]) == Bool(Bool.True)
expect Schema.with_keywords(Schema.string(none), []) == Schema.string(none)

# ── Objects

# z.object({ a: z.string(), b: z.number().optional() })
expect str(Schema.object([("a", req(Schema.string(none))), ("b", opt(Schema.number(none)))])) == "{\"type\":\"object\",\"properties\":{\"a\":{\"type\":\"string\"},\"b\":{\"type\":\"number\"}},\"required\":[\"a\"]}"
# z.object({})
expect str(Schema.object([])) == "{\"type\":\"object\",\"properties\":{}}"
# z.object({ a: z.string() }).describe("d")
expect str(Schema.object([("a", req(Schema.string(none)))]) |> Schema.with_keywords([("description", String("d"))])) == "{\"type\":\"object\",\"properties\":{\"a\":{\"type\":\"string\"}},\"required\":[\"a\"],\"description\":\"d\"}"
# z.string().optional().describe("d"): the description moves to the front.
expect str(Schema.object([("s", opt(Schema.string(d("d"))))])) == "{\"type\":\"object\",\"properties\":{\"s\":{\"description\":\"d\",\"type\":\"string\"}}}"
expect str(Schema.object([("s", opt(Schema.string({ title: "T", description: "d" })))])) == "{\"type\":\"object\",\"properties\":{\"s\":{\"title\":\"T\",\"description\":\"d\",\"type\":\"string\"}}}"
# z.object({ o: z.object({ x: z.boolean() }).optional().describe("n") })
expect str(Schema.object([("o", opt(Schema.object([("x", req(Schema.boolean(none)))]) |> Schema.with_keywords([("description", String("n"))])))])) == "{\"type\":\"object\",\"properties\":{\"o\":{\"description\":\"n\",\"type\":\"object\",\"properties\":{\"x\":{\"type\":\"boolean\"}},\"required\":[\"x\"]}}}"
# required keeps the order of the properties.
expect str(Schema.object([("z", req(Schema.string(none))), ("m", opt(Schema.string(none))), ("a", req(Schema.string(none)))])) == "{\"type\":\"object\",\"properties\":{\"z\":{\"type\":\"string\"},\"m\":{\"type\":\"string\"},\"a\":{\"type\":\"string\"}},\"required\":[\"z\",\"a\"]}"
expect Schema.object([("x", opt(Bool(Bool.True)))]) == Object([("type", String("object")), ("properties", Object([("x", Bool(Bool.True))]))])

# ── with_dialect: the root as the JS SDK sends it

expect str(Schema.with_dialect(Schema.object([]))) == "{\"type\":\"object\",\"$schema\":\"https://json-schema.org/draft/2020-12/schema\",\"properties\":{}}"
expect str(Schema.with_dialect(Schema.with_dialect(Schema.object([])))) == "{\"type\":\"object\",\"$schema\":\"https://json-schema.org/draft/2020-12/schema\",\"properties\":{}}"
expect str(Schema.with_dialect(Schema.any_of([]))) == "{\"type\":\"object\",\"$schema\":\"https://json-schema.org/draft/2020-12/schema\",\"anyOf\":[]}"
expect Schema.with_dialect(Null) == Null

# ── Goldens: roc-syntax-mcp 0.0.4 tools/list, inputSchema of each tool, as the JS SDK
# ── (@modelcontextprotocol/server 2.0.0, zod 4.4.3) sent them, captured 2026-11-19.

all_scopes : List(Str)
all_scopes = ["language", "builtin", "basic-webserver", "basic-cli", "joy", "roc-ray"]

platforms : List(Str)
platforms = ["basic-webserver", "basic-cli", "joy", "roc-ray"]

hint : Str
hint = " Name a platform (basic-webserver, basic-cli, joy, roc-ray) for what a host provides, such as I/O, graphics or networking, rather than the language or the builtins."

scope_arg : List(Str), Str -> Schema.Prop
scope_arg = |values, text| opt(Schema.enum(values, d(text)))

query_arg : Str -> Schema.Prop
query_arg = |text| opt(Schema.array(Schema.string(none), d(text)) |> Schema.with_keywords([("minItems", Number("1")), ("maxItems", Number("8"))]))

limit_arg : Str -> Schema.Prop
limit_arg = |text| opt(Schema.integer(d(text)) |> Schema.with_keywords([("exclusiveMinimum", Number("0")), ("maximum", Number("9007199254740991"))]))

golden : JsonValue, Str -> Bool
golden = |built, sent| {
	text = Schema.with_dialect(built).to_str()
	same_text = text == sent
	same_value = JsonValue.parse(sent) == Ok(Schema.with_dialect(built))
	same_text and same_value
}

# get_roc_syntax
expect golden(
	Schema.object([
		("topic", opt(Schema.string(d("Omit for the overview. A topic name (e.g. 'pattern_matching'), a package name for its page (e.g. 'roc-parser'), an example (e.g. 'basic-cli/hello'), or a question, which gets pointers when no topic is a sure match.")))),
		("scope", scope_arg(all_scopes, "One corpus only. Without `topic`, returns the page of that corpus. Omit for the language and builtins, or name a platform for its API. With `topic`, searches only the topics of that corpus.${hint}")),
	]),
	"{\"type\":\"object\",\"$schema\":\"https://json-schema.org/draft/2020-12/schema\",\"properties\":{\"topic\":{\"description\":\"Omit for the overview. A topic name (e.g. 'pattern_matching'), a package name for its page (e.g. 'roc-parser'), an example (e.g. 'basic-cli/hello'), or a question, which gets pointers when no topic is a sure match.\",\"type\":\"string\"},\"scope\":{\"description\":\"One corpus only. Without `topic`, returns the page of that corpus. Omit for the language and builtins, or name a platform for its API. With `topic`, searches only the topics of that corpus. Name a platform (basic-webserver, basic-cli, joy, roc-ray) for what a host provides, such as I/O, graphics or networking, rather than the language or the builtins.\",\"type\":\"string\",\"enum\":[\"language\",\"builtin\",\"basic-webserver\",\"basic-cli\",\"joy\",\"roc-ray\"]}}}",
)

# list_roc_index
expect golden(
	Schema.object([
		("kind", req(Schema.enum(["scopes", "topics", "modules", "examples"], d("Which index to list.")))),
		("scope", scope_arg(all_scopes, "For kind='topics', 'modules', 'examples': one corpus only. Omit for the working set.")),
	]),
	"{\"type\":\"object\",\"$schema\":\"https://json-schema.org/draft/2020-12/schema\",\"properties\":{\"kind\":{\"type\":\"string\",\"enum\":[\"scopes\",\"topics\",\"modules\",\"examples\"],\"description\":\"Which index to list.\"},\"scope\":{\"description\":\"For kind='topics', 'modules', 'examples': one corpus only. Omit for the working set.\",\"type\":\"string\",\"enum\":[\"language\",\"builtin\",\"basic-webserver\",\"basic-cli\",\"joy\",\"roc-ray\"]}},\"required\":[\"kind\"]}",
)

# search_symbols (`query` is a z.preprocess, which zod's input mode leaves out of `required`)
expect golden(
	Schema.object([
		("query", query_arg("Up to 8 queries. Each is a name ('Str.concat'), words in a name ('size window'), a module ending in '.' ('Keys.'), a type ('-> Bool', or 'Frame ->' for the functions that take a Frame), or a name and a type ('ceil : -> Dec').")),
		("scope", scope_arg(["builtin", "basic-webserver", "basic-cli", "joy", "roc-ray"], "A platform to read in place of the one this app's header imports, or one corpus to limit a list to.${hint}")),
		("limit", limit_arg("Max list entries per query (default 10, or 5 for several queries).")),
	]),
	"{\"type\":\"object\",\"$schema\":\"https://json-schema.org/draft/2020-12/schema\",\"properties\":{\"query\":{\"description\":\"Up to 8 queries. Each is a name ('Str.concat'), words in a name ('size window'), a module ending in '.' ('Keys.'), a type ('-> Bool', or 'Frame ->' for the functions that take a Frame), or a name and a type ('ceil : -> Dec').\",\"minItems\":1,\"maxItems\":8,\"type\":\"array\",\"items\":{\"type\":\"string\"}},\"scope\":{\"description\":\"A platform to read in place of the one this app's header imports, or one corpus to limit a list to. Name a platform (basic-webserver, basic-cli, joy, roc-ray) for what a host provides, such as I/O, graphics or networking, rather than the language or the builtins.\",\"type\":\"string\",\"enum\":[\"builtin\",\"basic-webserver\",\"basic-cli\",\"joy\",\"roc-ray\"]},\"limit\":{\"description\":\"Max list entries per query (default 10, or 5 for several queries).\",\"type\":\"integer\",\"exclusiveMinimum\":0,\"maximum\":9007199254740991}}}",
)

# get_roc_module
expect golden(
	Schema.object([
		("module", req(Schema.string(d("Module name, e.g. 'Str', 'U64', 'Num.Dec', 'Path'.")))),
		("detail", opt(Schema.enum(["signatures", "full"], d("'signatures' (default) lists name and type only. 'full' adds docstrings and examples, ~5x longer.")))),
		("scope", scope_arg(platforms, "Read a platform other than the one this app's header imports. Rarely needed.")),
	]),
	"{\"type\":\"object\",\"$schema\":\"https://json-schema.org/draft/2020-12/schema\",\"properties\":{\"module\":{\"type\":\"string\",\"description\":\"Module name, e.g. 'Str', 'U64', 'Num.Dec', 'Path'.\"},\"detail\":{\"description\":\"'signatures' (default) lists name and type only. 'full' adds docstrings and examples, ~5x longer.\",\"type\":\"string\",\"enum\":[\"signatures\",\"full\"]},\"scope\":{\"description\":\"Read a platform other than the one this app's header imports. Rarely needed.\",\"type\":\"string\",\"enum\":[\"basic-webserver\",\"basic-cli\",\"joy\",\"roc-ray\"]}},\"required\":[\"module\"]}",
)

# roc_check
expect golden(
	Schema.object([
		("code", opt(Schema.string(d("Roc source to check. Not with `path`.")))),
		("path", opt(Schema.string(d("Absolute path to a .roc file. Not with `code`.")))),
		("scope", scope_arg(platforms, "Wrap headerless `code` in this platform's app. Omit if it has a header.")),
	]),
	"{\"type\":\"object\",\"$schema\":\"https://json-schema.org/draft/2020-12/schema\",\"properties\":{\"code\":{\"description\":\"Roc source to check. Not with `path`.\",\"type\":\"string\"},\"path\":{\"description\":\"Absolute path to a .roc file. Not with `code`.\",\"type\":\"string\"},\"scope\":{\"description\":\"Wrap headerless `code` in this platform's app. Omit if it has a header.\",\"type\":\"string\",\"enum\":[\"basic-webserver\",\"basic-cli\",\"joy\",\"roc-ray\"]}}}",
)

# roc_fmt
expect golden(
	Schema.object([
		("code", opt(Schema.string(d("Roc source to format. Not with `path`.")))),
		("path", opt(Schema.string(d("Absolute path to a .roc file. Not with `code`.")))),
	]),
	"{\"type\":\"object\",\"$schema\":\"https://json-schema.org/draft/2020-12/schema\",\"properties\":{\"code\":{\"description\":\"Roc source to format. Not with `path`.\",\"type\":\"string\"},\"path\":{\"description\":\"Absolute path to a .roc file. Not with `code`.\",\"type\":\"string\"}}}",
)

# search_project_symbols
expect golden(
	Schema.object([
		("query", query_arg("As for `search_symbols`.")),
		("root", opt(Schema.string(d("Root of the codebase, absolute. The workspace by default.")))),
		("limit", limit_arg("As for `search_symbols`.")),
	]),
	"{\"type\":\"object\",\"$schema\":\"https://json-schema.org/draft/2020-12/schema\",\"properties\":{\"query\":{\"description\":\"As for `search_symbols`.\",\"minItems\":1,\"maxItems\":8,\"type\":\"array\",\"items\":{\"type\":\"string\"}},\"root\":{\"description\":\"Root of the codebase, absolute. The workspace by default.\",\"type\":\"string\"},\"limit\":{\"description\":\"As for `search_symbols`.\",\"type\":\"integer\",\"exclusiveMinimum\":0,\"maximum\":9007199254740991}}}",
)
