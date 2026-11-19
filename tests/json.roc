app [main!] { pkg: "../package/main.roc" }

import pkg.JsonValue

main! = |_args| Ok({})

## parse, then to_str
rt : Str -> Try(Str, [InvalidJson(Str)])
rt = |s| JsonValue.parse(s).map_ok(|v| v.to_str())

rejects : Str -> Bool
rejects = |s| JsonValue.parse(s).is_err()

num : Str -> JsonValue
num = |s| Number(s)

## Gives a tag literal the type JsonValue, so that its methods resolve.
jv : JsonValue -> JsonValue
jv = |v| v

# ── parse: values ────────────────────────────────────────────────────────────

expect JsonValue.parse("null") == Ok(Null)
expect JsonValue.parse("true") == Ok(Bool(Bool.True))
expect JsonValue.parse("false") == Ok(Bool(Bool.False))
expect JsonValue.parse("\"\"") == Ok(String(""))
expect JsonValue.parse("[]") == Ok(Array([]))
expect JsonValue.parse("{}") == Ok(Object([]))
expect JsonValue.parse(" \t\r\n[ 1 , {\n\"a\" :\tnull } ] \n") == Ok(Array([num("1"), Object([("a", Null)])]))
expect JsonValue.parse("{\"a\": [1, 2.5e3, -0, true, null, \"x\\ny\"]}") == Ok(Object([("a", Array([num("1"), num("2.5e3"), num("-0"), Bool(Bool.True), Null, String("x\ny")]))]))
expect JsonValue.parse("{\"b\":1,\"a\":2}") == Ok(Object([("b", num("1")), ("a", num("2"))]))
expect JsonValue.parse("[[[]],{}]") == Ok(Array([Array([Array([])]), Object([])]))

# ── parse: numbers keep their text ───────────────────────────────────────────

expect JsonValue.parse("-0") == Ok(num("-0"))
expect JsonValue.parse("0") == Ok(num("0"))
expect JsonValue.parse("1e400") == Ok(num("1e400"))
expect JsonValue.parse("-1.5E-3") == Ok(num("-1.5E-3"))
expect JsonValue.parse("1E+2") == Ok(num("1E+2"))
expect JsonValue.parse("0.1e-5") == Ok(num("0.1e-5"))
expect JsonValue.parse("10.000") == Ok(num("10.000"))
expect rt(" {\"id\": 12345678901234567890} ") == Ok("{\"id\":12345678901234567890}")
expect rt("123456789012345678901234567890.5e-3") == Ok("123456789012345678901234567890.5e-3")

# ── parse: strings and escapes ───────────────────────────────────────────────

expect JsonValue.parse("\"\\\"\\\\\\/\\b\\f\\n\\r\\t\"") == Ok(String("\"\\/\u(8)\u(C)\n\r\t"))
expect JsonValue.parse("\"\\u0041\\u00e9\\u00E9\\u4e2d\"") == Ok(String("Aéé中"))
expect JsonValue.parse("\"\\ud83d\\udc26 \\u00e9\"") == Ok(String("🐦 é"))
expect JsonValue.parse("\"\\uD83D\\uDC26\"") == Ok(String("🐦"))
expect JsonValue.parse("\"🐦 é / \u(2028)\"") == Ok(String("🐦 é / \u(2028)"))
expect JsonValue.parse("\"\\u0000\"") == Ok(String("\u(0)"))
# A lone surrogate becomes U+FFFD.
expect JsonValue.parse("\"\\ud83d x\"") == Ok(String("\u(FFFD) x"))
expect JsonValue.parse("\"\\ud83d\"") == Ok(String("\u(FFFD)"))
expect JsonValue.parse("\"\\udc26x\"") == Ok(String("\u(FFFD)x"))
expect JsonValue.parse("\"\\ud800\\u0041\"") == Ok(String("\u(FFFD)A"))
expect JsonValue.parse("\"\\ud800\\ud800\\udc00\"") == Ok(String("\u(FFFD)𐀀"))
expect JsonValue.parse("\"\\udfff\\ud800\"") == Ok(String("\u(FFFD)\u(FFFD)"))
expect JsonValue.parse("{\"\\u006b\":1}") == Ok(Object([("k", num("1"))]))

