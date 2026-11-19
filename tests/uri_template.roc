app [main!] { pkg: "../package/main.roc" }

import pkg.UriTemplate

main! = |_args| Ok({})

# Golden tests: each expected value was observed from the JS SDK 2.0.0
# `UriTemplate` (@modelcontextprotocol/server dist), run under node.

names : Str -> Try(List(Str), [InvalidTemplate(Str)])
names = |t| UriTemplate.parse(t).map_ok(|x| x.variable_names())

expand : Str, List((Str, Str)) -> Str
expand = |t, vars|
	match UriTemplate.parse(t) {
		Ok(x) => x.expand(vars)
		Err(_) => "<invalid>"
	}

matched : Str, Str -> Try(List((Str, List(Str))), [NoMatch, Invalid])
matched = |t, uri|
	match UriTemplate.parse(t) {
		Ok(x) =>
			match x.match_uri(uri) {
				Ok(v) => Ok(v.to_list())
				Err(NoMatch) => Err(NoMatch)
			}
		Err(_) => Err(Invalid)
	}

# parse / variable_names
expect names("") == Ok([])
expect names("plain/text") == Ok([])
expect names("{x}") == Ok(["x"])
expect names("{+x}") == Ok(["x"])
expect names("{#x}") == Ok(["x"])
expect names("{.x}") == Ok(["x"])
expect names("{/x}") == Ok(["x"])
expect names("{?x}") == Ok(["x"])
expect names("{&x}") == Ok(["x"])
expect names("{a,b,c}") == Ok(["a", "b", "c"])
expect names("{?a,b*,c}") == Ok(["a", "b", "c"])
expect names("{x*}") == Ok(["x"])
expect names("{/list*}") == Ok(["list"])
expect names("{ a , b }") == Ok(["a", "b"])
expect names("{}") == Ok([])
expect names("{,}") == Ok([])
expect names("{?}") == Ok([])
expect names("{a**}") == Ok(["a*"])
expect names("{*a}") == Ok(["a"])
expect names("{;x}") == Ok([";x"])
expect names("{=x}") == Ok(["=x"])
expect names("{x:3}") == Ok(["x:3"])
expect names("{a{b}") == Ok(["a{b"])
expect names("a}b") == Ok([])
expect names("{x") == Err(InvalidTemplate("Unclosed template expression"))
expect names("abc{") == Err(InvalidTemplate("Unclosed template expression"))
expect names("x{y}z{") == Err(InvalidTemplate("Unclosed template expression"))
expect names("{x}{x}") == Ok(["x", "x"])
expect names("{?a}{&b,c}") == Ok(["a", "b", "c"])
expect names("{+}") == Ok([])
expect names("{a,,b}") == Ok(["a", "b"])
expect names("{\tx\n}") == Ok(["x"])
expect names("roc-syntax://topic/{name}") == Ok(["name"])
expect names("roc-syntax://platform/{platform}/example/{name}") == Ok(["platform", "name"])
expect names("roc-syntax://package/{package}") == Ok(["package"])
expect names("roc-syntax://package/{package}/example/{name}") == Ok(["package", "name"])
expect names("roc-syntax://platform/{platform}/doc/{name}") == Ok(["platform", "name"])

