app [main!] { pkg: "../package/main.roc" }

import pkg.JsonValue
import pkg.Content
import pkg.Tool
import pkg.ToolResult
import pkg.Resource
import pkg.ResourceContents
import pkg.ResourceTemplate
import pkg.Prompt
import pkg.McpError
import pkg.LogLevel

main! = |_args| Ok({})

## L0 for the definition types. Each golden string is the wire JSON that the JS SDK 2.0.0
## server sent for the same definition (tests/golden/js-sdk-types*.jsonl, captured with a
## throwaway node script over InMemoryTransport).

json : Str -> JsonValue
json = |s| match JsonValue.parse(s) {
	Ok(v) => v
	Err(_) => crash "bad JSON in test: ${s}"
}

icon : Content.Icon
icon = { src: "https://x/i.png", mime_type: Ok("image/png"), sizes: ["48x48"], theme: Ok(Dark) }

# ---- Tool ----

expect Tool.new("bare").to_json().to_str() == "{\"name\":\"bare\",\"inputSchema\":{\"type\":\"object\",\"properties\":{}}}"

expect {
	t =
		Tool.new("full")
			.with_title("Full Tool")
			.with_description("Does all")
			.with_input_schema(json("{\"type\":\"object\",\"$schema\":\"https://json-schema.org/draft/2020-12/schema\",\"properties\":{\"a\":{\"type\":\"string\"}},\"required\":[\"a\"]}"))
			.with_output_schema(json("{\"$schema\":\"https://json-schema.org/draft/2020-12/schema\",\"type\":\"object\",\"properties\":{\"n\":{\"type\":\"number\"}},\"required\":[\"n\"],\"additionalProperties\":false}"))
			.annotation_title("Ann")
			.read_only(Bool.True)
			.destructive(Bool.False)
			.idempotent(Bool.True)
			.open_world(Bool.False)
			.with_icon(icon)
			.with_meta(json("{\"k\":1}"))
	t.to_json().to_str() == "{\"name\":\"full\",\"title\":\"Full Tool\",\"description\":\"Does all\",\"inputSchema\":{\"type\":\"object\",\"$schema\":\"https://json-schema.org/draft/2020-12/schema\",\"properties\":{\"a\":{\"type\":\"string\"}},\"required\":[\"a\"]},\"annotations\":{\"title\":\"Ann\",\"readOnlyHint\":true,\"destructiveHint\":false,\"idempotentHint\":true,\"openWorldHint\":false},\"icons\":[{\"src\":\"https://x/i.png\",\"mimeType\":\"image/png\",\"sizes\":[\"48x48\"],\"theme\":\"dark\"}],\"_meta\":{\"k\":1},\"outputSchema\":{\"$schema\":\"https://json-schema.org/draft/2020-12/schema\",\"type\":\"object\",\"properties\":{\"n\":{\"type\":\"number\"}},\"required\":[\"n\"],\"additionalProperties\":false}}"
}

# Hints keep the order in which they were set; setting one again keeps its place.
expect {
	t = Tool.new("hintorder").open_world(Bool.False).read_only(Bool.True).open_world(Bool.True)
	t.to_json().to_str() == "{\"name\":\"hintorder\",\"inputSchema\":{\"type\":\"object\",\"properties\":{}},\"annotations\":{\"openWorldHint\":true,\"readOnlyHint\":true}}"
}

expect {
	t = Tool.new("b").with_title("T").read_only(Bool.True).with_meta(json("{\"x\":1}")).with_icon({ src: "s", mime_type: Err(None), sizes: ["any"], theme: Err(None) })
	t.to_json().to_str() == "{\"name\":\"b\",\"title\":\"T\",\"inputSchema\":{\"type\":\"object\",\"properties\":{}},\"annotations\":{\"readOnlyHint\":true},\"icons\":[{\"src\":\"s\",\"sizes\":[\"any\"]}],\"_meta\":{\"x\":1}}"
}

expect Tool.new("a").with_description("only desc").to_json().to_str() == "{\"name\":\"a\",\"description\":\"only desc\",\"inputSchema\":{\"type\":\"object\",\"properties\":{}}}"

expect Tool.new("n").name() == "n"

# ---- ToolResult ----

expect ToolResult.text("hi").to_json().to_str() == "{\"content\":[{\"type\":\"text\",\"text\":\"hi\"}]}"

expect ToolResult.error("bad").with_meta(json("{\"m\":2}")).to_json().to_str() == "{\"_meta\":{\"m\":2},\"content\":[{\"type\":\"text\",\"text\":\"bad\"}],\"isError\":true}"

expect ToolResult.text("{\"n\":1}").with_structured(json("{\"n\":1}")).to_json().to_str() == "{\"content\":[{\"type\":\"text\",\"text\":\"{\\\"n\\\":1}\"}],\"structuredContent\":{\"n\":1}}"

