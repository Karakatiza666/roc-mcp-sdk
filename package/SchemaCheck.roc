import JsonValue

## Validates a JSON value against a JSON Schema, with the messages zod 4 gives for the zod schema
## that emits that JSON Schema (the JS SDK validates tool arguments with zod). The engine runs it
## on tools/call arguments and prompts/get arguments; apps can run it on their own values.
##
## The keywords checked are the subset `Schema` writes and zod emits: `type` (string, number,
## integer, boolean, null, object, array), `properties`, `required`, `additionalProperties`,
## `items`, `enum`, `const`, `anyOf`, `default`, `minLength`/`maxLength` (UTF-16 code units, as
## JS counts), `minimum`/`maximum`/`exclusiveMinimum`/`exclusiveMaximum`, `minItems`/`maxItems`.
## Not checked (accepted): `pattern`, `format`, `allOf`, `oneOf`, `not`, `$ref`, `multipleOf`
## and anything else.
##
## The zod rules this reproduces:
## - an `integer` is zod's `int()`: a number that is not an integer is "expected int" (and no
##   enclosing array then reports its size, as in zod), the
##   safe-integer range is checked as "expected int to be ..." (the bounds zod writes,
##   ±9007199254740991, are that check, not a separate one), other bounds as "expected number to be ...";
## - `{anyOf: [X, {type: "null"}]}` is zod's `nullable()`: `null` passes, anything else gets X's
##   messages; any other `anyOf` is a union: the first alternative that passes wins; when none
##   does and exactly one failed only on size or range checks, its messages are given, else "Invalid input";
## - an object keeps only its `properties` (zod strips unknown keys) unless `additionalProperties`
##   is set: `false` reports "Unrecognized key(s)", a schema checks the extra values, `{}` or `true` keeps them;
## - a missing property that has a `default` gets it; a missing required property is checked as
##   `undefined` (for a schema without `type`, "expected nonoptional").
SchemaCheck :: [].{

	## `Ok` with the parsed value (unknown keys dropped, defaults filled in, as zod returns it),
	## or the issues as the JS SDK prints them: `<path joined by ".">: <message>` (no prefix for
	## the root), in zod's order. The JS SDK joins them with ", ".
	validate : JsonValue, JsonValue -> Try(JsonValue, [Invalid(List(Str))])
	validate = |schema, value| {
		r = walk(schema, Ok(value), [])
		if r.issues.is_empty() {
			Ok(r.value ?? value)
		} else {
			Err(Invalid(r.issues.map(format_issue)))
		}
	}

	## How zod names the type of a value in "received ...": `undefined` for a missing one.
	type_name : Try(JsonValue, [Absent]) -> Str
	type_name = |v| match v {
		Err(Absent) => "undefined"
		Ok(Null) => "null"
		Ok(Bool(_)) => "boolean"
		Ok(Number(_)) => "number"
		Ok(String(_)) => "string"
		Ok(Array(_)) => "array"
		Ok(Object(_)) => "object"
	}

	## A JSON number's text as JavaScript's `String(n)` writes it (`1e+21`, `5.5e-7`, `0.1`),
	## assuming the text has at most 17 significant digits.
	js_number : Str -> Str
	js_number = |text| {
		b = text.to_utf8()
		negative = b.first() == Ok('-')
		unsigned = if (negative) b.drop_first(1) else b
		(mantissa, exp_part) = match unsigned.find_first_index(|c| c == 'e' or c == 'E') {
			Ok(i) => (unsigned.take_first(i), unsigned.drop_first(i + 1))
			Err(_) => (unsigned, [])
		}
		exp_sign = exp_part.first() ?? '0'
		exp_value =
			if exp_sign == '-' {
				0 - digits_value(exp_part.drop_first(1))
			} else {
				digits_value(exp_part)
			}
		(int_part, frac_part) = match mantissa.find_first_index(|c| c == '.') {
			Ok(i) => (mantissa.take_first(i), mantissa.drop_first(i + 1))
			Err(_) => (mantissa, [])
		}
		all = drop_leading_zeros(int_part.concat(frac_part))
		trailing = count_trailing_zeros(all)
		digits = all.take_first(all.len() - trailing)
		k = digits.len().to_i64_wrap()
		if k == 0 {
			"0"
		} else {
			power = exp_value - frac_part.len().to_i64_wrap() + trailing.to_i64_wrap()
			n = k + power
			ds = Str.from_utf8_lossy(digits)
			body =
				if k <= n and n <= 21 {
					Str.concat(ds, "0".repeat((n - k).to_u64_wrap()))
				} else if 0 < n and n <= 21 {
					cut = n.to_u64_wrap()
					"${Str.from_utf8_lossy(digits.take_first(cut))}.${Str.from_utf8_lossy(digits.drop_first(cut))}"
				} else if -6 < n and n <= 0 {
					"0.${"0".repeat((0 - n).to_u64_wrap())}${ds}"
				} else {
					e = n - 1
					sign = if (e < 0) "-" else "+"
					head = Str.from_utf8_lossy(digits.take_first(1))
					rest = if (k == 1) "" else ".${Str.from_utf8_lossy(digits.drop_first(1))}"
					magnitude = if e < 0 {
						0 - e
					} else {
						e
					}
					"${head}${rest}e${sign}${magnitude.to_str()}"
				}
			if (negative) "-${body}" else body
		}
	}

	## The number of UTF-16 code units of a string (JavaScript's `length`).
	utf16_length : Str -> U64
	utf16_length = |s| s.to_utf8().fold(0, |n, c| if (c >= 0xF0) n + 2 else if (c >= 0x80 and c < 0xC0) n else n + 1)
}

