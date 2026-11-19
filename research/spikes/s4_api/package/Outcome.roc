import Input
import McpError

## What a tools/call, prompts/get or resources/read handler returns.
Outcome(a) := [Done(a), NeedInput(Input.Required), Fail(McpError)].{
	done : a -> Outcome(a)
	done = |a| Done(a)

	need_input : Input.Required -> Outcome(a)
	need_input = |r| NeedInput(r)

	fail : McpError -> Outcome(a)
	fail = |e| Fail(e)

	map : Outcome(a), (a -> b) -> Outcome(b)
	map = |o, f| match o {
		Done(a) => Done(f(a))
		NeedInput(r) => NeedInput(r)
		Fail(e) => Fail(e)
	}
}
