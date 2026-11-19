import JsonValue

## A content block of a tool result, prompt message or sampling message.
Content :: [
	Text({ text : Str, annotations : Content.Annotations, meta : Try(JsonValue, [None]) }),
	Image({ data : Str, mime_type : Str, annotations : Content.Annotations }),
	Audio({ data : Str, mime_type : Str, annotations : Content.Annotations }),
	ResourceLink({ uri : Str, name : Str, title : Try(Str, [None]), description : Try(Str, [None]), mime_type : Try(Str, [None]), size : Try(U64, [None]) }),
	EmbeddedResource(JsonValue),
].{
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
	image_bytes = |_bytes, _mime_type| crash "unimplemented"

	audio : Str, Str -> Content
	audio = |data, mime_type| Audio({ data, mime_type, annotations: no_annotations })

	resource_link : Str, Str -> Content
	resource_link = |uri, name| ResourceLink({ uri, name, title: Err(None), description: Err(None), mime_type: Err(None), size: Err(None) })

	with_annotations : Content, Content.Annotations -> Content
	with_annotations = |_c, _a| crash "unimplemented"

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

	to_json : Content -> JsonValue
	to_json = |_c| crash "unimplemented"
}

no_annotations : Content.Annotations
no_annotations = { audience: [], priority: Err(None), last_modified: Err(None) }
