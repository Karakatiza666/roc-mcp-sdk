## Spike: a dynamic JSON value with its own parser and serializer.
## Numbers keep their source text, so ids and big integers pass through exactly.
JsonValue := [
	Null,
	Bool(Bool),
	Number(Str),
	String(Str),
	Array(List(JsonValue)),
	Object(List((Str, JsonValue))),
].{
	is_eq : _

	parse : Str -> Try(JsonValue, [InvalidJson(Str)])
	parse = |text| {
		bytes = text.to_utf8()
		(value, end) = parse_value(bytes, skip_ws(bytes, 0), 0)?
		rest = skip_ws(bytes, end)
		if rest == bytes.len() Ok(value) else Err(InvalidJson("trailing data at byte ${rest.to_str()}"))
	}

	to_str : JsonValue -> Str
	to_str = |value| Str.from_utf8_lossy(write(List.with_capacity(256), value))

	get : JsonValue, Str -> Try(JsonValue, [NotFound])
	get = |value, key| match value {
		Object(fields) =>
			match fields.find_first(|(k, _)| k == key) {
				Ok((_, v)) => Ok(v)
				Err(_) => Err(NotFound)
			}
		_ => Err(NotFound)
	}

	as_str : JsonValue -> Try(Str, [NotAString])
	as_str = |value| match value {
		String(s) => Ok(s)
		_ => Err(NotAString)
	}

	get_or_null : JsonValue, Str -> JsonValue
	get_or_null = |value, key| match value {
		Object(fields) =>
			match fields.find_first(|(k, _)| k == key) {
				Ok((_, v)) => v
				Err(_) => Null
			}
		_ => Null
	}

	from_i64 : I64 -> JsonValue
	from_i64 = |n| Number(n.to_str())

	to_i64 : JsonValue -> Try(I64, [NotANumber])
	to_i64 = |value| match value {
		Number(s) => I64.from_str(s).map_err(|_| NotANumber)
		_ => Err(NotANumber)
	}

	to_f64 : JsonValue -> Try(F64, [NotANumber])
	to_f64 = |value| match value {
		Number(s) => F64.from_str(s).map_err(|_| NotANumber)
		_ => Err(NotANumber)
	}

	to_dec : JsonValue -> Try(Dec, [NotANumber])
	to_dec = |value| match value {
		Number(s) => Json.dec_from_json_number(s).map_err(|_| NotANumber)
		_ => Err(NotANumber)
	}
}

max_depth : U64
max_depth = 256

is_ws : U8 -> Bool
is_ws = |b| b == 0x20 or b == 0x0A or b == 0x0D or b == 0x09

skip_ws : List(U8), U64 -> U64
skip_ws = |bytes, start| {
	var $i = start
	while $i < bytes.len() and is_ws(bytes.get($i) ?? 0) {
		$i = $i + 1
	}
	$i
}

bad : Str, U64 -> [InvalidJson(Str)]
bad = |what, at| InvalidJson("${what} at byte ${at.to_str()}")

expect_lit : List(U8), U64, List(U8), JsonValue -> Try((JsonValue, U64), [InvalidJson(Str)])
expect_lit = |bytes, at, lit, value|
	if bytes.sublist({ start: at, len: lit.len() }) == lit Ok((value, at + lit.len())) else Err(bad("bad literal", at))

parse_value : List(U8), U64, U64 -> Try((JsonValue, U64), [InvalidJson(Str)])
parse_value = |bytes, at, depth| {
	if depth > max_depth {
		return Err(bad("nesting too deep", at))
	}
	match bytes.get(at) {
		Err(_) => Err(bad("unexpected end", at))
		Ok(b) =>
			if b == '{' {
				parse_object(bytes, at + 1, depth + 1)
			} else if b == '[' {
				parse_array(bytes, at + 1, depth + 1)
			} else if b == '"' {
				(s, end) = parse_string(bytes, at + 1)?
				Ok((String(s), end))
			} else if b == 't' {
				expect_lit(bytes, at, "true".to_utf8(), Bool(Bool.True))
			} else if b == 'f' {
				expect_lit(bytes, at, "false".to_utf8(), Bool(Bool.False))
			} else if b == 'n' {
				expect_lit(bytes, at, "null".to_utf8(), Null)
			} else {
				parse_number(bytes, at)
			}
	}
}

parse_array : List(U8), U64, U64 -> Try((JsonValue, U64), [InvalidJson(Str)])
parse_array = |bytes, start, depth| {
	var $items = []
	var $i = skip_ws(bytes, start)
	if bytes.get($i) == Ok(']') {
		return Ok((Array([]), $i + 1))
	}
	while Bool.True {
		(v, after) = parse_value(bytes, skip_ws(bytes, $i), depth)?
		$items = $items.append(v)
		$i = skip_ws(bytes, after)
		match bytes.get($i) {
			Ok(b) if b == ',' => {
				$i = $i + 1
			}
			Ok(b) if b == ']' => return Ok((Array($items), $i + 1))
			_ => return Err(bad("expected , or ]", $i))
		}
	}
}

