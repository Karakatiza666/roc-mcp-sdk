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
}
