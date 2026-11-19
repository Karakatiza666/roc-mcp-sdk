app [main!] { pf: platform "https://github.com/roc-lang/basic-cli/releases/download/0.28.1/7brgwR8YUqfeGrkdfF1V4GPPN7DnP7ftqub9KcrTEZtr.tar.zst", pkg: "pkg/main.roc" }

import pf.Stdout
import pf.Monotonic
import pkg.JsonValue

item : U64 -> JsonValue
item = |n| Object([
	("id", JsonValue.from_i64(n.to_i64_wrap())),
	("name", String("item \"${n.to_str()}\" é 🐦\n")),
	("score", Number("1.25e2")),
	("tags", Array([String("a"), String("b"), Bool(Bool.True), Null])),
])

main! = |_args| {
	items : List(JsonValue)
	items = (0.U64..<20000).iter().map(item).collect()
	doc : JsonValue
	doc = Array(items)
	t0 = Monotonic.now!()
	text = doc.to_str()
	t1 = Monotonic.now!()
	parsed = JsonValue.parse(text)
	t2 = Monotonic.now!()
	ok = parsed == Ok(doc)
	Stdout.line!("bytes=${text.count_utf8_bytes().to_str()} encode_ms=${t1.since(t0).to_millis().to_str()} parse_ms=${t2.since(t1).to_millis().to_str()} roundtrip=${Str.inspect(ok)}")?
	Ok({})
}