parse_object : List(U8), U64, U64 -> Try((JsonValue, U64), [InvalidJson(Str)])
parse_object = |bytes, start, depth| {
	var $fields = []
	var $i = skip_ws(bytes, start)
	if bytes.get($i) == Ok('}') {
		return Ok((Object([]), $i + 1))
	}
	while Bool.True {
		if bytes.get($i) != Ok('"') {
			return Err(bad("expected string key", $i))
		}
		(key, after_key) = parse_string(bytes, $i + 1)?
		colon = skip_ws(bytes, after_key)
		if bytes.get(colon) != Ok(':') {
			return Err(bad("expected :", colon))
		}
		(v, after) = parse_value(bytes, skip_ws(bytes, colon + 1), depth)?
		$fields = $fields.append((key, v))
		$i = skip_ws(bytes, after)
		match bytes.get($i) {
			Ok(b) if b == ',' => {
				$i = skip_ws(bytes, $i + 1)
			}
			Ok(b) if b == '}' => return Ok((Object($fields), $i + 1))
			_ => return Err(bad("expected , or }", $i))
		}
	}
}

hex_val : U8 -> Try(U32, [NotHex])
hex_val = |b|
	if b >= '0' and b <= '9' {
		Ok((b - '0').to_u32())
	} else if b >= 'a' and b <= 'f' {
		Ok((b - 'a' + 10).to_u32())
	} else if b >= 'A' and b <= 'F' {
		Ok((b - 'A' + 10).to_u32())
	} else {
		Err(NotHex)
	}

read_hex4 : List(U8), U64 -> Try(U32, [InvalidJson(Str)])
read_hex4 = |bytes, at| {
	var $n = 0.U32
	for k in [0.U64, 1, 2, 3] {
		b = bytes.get(at + k) ?? 0
		d = hex_val(b).map_err(|_| bad("bad \\u escape", at))?
		$n = $n * 16 + d
	}
	Ok($n)
}