# roc-syntax-mcp sends `isError: !ok`, so an explicit false is kept.
expect ToolResult.text("x").with_is_error(Bool.False).to_json().to_str() == "{\"content\":[{\"type\":\"text\",\"text\":\"x\"}],\"isError\":false}"

expect {
	r = ToolResult.text("x")
	r.is_error() == Bool.False and ToolResult.error("y").is_error() == Bool.True and r.with_is_error(Bool.True).is_error()
}

expect {
	r = ToolResult.from_content([]).with_structured_value({ z: 1.I64 })
	r.to_json().to_str() == "{\"content\":[],\"structuredContent\":{\"z\":1}}"
}

expect {
	blocks = [
		Content.text("t")
			.with_annotations({ audience: [User, Assistant], priority: Ok(0.5), last_modified: Ok("2025-01-01T00:00:00Z") })
			.with_meta(json("{\"x\":1}")),
		Content.image("aGk=", "image/png"),
		Content.audio("aGk=", "audio/wav").with_annotations({ audience: [], priority: Ok(1), last_modified: Err(None) }),
		Content.resource_link("file:///a", "a"),
		Content.embedded_resource(ResourceContents.text("file:///b", "text/plain", "b")),
	]
	got = ToolResult.from_content(blocks).to_json().to_str()
	# The resource_link golden also has title/description/mimeType/size, which our
	# constructor does not set; this checks every other block exactly.
	got == "{\"content\":[{\"type\":\"text\",\"text\":\"t\",\"annotations\":{\"audience\":[\"user\",\"assistant\"],\"priority\":0.5,\"lastModified\":\"2025-01-01T00:00:00Z\"},\"_meta\":{\"x\":1}},{\"type\":\"image\",\"data\":\"aGk=\",\"mimeType\":\"image/png\"},{\"type\":\"audio\",\"data\":\"aGk=\",\"mimeType\":\"audio/wav\",\"annotations\":{\"priority\":1}},{\"name\":\"a\",\"uri\":\"file:///a\",\"type\":\"resource_link\"},{\"type\":\"resource\",\"resource\":{\"uri\":\"file:///b\",\"mimeType\":\"text/plain\",\"text\":\"b\"}}]}"
}

expect {
	r = ToolResult.from_content([Content.text("a"), Content.image("x", "image/png"), Content.text("b")]).map_last_text(|s| "${s}!")
	r.content().map(|c| c.as_text() ?? "-") == ["a", "-", "b!"]
}

expect ToolResult.from_content([]).map_last_text(|s| "${s}!").content().is_empty()

expect ToolResult.text("x").with_content([Content.text("y")]).content().map(|c| c.as_text() ?? "-") == ["y"]

# ---- Content ----

expect Content.image_bytes([104, 105], "image/png").to_json().to_str() == "{\"type\":\"image\",\"data\":\"aGk=\",\"mimeType\":\"image/png\"}"

expect Content.base64([]) == ""
expect Content.base64([0, 1]) == "AAE="
expect Content.base64("Man".to_utf8()) == "TWFu"
expect Content.base64("Ma".to_utf8()) == "TWE="
expect Content.base64("M".to_utf8()) == "TQ=="
expect Content.base64([0xFB, 0xFF, 0xBF]) == "+/+/"
expect Content.base64("hello world".to_utf8()) == "aGVsbG8gd29ybGQ="

expect Content.image("d", "m").as_text() == Err(NotText)
expect Content.text("q").map_text(|s| "${s}${s}").as_text() == Ok("qq")

expect Content.icon_to_json(Content.icon("s")).to_str() == "{\"src\":\"s\"}"
expect Content.icon_to_json({ src: "s", mime_type: Err(None), sizes: [], theme: Ok(Light) }).to_str() == "{\"src\":\"s\",\"theme\":\"light\"}"

expect Content.dec_json(0.25).to_str() == "0.25"
expect Content.dec_json(1).to_str() == "1"
expect Content.dec_json(-3).to_str() == "-3"

# ---- Resource ----

expect Resource.new("file:///plain", "plain").to_json().to_str() == "{\"uri\":\"file:///plain\",\"name\":\"plain\"}"

expect {
	r =
		Resource.new("file:///rich", "rich")
			.with_title("Rich")
			.with_description("desc")
			.with_mime_type("text/markdown")
			.with_size(42)
			.with_annotations({ audience: [User], priority: Ok(0.25), last_modified: Ok("2025-01-01T00:00:00Z") })
			.with_icon(icon)
			.with_meta(json("{\"r\":true}"))
	r.to_json().to_str() == "{\"uri\":\"file:///rich\",\"name\":\"rich\",\"title\":\"Rich\",\"description\":\"desc\",\"mimeType\":\"text/markdown\",\"size\":42,\"annotations\":{\"audience\":[\"user\"],\"priority\":0.25,\"lastModified\":\"2025-01-01T00:00:00Z\"},\"icons\":[{\"src\":\"https://x/i.png\",\"mimeType\":\"image/png\",\"sizes\":[\"48x48\"],\"theme\":\"dark\"}],\"_meta\":{\"r\":true}}"
}

