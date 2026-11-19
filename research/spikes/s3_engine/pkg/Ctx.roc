import JsonValue

## Spike: what a handler sees about the request it serves. Pure data plus one sender.
Ctx :: {
	request_id : JsonValue,
	client_capabilities : JsonValue,
	protocol_version : Str,
	input_responses : List((Str, JsonValue)),
	send! : Str => {},
}.{
	new : JsonValue, JsonValue, Str, List((Str, JsonValue)) -> Ctx
	new = |request_id, client_capabilities, protocol_version, input_responses| {
		request_id,
		client_capabilities,
		protocol_version,
		input_responses,
		send!: |_| {},
	}

	with_sender : Ctx, (Str => {}) -> Ctx
	with_sender = |ctx, send!| { ..ctx, send! }

	has_client_capability : Ctx, Str -> Bool
	has_client_capability = |ctx, name| ctx.client_capabilities.get(name).is_ok()

	input_response : Ctx, Str -> Try(JsonValue, [NotAnswered])
	input_response = |ctx, key| match ctx.input_responses.find_first(|(k, _)| k == key) {
		Ok((_, v)) => Ok(v)
		Err(_) => Err(NotAnswered)
	}

	## Sends notifications/message to the client (no level filter in the spike).
	log! : Ctx, Str, Str => {}
	log! = |ctx, level, text| {
		msg : JsonValue
		msg = Object([("jsonrpc", String("2.0")), ("method", String("notifications/message")), ("params", Object([("level", String(level)), ("data", String(text))]))])
		(ctx.send!)(msg.to_str())
	}
}
