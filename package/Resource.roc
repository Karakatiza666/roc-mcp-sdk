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
		annotations: Content.no_annotations,
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

	with_annotations : Resource, Content.Annotations -> Resource
	with_annotations = |r, a| { ..r, annotations: a }

	with_icon : Resource, Content.Icon -> Resource
	with_icon = |r, i| { ..r, icons: r.icons.append(i) }

	name : Resource -> Str
	name = |r| r.name

	## The resources/list entry: `uri`, `name`, `title`, `description`, `mimeType`, `size`,
	## `annotations`, `icons`, `_meta`, each optional one only when set.
	to_json : Resource -> JsonValue
	to_json = |r| Object([("uri", String(r.uri)), ("name", String(r.name))].concat(metadata(r)))

	## The optional fields of `to_json`, in order (without `uri` and `name`).
	metadata : Resource -> List((Str, JsonValue))
	metadata = |r| {
		sz = match r.size {
			Ok(n) => [("size", Number(n.to_str()))]
			Err(None) => []
		}
		opt_str("title", r.title)
			.concat(opt_str("description", r.description))
			.concat(opt_str("mimeType", r.mime_type))
			.concat(sz)
			.concat(Content.annotations_field(r.annotations))
			.concat(Content.icons_field(r.icons))
			.concat(opt_json("_meta", r.meta))
	}
}

opt_str : Str, Try(Str, [None]) -> List((Str, JsonValue))
opt_str = |k, v| match v {
	Ok(s) => [(k, String(s))]
	Err(None) => []
}

opt_json : Str, Try(JsonValue, [None]) -> List((Str, JsonValue))
opt_json = |k, v| match v {
	Ok(j) => [(k, j)]
	Err(None) => []
}