# ── parse: rejections ────────────────────────────────────────────────────────

expect rejects("")
expect rejects("   ")
expect rejects("nul")
expect rejects("nulll")
expect rejects("tru")
expect rejects("True")
expect rejects("NaN")
expect rejects("Infinity")
expect rejects("-Infinity")
expect rejects("undefined")
expect rejects("[1,]")
expect rejects("[,1]")
expect rejects("[1 2]")
expect rejects("[1,,2]")
expect rejects("[")
expect rejects("]")
expect rejects("[1")
expect rejects("{")
expect rejects("{,}")
expect rejects("{\"a\":1,}")
expect rejects("{\"a\" 1}")
expect rejects("{\"a\"}")
expect rejects("{\"a\":}")
expect rejects("{a:1}")
expect rejects("{'a':1}")
expect rejects("{1:1}")
expect rejects("{\"a\":1}}")
expect rejects("{\"a\":1")
expect rejects("1 2")
expect rejects("{\"a\":1} x")
expect rejects("01")
expect rejects("00")
expect rejects("-01")
expect rejects("1.")
expect rejects("1.e5")
expect rejects(".5")
expect rejects("+1")
expect rejects("-")
expect rejects("--1")
expect rejects("1e")
expect rejects("1e+")
expect rejects("1e-")
expect rejects("1E5.0")
expect rejects("0x10")
expect rejects("1_000")
expect rejects("'a'")
expect rejects("\"abc")
expect rejects("\"\\")
expect rejects("\"\\x\"")
expect rejects("\"\\U0041\"")
expect rejects("\"\\u12G4\"")
expect rejects("\"\\u123\"")
expect rejects("\"\\ud800\\u12\"")
expect rejects("\"a\tb\"")
expect rejects("\"a\nb\"")
expect rejects("\"\u(1F)\"")
# Not JSON whitespace: BOM, form feed, vertical tab, NBSP.
expect rejects("\u(FEFF)1")
expect rejects("\u(C)1")
expect rejects("\u(B)1")
expect rejects("\u(A0)1")
expect rejects("1\u(C)")

expect JsonValue.parse("[1,]") == Err(InvalidJson("unexpected character at byte 3"))
expect JsonValue.parse("{\"a\":1} x") == Err(InvalidJson("unexpected data after the value at byte 8"))

# ── parse: depth limit 256 ───────────────────────────────────────────────────

nested_arrays : U64 -> Str
nested_arrays = |n| "${"[".repeat(n)}${"]".repeat(n)}"

nested_objects : U64 -> Str
nested_objects = |n| "${"{\"a\":".repeat(n)}1${"}".repeat(n)}"

expect JsonValue.parse(nested_arrays(256)).is_ok()
expect rejects(nested_arrays(257))
expect rejects(nested_arrays(1000))
expect JsonValue.parse(nested_objects(256)).is_ok()
expect rejects(nested_objects(257))
expect JsonValue.parse("${"[".repeat(255)}{}${"]".repeat(255)}").is_ok()
expect rejects("${"[".repeat(256)}{}${"]".repeat(256)}")
expect rejects("${"[".repeat(256)}[1]${"]".repeat(256)}")
expect rt(nested_arrays(256)) == Ok(nested_arrays(256))
expect JsonValue.parse(nested_arrays(257)) == Err(InvalidJson("nesting deeper than 256 at byte 256"))

# ── to_str ───────────────────────────────────────────────────────────────────

