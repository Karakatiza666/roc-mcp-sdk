app [main!] { pkg: "pkg/main.roc" }

import pkg.JsonValue
import pkg.Typed

main! = |_args| Ok({})

expect JsonValue.parse("[]") == Ok(Array([]))

CheckArgs : { code : Try(Str, [Missing]), path : Try(Str, [Missing]), scope ?: Str }

expect {
	v = JsonValue.parse("{\"code\":\"x = 1\",\"extra\":true}")?
	args : Try(CheckArgs, _)
	args = Typed.decode(v)
	match args {
		Ok(a) => a.code == Ok("x = 1") and a.path == Err(Missing) and a.?scope.is_err()
		Err(_) => Bool.False
	}
}

expect {
	v = JsonValue.parse("{\"path\":3}")?
	args : Try(CheckArgs, _)
	args = Typed.decode(v)
	args.is_err()
}

expect Typed.encode({ ok: Bool.True, exit_code: 0.I64 }) == Object([("exit_code", Number("0")), ("ok", Bool(Bool.True))])
