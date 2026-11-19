import JsonValue
import Content

## A resource as resources/list shows it. Also what a template's `list` callback returns.
Resource :: {
	uri : Str,
	name : Str,
	title : Try(Str, [None]),
	description : Try(Str, [None]),
	mime_type : Try(Str, [None]),
	size : Try(U64, [None]),
	annotations : Content.Annotations,
	icons : List(Content.Icon),
	meta : Try(JsonValue, [None]),
}.{
	new : Str, Str -> Resource
	new = |u, n| {
		uri: u,
		name: n,
		title: Err(None),
		description: Err(None),
		mime_type: Err(None),
		size: Err(None),
		annotations: { audience: [], priority: Err(None), last_modified: Err(None) },
		icons: [],
		meta: Err(None),
	}

	uri : Resource -> Str
	uri = |r| r.uri

	with_title : Resource, Str -> Resource
	with_title = |r, s| { ..r, title: Ok(s) }

	with_description : Resource, Str -> Resource
	with_description = |r, s| { ..r, description: Ok(s) }

	with_mime_type : Resource, Str -> Resource
	with_mime_type = |r, s| { ..r, mime_type: Ok(s) }

	with_size : Resource, U64 -> Resource
	with_size = |r, n| { ..r, size: Ok(n) }

	with_meta : Resource, JsonValue -> Resource
	with_meta = |r, m| { ..r, meta: Ok(m) }

	to_json : Resource -> JsonValue
	to_json = |_r| crash "unimplemented"
}
