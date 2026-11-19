import JsonValue
import Ctx

## Spike: a server definition generic over the app state. Handlers are stored in lists.
Server(state) :: {
	name : Str,
	version : Str,
	instructions : Str,
	tools : List(
		{
			name : Str,
			description : Str,
			input_schema : JsonValue,
			## Pure: decodes the arguments, or says why they are wrong.
			prepare : JsonValue -> Try((state, Ctx => (state, Server.Outcome)), Str),
		},
	),
	notification_handlers : List({ method : Str, run! : state, Ctx, JsonValue => state }),
}.{
	## What a handler returns.
	Outcome := [
		Done(JsonValue),
		InputRequired(List((Str, JsonValue))),
	]

	## A tool's reply in the spike.
	Reply := [Text(Str), Error(Str), NeedInput(List((Str, JsonValue)))]

	new : { name : Str, version : Str, instructions : Str } -> Server(state)
	new = |i| { name: i.name, version: i.version, instructions: i.instructions, tools: [], notification_handlers: [] }

	## A tool whose arguments decode into the app's own record type.
	tool : Server(state), { name : Str, description : Str, input_schema : JsonValue }, (state, Ctx, args => (state, Server.Reply)) -> Server(state)
		where [args.Json.Parseable(_)]
	tool = |server, def, handler!| {
		prepare = |raw| match Json.parse(raw.to_str()) {
			Ok(args) => Ok(|state, ctx| {
				(state2, reply) = handler!(state, ctx, args)
				(state2, to_outcome(reply))
			})
			Err(e) => Err("Invalid arguments for tool ${def.name}: ${Str.inspect(e)}")
		}
		{ ..server, tools: server.tools.append({ name: def.name, description: def.description, input_schema: def.input_schema, prepare }) }
	}

	on_notification : Server(state), Str, (state, Ctx, JsonValue => state) -> Server(state)
	on_notification = |server, method, run!| { ..server, notification_handlers: server.notification_handlers.append({ method, run! }) }

	info : Server(state) -> { name : Str, version : Str, instructions : Str }
	info = |server| { name: server.name, version: server.version, instructions: server.instructions }

	tool_list : Server(state) -> List({ name : Str, description : Str, input_schema : JsonValue })
	tool_list = |server| server.tools.map(|t| { name: t.name, description: t.description, input_schema: t.input_schema })

	find_tool : Server(state), Str -> Try(JsonValue -> Try((state, Ctx => (state, Server.Outcome)), Str), [NotFound])
	find_tool = |server, name| match server.tools.find_first(|t| t.name == name) {
		Ok(t) => Ok(t.prepare)
		Err(_) => Err(NotFound)
	}

	find_notification_handler : Server(state), Str -> Try((state, Ctx, JsonValue => state), [NotFound])
	find_notification_handler = |server, method| match server.notification_handlers.find_first(|h| h.method == method) {
		Ok(h) => Ok(h.run!)
		Err(_) => Err(NotFound)
	}
}

text_result : Str, Bool -> JsonValue
text_result = |text, is_error| Object([
	("content", Array([Object([("type", String("text")), ("text", String(text))])])),
	("isError", Bool(is_error)),
])

to_outcome : Server.Reply -> Server.Outcome
to_outcome = |reply| match reply {
	Text(t) => Done(text_result(t, Bool.False))
	Error(t) => Done(text_result(t, Bool.True))
	NeedInput(reqs) => InputRequired(reqs)
}
