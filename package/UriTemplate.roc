## RFC 6570 URI templates, with the matching rules of the JS SDK 2.0.0.
##
## Expressions: `{x}`, `{+x}`, `{#x}`, `{.x}`, `{/x}`, `{?a,b}`, `{&a}`, and the
## explode modifier `*`. Prefix modifiers (`{x:3}`) are not supported: `x:3` is
## then the variable name, as in JS.
##
## Matching follows the JS behaviour, quirks included:
## - values are not percent-decoded;
## - `{#x}` and `{+x}` match one or more characters (no line terminators), and
##   the `#` is not required, so `{#x}` matches `frag` and `#frag` (`x` = `#frag`);
## - `{x}` and `{/x}` match a run without `/` or `,`; `{.x}` matches `.` then such
##   a run, so `{.x}` on `.a.b` gives `a.b`;
## - `{?a,b}` matches exactly `?a=..&b=..` in that order, each value without `&`;
## - an expression with several names that is not `?` or `&` captures only its
##   first name (`{a,b}` matches `x`, not `x,y`);
## - a value of an exploded expression that holds a comma is split on commas;
## - earlier captures are greedy (`{a}.{b}` on `x.y.z` gives `a` = `x.y`);
## - a name repeated in the template keeps the last captured value.
UriTemplate :: { source : Str, parts : List([Literal(Str), Expr({ op : Str, names : List(Str), explode : Bool })]) }.{

	## Parses a template. Fails only on an unclosed `{`, more than 10 000
	## expressions, or a template longer than 1 000 000 UTF-16 code units.
	parse : Str -> Try(UriTemplate, [InvalidTemplate(Str)])
	parse = |s| {
		bs = s.to_utf8()
		units = utf16_len(bs)
		if units > max_length {
			Err(InvalidTemplate("Template exceeds maximum length of 1000000 characters (got ${units.to_str()})"))
		} else {
			match parse_parts(bs) {
				Ok(ps) => Ok({ source: s, parts: ps })
				Err(e) => Err(e)
			}
		}
	}

	to_str : UriTemplate -> Str
	to_str = |t| t.source

	## Every name of every expression, in template order, duplicates kept.
	variable_names : UriTemplate -> List(Str)
	variable_names = |t|
		t.parts.join_map(
			|p|
				match p {
					Literal(_) => []
					Expr(e) => e.names
				},
		)

	## Matches a whole URI. Values are not percent-decoded (JS parity).
	match_uri : UriTemplate, Str -> Try(UriTemplate.Vars, [NoMatch])
	match_uri = |t, uri| {
		bs = uri.to_utf8()
		if utf16_len(bs) > max_length {
			Err(NoMatch)
		} else {
			elems = t.parts.join_map(to_elems)
			match match_from(bs, elems, 0, 0) {
				Ok(caps) => build_vars(bs, caps)
				Err(_) => Err(NoMatch)
			}
		}
	}

	## Expands the template. A name given twice takes its last value. `?` and
	## `&` expressions after the first non-empty one start with `&`.
	expand : UriTemplate, List((Str, Str)) -> Str
	expand = |t, vars| {
		var $out = ""
		var $has_query = Bool.False
		for p in t.parts {
			match p {
				Literal(l) => {
					$out = $out.concat(l)
				}
				Expr(e) => {
					x = expand_expr(e.op, e.names, vars)
					is_query = e.op == "?" or e.op == "&"
					if !x.is_empty() {
						piece = if (is_query and $has_query) x.replace_first("?", "&") else x
						$out = $out.concat(piece)
						if is_query {
							$has_query = Bool.True
						}
					}
				}
			}
		}
		$out
	}

	## Matched variables. An exploded variable may hold several values.
	Vars :: { entries : List((Str, List(Str))) }.{

		## The first value of a variable.
		get : UriTemplate.Vars, Str -> Try(Str, [Missing])
		get = |v, n|
			match v.entries.find_first(|(k, _)| k == n) {
				Ok((_, [first, ..])) => Ok(first)
				_ => Err(Missing)
			}

		get_all : UriTemplate.Vars, Str -> List(Str)
		get_all = |v, n|
			match v.entries.find_first(|(k, _)| k == n) {
				Ok((_, vals)) => vals
				Err(_) => []
			}

		to_list : UriTemplate.Vars -> List((Str, List(Str)))
		to_list = |v| v.entries
	}
}

max_length : U64
max_length = 1000000

max_expressions : U64
max_expressions = 10000

## Length in UTF-16 code units, the unit of the JS limits.
utf16_len : List(U8) -> U64
utf16_len = |bs|
	bs.fold(
		0,
		|acc, b|
			if b.bitwise_and(0xC0) == 0x80 {
				acc
			} else if b >= 0xF0 {
				acc + 2
			} else {
				acc + 1
			},
	)

