## Base64 (RFC 4648 section 4): the standard alphabet, with `=` padding.
Base64 :: [].{
	encode : List(U8) -> Str
	encode = |bytes| {
		var $out = List.with_capacity((bytes.len() + 2) // 3 * 4)
		var $i = 0
		n = bytes.len()
		while $i + 3 <= n {
			a = bytes.get($i) ?? 0
			b = bytes.get($i + 1) ?? 0
			c = bytes.get($i + 2) ?? 0
			$out = $out
				.append(sym(a // 4))
				.append(sym((a % 4) * 16 + b // 16))
				.append(sym((b % 16) * 4 + c // 64))
				.append(sym(c % 64))
			$i = $i + 3
		}
		left = n - $i
		if left == 1 {
			a = bytes.get($i) ?? 0
			$out = $out.append(sym(a // 4)).append(sym((a % 4) * 16)).append('=').append('=')
		} else if left == 2 {
			a = bytes.get($i) ?? 0
			b = bytes.get($i + 1) ?? 0
			$out = $out
				.append(sym(a // 4))
				.append(sym((a % 4) * 16 + b // 16))
				.append(sym((b % 16) * 4))
				.append('=')
		}
		Str.from_utf8_lossy($out)
	}

	## Strict: the length is a multiple of 4, `=` only as the last one or two
	## characters, and nothing outside the alphabet (no whitespace).
	decode : Str -> Try(List(U8), [InvalidBase64])
	decode = |text| {
		chars = text.to_utf8()
		n = chars.len()
		if n % 4 != 0 {
			return Err(InvalidBase64)
		}
		pad =
			if n >= 2 and chars.get(n - 2) == Ok('=') {
				2
			} else if n >= 1 and chars.get(n - 1) == Ok('=') {
				1
			} else {
				0
			}
		var $out = List.with_capacity(n // 4 * 3)
		var $i = 0
		while $i < n {
			last = $i + 4 == n
			c0 = val(chars.get($i) ?? 0)?
			c1 = val(chars.get($i + 1) ?? 0)?
			if last and pad == 2 {
				if chars.get($i + 3) != Ok('=') {
					return Err(InvalidBase64)
				}
				$out = $out.append(c0 * 4 + c1 // 16)
			} else {
				c2 = val(chars.get($i + 2) ?? 0)?
				if last and pad == 1 {
					$out = $out.append(c0 * 4 + c1 // 16).append((c1 % 16) * 16 + c2 // 4)
				} else {
					c3 = val(chars.get($i + 3) ?? 0)?
					$out = $out
						.append(c0 * 4 + c1 // 16)
						.append((c1 % 16) * 16 + c2 // 4)
						.append((c2 % 4) * 64 + c3)
				}
			}
			$i = $i + 4
		}
		Ok($out)
	}
}

alphabet : List(U8)
alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/".to_utf8()

sym : U8 -> U8
sym = |six| alphabet.get(six.to_u64()) ?? '='

val : U8 -> Try(U8, [InvalidBase64])
val = |c|
	if c >= 'A' and c <= 'Z' {
		Ok(c - 'A')
	} else if c >= 'a' and c <= 'z' {
		Ok(c - 'a' + 26)
	} else if c >= '0' and c <= '9' {
		Ok(c - '0' + 52)
	} else if c == '+' {
		Ok(62)
	} else if c == '/' {
		Ok(63)
	} else {
		Err(InvalidBase64)
	}

expect Base64.encode([]) == ""
expect Base64.encode("f".to_utf8()) == "Zg=="
expect Base64.encode("fo".to_utf8()) == "Zm8="
expect Base64.encode("foo".to_utf8()) == "Zm9v"
expect Base64.encode("foob".to_utf8()) == "Zm9vYg=="
expect Base64.encode("fooba".to_utf8()) == "Zm9vYmE="
expect Base64.encode("foobar".to_utf8()) == "Zm9vYmFy"
expect Base64.encode([0xFB, 0xFF, 0xBF]) == "+/+/"
expect Base64.encode([0, 0, 0]) == "AAAA"
expect Base64.decode("") == Ok([])
expect Base64.decode("Zg==") == Ok("f".to_utf8())
expect Base64.decode("Zm8=") == Ok("fo".to_utf8())
expect Base64.decode("Zm9vYmFy") == Ok("foobar".to_utf8())
expect Base64.decode("+/+/") == Ok([0xFB, 0xFF, 0xBF])
expect Base64.decode("Zg=") == Err(InvalidBase64)
expect Base64.decode("Zg") == Err(InvalidBase64)
expect Base64.decode("Z===") == Err(InvalidBase64)
expect Base64.decode("====") == Err(InvalidBase64)
expect Base64.decode("Zg==Zg==") == Err(InvalidBase64)
expect Base64.decode("Zm9v YmFy") == Err(InvalidBase64)
expect Base64.decode("Zm9-") == Err(InvalidBase64)
expect Base64.decode("Zm=v") == Err(InvalidBase64)
expect {
	bytes = (0.U64..<256).iter().map(|i| i.to_u8_wrap()).collect()
	Base64.decode(Base64.encode(bytes)) == Ok(bytes)
}
