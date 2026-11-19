import ../JsonValue

## Pagination of the list methods. Off by default (JS parity): everything is returned and the
## cursor is ignored. With a page size, the cursor is the decimal offset of the next item.
Paging :: [].{

	## One page of `items` and the `nextCursor` when more remain.
	page : List(a), Try(U64, [None]), JsonValue -> Try({ items : List(a), next : Try(Str, [None]) }, [InvalidCursor])
	page = |items, size, cursor| match size {
		Err(None) => Ok({ items, next: Err(None) })
		Ok(n) => {
			start = match cursor {
				Null => Ok(0)
				String(s) =>
					match U64.from_str(s) {
						Ok(k) if k <= items.len() and s == k.to_str() => Ok(k)
						_ => Err(InvalidCursor)
					}
				_ => Err(InvalidCursor)
			}?
			size_ = if (n == 0) 1 else n
			chunk = items.sublist({ start, len: size_ })
			next_start = start + chunk.len()
			next = if (next_start < items.len()) Ok(next_start.to_str()) else Err(None)
			Ok({ items: chunk, next })
		}
	}

	## `{key: items, nextCursor?}`.
	result : Str, List(JsonValue), Try(Str, [None]) -> JsonValue
	result = |key, items, next| {
		nc = match next {
			Ok(c) => [("nextCursor", String(c))]
			Err(None) => []
		}
		Object([(key, Array(items))].concat(nc))
	}
}

expect Paging.page([1, 2, 3], Err(None), String("x")) == Ok({ items: [1, 2, 3], next: Err(None) })
expect Paging.page([1, 2, 3], Ok(2), Null) == Ok({ items: [1, 2], next: Ok("2") })
expect Paging.page([1, 2, 3], Ok(2), String("2")) == Ok({ items: [3], next: Err(None) })
expect Paging.page([1, 2, 3], Ok(2), String("4")) == Err(InvalidCursor)
expect Paging.page([1, 2, 3], Ok(2), String("01")) == Err(InvalidCursor)