## `continues`: a size or range issue (a union may report it). `fatal`: zod's non-integer
## issue, after which no enclosing array checks its size.
Issue : { path : List(Str), message : Str, continues : Bool, fatal : Bool }

Checked : { issues : List(Issue), value : Try(JsonValue, [Absent]) }

max_safe : F64
max_safe = 9007199254740991.0

format_issue : Issue -> Str
format_issue = |i| if (i.path.is_empty()) i.message else "${Str.join_with(i.path, ".")}: ${i.message}"

digits_value : List(U8) -> I64
digits_value = |ds| ds.fold(0, |acc, c| if (c >= '0' and c <= '9') acc * 10 + (c - '0').to_i64() else acc)

count_trailing_zeros : List(U8) -> U64
count_trailing_zeros = |ds| {
	var $n = 0.U64
	while $n < ds.len() and ds.get(ds.len() - 1 - $n) == Ok('0') {
		$n = $n + 1
	}
	$n
}

drop_leading_zeros : List(U8) -> List(U8)
drop_leading_zeros = |ds| match ds.find_first_index(|c| c != '0') {
	Ok(i) => ds.drop_first(i)
	Err(_) => []
}

ok : Try(JsonValue, [Absent]) -> Checked
ok = |v| { issues: [], value: v }

fail : List(Str), Str, Bool -> Checked
fail = |path, message, continues| { issues: [{ path, message, continues, fatal: Bool.False }], value: Err(Absent) }

type_issue : List(Str), Str, Try(JsonValue, [Absent]) -> Checked
type_issue = |path, expected, v| fail(path, "Invalid input: expected ${expected}, received ${SchemaCheck.type_name(v)}", Bool.False)

## A primitive as zod prints it in "expected ...": strings as JSON, numbers as JS writes them.
show : JsonValue -> Str
show = |v| match v {
	Number(t) => SchemaCheck.js_number(t)
	other => other.to_str()
}

quote : Str -> Str
quote = |k| {
	j : JsonValue
	j = String(k)
	j.to_str()
}

is_absent : Try(JsonValue, [Absent]) -> Bool
is_absent = |v| match v {
	Err(Absent) => Bool.True
	Ok(_) => Bool.False
}

field : JsonValue, Str -> Try(JsonValue, [NotFound])
field = |schema, k| schema.get(k)