# expand
expect expand("{x}", [("x", "hello")]) == "hello"
expect expand("{x}", []) == ""
expect expand("{x}", [("x", "")]) == ""
expect expand("a{x}b", [("x", "")]) == "ab"
expect expand("{x}", [("x", "a b/c?d&e=f#g%h,i")]) == "a%20b%2Fc%3Fd%26e%3Df%23g%25h%2Ci"
expect expand("{+x}", [("x", "a b/c?d&e=f#g%h,i")]) == "a%20b/c?d&e=f#g%25h,i"
expect expand("{#x}", [("x", "a b/c?d&e=f#g%h,i")]) == "#a%20b/c?d&e=f#g%25h,i"
expect expand("{#x}", [("x", "")]) == "#"
expect expand("{.x}", [("x", "a.b c")]) == ".a.b%20c"
expect expand("{.x}", [("x", "")]) == "."
expect expand("{/x}", [("x", "a/b c")]) == "/a%2Fb%20c"
expect expand("{/x}", [("x", "")]) == "/"
expect expand("{?x}", [("x", "1 2")]) == "?x=1%202"
expect expand("{?x}", [("x", "")]) == "?x="
expect expand("{?x}", []) == ""
expect expand("{&x}", [("x", "v")]) == "&x=v"
expect expand("{?a,b,c}", [("a", "1"), ("c", "3")]) == "?a=1&c=3"
expect expand("{?a,b}", []) == ""
expect expand("/p{?a}{&b}", [("a", "1"), ("b", "2")]) == "/p?a=1&b=2"
expect expand("/p{?a}{&b}", [("b", "2")]) == "/p&b=2"
expect expand("/p{?a}{?b}", [("a", "1"), ("b", "2")]) == "/p?a=1&b=2"
expect expand("/p{&a}{&b}", [("a", "1"), ("b", "2")]) == "/p&a=1&b=2"
expect expand("/p{&a}{?b}", [("a", "1"), ("b", "2")]) == "/p&a=1&b=2"
expect expand("{?a}{?b}{?c}", [("a", "1"), ("c", "3")]) == "?a=1&c=3"
expect expand("{?a}x{?b}", [("a", "1"), ("b", "2")]) == "?a=1x&b=2"
expect expand("{?a}{?b}", [("a", ""), ("b", "?")]) == "?a=&b=%3F"
expect expand("{a,b}", [("a", "x y"), ("b", "/")]) == "x y,/"
expect expand("{/a,b}", [("a", "1"), ("b", "2")]) == "1,2"
expect expand("{.a,b}", [("b", "2")]) == "2"
expect expand("{#a,b}", [("a", "1"), ("b", "2")]) == "1,2"
expect expand("{a,b}", []) == ""
expect expand("{a,b}", [("a", ""), ("b", "")]) == ","
expect expand("{x*}", [("x", "a,b")]) == "a%2Cb"
expect expand("{/x*}", [("x", "a,b")]) == "/a%2Cb"
expect expand("{x}", [("x", "unreserved-_.!~*'()")]) == "unreserved-_.!~*'()"
expect expand("{+x}", [("x", ";,/?:@&=+\$#")]) == ";,/?:@&=+\$#"
expect expand("{x}", [("x", ";,/?:@&=+\$#")]) == "%3B%2C%2F%3F%3A%40%26%3D%2B%24%23"
expect expand("{x}", [("x", "caf\u(E9) \u(1F426) \u(20AC)")]) == "caf%C3%A9%20%F0%9F%90%A6%20%E2%82%AC"
expect expand("{+x}", [("x", "caf\u(E9) [x] {y} |")]) == "caf%C3%A9%20%5Bx%5D%20%7By%7D%20%7C"
expect expand("{x}", [("x", "[]{}|^`\"<>\\")]) == "%5B%5D%7B%7D%7C%5E%60%22%3C%3E%5C"
expect expand("{x}", [("x", "\n\t\u(0)\u(7F)")]) == "%0A%09%00%7F"
expect expand("{x}", [("x", "%41")]) == "%2541"
expect expand("{+x}", [("x", "%41")]) == "%2541"
expect expand("{x:3}", [("x:3", "abcdef")]) == "abcdef"
expect expand("{x:3}", [("x", "abcdef")]) == ""
expect expand("{a**}", [("a*", "v")]) == "v"
expect expand("{a**}", [("a", "v")]) == ""
expect expand("{}", [("x", "v")]) == ""
expect expand("{x}/{x}", [("x", "v")]) == "v/v"
expect expand("{?x*}", [("x", "a,b")]) == "?x=a%2Cb"
expect expand("{x}", [("x", "1"), ("y", "2")]) == "1"
expect expand("roc-syntax://topic/{name}", [("name", "strings")]) == "roc-syntax://topic/strings"
expect expand("roc-syntax://platform/{platform}/example/{name}", [("platform", "basic-cli"), ("name", "hello world")]) == "roc-syntax://platform/basic-cli/example/hello%20world"
expect expand("roc-syntax://package/{package}", [("package", "roc-parser")]) == "roc-syntax://package/roc-parser"
expect expand("roc-syntax://package/{package}/example/{name}", [("package", "p"), ("name", "a/b")]) == "roc-syntax://package/p/example/a%2Fb"
expect expand("roc-syntax://platform/{platform}/doc/{name}", [("platform", "joy"), ("name", "Html")]) == "roc-syntax://platform/joy/doc/Html"

