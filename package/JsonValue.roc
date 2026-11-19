## A JSON value, with its own parser and serializer.
##
## A number keeps its source text (`Number("12345678901234567890")`), so ids and
## big integers pass through unchanged, and `1e400` stays `1e400`. An object is
## an ordered list of pairs: `to_str` writes the keys in that order.
##
## Build values with the tags where a `JsonValue` is expected:
## `Object([("type", String("object"))])`.
JsonValue := [
	Null,
	Bool(Bool),
	Number(Str),
	String(Str),
	Array(List(JsonValue)),
	Object(List((Str, JsonValue))),
].{

	## Structural and order-sensitive: `{"a":1,"b":2}` is not `{"b":2,"a":1}`, and `1` is not `1.0`.
	## Use `equivalent` to compare by meaning.
	is_eq : _

	## Parses one JSON text (RFC 8259), with whitespace around it.
	## Nesting deeper than 256 arrays or objects is rejected. An escaped lone
	## surrogate (`"\ud800"`) becomes U+FFFD.
	parse : Str -> Try(JsonValue, [InvalidJson(Str)])
	parse = |text| {
		bytes = text.to_utf8()
		(parsed, end) = parse_value(bytes, skip_ws(bytes, 0), 0)?
		rest = skip_ws(bytes, end)
		if (rest == bytes.len()) Ok(parsed) else Err(bad("unexpected data after the value", rest))
	}

	## Compact JSON text, with the escapes of JavaScript's `JSON.stringify`:
	## `"`, `\` and the control characters. `/` and non-ASCII text are written as they are.
	## A number is written as its text.
	to_str : JsonValue -> Str
	to_str = |v| Str.from_utf8_lossy(write(List.with_capacity(256), v))

	## The value of a key of an object. With a repeated key the last one wins, as in `JSON.parse`.
	get : JsonValue, Str -> Try(JsonValue, [NotFound])
	get = |v, key| match v {
		Object(fields) =>
			match fields.find_last(|(k, _)| k == key) {
				Ok((_, found)) => Ok(found)
				Err(_) => Err(NotFound)
			}
		_ => Err(NotFound)
	}

	## Like `get`, but `Null` when the key is missing or the value is not an object.
	get_or_null : JsonValue, Str -> JsonValue
	get_or_null = |v, key| match v {
		Object(fields) =>
			match fields.find_last(|(k, _)| k == key) {
				Ok((_, found)) => found
				Err(_) => Null
			}
		_ => Null
	}

	as_str : JsonValue -> Try(Str, [NotAString])
	as_str = |v| match v {
		String(s) => Ok(s)
		_ => Err(NotAString)
	}

	as_bool : JsonValue -> Try(Bool, [NotABool])
	as_bool = |v| match v {
		Bool(b) => Ok(b)
		_ => Err(NotABool)
	}

	as_list : JsonValue -> Try(List(JsonValue), [NotAList])
	as_list = |v| match v {
		Array(items) => Ok(items)
		_ => Err(NotAList)
	}

	as_object : JsonValue -> Try(List((Str, JsonValue)), [NotAnObject])
	as_object = |v| match v {
		Object(fields) => Ok(fields)
		_ => Err(NotAnObject)
	}

	## An integer that fits in I64. `3`, `3.0`, `3e0` and `30e-1` all give 3; `3.5` is an error.
	to_i64 : JsonValue -> Try(I64, [NotANumber])
	to_i64 = |v| match v {
		Number(s) => {
			text = integer_text(s)?
			I64.from_str(text).map_err(|_| NotANumber)
		}
		_ => Err(NotANumber)
	}

	## An integer that fits in U64, written in any form (see `to_i64`).
	to_u64 : JsonValue -> Try(U64, [NotANumber])
	to_u64 = |v| match v {
		Number(s) => {
			text = integer_text(s)?
			U64.from_str(text).map_err(|_| NotANumber)
		}
		_ => Err(NotANumber)
	}

	## The nearest F64. A number outside the F64 range (`1e400`) is an error.
	to_f64 : JsonValue -> Try(F64, [NotANumber])
	to_f64 = |v| match v {
		Number(s) => F64.from_str(s).map_err(|_| NotANumber)
		_ => Err(NotANumber)
	}

	to_dec : JsonValue -> Try(Dec, [NotANumber])
	to_dec = |v| match v {
		Number(s) => Json.dec_from_json_number(s).map_err(|_| NotANumber)
		_ => Err(NotANumber)
	}

	from_i64 : I64 -> JsonValue
	from_i64 = |n| Number(n.to_str())

	from_u64 : U64 -> JsonValue
	from_u64 = |n| Number(n.to_str())

	## The text JavaScript prints for the same number: `1` (not `1.0`), `2.5`, `1e-7`.
	from_dec : Dec -> JsonValue
	from_dec = |d| Number(canonical_number(d.to_str()))

	## The shortest text that reads back as the same F64, in JavaScript's form
	## (`1`, `0.1`, `1e+21`, `5e-324`). `-0` is written `0`, as `JSON.stringify` does.
	from_f64 : F64 -> Try(JsonValue, [NotFinite])
	from_f64 = |f|
		if F64.is_finite(f) {
			Ok(Number(canonical_number(f.to_str())))
		} else {
			Err(NotFinite)
		}

	## Equal in meaning: object keys in any order (with a repeated key, the last
	## one counts), numbers by exact decimal value (`1`, `1.0`, `10e-1`; `-0` and `0`).
	equivalent : JsonValue, JsonValue -> Bool
	equivalent = |a, b| match (a, b) {
		(Null, Null) => Bool.True
		(Bool(x), Bool(y)) => x == y
		(Number(x), Number(y)) =>
			match (decimal_of(x), decimal_of(y)) {
				(Ok(dx), Ok(dy)) => dx == dy
				_ => x == y
			}
		(String(x), String(y)) => x == y
		(Array(xs), Array(ys)) => xs.len() == ys.len() and xs.map2(ys, |x, y| equivalent(x, y)).all(|t| t)
		(Object(xs), Object(ys)) => {
			kx = Set.from_list(xs.map(|(k, _)| k))
			ky = Set.from_list(ys.map(|(k, _)| k))
			kx == ky and kx.to_list().all(|k| equivalent(get_or_null(a, k), get_or_null(b, k)))
		}
		_ => Bool.False
	}

	## Decodes into a Roc type through `Encoding.Json`, with the field names as they are.
	decode : JsonValue -> Try(a, [InvalidJson(Str)])
		where [a.Json.Parseable(_)]
	decode = |v| Json.parse(v.to_str()).map_err(|e| InvalidJson(Str.inspect(e)))

	## Like `decode`, with the camelCase dialect: the field `mime_type` reads the key `mimeType`.
	decode_camel : JsonValue -> Try(a, [InvalidJson(Str)])
		where [a.Json.Parseable(_)]
	decode_camel = |v| {
		parser = Json.parser_camel()
		parser(v.to_str()).map_err(|e| InvalidJson(Str.inspect(e)))
	}

	## Encodes a Roc value through `Encoding.Json`. Numbers are written as JavaScript
	## prints them (`1.0.Dec` becomes `1`).
	encode : a -> JsonValue where [a.Json.Encodable([])]
	encode = |item| match parse(Json.to_str(item)) {
		Ok(parsed) => canonical_numbers(parsed)
		Err(_) => crash "JsonValue.encode: Encoding.Json produced invalid JSON"
	}
}