number_of : JsonValue -> Try(F64, [NotANumber])
number_of = |v| v.to_f64()

## `walk`, `any_of`, `typed` and `of_type` each start with an early `return`, which keeps the
## optimizer from inlining them into each other (DESIGN 12.21).
walk : JsonValue, Try(JsonValue, [Absent]), List(Str) -> Checked
walk = |schema, input, path| {
	if schema.as_object().is_err() {
		return ok(input)
	}
	match (input, field(schema, "default")) {
		(Err(Absent), Ok(d)) => ok(Ok(d))
		_ =>
			match field(schema, "anyOf") {
				Ok(Array(alternatives)) => any_of(alternatives, input, path)
				_ =>
					match field(schema, "const") {
						Ok(c) => if (same(input, c)) ok(input) else fail(path, "Invalid input: expected ${show(c)}", Bool.False)
						Err(_) =>
							match field(schema, "enum") {
								Ok(Array(values)) => enum_of(values, input, path)
								_ => typed(schema, input, path)
							}
					}
			}
	}
}

same : Try(JsonValue, [Absent]), JsonValue -> Bool
same = |input, c| match input {
	Ok(v) => v.equivalent(c)
	Err(Absent) => Bool.False
}

enum_of : List(JsonValue), Try(JsonValue, [Absent]), List(Str) -> Checked
enum_of = |values, input, path|
	if values.any(|c| same(input, c)) {
		ok(input)
	} else {
		if values.len() == 1 {
			fail(path, "Invalid input: expected ${show(values.first() ?? Null)}", Bool.False)
		} else {
			fail(path, "Invalid option: expected one of ${Str.join_with(values.map(show), "|")}", Bool.False)
		}
	}

null_schema : JsonValue
null_schema = Object([("type", String("null"))])

any_of : List(JsonValue), Try(JsonValue, [Absent]), List(Str) -> Checked
any_of = |alternatives, input, path|
	if alternatives.len() == 2 and alternatives.get(1) == Ok(null_schema) {
		if input == Ok(Null) {
			ok(input)
		} else {
			walk(alternatives.get(0) ?? Object([]), input, path)
		}
	} else {
		if alternatives.is_empty() {
			return fail(path, "Invalid input", Bool.False)
		}
		var $results = []
		for alt in alternatives {
			$results = $results.append(walk(alt, input, path))
		}
		results = $results
		match results.find_first(|r| r.issues.is_empty()) {
			Ok(r) => r
			Err(_) => {
				partial = results.keep_if(|r| r.issues.all(|i| i.continues))
				if partial.len() == 1 {
					partial.first() ?? fail(path, "Invalid input", Bool.False)
				} else {
					fail(path, "Invalid input", Bool.False)
				}
			}
		}
	}

typed : JsonValue, Try(JsonValue, [Absent]), List(Str) -> Checked
typed = |schema, input, path| match field(schema, "type") {
	Ok(String(t)) => of_type(schema, t, input, path)
	Ok(Array(names)) => {
		types = names.keep_oks(|n| n.as_str())
		if types.is_empty() {
			return ok(input)
		}
		var $found = not_found_yet
		for t in types {
			if $found.is_err() {
				r = of_type(schema, t, input, path)
				if r.issues.is_empty() {
					$found = Ok(r)
				}
			}
		}
		match $found {
			Ok(r) => r
			Err(_) =>
				match types.first() {
					Ok(t) => of_type(schema, t, input, path)
					Err(_) => ok(input)
				}
		}
	}
	_ =>
		match input {
			Err(Absent) => type_issue(path, "nonoptional", input)
			_ => ok(input)
		}
}

