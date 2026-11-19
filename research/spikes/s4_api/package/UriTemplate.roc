## RFC 6570 URI templates, the subset the JS SDK matches: `{x}`, `{+x}`, `{#x}`, `{.x}`, `{/x}`, `{?a,b}`, `{&a}`, and `*`.
UriTemplate :: { source : Str, parts : List([Literal(Str), Expr({ op : Str, names : List(Str), explode : Bool })]) }.{
	parse : Str -> Try(UriTemplate, [InvalidTemplate(Str)])
	parse = |s| Ok({ source: s, parts: [Literal(s)] })

	to_str : UriTemplate -> Str
	to_str = |t| t.source

	variable_names : UriTemplate -> List(Str)
	variable_names = |_t| crash "unimplemented"

	## Matches a whole URI. Values are not percent-decoded (JS parity).
	match_uri : UriTemplate, Str -> Try(UriTemplate.Vars, [NoMatch])
	match_uri = |_t, _uri| crash "unimplemented"

	expand : UriTemplate, List((Str, Str)) -> Str
	expand = |_t, _vars| crash "unimplemented"

	## Matched variables. An exploded variable may hold several values.
	Vars :: List((Str, List(Str))).{
		get : UriTemplate.Vars, Str -> Try(Str, [Missing])
		get = |_v, _name| crash "unimplemented"

		get_all : UriTemplate.Vars, Str -> List(Str)
		get_all = |_v, _name| crash "unimplemented"

		to_list : UriTemplate.Vars -> List((Str, List(Str)))
		to_list = |_v| crash "unimplemented"
	}
}
