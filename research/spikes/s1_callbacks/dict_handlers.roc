## Q1: can effectful handlers live in a Dict inside a record, and be called?
Handlers(state) : Dict(Str, (state, Str => (state, Str)))

make : {} -> Handlers(U64)
make = |{}| Dict.empty().insert("inc", |n, s| (n + 1, s)).insert("say", |n, s| {
	echo!("say ${s}\n")
	(n, s)
})

main! = |_args| {
	hs = make({})
	var $n = 0.U64
	for name in ["inc", "say", "inc", "missing"] {
		match hs.get(name) {
			Ok(h!) => {
				(n2, out) = h!($n, name)
				$n = n2
				echo!("${out} -> ${$n.to_str()}\n")
			}
			Err(_) => echo!("no handler ${name}\n")
		}
	}
	Ok({})
}
