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

	## Drops `mimeType` from the item (JS allows contents without one).
	without_mime_type : ResourceContents -> ResourceContents
	without_mime_type = |rc| match rc {
		Text(t) => Text({ ..t, mime_type: Err(None) })
		Blob(b) => Blob({ ..b, mime_type: Err(None) })
	}

	with_meta : ResourceContents, JsonValue -> ResourceContents
	with_meta = |rc, m| match rc {
		Text(t) => Text({ ..t, meta: Ok(m) })
		Blob(b) => Blob({ ..b, meta: Ok(m) })
	}

	uri : ResourceContents -> Str
	uri = |rc| match rc {
		Text(t) => t.uri
		Blob(b) => b.uri
	}

	## `{uri, mimeType?, text | blob, _meta?}`.
	to_json : ResourceContents -> JsonValue
	to_json = |rc| match rc {
		Text(t) => Object([("uri", String(t.uri))].concat(opt_mime(t.mime_type)).append(("text", String(t.text))).concat(opt_meta(t.meta)))
		Blob(b) => Object([("uri", String(b.uri))].concat(opt_mime(b.mime_type)).append(("blob", String(b.blob))).concat(opt_meta(b.meta)))
	}
}

opt_mime : Try(Str, [None]) -> List((Str, JsonValue))
opt_mime = |m| match m {
	Ok(s) => [("mimeType", String(s))]
	Err(None) => []
}

opt_meta : Try(JsonValue, [None]) -> List((Str, JsonValue))
opt_meta = |m| match m {
	Ok(j) => [("_meta", j)]
	Err(None) => []
}
