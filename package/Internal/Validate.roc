import ../JsonValue
import Base64

## The checks the JS SDK makes on a handler's result before sending it: base64 payloads
## (`data` of image and audio blocks, `blob` of resource contents) must be valid base64, and
## every `lastModified` annotation must be an ISO 8601 date-time. A failure is answered with
## -32602 "Invalid <method> result: <path>: <reason>" (JS parity: JS rejects such results too).
Validate :: [].{
	result : JsonValue -> Try({}, Str)
	result = |v| walk(v, "")

	## `YYYY-MM-DDTHH:MM[:SS[.fraction]](Z|±HH:MM)`, with valid month, day, hour and minute ranges.
	is_iso_datetime : Str -> Bool
	is_iso_datetime = |s| {
		b = s.to_utf8()
		digits = |from, n| {
			part = b.sublist({ start: from, len: n })
			part.len() == n and part.all(is_digit)
		}
		num = |from, n| b.sublist({ start: from, len: n }).fold(0.U64, |acc, c| acc * 10 + (c - '0').to_u64())
		at = |i, c| b.get(i) == Ok(c)
		head_ok =
			b.len() >= 17
				and digits(0, 4)
				and at(4, '-')
				and digits(5, 2)
				and at(7, '-')
				and digits(8, 2)
				and at(10, 'T')
				and digits(11, 2)
				and at(13, ':')
				and digits(14, 2)
		if !head_ok {
			Bool.False
		} else {
			month = num(5, 2)
			day = num(8, 2)
			ranges_ok = month >= 1 and month <= 12 and day >= 1 and day <= 31 and num(11, 2) <= 23 and num(14, 2) <= 59
			after_minutes =
				if at(16, ':') {
					if digits(17, 2) and num(17, 2) <= 59 {
						if at(19, '.') {
							frac = count_digits(b, 20)
							if (frac == 0) Err(Bad) else Ok(20 + frac)
						} else {
							Ok(19)
						}
					} else {
						Err(Bad)
					}
				} else {
					Ok(16)
				}
			zone_ok = match after_minutes {
				Ok(i) =>
					if at(i, 'Z') and b.len() == i + 1 {
						Bool.True
					} else if (at(i, '+') or at(i, '-')) and b.len() == i + 6 {
						digits(i + 1, 2) and at(i + 3, ':') and digits(i + 4, 2) and num(i + 1, 2) <= 23 and num(i + 4, 2) <= 59
					} else {
						Bool.False
					}
				Err(Bad) => Bool.False
			}
			ranges_ok and zone_ok
		}
	}
}

is_digit : U8 -> Bool
is_digit = |c| c >= '0' and c <= '9'

count_digits : List(U8), U64 -> U64
count_digits = |b, from| {
	var $i = from
	while is_digit(b.get($i) ?? 0) {
		$i = $i + 1
	}
	$i - from
}

still_ok : Try({}, Str)
still_ok = Ok({})

join_path : Str, Str -> Str
join_path = |base, key| if (base == "") key else "${base}.${key}"

walk : JsonValue, Str -> Try({}, Str)
walk = |v, path| match v {
	Object(fs) => {
		media = v.get("type") == Ok(String("image")) or v.get("type") == Ok(String("audio"))
		var $res = still_ok
		for (k, x) in fs {
			if $res.is_ok() {
				p = join_path(path, k)
				$res =
					if (k == "blob" or (media and k == "data")) and !(is_base64(x)) {
						Err("${p}: Invalid Base64 string")
					} else if k == "lastModified" and !(is_datetime(x)) {
						Err("${p}: Invalid ISO datetime")
					} else {
						walk(x, p)
					}
			}
		}
		$res
	}
	Array(xs) => {
		var $res = still_ok
		var $i = 0.U64
		for x in xs {
			if $res.is_ok() {
				$res = walk(x, "${path}[${$i.to_str()}]")
			}
			$i = $i + 1
		}
		$res
	}
	_ => Ok({})
}

is_base64 : JsonValue -> Bool
is_base64 = |v| match v {
	String(s) => Base64.decode(s).is_ok()
	_ => Bool.True
}

is_datetime : JsonValue -> Bool
is_datetime = |v| match v {
	String(s) => Validate.is_iso_datetime(s)
	_ => Bool.True
}

expect Validate.is_iso_datetime("2025-01-01T00:00:00Z")
expect Validate.is_iso_datetime("2025-01-01T00:00Z")
expect Validate.is_iso_datetime("2025-01-01T00:00:00.123+02:00")
expect !(Validate.is_iso_datetime("yesterday"))
expect !(Validate.is_iso_datetime("2025-13-01T00:00:00Z"))
expect !(Validate.is_iso_datetime("2025-01-01T00:00:00"))