expect Resource.new("u", "n").uri() == "u" and Resource.new("u", "n").name() == "n"

# ---- ResourceContents ----

expect {
	items = [
		ResourceContents.text("file:///rich", "text/markdown", "# hi").with_meta(json("{\"c\":1}")),
		ResourceContents.blob("file:///rich", "application/octet-stream", "AAE="),
	]
	JsonValue.Array(items.map(|i| i.to_json())).to_str() == "[{\"uri\":\"file:///rich\",\"mimeType\":\"text/markdown\",\"text\":\"# hi\",\"_meta\":{\"c\":1}},{\"uri\":\"file:///rich\",\"mimeType\":\"application/octet-stream\",\"blob\":\"AAE=\"}]"
}

expect ResourceContents.text("u", "m", "t").without_mime_type().to_json().to_str() == "{\"uri\":\"u\",\"text\":\"t\"}"
expect ResourceContents.blob("b", "m", "AA==").uri() == "b"

# ---- ResourceTemplate ----

expect ResourceTemplate.new("file:///t/{name}", "tpl").to_json().to_str() == "{\"name\":\"tpl\",\"uriTemplate\":\"file:///t/{name}\"}"

expect {
	t =
		ResourceTemplate.new("file:///r/{+path}{?q}", "tplrich")
			.with_title("TR")
			.with_description("tdesc")
			.with_mime_type("text/plain")
			.with_annotations({ audience: [Assistant], priority: Err(None), last_modified: Err(None) })
			.with_icon(icon)
			.with_meta(json("{\"t\":1}"))
	t.to_json().to_str() == "{\"name\":\"tplrich\",\"uriTemplate\":\"file:///r/{+path}{?q}\",\"title\":\"TR\",\"description\":\"tdesc\",\"mimeType\":\"text/plain\",\"annotations\":{\"audience\":[\"assistant\"]},\"icons\":[{\"src\":\"https://x/i.png\",\"mimeType\":\"image/png\",\"sizes\":[\"48x48\"],\"theme\":\"dark\"}],\"_meta\":{\"t\":1}}"
}

# A resources/list entry produced by a template's `list`: the template's metadata first.
expect {
	t = ResourceTemplate.new("file:///r/{+path}{?q}", "tplrich").with_title("TR").with_description("tdesc").with_mime_type("text/plain").with_annotations({ audience: [Assistant], priority: Err(None), last_modified: Err(None) }).with_icon(icon).with_meta(json("{\"t\":1}"))
	entry = JsonValue.Object(t.metadata().concat([("uri", String("file:///r/x")), ("name", String("x"))]))
	entry.to_str() == "{\"title\":\"TR\",\"description\":\"tdesc\",\"mimeType\":\"text/plain\",\"annotations\":{\"audience\":[\"assistant\"]},\"icons\":[{\"src\":\"https://x/i.png\",\"mimeType\":\"image/png\",\"sizes\":[\"48x48\"],\"theme\":\"dark\"}],\"_meta\":{\"t\":1},\"uri\":\"file:///r/x\",\"name\":\"x\"}"
}

expect ResourceTemplate.new("file:///t/{name}", "tpl").name() == "tpl"
expect ResourceTemplate.new("file:///t/{name}", "tpl").source() == "file:///t/{name}"

# ---- Prompt ----

expect Prompt.new("p0").to_json().to_str() == "{\"name\":\"p0\"}"

expect {
	p =
		Prompt.new("p1")
			.with_title("P1")
			.with_description("pd")
			.with_argument({ name: "who", description: "Who", required: Bool.True })
			.with_argument({ name: "opt", description: "", required: Bool.False })
			.with_icon(icon)
			.with_meta(json("{\"p\":1}"))
	p.to_json().to_str() == "{\"name\":\"p1\",\"title\":\"P1\",\"description\":\"pd\",\"arguments\":[{\"name\":\"who\",\"description\":\"Who\",\"required\":true},{\"name\":\"opt\",\"required\":false}],\"icons\":[{\"src\":\"https://x/i.png\",\"mimeType\":\"image/png\",\"sizes\":[\"48x48\"],\"theme\":\"dark\"}],\"_meta\":{\"p\":1}}"
}

expect Prompt.result_to_json({ description: Ok("res"), messages: [Prompt.user("hello w"), Prompt.assistant("ok")] }).to_str() == "{\"description\":\"res\",\"messages\":[{\"role\":\"user\",\"content\":{\"type\":\"text\",\"text\":\"hello w\"}},{\"role\":\"assistant\",\"content\":{\"type\":\"text\",\"text\":\"ok\"}}]}"

