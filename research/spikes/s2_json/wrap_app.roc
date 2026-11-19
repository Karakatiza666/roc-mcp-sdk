from_json : Str -> Try(a, [InvalidJson(Str), ..errs])
	where [a.Json.Parseable([InvalidJson(Str), ..errs])]
from_json = |text| Json.parse(text)

P : { x : I64 }

expect {
	r : Try(P, _)
	r = from_json("{\"x\":1}")
	r == Ok({ x: 1 })
}

from_json2 : Str -> Try(a, _)
	where [a.Json.Parseable(_)]
from_json2 = |text| Json.parse(text)

expect {
	r : Try(P, _)
	r = from_json2("{\"x\":1}")
	r == Ok({ x: 1 })
}