slice_str : List(U8), U64, U64 -> Str
slice_str = |bs, start, end| Str.from_utf8(bs.sublist({ start, len: end - start })) ?? ""

parse_parts : List(U8) -> Try(List([Literal(Str), Expr({ op : Str, names : List(Str), explode : Bool })]), [InvalidTemplate(Str)])
parse_parts = |bs| {
	n = bs.len()
	var $i = 0
	var $text_start = 0
	var $count = 0
	var $parts = []
	while $i < n {
		if bs.get($i) == Ok('{') {
			match find_close(bs, $i + 1) {
				Err(_) => {
					return Err(InvalidTemplate("Unclosed template expression"))
				}
				Ok(end) => {
					if $i > $text_start {
						$parts = $parts.append(Literal(slice_str(bs, $text_start, $i)))
					}
					$count = $count + 1
					if $count > max_expressions {
						return Err(InvalidTemplate("Template contains too many expressions (max 10000)"))
					}
					$parts = $parts.append(parse_expr(slice_str(bs, $i + 1, end)))
					$i = end + 1
					$text_start = $i
				}
			}
		} else {
			$i = $i + 1
		}
	}
	if n > $text_start {
		$parts = $parts.append(Literal(slice_str(bs, $text_start, n)))
	}
	Ok($parts)
}

## The index of the first `}` at or after `from`.
find_close : List(U8), U64 -> Try(U64, [NotFound])
find_close = |bs, from| {
	var $j = from
	while $j < bs.len() {
		if bs.get($j) == Ok('}') {
			return Ok($j)
		}
		$j = $j + 1
	}
	Err(NotFound)
}

parse_expr : Str -> [Literal(Str), Expr({ op : Str, names : List(Str), explode : Bool })]
parse_expr = |e| {
	op = match e.to_utf8() {
		[c, ..] if "+#./?&".to_utf8().contains(c) => Str.from_utf8([c]) ?? ""
		_ => ""
	}
	ns =
		e.drop_prefix(op)
			.split_on(",")
			.map(|x| x.replace_first("*", "").trim())
			.keep_if(|x| !x.is_empty())
	Expr({ op, names: ns, explode: e.contains("*") })
}

# ---- expand

lookup : List((Str, Str)), Str -> Try(Str, [NotFound])
lookup = |vars, n|
	match vars.find_last(|(k, _)| k == n) {
		Ok((_, v)) => Ok(v)
		Err(_) => Err(NotFound)
	}

expand_expr : Str, List(Str), List((Str, Str)) -> Str
expand_expr = |op, ns, vars|
	if op == "?" or op == "&" {
		pairs = ns.keep_oks(|n| lookup(vars, n).map_ok(|v| "${n}=${encode(v, Bool.False)}"))
		if (pairs.is_empty()) "" else op.concat(Str.join_with(pairs, "&"))
	} else if ns.len() > 1 {
		# JS quirk: several names are joined raw, without encoding or prefix.
		Str.join_with(ns.keep_oks(|n| lookup(vars, n)), ",")
	} else {
		match ns {
			[n] =>
				match lookup(vars, n) {
					Ok(v) =>
						match op {
							"+" => encode(v, Bool.True)
							"#" => "#".concat(encode(v, Bool.True))
							"." => ".".concat(encode(v, Bool.False))
							"/" => "/".concat(encode(v, Bool.False))
							_ => encode(v, Bool.False)
						}
					Err(_) => ""
				}
			_ => ""
		}
	}