max_depth : U64
max_depth = 256

## A finite decimal number: 0.d1d2d3... × 10^point. `digits` are ASCII and have
## no leading or trailing zero. Zero has no digits and is never negative.
Decimal : { neg : Bool, digits : List(U8), point : I64 }

## Exponents beyond this are clamped, which keeps the arithmetic in I64.
exponent_cap : I64
exponent_cap = 1_000_000_000_000_000

## Reads number text (JSON grammar, also accepting a leading `+`-less integer such
## as `Dec.to_str` and `F64.to_str` write) into a Decimal.
decimal_of : Str -> Try(Decimal, [BadNumber])
decimal_of = |text| {
	bytes = text.to_utf8()
	var $i = 0
	neg = bytes.get(0) == Ok('-')
	if neg {
		$i = 1
	}
	int_start = $i
	$i = digits_from(bytes, $i)
	int_len = $i - int_start
	var $mant = bytes.sublist({ start: int_start, len: int_len })
	if bytes.get($i) == Ok('.') {
		frac_end = digits_from(bytes, $i + 1)
		if frac_end == $i + 1 {
			return Err(BadNumber)
		}
		$mant = $mant.concat(bytes.sublist({ start: $i + 1, len: frac_end - $i - 1 }))
		$i = frac_end
	}
	if $mant.is_empty() {
		return Err(BadNumber)
	}
	var $exp = 0.I64
	e = bytes.get($i) ?? 0
	if e == 'e' or e == 'E' {
		$i = $i + 1
		s = bytes.get($i) ?? 0
		exp_neg = s == '-'
		if s == '+' or s == '-' {
			$i = $i + 1
		}
		exp_start = $i
		while is_digit(bytes.get($i) ?? 0) {
			d = ((bytes.get($i) ?? '0') - '0').to_i64()
			if $exp < exponent_cap {
				$exp = $exp * 10 + d
			}
			$i = $i + 1
		}
		if $i == exp_start {
			return Err(BadNumber)
		}
		if exp_neg {
			$exp = -$exp
		}
	}
	if $i != bytes.len() {
		return Err(BadNumber)
	}
	lead = count_while($mant, |b| b == '0')
	if lead == $mant.len() {
		return Ok({ neg: Bool.False, digits: [], point: 0 })
	}
	trail = count_while($mant.rev(), |b| b == '0')
	digits = $mant.sublist({ start: lead, len: $mant.len() - lead - trail })
	Ok({ neg, digits, point: int_len.to_i64_wrap() - lead.to_i64_wrap() + $exp })
}