of_type : JsonValue, Str, Try(JsonValue, [Absent]), List(Str) -> Checked
of_type = |schema, t, input, path| {
	if t == "" {
		return ok(input)
	}
	v = input ?? Null
	present = !(is_absent(input))
	if t == "string" {
		match v {
			String(s) if present => string_checks(schema, s, path)
			_ => type_issue(path, t, input)
		}
	} else if t == "number" or t == "integer" {
		match v {
			Number(_) if present => number_checks(schema, input, path, t == "integer")
			_ => type_issue(path, "number", input)
		}
	} else if t == "boolean" {
		match v {
			Bool(_) if present => ok(input)
			_ => type_issue(path, t, input)
		}
	} else if t == "null" {
		if (present and v == Null) ok(input) else type_issue(path, t, input)
	} else if t == "array" {
		match v {
			Array(items) if present => array_checks(schema, items, path)
			_ => type_issue(path, t, input)
		}
	} else if t == "object" {
		match v {
			Object(fs) if present => object_checks(schema, fs, path)
			_ => type_issue(path, if (field(schema, "propertyNames").is_ok()) "record" else "object", input)
		}
	} else {
		ok(input)
	}
}

bound : JsonValue, Str -> Try({ value : F64, text : Str }, [None])
bound = |schema, k| match field(schema, k) {
	Ok(Number(t)) =>
		match F64.from_str(t) {
			Ok(f) => Ok({ value: f, text: SchemaCheck.js_number(t) })
			Err(_) => Err(None)
		}
	_ => Err(None)
}

size_issue : List(Str), Str -> Issue
size_issue = |path, message| { path, message, continues: Bool.True, fatal: Bool.False }

string_checks : JsonValue, Str, List(Str) -> Checked
string_checks = |schema, s, path| {
	len = SchemaCheck.utf16_length(s).to_f64()
	small = match bound(schema, "minLength") {
		Ok(b) if len < b.value => [size_issue(path, "Too small: expected string to have >=${b.text} characters")]
		_ => []
	}
	big = match bound(schema, "maxLength") {
		Ok(b) if len > b.value => [size_issue(path, "Too big: expected string to have <=${b.text} characters")]
		_ => []
	}
	issues = small.concat(big)
	{ issues, value: if (issues.is_empty()) Ok(String(s)) else Err(Absent) }
}

number_checks : JsonValue, Try(JsonValue, [Absent]), List(Str), Bool -> Checked
number_checks = |schema, input, path, integer| {
	f = match input {
		Ok(v) => number_of(v) ?? F64.nan
		Err(Absent) => F64.nan
	}
	if !(f.is_finite()) {
		type_issue(path, "number", input)
	} else if integer and !(f.rem_by(1.0).is_zero()) {
		{ issues: [{ path, message: "Invalid input: expected int, received number", continues: Bool.False, fatal: Bool.True }], value: Err(Absent) }
	} else {
		safe =
			if !integer {
				[]
			} else if f > max_safe {
				[size_issue(path, "Too big: expected int to be <=9007199254740991")]
			} else if f < 0.0 - max_safe {
				[size_issue(path, "Too small: expected int to be >=-9007199254740991")]
			} else {
				[]
			}

		## zod writes the safe-integer range of `int()` as minimum/maximum: not a check of its own.
		low = match (explicit(schema, integer, "minimum"), explicit(schema, integer, "exclusiveMinimum")) {
			(Ok(b), _) if f < b.value => [size_issue(path, "Too small: expected number to be >=${b.text}")]
			(_, Ok(b)) if f <= b.value => [size_issue(path, "Too small: expected number to be >${b.text}")]
			_ => []
		}
		high = match (explicit(schema, integer, "maximum"), explicit(schema, integer, "exclusiveMaximum")) {
			(Ok(b), _) if f > b.value => [size_issue(path, "Too big: expected number to be <=${b.text}")]
			(_, Ok(b)) if f >= b.value => [size_issue(path, "Too big: expected number to be <${b.text}")]
			_ => []
		}
		issues = safe.concat(low).concat(high)
		{ issues, value: if (issues.is_empty()) input else Err(Absent) }
	}
}