expect JsonValue.to_str(String("a\"b\\c\u(1)\n")) == "\"a\\\"b\\\\c\\u0001\\n\""
expect JsonValue.to_str(String("\u(8)\u(C)\n\r\t")) == "\"\\b\\f\\n\\r\\t\""
expect JsonValue.to_str(String("\u(0)\u(1F)\u(B)\u(1B)")) == "\"\\u0000\\u001f\\u000b\\u001b\""
# Not escaped: `/`, DEL, non-ASCII, U+2028.
expect JsonValue.to_str(String("a/b\u(7F)é🐦\u(2028)")) == "\"a/b\u(7F)é🐦\u(2028)\""
expect JsonValue.to_str(Object([("k\"", Array([Null, Bool(Bool.False), num("1.50")]))])) == "{\"k\\\"\":[null,false,1.50]}"
expect JsonValue.to_str(Object([])) == "{}"
expect JsonValue.to_str(Array([])) == "[]"
expect JsonValue.to_str(Object([("a", num("1")), ("a", num("2"))])) == "{\"a\":1,\"a\":2}"
expect rt("{ \"z\" : 1 , \"a\" : [ true , \"x\" ] }") == Ok("{\"z\":1,\"a\":[true,\"x\"]}")
expect rt("\"\\u00e9\\/\"") == Ok("\"é/\"")
expect rt("\"\\u007f\\u001F\"") == Ok("\"\u(7F)\\u001f\"")
expect {
	text = "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"tools\":[{\"name\":\"t\",\"inputSchema\":{\"type\":\"object\",\"properties\":{}}}]}}"
	rt(text) == Ok(text)
}
# Every escape the parser accepts survives a round trip.
expect {
	all_controls = (0.U8..<32).iter().map(|b| b).collect()
	s = Str.from_utf8_lossy(all_controls)
	JsonValue.parse(JsonValue.to_str(String(s))) == Ok(String(s))
}

# ── get, get_or_null ─────────────────────────────────────────────────────────

doc : JsonValue
doc = Object([("n", num("3")), ("s", String("x")), ("b", Bool(Bool.True)), ("l", Array([Null])), ("o", Object([]))])

expect doc.get("n") == Ok(num("3"))
expect doc.get("missing") == Err(NotFound)
expect jv(String("x")).get("n") == Err(NotFound)
expect jv(Array([doc])).get("n") == Err(NotFound)
expect doc.get_or_null("s") == String("x")
expect doc.get_or_null("missing") == Null
expect jv(Null).get_or_null("x") == Null
# A repeated key: the last one wins, as in JSON.parse.
expect JsonValue.parse("{\"a\":1,\"a\":2}").map_ok(|v| v.get("a")) == Ok(Ok(num("2")))
expect JsonValue.parse("{\"a\":1,\"a\":2}").map_ok(|v| v.get_or_null("a")) == Ok(num("2"))

# ── as_* ─────────────────────────────────────────────────────────────────────

expect jv(String("x")).as_str() == Ok("x")
expect num("1").as_str() == Err(NotAString)
expect jv(Bool(Bool.False)).as_bool() == Ok(Bool.False)
expect jv(Null).as_bool() == Err(NotABool)
expect jv(Array([Null])).as_list() == Ok([Null])
expect jv(Object([])).as_list() == Err(NotAList)
expect doc.as_object().map_ok(|fs| fs.len()) == Ok(5)
expect jv(Array([])).as_object() == Err(NotAnObject)

# ── to_i64, to_u64, to_f64, to_dec ───────────────────────────────────────────

