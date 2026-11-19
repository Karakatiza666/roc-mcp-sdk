// The behavioural twin of examples/everything.roc on the JS SDK (@modelcontextprotocol/server
// 2.0.0). tests/e2e/js/gen.sh runs it on each tests/e2e/*.in.jsonl to make the expected
// *.out.jsonl. Keep the two servers in step: same names, texts, schemas and state.
//
// The SDK comes from an existing node_modules (no package.json here):
// MCP_JS_NODE_MODULES, default ../roc-syntax-mcp/node_modules next to this repository.
import * as path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const NM = process.env.MCP_JS_NODE_MODULES ?? path.resolve(here, "../../../../roc-syntax-mcp/node_modules");
const load = (p) => import(pathToFileURL(path.join(NM, p)).href);

const { McpServer, ResourceTemplate, ResourceNotFoundError, completable, inputRequired } = await load(
	"@modelcontextprotocol/server/dist/index.mjs",
);
const { serveStdio } = await load("@modelcontextprotocol/server/dist/stdio.mjs");
const { z } = await load("zod/index.js");

// The app state (State in everything.roc).
const state = { count: 0, toolCalls: 0, pokes: 0, unlocked: false, roots: null, subscribed: [] };
const notes = ["alpha", "beta", "gamma"];
const styles = ["casual", "formal"];
const text = (t) => ({ content: [{ type: "text", text: t }] });
const error = (t) => ({ content: [{ type: "text", text: t }], isError: true });