## A bound of a number schema; zod writes the safe-integer range of `int()` as
## minimum/maximum, which is not a check of its own.
explicit : JsonValue, Bool, Str -> Try({ value : F64, text : Str }, [None])
explicit = |schema, integer, k| match bound(schema, k) {
	Ok(b) if integer and ((k == "minimum" and b.value == 0.0 - max_safe) or (k == "maximum" and b.value == max_safe)) => Err(None)
	other => other
}

array_checks : JsonValue, List(JsonValue), List(Str) -> Checked
array_checks = |schema, items, path| {
	item_schema = field(schema, "items") ?? Object([])
	var $elements = []
	var $i = 0.U64
	for x in items {
		$elements = $elements.append(walk(item_schema, Ok(x), path.append($i.to_str())))
		$i = $i + 1
	}
	elements = $elements
	n = items.len().to_f64()
	element_issues = elements.join_map(|r| r.issues)
	sized = !(element_issues.any(|i| i.fatal))
	small = match bound(schema, "minItems") {
		Ok(b) if sized and n < b.value => [size_issue(path, "Too small: expected array to have >=${b.text} items")]
		_ => []
	}
	big = match bound(schema, "maxItems") {
		Ok(b) if sized and n > b.value => [size_issue(path, "Too big: expected array to have <=${b.text} items")]
		_ => []
	}
	issues = element_issues.concat(small).concat(big)
	{ issues, value: if (issues.is_empty()) Ok(Array(elements.keep_oks(|r| r.value))) else Err(Absent) }
}

not_found_yet : Try(Checked, [None])
not_found_yet = Err(None)

lookup : List((Str, JsonValue)), Str -> Try(JsonValue, [Absent])
lookup = |fs, k| match fs.find_first(|(name, _)| name == k) {
	Ok((_, v)) => Ok(v)
	Err(_) => Err(Absent)
}

object_checks : JsonValue, List((Str, JsonValue)), List(Str) -> Checked
object_checks = |schema, fs, path| {
	props = match field(schema, "properties") {
		Ok(Object(ps)) => ps
		_ => []
	}
	required = match field(schema, "required") {
		Ok(Array(names)) => names.keep_oks(|n| n.as_str())
		_ => []
	}

	## Required names without a schema are checked as `{}`.
	unlisted = required.drop_if(|n| props.any(|(k, _)| k == n)).map(|n| (n, Object([])))
	known = props.concat(unlisted)
	var $results = []
	for (k, sub) in known {
		v = lookup(fs, k)
		r =
			if is_absent(v) and !(required.contains(k)) {
				match field(sub, "default") {
					Ok(d) => ok(Ok(d))
					Err(_) => ok(Err(Absent))
				}
			} else {
				walk(sub, v, path.append(k))
			}
		$results = $results.append((k, r))
	}
	results = $results
	extras = fs.drop_if(|(k, _)| known.any(|(name, _)| name == k))
	(extra_issues, kept) = match field(schema, "additionalProperties") {
		Ok(Bool(b)) if !b =>
			if extras.is_empty() {
				([], [])
			} else {
				noun = if (extras.len() == 1) "key" else "keys"
				([{ path, message: "Unrecognized ${noun}: ${Str.join_with(extras.map(|(k, _)| quote(k)), ", ")}", continues: Bool.False, fatal: Bool.False }], [])
			}
		Ok(Object([])) | Ok(Bool(_)) => ([], extras)
		Ok(Object(sub_fields)) => {
			sub = Object(sub_fields)
			var $checked = []
			for (k, x) in extras {
				$checked = $checked.append((k, walk(sub, Ok(x), path.append(k))))
			}
			checked = $checked
			(checked.join_map(|(_, r)| r.issues), checked.keep_oks(|(k, r)| r.value.map_ok(|x| (k, x))))
		}
		_ => ([], [])
	}
	issues = results.join_map(|(_, r)| r.issues).concat(extra_issues)
	if issues.is_empty() {
		values = results.keep_oks(|(k, r)| r.value.map_ok(|x| (k, x)))
		{ issues, value: Ok(Object(values.concat(kept))) }
	} else {
		{ issues, value: Err(Absent) }
	}
}