## Percent-encodes UTF-8 bytes like JS `encodeURIComponent`, or like
## `encodeURI` when `keep_reserved` is true.
encode : Str, Bool -> Str
encode = |s, keep_reserved| {
	unreserved = "-_.!~*'()".to_utf8()
	reserved = ";,/?:@&=+\$#".to_utf8()
	digits = "0123456789ABCDEF".to_utf8()
	var $out = []
	for b in s.to_utf8() {
		alnum = (b >= 'a' and b <= 'z') or (b >= 'A' and b <= 'Z') or (b >= '0' and b <= '9')
		if alnum or unreserved.contains(b) or (keep_reserved and reserved.contains(b)) {
			$out = $out.append(b)
		} else {
			hi = digits.get((b // 16).to_u64()) ?? '0'
			lo = digits.get((b % 16).to_u64()) ?? '0'
			$out = $out.append('%').append(hi).append(lo)
		}
	}
	Str.from_utf8($out) ?? ""
}

# ---- match

## One step of the match: a literal, or a capture of one variable.
## `Seg` is `[^/,]+`, `SegList` is `[^/,]+(,[^/,]+)*`, `Any` is `.+`
## (no line terminators), `NotAmp` is `[^&]+`.
to_elems : [Literal(Str), Expr({ op : Str, names : List(Str), explode : Bool })] -> List([Lit(List(U8)), Cap({ cls : [Seg, SegList, Any, NotAmp], name : Str, named : Bool, explode : Bool })])
to_elems = |p|
	match p {
		Literal(l) => [Lit(l.to_utf8())]
		Expr(e) =>
			if e.op == "?" or e.op == "&" {
				e.names.map_with_index(
					|n, i| {
						lead = if (i == 0) e.op else "&"
						[Lit("${lead}${n}=".to_utf8()), Cap({ cls: NotAmp, name: n, named: Bool.True, explode: e.explode })]
					},
				).join()
			} else {
				(n, named) = match e.names {
					[first, ..] => (first, Bool.True)
					[] => ("", Bool.False)
				}
				seg = if (e.explode) SegList else Seg
				cap = |cls| Cap({ cls, name: n, named, explode: e.explode })
				match e.op {
					"+" => [cap(Any)]
					"#" => [cap(Any)]
					"." => [Lit(['.']), cap(Seg)]
					"/" => [Lit(['/']), cap(seg)]
					_ => [cap(seg)]
				}
			}
	}

## Backtracking match, in the order of a JS regex: each capture tries its
## longest end first.
match_from = |bs, elems, k, p|
	match elems.get(k) {
		Err(_) => if (p == bs.len()) Ok([]) else Err(NoMatch)
		Ok(Lit(l)) =>
			if bs.sublist({ start: p, len: l.len() }) == l {
				match_from(bs, elems, k + 1, p + l.len())
			} else {
				Err(NoMatch)
			}
		Ok(Cap(c)) => {
			ends = cap_ends(bs, p, c.cls)
			var $j = ends.len()
			while $j > 0 {
				$j = $j - 1
				e = ends.get($j) ?? 0
				match match_from(bs, elems, k + 1, e) {
					Ok(rest) => {
						return Ok(List.concat([{ name: c.name, named: c.named, explode: c.explode, start: p, end: e }], rest))
					}
					Err(_) => {}
				}
			}
			Err(NoMatch)
		}
	}

## True when `i` is not inside a UTF-8 sequence, so a capture may end there.
## (JS splits astral characters into surrogates; we never split a character.)
at_boundary : List(U8), U64 -> Bool
at_boundary = |bs, i|
	match bs.get(i) {
		Ok(b) => b.bitwise_and(0xC0) != 0x80
		Err(_) => Bool.True
	}

## A JS line terminator at `i`: LF, CR, U+2028, U+2029.
line_end : List(U8), U64 -> Bool
line_end = |bs, i|
	match bs.sublist({ start: i, len: 3 }) {
		[10, ..] | [13, ..] => Bool.True
		[0xE2, 0x80, 0xA8] | [0xE2, 0x80, 0xA9] => Bool.True
		_ => Bool.False
	}

## The ends that a capture starting at `p` can have, ascending.
cap_ends : List(U8), U64, [Seg, SegList, Any, NotAmp] -> List(U64)
cap_ends = |bs, p, cls| {
	n = bs.len()
	var $out = []
	var $i = p
	var $prev = 0
	while $i < n {
		b = bs.get($i) ?? 0
		stop = match cls {
			Seg => b == '/' or b == ','
			NotAmp => b == '&'
			Any => line_end(bs, $i)
			SegList => b == '/' or (b == ',' and ($i == p or $prev == ','))
		}
		if stop {
			break
		}
		$prev = b
		$i = $i + 1
		ok_end = match cls {
			SegList => b != ','
			_ => Bool.True
		}
		if ok_end and at_boundary(bs, $i) {
			$out = $out.append($i)
		}
	}
	$out
}

build_vars : List(U8), List({ name : Str, named : Bool, explode : Bool, start : U64, end : U64 }) -> Try(UriTemplate.Vars, [NoMatch])
build_vars = |bs, caps| {
	var $acc = []
	for c in caps {
		if !c.named {
			# JS throws here (a capture without a name); we report no match.
			return Err(NoMatch)
		}
		key = c.name.replace_first("*", "")
		raw = slice_str(bs, c.start, c.end)
		vals = if (c.explode and raw.contains(",")) raw.split_on(",") else [raw]
		$acc =
			if $acc.any(|(k, _)| k == key) {
				$acc.map(|(k, v)| if (k == key) (k, vals) else (k, v))
			} else {
				$acc.append((key, vals))
			}
	}
	Ok({ entries: $acc })
}
