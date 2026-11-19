app [main!] {
	mcp: "../../package/main.roc",
	pf: platform "https://github.com/roc-lang/basic-cli/releases/download/0.28.1/7brgwR8YUqfeGrkdfF1V4GPPN7DnP7ftqub9KcrTEZtr.tar.zst",
}

import pf.Stdin
import pf.Stdout
import mcp.JsonValue

# Baseline: only JsonValue parse and print.
main! = |_args| {
	v = JsonValue.parse(Stdin.line!() ?? "") ?? Null
	Stdout.line!(v.to_str()) ?? {}
	Ok({})
}
