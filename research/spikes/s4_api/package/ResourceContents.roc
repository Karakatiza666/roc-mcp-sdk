import JsonValue

## One item of a resources/read result.
ResourceContents :: [
	Text({ uri : Str, mime_type : Try(Str, [None]), text : Str, meta : Try(JsonValue, [None]) }),
	Blob({ uri : Str, mime_type : Try(Str, [None]), blob : Str, meta : Try(JsonValue, [None]) }),
].{
	text : Str, Str, Str -> ResourceContents
	text = |u, m, t| Text({ uri: u, mime_type: Ok(m), text: t, meta: Err(None) })

	## `blob` is base64.
	blob : Str, Str, Str -> ResourceContents
	blob = |u, m, b| Blob({ uri: u, mime_type: Ok(m), blob: b, meta: Err(None) })
}