// serveStdio picks the era from the first message and builds one server per connection (a
// server/discover probe instance is replaced when the client falls back to initialize). The
// state above is shared, as in the Roc app.
function makeServer() {
const server = new McpServer(
	{ name: "everything", version: "1.0.0", title: "Everything" },
	{ capabilities: { logging: {} }, instructions: "Exercises every feature of the SDK." },
);
// The client capabilities: initialize's (2025), or the request envelope's (2026-07-28; on
// stdio JS does not copy them into getClientCapabilities()).
const clientCaps = (ctx) => ctx.mcpReq.envelope?.["io.modelcontextprotocol/clientCapabilities"] ?? server.server.getClientCapabilities();

// The middleware (around_tools count_calls!): counts every handler run.
const counted = (cb) => (...args) => {
	state.toolCalls += 1;
	return cb(...args);
};

server.registerTool(
	"echo",
	{
		description: "Echo text, optionally repeated",
		inputSchema: z.object({ text: z.string().describe("Text to echo"), times: z.number().optional() }),
		annotations: { readOnlyHint: true },
	},
	counted(({ text: t, times }) => text(Array(times ?? 1).fill(t).join(" "))),
);

server.registerTool(
	"add",
	{
		description: "Add two integers",
		inputSchema: z.object({ a: z.number(), b: z.number() }),
		outputSchema: z.object({ sum: z.number() }),
	},
	counted(({ a, b }) => {
		if (!Number.isInteger(a) || !Number.isInteger(b)) return error("a and b must be integers");
		const sum = a + b;
		return { content: [{ type: "text", text: String(sum) }], structuredContent: { sum } };
	}),
);

server.registerTool(
	"counter",
	{ description: "Count calls" },
	counted(() => {
		state.count += 1;
		return text(`count: ${state.count}`);
	}),
);

// unlock enables `secret`; enable() sends notifications/tools/list_changed (Ctx.list_changed! in Roc).
let secret;
server.registerTool(
	"unlock",
	{ description: "Enable the secret tool" },
	counted(() => {
		state.unlocked = true;
		secret.enable();
		return text("unlocked");
	}),
);
secret = server.registerTool("secret", { description: "Listed once unlocked" }, counted(() => text("the secret is 42")));
secret.disable();

server.registerTool("fail", { description: "Always fails" }, counted(() => error("it failed")));

server.registerTool(
	"log_levels",
	{ description: "Log at four levels" },
	counted(async (ctx) => {
		await ctx.mcpReq.log("debug", "debug line");
		await ctx.mcpReq.log("info", "info line");
		await ctx.mcpReq.log("warning", "warning line");
		await ctx.mcpReq.log("error", { detail: "error line" });
		return text("logged");
	}),
);

server.registerTool(
	"slow",
	{ description: "Report progress", inputSchema: z.object({ steps: z.number() }) },
	counted(async ({ steps }, ctx) => {
		const progressToken = ctx.mcpReq._meta?.progressToken;
		for (let i = 1; i <= steps; i++) {
			if (progressToken !== undefined)
				await ctx.mcpReq.notify({
					method: "notifications/progress",
					params: { progressToken, progress: i, total: steps, message: `step ${i}` },
				});
		}
		return text(`done ${steps} steps`);
	}),
);

server.registerTool(
	"roots",
	{ description: "Ask the client for its roots" },
	counted((ctx) => {
		if (state.roots !== null) return text(`cached roots: ${state.roots.join(", ")}`);
		if (!clientCaps(ctx)?.roots) return text("no roots capability");
		const answer = ctx.mcpReq.inputResponses?.roots;
		if (answer === undefined) return inputRequired({ inputRequests: { roots: inputRequired.listRoots() } });
		if (!Array.isArray(answer.roots)) return error("bad roots answer: roots is not an array");
		state.roots = answer.roots.map((r) => r.uri);
		return text(`roots: ${state.roots.join(", ")}`);
	}),
);

server.registerTool(
	"confirm",
	{ description: "Ask the user to confirm" },
	counted((ctx) => {
		const answer = ctx.mcpReq.inputResponses?.confirm;
		if (answer === undefined)
			return inputRequired({
				inputRequests: {
					confirm: inputRequired.elicit({
						message: "Proceed?",
						requestedSchema: { type: "object", properties: { ok: { type: "boolean" } }, required: ["ok"] },
					}),
				},
			});
		switch (answer.action) {
			case "accept":
				return text(`accepted: ok=${JSON.stringify(answer.content?.ok ?? null)}`);
			case "decline":
				return text("declined");
			case "cancel":
				return text("cancelled");
			default:
				return text(`bad answer: unknown action: ${answer.action}`);
		}
	}),
);

server.registerTool(
	"touch",
	{ description: "Notify subscribers" },
	counted(async () => {
		for (const uri of state.subscribed) await server.server.sendResourceUpdated({ uri });
		return text(`touched ${state.subscribed.length}`);
	}),
);

// Resources.
server.registerResource("info", "info://server", { title: "Server info", mimeType: "text/plain" }, (uri) => ({
	contents: [{ uri: uri.href, mimeType: "text/plain", text: "everything server" }],
}));
server.registerResource("stats", "info://stats", { mimeType: "application/json" }, (uri) => ({
	contents: [{ uri: uri.href, mimeType: "application/json", text: JSON.stringify(stats()) }],
}));
server.registerResource(
	"note",
	new ResourceTemplate("note://{name}", {
		list: () => ({ resources: notes.map((n) => ({ uri: `note://${n}`, name: n })) }),
		complete: { name: (v) => notes.filter((n) => n.startsWith(v)) },
	}),
	{ description: "A note", mimeType: "text/plain" },
	(uri, vars) => {
		const name = Array.isArray(vars.name) ? vars.name[0] : vars.name;
		if (!notes.includes(name)) throw new ResourceNotFoundError(uri.href);
		return { contents: [{ uri: uri.href, mimeType: "text/plain", text: `note ${name}` }] };
	},
);
server.registerResource("file", new ResourceTemplate("file:///{+path}", { list: undefined }), {}, (uri, vars) => ({
	contents: [{ uri: uri.href, mimeType: "text/plain", text: `path=${vars.path}` }],
}));

// resources/subscribe (Server.on_subscribe in Roc; JS has no built-in handler).
server.server.registerCapabilities({ resources: { subscribe: true } });
server.server.setRequestHandler("resources/subscribe", (req) => {
	const uri = req.params.uri;
	if (!state.subscribed.includes(uri)) state.subscribed.push(uri);
	return {};
});
server.server.setRequestHandler("resources/unsubscribe", (req) => {
	state.subscribed = state.subscribed.filter((u) => u !== req.params.uri);
	return {};
});

// Prompts.
server.registerPrompt(
	"greet",
	{
		title: "Greeting",
		description: "Greet someone",
		argsSchema: z.object({
			name: z.string().describe("Who to greet"),
			style: completable(z.string(), (v, context) =>
				(context?.arguments?.name === "Bob" ? ["formal"] : styles).filter((s) => s.startsWith(v)),
			).optional(),
		}),
	},
	({ name, style }) => ({
		description: "A greeting",
		messages: [{ role: "user", content: { type: "text", text: style === "formal" ? `Good day, ${name}.` : `Hi ${name}!` } }],
	}),
);

server.server.setRequestHandler("everything/stats", { params: z.any() }, () => stats());
server.server.setNotificationHandler("everything/poke", { params: z.any() }, () => {
	state.pokes += 1;
});
server.server.setNotificationHandler("notifications/roots/list_changed", () => {
	state.roots = null;
});

return server;
}

function stats() {
	return { count: state.count, toolCalls: state.toolCalls, pokes: state.pokes };
}

const handle = serveStdio(makeServer, { onerror: (e) => console.error(String(e)) });
// The Roc server ends at stdin EOF and closes gracefully (Engine.close: the final
// subscriptions/listen results). JS does not watch EOF, so the twin closes here.
process.stdin.on("end", () => handle.close());