expect Prompt.result_to_json({ description: Err(None), messages: [Prompt.user("u")] }).to_str() == "{\"messages\":[{\"role\":\"user\",\"content\":{\"type\":\"text\",\"text\":\"u\"}}]}"

expect {
	msgs = [{ role: Assistant, content: Content.image("d", "m") }, { role: User, content: Content.embedded_resource(ResourceContents.text("u", "x", "t").without_mime_type()) }]
	Prompt.result_to_json({ description: Err(None), messages: msgs }).to_str() == "{\"messages\":[{\"role\":\"assistant\",\"content\":{\"type\":\"image\",\"data\":\"d\",\"mimeType\":\"m\"}},{\"role\":\"user\",\"content\":{\"type\":\"resource\",\"resource\":{\"uri\":\"u\",\"text\":\"t\"}}}]}"
}

expect Prompt.new("p").name() == "p" and Prompt.new("p").with_argument({ name: "a", description: "", required: Bool.True }).arguments().len() == 1

# ---- McpError ----

expect McpError.resource_not_found("file:///nope").to_json().to_str() == "{\"code\":-32602,\"message\":\"Resource not found: file:///nope\",\"data\":{\"uri\":\"file:///nope\"}}"
expect McpError.method_not_found("x/y").to_json().to_str() == "{\"code\":-32601,\"message\":\"Method not found\"}"
expect McpError.invalid_params("Tool missing not found").to_json().to_str() == "{\"code\":-32602,\"message\":\"Tool missing not found\"}"
expect McpError.internal("boom").code() == -32603 and McpError.internal("boom").message() == "boom"
expect McpError.unsupported_version(["2026-07-28"], "1999").to_json().to_str() == "{\"code\":-32022,\"message\":\"Unsupported protocol version: 1999\",\"data\":{\"supported\":[\"2026-07-28\"],\"requested\":\"1999\"}}"
expect McpError.missing_capabilities(json("{\"sampling\":{}}")).to_json().to_str() == "{\"code\":-32021,\"message\":\"Missing required client capabilities: sampling\",\"data\":{\"requiredCapabilities\":{\"sampling\":{}}}}"
expect {
	e = json("{\"mode\":\"url\",\"message\":\"m\",\"url\":\"u\",\"elicitationId\":\"e\"}")
	McpError.url_elicitation_required([e]).to_json().to_str() == "{\"code\":-32042,\"message\":\"URL elicitation required\",\"data\":{\"elicitations\":[{\"mode\":\"url\",\"message\":\"m\",\"url\":\"u\",\"elicitationId\":\"e\"}]}}"
		and McpError.url_elicitation_required([e, e]).message() == "URL elicitations required"
}
expect McpError.new(-32000, "x").data() == Err(None)
expect McpError.bad_request("r").code() == -32600 and McpError.parse_failed("p").code() == -32700

expect
	[McpError.parse_error, McpError.invalid_request, McpError.method_not_found_code, McpError.invalid_params_code, McpError.internal_error, McpError.header_mismatch, McpError.missing_required_client_capability, McpError.unsupported_protocol_version, McpError.url_elicitation_required_code, McpError.resource_not_found_code]
		== [-32700, -32600, -32601, -32602, -32603, -32020, -32021, -32022, -32042, -32002]

expect {
	e = McpError.from_json(json("{\"code\":-32002,\"message\":\"Resource not found\",\"data\":{\"uri\":\"x\"}}"))
	match e {
		Ok(err) => err.code() == -32002 and err.message() == "Resource not found" and err.data() == Ok(json("{\"uri\":\"x\"}"))
		Err(_) => Bool.False
	}
}
expect McpError.from_json(json("{\"code\":-32601,\"message\":\"no\"}")).map_ok(|e| e.to_json().to_str()) == Ok("{\"code\":-32601,\"message\":\"no\"}")
expect McpError.from_json(json("{\"message\":\"no\"}")).is_err()
expect McpError.from_json(json("{\"code\":\"x\",\"message\":\"no\"}")).is_err()

# ---- LogLevel ----

expect LogLevel.all.map(|l| l.to_str()) == ["debug", "info", "notice", "warning", "error", "critical", "alert", "emergency"]
expect LogLevel.all.map(|l| l.severity()) == [0, 1, 2, 3, 4, 5, 6, 7]
expect LogLevel.all.map(|l| LogLevel.from_str(l.to_str())) == LogLevel.all.map(|l| Ok(l))
expect LogLevel.from_str("Warning") == Err(UnknownLevel)
expect LogLevel.from_str("warn") == Err(UnknownLevel)
expect LogLevel.is_at_least(Error, Warning) and !LogLevel.is_at_least(Info, Warning) and LogLevel.is_at_least(Debug, Debug)