append_utf8 : List(U8), U32 -> List(U8)
append_utf8 = |out, cp|
	if cp < 0x80 {
		out.append(cp.to_u8_wrap())
	} else if cp < 0x800 {
		out.append((0xC0 + (cp // 64)).to_u8_wrap()).append((0x80 + (cp % 64)).to_u8_wrap())
	} else if cp < 0x10000 {
		out
			.append((0xE0 + (cp // 4096)).to_u8_wrap())
			.append((0x80 + ((cp // 64) % 64)).to_u8_wrap())
			.append((0x80 + (cp % 64)).to_u8_wrap())
	} else {
		out
			.append((0xF0 + (cp // 262144)).to_u8_wrap())
			.append((0x80 + ((cp // 4096) % 64)).to_u8_wrap())
			.append((0x80 + ((cp // 64) % 64)).to_u8_wrap())
			.append((0x80 + (cp % 64)).to_u8_wrap())
	}

## Parses a string body starting after the opening quote. Returns the end after the closing quote.
parse_string : List(U8), U64 -> Try((Str, U64), [InvalidJson(Str)])
parse_string = |bytes, start| {
	var $out = []
	var $run = start
	var $i = start
	while $i < bytes.len() {
		b = bytes.get($i) ?? 0
		if b == '"' {
			out = $out.concat(bytes.sublist({ start: $run, len: $i - $run }))
			return Ok((Str.from_utf8_lossy(out), $i + 1))
		} else if b == '\\' {
			$out = $out.concat(bytes.sublist({ start: $run, len: $i - $run }))
			e = bytes.get($i + 1) ?? 0
			if e == 'u' {
				hi = read_hex4(bytes, $i + 2)?
				if hi >= 0xD800 and hi < 0xDC00 and bytes.get($i + 6) == Ok('\\') and bytes.get($i + 7) == Ok('u') {
					lo = read_hex4(bytes, $i + 8)?
					if lo >= 0xDC00 and lo < 0xE000 {
						$out = append_utf8($out, 0x10000 + (hi - 0xD800) * 1024 + (lo - 0xDC00))
						$i = $i + 12
					} else {
						$out = append_utf8($out, 0xFFFD)
						$i = $i + 6
					}
				} else if hi >= 0xD800 and hi < 0xE000 {
					$out = append_utf8($out, 0xFFFD)
					$i = $i + 6
				} else {
					$out = append_utf8($out, hi)
					$i = $i + 6
				}
			} else {
				c =
					if e == '"' Ok('"')
					else if e == '\\' Ok('\\')
					else if e == '/' Ok('/')
					else if e == 'b' Ok(0x08)
					else if e == 'f' Ok(0x0C)
					else if e == 'n' Ok(0x0A)
					else if e == 'r' Ok(0x0D)
					else if e == 't' Ok(0x09)
					else Err(bad("bad escape", $i))
				$out = $out.append(c?)
				$i = $i + 2
			}
			$run = $i
		} else if b < 0x20 {
			return Err(bad("control character in string", $i))
		} else {
			$i = $i + 1
		}
	}
	Err(bad("unterminated string", start))
}

is_digit : U8 -> Bool
is_digit = |b| b >= '0' and b <= '9'

digits_from : List(U8), U64 -> U64
digits_from = |bytes, start| {
	var $i = start
	while is_digit(bytes.get($i) ?? 0) {
		$i = $i + 1
	}
	$i
}

parse_number : List(U8), U64 -> Try((JsonValue, U64), [InvalidJson(Str)])
parse_number = |bytes, start| {
	var $i = start
	if bytes.get($i) == Ok('-') {
		$i = $i + 1
	}
	if bytes.get($i) == Ok('0') {
		$i = $i + 1
	} else {
		after = digits_from(bytes, $i)
		if after == $i {
			return Err(bad("unexpected character", start))
		}
		$i = after
	}
	if bytes.get($i) == Ok('.') {
		after = digits_from(bytes, $i + 1)
		if after == $i + 1 {
			return Err(bad("bad fraction", $i))
		}
		$i = after
	}
	e = bytes.get($i) ?? 0
	if e == 'e' or e == 'E' {
		$i = $i + 1
		s = bytes.get($i) ?? 0
		if s == '+' or s == '-' {
			$i = $i + 1
		}
		after = digits_from(bytes, $i)
		if after == $i {
			return Err(bad("bad exponent", $i))
		}
		$i = after
	}
	Ok((Number(Str.from_utf8_lossy(bytes.sublist({ start, len: $i - start }))), $i))
}

write : List(U8), JsonValue -> List(U8)
write = |out, value| match value {
	Null => out.concat("null".to_utf8())
	Bool(b) => out.concat((if b "true" else "false").to_utf8())
	Number(s) => out.concat(s.to_utf8())
	String(s) => write_string(out, s)
	Array(items) => {
		var $o = out.append('[')
		var $first = Bool.True
		for item in items {
			if !$first {
				$o = $o.append(',')
			}
			$first = Bool.False
			$o = write($o, item)
		}
		$o.append(']')
	}
	Object(fields) => {
		var $o = out.append('{')
		var $first = Bool.True
		for (k, v) in fields {
			if !$first {
				$o = $o.append(',')
			}
			$first = Bool.False
			$o = write(write_string($o, k).append(':'), v)
		}
		$o.append('}')
	}
}

hex_digit : U8 -> U8
hex_digit = |n| if n < 10 '0' + n else 'a' + n - 10

write_string : List(U8), Str -> List(U8)
write_string = |out, s| {
	var $o = out.append('"')
	for b in s.to_utf8() {
		$o =
			if b == '"' {
				$o.append('\\').append('"')
			} else if b == '\\' {
				$o.append('\\').append('\\')
			} else if b == 0x0A {
				$o.append('\\').append('n')
			} else if b == 0x0D {
				$o.append('\\').append('r')
			} else if b == 0x09 {
				$o.append('\\').append('t')
			} else if b < 0x20 {
				$o.concat("\\u00".to_utf8()).append(hex_digit(b // 16)).append(hex_digit(b % 16))
			} else {
				$o.append(b)
			}
	}
	$o.append('"')
}

expect JsonValue.parse("{\"a\": [1, 2.5e3, -0, true, null, \"x\\ny\"]}") == Ok(Object([("a", Array([Number("1"), Number("2.5e3"), Number("-0"), Bool(Bool.True), Null, String("x\ny")]))]))
expect JsonValue.parse("\"\\ud83d\\udc26 \\u00e9\"") == Ok(String("🐦 é"))
expect JsonValue.parse("\"\\ud83d x\"") == Ok(String("\u(FFFD) x"))
expect JsonValue.parse("[1,]").is_err()
expect JsonValue.parse("01").is_err()
expect JsonValue.parse("{\"a\":1} x").is_err()
expect JsonValue.parse(" {\"id\": 12345678901234567890} ").map_ok(|v| v.to_str()) == Ok("{\"id\":12345678901234567890}")
expect JsonValue.to_str(String("a\"b\\c\u(1)\n")) == "\"a\\\"b\\\\c\\u0001\\n\""
expect JsonValue.parse("{\"n\": 3}").map_ok(|v| v.get("n").map_ok(|n| n.to_i64())) == Ok(Ok(Ok(3)))
expect JsonValue.parse("2.5").map_ok(|v| v.to_dec()) == Ok(Ok(2.5))
