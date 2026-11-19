app [main!] { pkg: "pkg/main.roc" }

main! = |_args| Ok({})

import pkg.Server

# Q: can a pure lambda be passed where `=>` is expected, and can an expect call serve!?
expect {
	server = Server.new("t").tool("count", |n, _| (n + 1, "c"))
	io = { read_line!: || Err(Eof), write!: |_s| {} }
	final = server.serve!(0.U64, io)
	final == 0
}
