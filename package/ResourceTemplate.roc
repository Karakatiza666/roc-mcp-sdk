import JsonValue
import Content
import UriTemplate

## A URI template, as resources/templates/list shows it.
ResourceTemplate :: {
	template : UriTemplate,
	name : Str,
	title : Try(Str, [None]),
	description : Try(Str, [None]),
	mime_type : Try(Str, [None]),
	annotations : Content.Annotations,
	icons : List(Content.Icon),
	meta : Try(JsonValue, [None]),
}.{

	## Crashes on an invalid template: templates are written by the app author.
	new : Str, Str -> ResourceTemplate
	new = |src, n| match UriTemplate.parse(src) {
		Ok(t) => { template: t, name: n, title: Err(None), description: Err(None), mime_type: Err(None), annotations: Content.no_annotations, icons: [], meta: Err(None) }
		Err(InvalidTemplate(why)) => crash "invalid URI template ${src}: ${why}"
	}

	name : ResourceTemplate -> Str
	name = |t| t.name

	with_title : ResourceTemplate, Str -> ResourceTemplate
	with_title = |t, s| { ..t, title: Ok(s) }

	with_description : ResourceTemplate, Str -> ResourceTemplate
	with_description = |t, s| { ..t, description: Ok(s) }

	with_mime_type : ResourceTemplate, Str -> ResourceTemplate
	with_mime_type = |t, s| { ..t, mime_type: Ok(s) }

	with_annotations : ResourceTemplate, Content.Annotations -> ResourceTemplate
	with_annotations = |t, a| { ..t, annotations: a }

	with_icon : ResourceTemplate, Content.Icon -> ResourceTemplate
	with_icon = |t, i| { ..t, icons: t.icons.append(i) }

	with_meta : ResourceTemplate, JsonValue -> ResourceTemplate
	with_meta = |t, m| { ..t, meta: Ok(m) }

	uri_template : ResourceTemplate -> UriTemplate
	uri_template = |t| t.template

	## The template source, as given to `new`.
	source : ResourceTemplate -> Str
	source = |t| t.template.to_str()

	## The resources/templates/list entry: `name`, `uriTemplate`, then `metadata`.
	to_json : ResourceTemplate -> JsonValue
	to_json = |t| Object([("name", String(t.name)), ("uriTemplate", String(t.template.to_str()))].concat(metadata(t)))

	## `title`, `description`, `mimeType`, `annotations`, `icons`, `_meta`, each only when set.
	## JS puts these first in each resources/list entry that the template's `list` returns,
	## followed by the entry's own fields, which win on a duplicate key.
	metadata : ResourceTemplate -> List((Str, JsonValue))
	metadata = |t|
		opt_str("title", t.title)
			.concat(opt_str("description", t.description))
			.concat(opt_str("mimeType", t.mime_type))
			.concat(Content.annotations_field(t.annotations))
			.concat(Content.icons_field(t.icons))
			.concat(
				match t.meta {
					Ok(j) => [("_meta", j)]
					Err(None) => []
				},
			)
}

opt_str : Str, Try(Str, [None]) -> List((Str, JsonValue))
opt_str = |k, v| match v {
	Ok(s) => [(k, String(s))]
	Err(None) => []
}