# match
expect matched("{x}", "hello") == Ok([("x", ["hello"])])
expect matched("{x}", "") == Err(NoMatch)
expect matched("{x}", "a/b") == Err(NoMatch)
expect matched("{x}", "a,b") == Err(NoMatch)
expect matched("{x}", "a b") == Ok([("x", ["a b"])])
expect matched("{x}", "%20") == Ok([("x", ["%20"])])
expect matched("{x}", "caf\u(E9)") == Ok([("x", ["caf\u(E9)"])])
expect matched("{x}", "a\nb") == Ok([("x", ["a\nb"])])
expect matched("{x}", "a?b#c") == Ok([("x", ["a?b#c"])])
expect matched("/users/{id}", "/users/42") == Ok([("id", ["42"])])
expect matched("/users/{id}", "/users/") == Err(NoMatch)
expect matched("/users/{id}", "/users/42/") == Err(NoMatch)
expect matched("/users/{id}", "/users/4,2") == Err(NoMatch)
expect matched("/users/{id}", "users/42") == Err(NoMatch)
expect matched("/users/{id}", "/users/42?x=1") == Ok([("id", ["42?x=1"])])
expect matched("{+x}", "a/b/c") == Ok([("x", ["a/b/c"])])
expect matched("{+x}", "") == Err(NoMatch)
expect matched("{+x}", "a,b") == Ok([("x", ["a,b"])])
expect matched("{+x}", "a\nb") == Err(NoMatch)
expect matched("{+x}", "a\u(2028)b") == Err(NoMatch)
expect matched("{+x}", "a\u(2029)b") == Err(NoMatch)
expect matched("{+x}", "a\rb") == Err(NoMatch)
expect matched("{+x}", "\u(1F426)") == Ok([("x", ["\u(1F426)"])])
expect matched("{+x}", "\u(2027)") == Ok([("x", ["\u(2027)"])])
expect matched("{#x}", "#frag") == Ok([("x", ["#frag"])])
expect matched("{#x}", "frag") == Ok([("x", ["frag"])])
expect matched("{#x}", "a/b") == Ok([("x", ["a/b"])])
expect matched("/p{#x}", "/p#frag") == Ok([("x", ["#frag"])])
expect matched("/p{#x}", "/pfrag") == Ok([("x", ["frag"])])
expect matched("/p{#x}", "/p") == Err(NoMatch)
expect matched("{.x}", ".json") == Ok([("x", ["json"])])
expect matched("{.x}", "json") == Err(NoMatch)
expect matched("{.x}", ".a.b") == Ok([("x", ["a.b"])])
expect matched("{.x}", ".a,b") == Err(NoMatch)
expect matched("{.x}", ".") == Err(NoMatch)
expect matched("{.x}", "./x") == Err(NoMatch)
expect matched("file{.ext}", "file.txt") == Ok([("ext", ["txt"])])
expect matched("file{.ext}", "file.tar.gz") == Ok([("ext", ["tar.gz"])])
expect matched("file{.ext}", "file") == Err(NoMatch)
expect matched("file{.ext}", "file.") == Err(NoMatch)
expect matched("{/x}", "/a") == Ok([("x", ["a"])])
expect matched("{/x}", "a") == Err(NoMatch)
expect matched("{/x}", "/a/b") == Err(NoMatch)
expect matched("{/x}", "/a,b") == Err(NoMatch)
expect matched("{/x}", "/") == Err(NoMatch)
expect matched("{/x*}", "/a") == Ok([("x", ["a"])])
expect matched("{/x*}", "/a,b") == Ok([("x", ["a", "b"])])
expect matched("{/x*}", "/a,,b") == Err(NoMatch)
expect matched("{/x*}", "/a,") == Err(NoMatch)
expect matched("{/x*}", "/,a") == Err(NoMatch)
expect matched("{/x*}", "/a/b") == Err(NoMatch)
expect matched("{x*}", "a") == Ok([("x", ["a"])])
expect matched("{x*}", "a,b,c") == Ok([("x", ["a", "b", "c"])])
expect matched("{x*}", "a,") == Err(NoMatch)
expect matched("{x*}", ",a") == Err(NoMatch)
expect matched("{x*}", "a,,b") == Err(NoMatch)
expect matched("{x*}", "a/b") == Err(NoMatch)
expect matched("{x*}", "a,b/c") == Err(NoMatch)
expect matched("{+x*}", "a,b/c") == Ok([("x", ["a", "b/c"])])
expect matched("{+x*}", "a") == Ok([("x", ["a"])])
expect matched("{+x*}", ",") == Ok([("x", ["", ""])])
expect matched("{+x*}", "a,,b") == Ok([("x", ["a", "", "b"])])
expect matched("{#x*}", "a,b") == Ok([("x", ["a", "b"])])
expect matched("{#x*}", "#a,b") == Ok([("x", ["#a", "b"])])
expect matched("{.x*}", ".a") == Ok([("x", ["a"])])
expect matched("{.x*}", ".a,b") == Err(NoMatch)
expect matched("{?x}", "?x=1") == Ok([("x", ["1"])])
expect matched("{?x}", "?x=") == Err(NoMatch)
expect matched("{?x}", "?x=1&y=2") == Err(NoMatch)
expect matched("{?x}", "?y=1") == Err(NoMatch)
expect matched("{?x}", "x=1") == Err(NoMatch)
expect matched("{?x}", "?x=a=b") == Ok([("x", ["a=b"])])
expect matched("{?x}", "?x=1,2") == Ok([("x", ["1,2"])])
expect matched("{?x}", "?x=a/b#c") == Ok([("x", ["a/b#c"])])
expect matched("{?x*}", "?x=1,2") == Ok([("x", ["1", "2"])])
expect matched("{?x*}", "?x=1") == Ok([("x", ["1"])])
expect matched("{&x}", "&x=1") == Ok([("x", ["1"])])
expect matched("{&x}", "?x=1") == Err(NoMatch)
expect matched("/s{?q,page}", "/s?q=roc&page=2") == Ok([("q", ["roc"]), ("page", ["2"])])
expect matched("/s{?q,page}", "/s?q=roc") == Err(NoMatch)
expect matched("/s{?q,page}", "/s?page=2&q=roc") == Err(NoMatch)
expect matched("/s{?q,page}", "/s?q=a&b&page=2") == Err(NoMatch)
expect matched("/s{?q}{&page}", "/s?q=roc&page=2") == Ok([("q", ["roc"]), ("page", ["2"])])
expect matched("/s{?q}{&page}", "/s?q=roc") == Err(NoMatch)
expect matched("/s{?q,page*}", "/s?q=roc&page=1,2") == Ok([("q", ["roc"]), ("page", ["1", "2"])])
expect matched("{a,b}", "x") == Ok([("a", ["x"])])
expect matched("{a,b}", "x,y") == Err(NoMatch)
expect matched("{a,b}", "x/y") == Err(NoMatch)
expect matched("{/a,b}", "/x") == Ok([("a", ["x"])])
expect matched("{/a,b}", "/x/y") == Err(NoMatch)
expect matched("{?a,b}{?c}", "?a=1&b=2?c=3") == Ok([("a", ["1"]), ("b", ["2"]), ("c", ["3"])])
expect matched("{a}{b}", "xy") == Ok([("a", ["x"]), ("b", ["y"])])
expect matched("{a}{b}", "x") == Err(NoMatch)
expect matched("{a}{b}", "xyz") == Ok([("a", ["xy"]), ("b", ["z"])])
expect matched("{a}{b}", "caf\u(E9)") == Ok([("a", ["caf"]), ("b", ["\u(E9)"])])
expect matched("{a}{b}", "\u(E9)") == Err(NoMatch)
expect matched("{a}{b}", "a\u(E9)") == Ok([("a", ["a"]), ("b", ["\u(E9)"])])
expect matched("{a}.{b}", "x.y") == Ok([("a", ["x"]), ("b", ["y"])])
expect matched("{a}.{b}", "x.y.z") == Ok([("a", ["x.y"]), ("b", ["z"])])
expect matched("{a}.{b}", "x.") == Err(NoMatch)
expect matched("{a}.{b}", ".y") == Err(NoMatch)
expect matched("{+a}/{b}", "x/y/z") == Ok([("a", ["x/y"]), ("b", ["z"])])
expect matched("{+a}/{b}", "x/y") == Ok([("a", ["x"]), ("b", ["y"])])
expect matched("{+a}/{b}", "/y") == Err(NoMatch)
expect matched("{a}/{+b}", "x/y/z") == Ok([("a", ["x"]), ("b", ["y/z"])])
expect matched("{+a}{+b}", "xyz") == Ok([("a", ["xy"]), ("b", ["z"])])
expect matched("{x*}{y}", "a,b") == Err(NoMatch)
expect matched("{x*}{y}", "ab,cd") == Ok([("x", ["ab", "c"]), ("y", ["d"])])
expect matched("{x*},{y}", "a,b,c") == Ok([("x", ["a", "b"]), ("y", ["c"])])
expect matched("{x}/{x}", "a/b") == Ok([("x", ["b"])])
expect matched("{a**}", "v") == Ok([("a", ["v"])])
expect matched("{a**}", "v,w") == Ok([("a", ["v", "w"])])
expect matched("{x:3}", "abc") == Ok([("x:3", ["abc"])])
expect matched("{x:3}", "abcdef") == Ok([("x:3", ["abcdef"])])
expect matched("a.b*c(d)[e]^\$|{x}", "a.b*c(d)[e]^\$|v") == Ok([("x", ["v"])])
expect matched("a.b*c(d)[e]^\$|{x}", "aXb*c(d)[e]^\$|v") == Err(NoMatch)
expect matched("", "") == Ok([])
expect matched("", "x") == Err(NoMatch)
expect matched("plain", "plain") == Ok([])
expect matched("plain", "plainx") == Err(NoMatch)
expect matched("{}", "") == Err(NoMatch)
expect matched("{}", "x") == Err(NoMatch)
# ^ JS throws "Cannot read properties of undefined (reading 'replace')"; we answer NoMatch.
expect matched("{?}", "") == Ok([])
expect matched("{?}", "?") == Err(NoMatch)
expect matched("{,}", "x") == Err(NoMatch)
# ^ JS throws "Cannot read properties of undefined (reading 'replace')"; we answer NoMatch.
expect matched("roc-syntax://topic/{name}", "roc-syntax://topic/strings") == Ok([("name", ["strings"])])
expect matched("roc-syntax://topic/{name}", "roc-syntax://topic/a%20b") == Ok([("name", ["a%20b"])])
expect matched("roc-syntax://topic/{name}", "roc-syntax://topic/a/b") == Err(NoMatch)
expect matched("roc-syntax://topic/{name}", "roc-syntax://topic/") == Err(NoMatch)
expect matched("roc-syntax://topic/{name}", "roc-syntax://topic/x,y") == Err(NoMatch)
expect matched("roc-syntax://topic/{name}", "roc-syntax://topic/x?y=1") == Ok([("name", ["x?y=1"])])
expect matched("roc-syntax://platform/{platform}/example/{name}", "roc-syntax://platform/basic-cli/example/hello") == Ok([("platform", ["basic-cli"]), ("name", ["hello"])])
expect matched("roc-syntax://platform/{platform}/example/{name}", "roc-syntax://platform/basic-cli/example/") == Err(NoMatch)
expect matched("roc-syntax://platform/{platform}/example/{name}", "roc-syntax://platform//example/hello") == Err(NoMatch)
expect matched("roc-syntax://platform/{platform}/example/{name}", "roc-syntax://platform/a/b/example/hello") == Err(NoMatch)
expect matched("roc-syntax://package/{package}", "roc-syntax://package/roc-parser") == Ok([("package", ["roc-parser"])])
expect matched("roc-syntax://package/{package}", "roc-syntax://package/roc-parser/example/x") == Err(NoMatch)
expect matched("roc-syntax://package/{package}/example/{name}", "roc-syntax://package/roc-parser/example/csv") == Ok([("package", ["roc-parser"]), ("name", ["csv"])])
expect matched("roc-syntax://package/{package}/example/{name}", "roc-syntax://package/roc-parser/example/a.b") == Ok([("package", ["roc-parser"]), ("name", ["a.b"])])
expect matched("roc-syntax://platform/{platform}/doc/{name}", "roc-syntax://platform/joy/doc/Html") == Ok([("platform", ["joy"]), ("name", ["Html"])])
expect matched("roc-syntax://platform/{platform}/doc/{name}", "roc-syntax://platform/joy/doc/Html.Attr") == Ok([("platform", ["joy"]), ("name", ["Html.Attr"])])
expect matched("roc-syntax://platform/{platform}/doc/{name}", "roc-syntax://platform/joy/docs/Html") == Err(NoMatch)

