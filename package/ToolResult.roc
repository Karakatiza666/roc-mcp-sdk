import JsonValue
import Content

## The result of tools/call.
## `is_error` is `Err(None)` until set, so `isError` is sent only when the app set it (JS echoes `isError: false`).
ToolResult :: { content : List(Content), structured : Try(JsonValue, [None]), is_error : Try(Bool, [None]), meta : Try(JsonValue, [None]) }.{
	text : Str -> ToolResult
	text = |s| { content: [Content.text(s)], structured: Err(None), is_error: Err(None), meta: Err(None) }

	## `isError: true` with one text block. The model sees it; the call itself succeeded.
	error : Str -> ToolResult
	error = |s| { content: [Content.text(s)], structured: Err(None), is_error: Ok(Bool.True), meta: Err(None) }

	from_content : List(Content) -> ToolResult
	from_content = |blocks| { content: blocks, structured: Err(None), is_error: Err(None), meta: Err(None) }

	with_structured : ToolResult, JsonValue -> ToolResult
	with_structured = |r, j| { ..r, structured: Ok(j) }

	## Typed structured content, encoded with Encoding.Json.
	with_structured_value : ToolResult, a -> ToolResult where [a.Json.Encodable([])]
	with_structured_value = |r, value| { ..r, structured: Ok(JsonValue.encode(value)) }

	with_is_error : ToolResult, Bool -> ToolResult
	with_is_error = |r, b| { ..r, is_error: Ok(b) }

	with_meta : ToolResult, JsonValue -> ToolResult
	with_meta = |r, m| { ..r, meta: Ok(m) }

	content : ToolResult -> List(Content)
	content = |r| r.content

	is_error : ToolResult -> Bool
	is_error = |r| r.is_error ?? Bool.False

	structured : ToolResult -> Try(JsonValue, [None])
	structured = |r| r.structured

	with_content : ToolResult, List(Content) -> ToolResult
	with_content = |r, c| { ..r, content: c }

	## Applies `f` to the last block when it is text (roc-syntax-mcp's stalled-fetch note).
	map_last_text : ToolResult, (Str -> Str) -> ToolResult
	map_last_text = |r, f| {
		n = r.content.len()
		match r.content.last() {
			Ok(last) => { ..r, content: r.content.take_first(n - 1).append(last.map_text(f)) }
			Err(_) => r
		}
	}

	## `{_meta?, content, structuredContent?, isError?}` (the JS key order).
	to_json : ToolResult -> JsonValue
	to_json = |r| {
		meta = match r.meta {
			Ok(m) => [("_meta", m)]
			Err(None) => []
		}
		sc = match r.structured {
			Ok(j) => [("structuredContent", j)]
			Err(None) => []
		}
		is_err = match r.is_error {
			Ok(b) => [("isError", Bool(b))]
			Err(None) => []
		}
		Object(meta.append(("content", Array(r.content.map(Content.to_json)))).concat(sc).concat(is_err))
	}
}
