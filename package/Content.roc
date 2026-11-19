import JsonValue
import ResourceContents
import Internal/Base64

## A content block of a tool result, prompt message or sampling message.
Content :: [
	Text({ text : Str, annotations : Content.Annotations, meta : Try(JsonValue, [None]) }),
	Image({ data : Str, mime_type : Str, annotations : Content.Annotations }),
	Audio({ data : Str, mime_type : Str, annotations : Content.Annotations }),
	ResourceLink({ uri : Str, name : Str, title : Try(Str, [None]), description : Try(Str, [None]), mime_type : Try(Str, [None]), size : Try(U64, [None]) }),
	EmbeddedResource(JsonValue),
].{

	## `audience` is sent only when not empty; `last_modified` is an ISO 8601 date-time.
	Annotations : { audience : List([User, Assistant]), priority : Try(Dec, [None]), last_modified : Try(Str, [None]) }

	## An icon of a server, tool, resource or prompt.
	Icon : { src : Str, mime_type : Try(Str, [None]), sizes : List(Str), theme : Try([Light, Dark], [None]) }

	text : Str -> Content
	text = |t| Text({ text: t, annotations: no_annotations, meta: Err(None) })

	## `data` is base64.
	image : Str, Str -> Content
	image = |data, mime_type| Image({ data, mime_type, annotations: no_annotations })

	## Encodes raw bytes as base64.
	image_bytes : List(U8), Str -> Content
	image_bytes = |bytes, mime_type| Image({ data: Base64.encode(bytes), mime_type, annotations: no_annotations })

	## `data` is base64.
	audio : Str, Str -> Content
	audio = |data, mime_type| Audio({ data, mime_type, annotations: no_annotations })

	resource_link : Str, Str -> Content
	resource_link = |uri, n| ResourceLink({ uri, name: n, title: Err(None), description: Err(None), mime_type: Err(None), size: Err(None) })

	## A `resource` block that embeds the contents of a resource.
	embedded_resource : ResourceContents -> Content
	embedded_resource = |rc| EmbeddedResource(rc.to_json())

	## Sets the annotations of a text, image or audio block. Other blocks are returned unchanged.
	with_annotations : Content, Content.Annotations -> Content
	with_annotations = |c, a| match c {
		Text(t) => Text({ ..t, annotations: a })
		Image(i) => Image({ ..i, annotations: a })
		Audio(i) => Audio({ ..i, annotations: a })
		other => other
	}

	## Sets `_meta` of a text block. Other blocks are returned unchanged.
	with_meta : Content, JsonValue -> Content
	with_meta = |c, m| match c {
		Text(t) => Text({ ..t, meta: Ok(m) })
		other => other
	}

	## The text of a Text block.
	as_text : Content -> Try(Str, [NotText])
	as_text = |c| match c {
		Text(t) => Ok(t.text)
		_ => Err(NotText)
	}

	map_text : Content, (Str -> Str) -> Content
	map_text = |c, f| match c {
		Text(t) => Text({ ..t, text: f(t.text) })
		other => other
	}

	## The wire form of the block.
	to_json : Content -> JsonValue
	to_json = |c| match c {
		Text(t) =>
			Object(
				[("type", String("text")), ("text", String(t.text))]
					.concat(annotations_field(t.annotations))
					.concat(opt_field("_meta", t.meta)),
			)
		Image(i) =>
			Object(
				[("type", String("image")), ("data", String(i.data)), ("mimeType", String(i.mime_type))]
					.concat(annotations_field(i.annotations)),
			)
		Audio(i) =>
			Object(
				[("type", String("audio")), ("data", String(i.data)), ("mimeType", String(i.mime_type))]
					.concat(annotations_field(i.annotations)),
			)
		ResourceLink(l) =>
			Object(
				[("name", String(l.name))]
					.concat(opt_str("title", l.title))
					.append(("uri", String(l.uri)))
					.concat(opt_str("description", l.description))
					.concat(opt_str("mimeType", l.mime_type))
					.concat(opt_u64("size", l.size))
					.append(("type", String("resource_link"))),
			)
		EmbeddedResource(r) => Object([("type", String("resource")), ("resource", r)])
	}

	## The wire form of annotations: `audience`, `priority`, `lastModified`, each only when set.
	annotations_to_json : Content.Annotations -> JsonValue
	annotations_to_json = |a| {
		audience =
			if a.audience.is_empty() {
				[]
			} else {
				[("audience", Array(a.audience.map(|r| String(role_str(r)))))]
			}
		priority = match a.priority {
			Ok(p) => [("priority", dec_json(p))]
			Err(None) => []
		}
		Object(audience.concat(priority).concat(opt_str("lastModified", a.last_modified)))
	}

	## True when no annotation is set; such annotations are not sent.
	annotations_empty : Content.Annotations -> Bool
	annotations_empty = |a| a.audience.is_empty() and a.priority.is_err() and a.last_modified.is_err()

	## Standard base64 with padding (`Internal/Base64`).
	base64 : List(U8) -> Str
	base64 = |bytes| Base64.encode(bytes)

	no_annotations : Content.Annotations
	no_annotations = { audience: [], priority: Err(None), last_modified: Err(None) }

	## An icon with only `src`.
	icon : Str -> Content.Icon
	icon = |s| { src: s, mime_type: Err(None), sizes: [], theme: Err(None) }

	## The wire form of an icon: `src`, `mimeType`, `sizes` (when not empty), `theme`.
	icon_to_json : Content.Icon -> JsonValue
	icon_to_json = |i| {
		sizes = if (i.sizes.is_empty()) [] else [("sizes", Array(i.sizes.map(|s| String(s))))]
		theme = match i.theme {
			Ok(Light) => [("theme", String("light"))]
			Ok(Dark) => [("theme", String("dark"))]
			Err(None) => []
		}
		Object([("src", String(i.src))].concat(opt_str("mimeType", i.mime_type)).concat(sizes).concat(theme))
	}

	## `[("icons", [...])]` when the list is not empty, else `[]`. For the `to_json` of definitions.
	icons_field : List(Content.Icon) -> List((Str, JsonValue))
	icons_field = |icons| if (icons.is_empty()) [] else [("icons", Array(icons.map(icon_to_json)))]

	## `[("annotations", {...})]` when any annotation is set, else `[]`.
	annotations_field : Content.Annotations -> List((Str, JsonValue))
	annotations_field = |a| if (annotations_empty(a)) [] else [("annotations", annotations_to_json(a))]

	## A JSON number for a Dec: integral values have no fraction (`1`, not `1.0`).
	dec_json : Dec -> JsonValue
	dec_json = |d| if (Dec.trunc(d) == d) Number(d.round_to_i128().to_str()) else Number(d.to_str())
}

role_str : [User, Assistant] -> Str
role_str = |r| match r {
	User => "user"
	Assistant => "assistant"
}

opt_str : Str, Try(Str, [None]) -> List((Str, JsonValue))
opt_str = |k, v| match v {
	Ok(s) => [(k, String(s))]
	Err(None) => []
}

opt_u64 : Str, Try(U64, [None]) -> List((Str, JsonValue))
opt_u64 = |k, v| match v {
	Ok(n) => [(k, Number(n.to_str()))]
	Err(None) => []
}

opt_field : Str, Try(JsonValue, [None]) -> List((Str, JsonValue))
opt_field = |k, v| match v {
	Ok(j) => [(k, j)]
	Err(None) => []
}
