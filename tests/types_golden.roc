app [main!] { pkg: "../package/main.roc" }

import pkg.JsonValue
import pkg.Tool
import pkg.Resource
import pkg.ResourceTemplate

import "golden/roc-syntax-mcp/tools-list.json" as tools_golden : Str
import "golden/roc-syntax-mcp/resources-list.json" as resources_golden : Str
import "golden/roc-syntax-mcp/resources-templates-list.json" as templates_golden : Str

main! = |_args| Ok({})

## Parity with the real roc-syntax-mcp (JS SDK 2.0.0): every tools/list, resources/list and
## resources/templates/list entry it sends is rebuilt with our builders from the fields of
## the golden entry, and the `to_json` must give the same text, key order included.

json : Str -> JsonValue
json = |s| match JsonValue.parse(s) {
	Ok(v) => v
	Err(_) => crash "bad golden JSON"
}

items : Str, Str -> List(JsonValue)
items = |text, key| match json(text).get("result") {
	Ok(r) =>
		match r.get(key) {
			Ok(Array(xs)) => xs
			_ => crash "no ${key}"
		}
	Err(_) => crash "no result"
}

str : JsonValue, Str -> Str
str = |j, key| match j.get(key) {
	Ok(String(s)) => s
	_ => crash "no string ${key}"
}

hint : JsonValue, Str -> Try(Bool, [None])
hint = |j, key| match j.get("annotations") {
	Ok(a) =>
		match a.get(key) {
			Ok(Bool(b)) => Ok(b)
			_ => Err(None)
		}
	Err(_) => Err(None)
}

rebuild_tool : JsonValue -> Tool
rebuild_tool = |j| {
	base = Tool.new(str(j, "name")).with_title(str(j, "title")).with_description(str(j, "description")).with_input_schema(j.get_or_null("inputSchema"))
	ro = match hint(j, "readOnlyHint") {
		Ok(b) => base.read_only(b)
		Err(None) => base
	}
	match hint(j, "openWorldHint") {
		Ok(b) => ro.open_world(b)
		Err(None) => ro
	}
}

expect {
	tools = items(tools_golden, "tools")
	tools.len() == 7 and tools.all(|j| rebuild_tool(j).to_json().to_str() == j.to_str())
}

# Static resources: `uri` comes first.
static_resources : List(JsonValue)
static_resources = items(resources_golden, "resources").keep_if(
	|j| match j {
		Object([("uri", _), ..]) => Bool.True
		_ => Bool.False
	},
)

expect {
	rebuilt = |j| Resource.new(str(j, "uri"), str(j, "name")).with_title(str(j, "title")).with_description(str(j, "description")).with_mime_type(str(j, "mimeType"))
	static_resources.len() == 3 and static_resources.all(|j| rebuilt(j).to_json().to_str() == j.to_str())
}

templates : List(ResourceTemplate)
templates = items(templates_golden, "resourceTemplates").map(
	|j| ResourceTemplate.new(str(j, "uriTemplate"), str(j, "name")).with_title(str(j, "title")).with_description(str(j, "description")).with_mime_type(str(j, "mimeType")),
)

expect {
	golden = items(templates_golden, "resourceTemplates")
	templates.map(|t| t.to_json().to_str()) == golden.map(|j| j.to_str())
}

## The JS merge for a resource that a template's `list` returns: `{...template metadata, ...entry}`.
## A key of the entry that the metadata has keeps the metadata's position.
merge : List((Str, JsonValue)), List((Str, JsonValue)) -> List((Str, JsonValue))
merge = |meta, entry| entry.fold(
	meta,
	|acc, (k, v)|
		if acc.any(|(k2, _)| k2 == k) {
			acc.map(|(k2, v2)| if (k2 == k) (k2, v) else (k2, v2))
		} else {
			acc.append((k, v))
		},
)

prefix : ResourceTemplate -> Str
prefix = |t| match t.source().split_first("{") {
	Ok({ before, after: _ }) => before
	Err(_) => t.source()
}

## The template with the longest literal prefix of the URI.
template_for : Str -> ResourceTemplate
template_for = |uri| {
	candidates = templates.keep_if(|t| uri.starts_with(prefix(t)))
	best = candidates.fold(
		Err(None),
		|acc, t| match acc {
			Ok(b) if prefix(b).count_utf8_bytes() >= prefix(t).count_utf8_bytes() => Ok(b)
			_ => Ok(t)
		},
	)
	match best {
		Ok(t) => t
		Err(None) => crash "no template for ${uri}"
	}
}

expect {
	listed = items(resources_golden, "resources").drop_if(|j| static_resources.contains(j))
	ok = listed.all(
		|j| {
			uri = str(j, "uri")
			entry = Resource.new(uri, str(j, "name")).with_title(str(j, "title")).with_description(str(j, "description")).with_mime_type(str(j, "mimeType"))
			fields = match entry.to_json() {
				Object(pairs) => pairs
				_ => []
			}
			JsonValue.Object(merge(template_for(uri).metadata(), fields)).to_str() == j.to_str()
		},
	)
	listed.len() == 211 and ok
}
