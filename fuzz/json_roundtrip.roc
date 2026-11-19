app [target] {
	fuzz: platform "https://github.com/lukewilliamboswell/roc-fuzz/releases/download/0.6.2/3kyiehxxzwAsjM23uCQGJ3Hx7dAAdzSGtK3k9Jq7Egtu.tar.zst",
	pkg: "../package/main.roc",
}

import fuzz.Fuzz
import pkg.JsonValue

# L1 (DESIGN 9): JsonValue.parse never crashes, and a value it accepts is stable:
# parse(to_str(v)) == v, and to_str of that is the same text. Any string survives
# to_str then parse. The inputs are arbitrary text and texts made from JSON tokens
# (valid and broken ones), so that most of them reach deep into the parser.

## JSON pieces: structure, escapes, surrogates, numbers at the edges, and some broken ones.
pieces : List(Str)
pieces = [
	"{",
	"}",
	"[",
	"]",
	",",
	":",
	"\"k\"",
	"\"a\\\"b\\\\\"",
	"\"\\u00e9\\u0000\"",
	"\"\\ud83d\\udc26\"",
	"\"\\ud800\"",
	"\"\\udc00\\ud800x\"",
	"\"\\n\\t\\/\\b\\f\\r\"",
	"\"é🐦\u(2028)\"",
	"0",
	"-0",
	"12345678901234567890",
	"1.5e3",
	"-2E-7",
	"1e400",
	"0.000",
	"true",
	"false",
	"null",
	" ",
	"\n",
	"01",
	"1.",
	"\\",
	"\"",
	"\u(1)",
	"x",
	"\"\\u12",
	"[[[[",
]

## A record type, so that the platform derives its encoding (roc-fuzz 0.6.2 needs it for examples).
Input : { tokens : List(U8), text : Str }

input : Fuzz.Generator(Input)
input = {
	tokens: Fuzz.list(Fuzz.u8_in(0, 33), 64),
	text: Fuzz.str,
}.Fuzz

text_of : List(U8) -> Str
text_of = |tokens| Str.join_with(tokens.map(|t| pieces.get(t.to_u64()) ?? " "), "")

## parse never crashes; when it accepts the text, the value is stable.
stable : Str -> Bool
stable = |text| match JsonValue.parse(text) {
	Ok(v) => {
		out = v.to_str()
		JsonValue.parse(out) == Ok(v) and JsonValue.parse(out).map_ok(|w| w.to_str()) == Ok(out) and v.equivalent(v)
	}
	Err(_) => Bool.True
}

test : Input -> Fuzz.Outcome
test = |i| {
	tokens_text = text_of(i.tokens)
	if !stable(tokens_text) {
		crash "not stable: ${tokens_text}"
	}
	if !stable(i.text) {
		crash "not stable: ${i.text}"
	}
	if JsonValue.parse(JsonValue.to_str(String(i.text))) != Ok(String(i.text)) {
		crash "string round trip failed: ${i.text}"
	}
	Fuzz.keep
}

target = Fuzz.target_with({
	name: "json-roundtrip",
	examples: [],
	generator: input,
	test,
	show: |i| "${text_of(i.tokens)} | ${i.text}",
})