expect JsonValue.parse("{\"n\": 3}").map_ok(|v| v.get("n").map_ok(|n| n.to_i64())) == Ok(Ok(Ok(3)))
expect num("-42").to_i64() == Ok(-42)
expect num("3.0").to_i64() == Ok(3)
expect num("3e0").to_i64() == Ok(3)
expect num("30e-1").to_i64() == Ok(3)
expect num("1E3").to_i64() == Ok(1000)
expect num("-0").to_i64() == Ok(0)
expect num("0.000").to_i64() == Ok(0)
expect num("3.5").to_i64() == Err(NotANumber)
expect num("1e-1").to_i64() == Err(NotANumber)
expect num("9223372036854775807").to_i64() == Ok(9223372036854775807)
expect num("-9223372036854775808").to_i64() == Ok(-9223372036854775808)
expect num("9223372036854775808").to_i64() == Err(NotANumber)
expect num("1e400").to_i64() == Err(NotANumber)
expect num("abc").to_i64() == Err(NotANumber)
expect jv(String("3")).to_i64() == Err(NotANumber)
expect num("18446744073709551615").to_u64() == Ok(18446744073709551615)
expect num("18446744073709551616").to_u64() == Err(NotANumber)
expect num("1.8446744073709551615e19").to_u64() == Ok(18446744073709551615)
expect num("-1").to_u64() == Err(NotANumber)
expect num("-0").to_u64() == Ok(0)
expect jv(Null).to_u64() == Err(NotANumber)
expect num("2.5").to_f64().map_ok(|f| f == 2.5) == Ok(Bool.True)
expect num("-1e-3").to_f64().map_ok(|f| f == -0.001) == Ok(Bool.True)
expect num("1e400").to_f64() |> Try.is_err
expect jv(Bool(Bool.True)).to_f64() |> Try.is_err
expect JsonValue.parse("2.5").map_ok(|v| v.to_dec()) == Ok(Ok(2.5))
expect num("-0.125").to_dec() == Ok(-0.125)
expect num("1e3").to_dec() == Ok(1000.0)
expect num("1e400").to_dec() == Err(NotANumber)
expect jv(String("1")).to_dec() == Err(NotANumber)

# ── from_* ───────────────────────────────────────────────────────────────────

expect JsonValue.from_i64(-5) == num("-5")
expect JsonValue.from_i64(-9223372036854775808) == num("-9223372036854775808")
expect JsonValue.from_u64(18446744073709551615) == num("18446744073709551615")
expect JsonValue.from_dec(1.0) == num("1")
expect JsonValue.from_dec(0.0) == num("0")
expect JsonValue.from_dec(-0.0) == num("0")
expect JsonValue.from_dec(2.5) == num("2.5")
expect JsonValue.from_dec(-0.5) == num("-0.5")
expect JsonValue.from_dec(100.0) == num("100")
expect JsonValue.from_dec(0.000001) == num("0.000001")
expect JsonValue.from_dec(0.0000001) == num("1e-7")
expect JsonValue.from_dec(0.000000000000000001) == num("1e-18")
expect JsonValue.from_dec(-0.00000015) == num("-1.5e-7")
expect JsonValue.from_dec(170141183460469231731.0) == num("170141183460469231731")
expect JsonValue.from_dec(12345.678) == num("12345.678")

f64 : F64 -> Str
f64 = |f| match JsonValue.from_f64(f) {
	Ok(Number(s)) => s
	_ => "error"
}

expect f64(1.0) == "1"
expect f64(0.1) == "0.1"
expect f64(-2.5) == "-2.5"
expect f64(100.0) == "100"
expect f64(0.30000000000000004) == "0.30000000000000004"
expect f64(1.0e20) == "100000000000000000000"
expect f64(123456789012345680000.0) == "123456789012345680000"
expect f64(1.0e21) == "1e+21"
expect f64(1.5e300) == "1.5e+300"
expect f64(1.7976931348623157e308) == "1.7976931348623157e+308"
expect f64(0.000001) == "0.000001"
expect f64(0.0000012) == "0.0000012"
expect f64(1.0e-7) == "1e-7"
expect f64(-1.25e-10) == "-1.25e-10"
expect f64(5.0e-324) == "5e-324"
expect f64(0.0) == "0"
expect f64(-0.0) == "0"
expect f64(9007199254740993.0) == "9007199254740992"
expect JsonValue.from_f64(F64.nan) == Err(NotFinite)
expect JsonValue.from_f64(F64.infinity) == Err(NotFinite)
expect JsonValue.from_f64(-F64.infinity) == Err(NotFinite)

