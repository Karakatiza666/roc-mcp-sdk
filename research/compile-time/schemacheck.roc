app [main!] {
	mcp: "../../package/main.roc",
	pf: platform "https://github.com/roc-lang/basic-cli/releases/download/0.28.1/7brgwR8YUqfeGrkdfF1V4GPPN7DnP7ftqub9KcrTEZtr.tar.zst",
}

import pf.Stdin
import pf.Stdout
import mcp.JsonValue
import mcp.SchemaCheck

# Only SchemaCheck.validate on two stdin lines (schema, value).
main! = |_args| {
	s = JsonValue.parse(Stdin.line!() ?? "") ?? Null
	v = JsonValue.parse(Stdin.line!() ?? "") ?? Null
	out = match SchemaCheck.validate(s, v) {
		Ok(j) => j.to_str()
		Err(Invalid(xs)) => Str.join_with(xs, ", ")
	}
	Stdout.line!(out) ?? {}
	Ok({})
}
