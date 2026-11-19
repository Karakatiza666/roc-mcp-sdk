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
	new = |source, n| match UriTemplate.parse(source) {
		Ok(t) => { template: t, name: n, title: Err(None), description: Err(None), mime_type: Err(None), annotations: { audience: [], priority: Err(None), last_modified: Err(None) }, icons: [], meta: Err(None) }
		Err(InvalidTemplate(why)) => crash "invalid URI template ${source}: ${why}"
	}

	name : ResourceTemplate -> Str
	name = |t| t.name

	with_title : ResourceTemplate, Str -> ResourceTemplate
	with_title = |t, s| { ..t, title: Ok(s) }

	with_description : ResourceTemplate, Str -> ResourceTemplate
	with_description = |t, s| { ..t, description: Ok(s) }

	with_mime_type : ResourceTemplate, Str -> ResourceTemplate
	with_mime_type = |t, s| { ..t, mime_type: Ok(s) }

	uri_template : ResourceTemplate -> UriTemplate
	uri_template = |t| t.template
}
