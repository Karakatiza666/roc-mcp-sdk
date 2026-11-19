import JsonValue
import Content

## A prompt definition, as prompts/list shows it.
Prompt :: {
	name : Str,
	title : Try(Str, [None]),
	description : Try(Str, [None]),
	arguments : List(Prompt.Argument),
	icons : List(Content.Icon),
	meta : Try(JsonValue, [None]),
}.{

	## An empty `description` is not sent.
	Argument : { name : Str, description : Str, required : Bool }

	new : Str -> Prompt
	new = |n| { name: n, title: Err(None), description: Err(None), arguments: [], icons: [], meta: Err(None) }

	name : Prompt -> Str
	name = |p| p.name

	with_title : Prompt, Str -> Prompt
	with_title = |p, s| { ..p, title: Ok(s) }

	with_description : Prompt, Str -> Prompt
	with_description = |p, s| { ..p, description: Ok(s) }

	with_argument : Prompt, Prompt.Argument -> Prompt
	with_argument = |p, a| { ..p, arguments: p.arguments.append(a) }

	Message : { role : [User, Assistant], content : Content }

	## The result of prompts/get.
	Result : { description : Try(Str, [None]), messages : List(Prompt.Message) }

	user : Str -> Prompt.Message
	user = |text| { role: User, content: Content.text(text) }

	assistant : Str -> Prompt.Message
	assistant = |text| { role: Assistant, content: Content.text(text) }

	with_icon : Prompt, Content.Icon -> Prompt
	with_icon = |p, i| { ..p, icons: p.icons.append(i) }

	with_meta : Prompt, JsonValue -> Prompt
	with_meta = |p, m| { ..p, meta: Ok(m) }

	arguments : Prompt -> List(Prompt.Argument)
	arguments = |p| p.arguments

	## The prompts/list entry: `name`, `title`, `description`, `arguments` (when not empty), `icons`, `_meta`.
	to_json : Prompt -> JsonValue
	to_json = |p| {
		args = if (p.arguments.is_empty()) [] else [("arguments", Array(p.arguments.map(argument_to_json)))]
		mt = match p.meta {
			Ok(j) => [("_meta", j)]
			Err(None) => []
		}
		Object(
			[("name", String(p.name))]
				.concat(opt_str("title", p.title))
				.concat(opt_str("description", p.description))
				.concat(args)
				.concat(Content.icons_field(p.icons))
				.concat(mt),
		)
	}

	## `{role, content}`.
	message_to_json : Prompt.Message -> JsonValue
	message_to_json = |m| {
		r = match m.role {
			User => "user"
			Assistant => "assistant"
		}
		Object([("role", String(r)), ("content", m.content.to_json())])
	}

	## The prompts/get result: `{description?, messages}`.
	result_to_json : Prompt.Result -> JsonValue
	result_to_json = |res| Object(opt_str("description", res.description).append(("messages", Array(res.messages.map(message_to_json)))))
}

argument_to_json : Prompt.Argument -> JsonValue
argument_to_json = |a| {
	d = if (a.description.is_empty()) [] else [("description", String(a.description))]
	Object([("name", String(a.name))].concat(d).append(("required", Bool(a.required))))
}

opt_str : Str, Try(Str, [None]) -> List((Str, JsonValue))
opt_str = |k, v| match v {
	Ok(s) => [(k, String(s))]
	Err(None) => []
}