# ── equivalent and is_eq ─────────────────────────────────────────────────────

equiv : Str, Str -> Bool
equiv = |a, b| match (JsonValue.parse(a), JsonValue.parse(b)) {
	(Ok(x), Ok(y)) => x.equivalent(y)
	_ => Bool.False
}

expect equiv("{\"a\":1,\"b\":[true,null]}", "{\"b\":[true,null],\"a\":1}")
expect equiv("{\"o\":{\"x\":1,\"y\":2}}", "{\"o\":{\"y\":2,\"x\":1}}")
expect equiv("1", "1.0")
expect equiv("1", "10e-1")
expect equiv("100", "1E2")
expect equiv("-0", "0")
expect equiv("0.0", "-0e5")
expect equiv("1e400", "10e399")
expect equiv("12345678901234567890", "1.2345678901234567890e19")
expect equiv("\"x\"", "\"x\"")
expect equiv("[]", "[]")
expect equiv("{}", "{}")
expect equiv("{\"a\":1,\"a\":2}", "{\"a\":2}")
expect !equiv("12345678901234567890", "12345678901234567891")
expect !equiv("1", "-1")
expect !equiv("1", "\"1\"")
expect !equiv("null", "false")
expect !equiv("0", "false")
expect !equiv("[1,2]", "[2,1]")
expect !equiv("[1]", "[1,1]")
expect !equiv("{\"a\":1}", "{\"a\":1,\"b\":2}")
expect !equiv("{\"a\":1,\"b\":2}", "{\"a\":1}")
expect !equiv("{\"a\":1}", "{\"b\":1}")
expect !equiv("{\"a\":null}", "{}")
expect !equiv("{\"a\":1}", "[1]")
expect !equiv("\"a\"", "\"A\"")
expect jv(Number("x")).equivalent(Number("x"))
expect !jv(Number("x")).equivalent(Number("y"))
# is_eq is structural and order-sensitive.
expect JsonValue.parse("{\"a\":1,\"b\":2}") != JsonValue.parse("{\"b\":2,\"a\":1}")
expect num("1") != num("1.0")

# ── decode, decode_camel, encode ─────────────────────────────────────────────

CheckArgs : { code : Try(Str, [Missing]), path : Try(Str, [Missing]), scope ?: Str }

expect {
	v = JsonValue.parse("{\"code\":\"x = 1\",\"extra\":true}")?
	args : Try(CheckArgs, _)
	args = v.decode()
	match args {
		Ok(a) => a.code == Ok("x = 1") and a.path == Err(Missing) and a.?scope.is_err()
		Err(_) => Bool.False
	}
}

expect {
	v = JsonValue.parse("{\"path\":3}")?
	args : Try(CheckArgs, _)
	args = v.decode()
	args.is_err()
}

expect {
	v = JsonValue.parse("{\"mimeType\":\"text/plain\",\"size\":12}")?
	r : Try({ mime_type : Str, size : U64 }, _)
	r = v.decode_camel()
	r == Ok({ mime_type: "text/plain", size: 12 })
}

expect {
	v = JsonValue.parse("{\"a\":\"x\"}")?
	r : Try({ a : U64 }, _)
	r = v.decode()
	match r {
		Err(InvalidJson(_)) => Bool.True
		_ => Bool.False
	}
}

expect JsonValue.encode({ ok: Bool.True, exit_code: 0.I64 }).equivalent(Object([("ok", Bool(Bool.True)), ("exit_code", num("0"))]))
expect JsonValue.encode({ name: "a\"b", tags: ["x", "y"] }).equivalent(Object([("name", String("a\"b")), ("tags", Array([String("x"), String("y")]))]))
expect JsonValue.encode({ d: 1.0.Dec, h: 2.5.Dec }) == Object([("d", num("1")), ("h", num("2.5"))])
expect JsonValue.encode(12345678901234567890.U64) == num("12345678901234567890")