# limits (JS: max 10000 expressions, max 1000000 UTF-16 code units)
expect names("{x}".repeat(10000)).map_ok(|l| l.len()) == Ok(10000)
expect names("{x}".repeat(10001)) == Err(InvalidTemplate("Template contains too many expressions (max 10000)"))
expect names("a".repeat(1000000)) == Ok([])
expect names("a".repeat(1000001)) == Err(InvalidTemplate("Template exceeds maximum length of 1000000 characters (got 1000001)"))
expect names("\u(1F426)".repeat(500000)) == Ok([])
expect names("\u(1F426)".repeat(500001)) == Err(InvalidTemplate("Template exceeds maximum length of 1000000 characters (got 1000002)"))

# to_str and Vars accessors
expect UriTemplate.parse("a{/b*}{?c}").map_ok(|t| t.to_str()) == Ok("a{/b*}{?c}")

vars : Str, Str -> Try(UriTemplate.Vars, [NoMatch, Invalid])
vars = |t, uri|
	match UriTemplate.parse(t) {
		Ok(x) => x.match_uri(uri).map_err(|_| NoMatch)
		Err(_) => Err(Invalid)
	}

expect vars("{/x*}{?q}", "/a,b?q=1").map_ok(|v| v.get("x")) == Ok(Ok("a"))
expect vars("{/x*}{?q}", "/a,b?q=1").map_ok(|v| v.get_all("x")) == Ok(["a", "b"])
expect vars("{/x*}{?q}", "/a,b?q=1").map_ok(|v| v.get("q")) == Ok(Ok("1"))
expect vars("{/x*}{?q}", "/a,b?q=1").map_ok(|v| v.get("nope")) == Ok(Err(Missing))
expect vars("{/x*}{?q}", "/a,b?q=1").map_ok(|v| v.get_all("nope")) == Ok([])