count_while : List(U8), (U8 -> Bool) -> U64
count_while = |bytes, pred| {
	var $n = 0
	while $n < bytes.len() and pred(bytes.get($n) ?? 0) {
		$n = $n + 1
	}
	$n
}

zeros : I64 -> Str
zeros = |n| "0".repeat(n.to_u64_try() ?? 0)

## Number text in the form of JavaScript's Number::toString (ECMA-262 Number::toString, radix 10).
js_text : Decimal -> Str
js_text = |d| {
	digits = Str.from_utf8_lossy(d.digits)
	k = d.digits.len().to_i64_wrap()
	n = d.point
	sign = if (d.neg) "-" else ""
	if k == 0 {
		"0"
	} else if k <= n and n <= 21 {
		"${sign}${digits}${zeros(n - k)}"
	} else if 0 < n and n <= 21 {
		at = n.to_u64_try() ?? 0
		int_part = Str.from_utf8_lossy(d.digits.take_first(at))
		frac_part = Str.from_utf8_lossy(d.digits.drop_first(at))
		"${sign}${int_part}.${frac_part}"
	} else if -6 < n and n <= 0 {
		"${sign}0.${zeros(-n)}${digits}"
	} else {
		first = Str.from_utf8_lossy(d.digits.take_first(1))
		rest = Str.from_utf8_lossy(d.digits.drop_first(1))
		mantissa = if (k == 1) first else "${first}.${rest}"
		e = n - 1
		exp_part = if (e >= 0) "e+${e.to_str()}" else "e${e.to_str()}"
		"${sign}${mantissa}${exp_part}"
	}
}

## The JavaScript text of number text, or the text unchanged when it is not a number.
canonical_number : Str -> Str
canonical_number = |text| match decimal_of(text) {
	Ok(d) => js_text(d)
	Err(_) => text
}

canonical_numbers : JsonValue -> JsonValue
canonical_numbers = |v| match v {
	Number(s) => Number(canonical_number(s))
	Array(items) => Array(items.map(canonical_numbers))
	Object(fields) => Object(fields.map(|(k, x)| (k, canonical_numbers(x))))
	_ => v
}

## The plain integer text of a number (`-12`, `300`), or an error when it has a fraction.
integer_text : Str -> Try(Str, [NotANumber])
integer_text = |text| {
	d = decimal_of(text).map_err(|_| NotANumber)?
	k = d.digits.len().to_i64_wrap()
	if k == 0 {
		Ok("0")
	} else if d.point < k or d.point > 40 {
		Err(NotANumber)
	} else {
		sign = if (d.neg) "-" else ""
		Ok("${sign}${Str.from_utf8_lossy(d.digits)}${zeros(d.point - k)}")
	}
}

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
expect_lit = |bytes, at, lit, v|
	if (bytes.sublist({ start: at, len: lit.len() }) == lit) Ok((v, at + lit.len())) else Err(bad("bad literal", at))

## `depth` is the number of arrays and objects that enclose this value.
parse_value : List(U8), U64, U64 -> Try((JsonValue, U64), [InvalidJson(Str)])
parse_value = |bytes, at, depth| {
	match bytes.get(at) {
		Err(_) => Err(bad("unexpected end", at))
		Ok(b) =>
			if b == '{' or b == '[' {
				if depth >= max_depth {
					Err(bad("nesting deeper than 256", at))
				} else if b == '{' {
					parse_object(bytes, at + 1, depth + 1)
				} else {
					parse_array(bytes, at + 1, depth + 1)
				}
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
		(item, after) = parse_value(bytes, skip_ws(bytes, $i), depth)?
		$items = $items.append(item)
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
		(item, after) = parse_value(bytes, skip_ws(bytes, colon + 1), depth)?
		$fields = $fields.append((key, item))
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
					if (e == '"') Ok('"')
					else if (e == '\\') Ok('\\')
					else if (e == '/') Ok('/')
					else if (e == 'b') Ok(0x08)
					else if (e == 'f') Ok(0x0C)
					else if (e == 'n') Ok(0x0A)
					else if (e == 'r') Ok(0x0D)
					else if (e == 't') Ok(0x09)
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

## The number grammar of RFC 8259: `-? (0 | [1-9][0-9]*) (. [0-9]+)? ([eE] [+-]? [0-9]+)?`
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
write = |out, v| match v {
	Null => out.concat("null".to_utf8())
	Bool(b) => out.concat((if (b) "true" else "false").to_utf8())
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
		for (k, x) in fields {
			if !$first {
				$o = $o.append(',')
			}
			$first = Bool.False
			$o = write(write_string($o, k).append(':'), x)
		}
		$o.append('}')
	}
}

hex_digit : U8 -> U8
hex_digit = |n| if (n < 10) '0' + n else 'a' + n - 10

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
			} else if b == 0x08 {
				$o.append('\\').append('b')
			} else if b == 0x0C {
				$o.append('\\').append('f')
			} else if b < 0x20 {
				$o.concat("\\u00".to_utf8()).append(hex_digit(b // 16)).append(hex_digit(b % 16))
			} else {
				$o.append(b)
			}
	}
	$o.append('"')
}
