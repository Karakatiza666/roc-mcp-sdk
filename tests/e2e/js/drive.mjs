// Feeds one transcript to the JS twin, a line at a time, and prints its stdout.
// Usage: node drive.mjs <transcript.in.jsonl> [pace_ms]
//
// - Lines starting with `#` and empty lines are comments, as in scripts/e2e.sh.
// - The JS SDK answers asynchronously, so the lines are paced (default 150 ms): a client
//   answer must not reach the server before the server has sent the request it answers.
// - Server-to-client request ids: the Roc engine sends "mcp-sdk-<n>", the JS SDK sends the
//   integer <n> (the same counter, from 0). The transcripts use the Roc ids. This driver
//   rewrites them to integers on the way in and back to "mcp-sdk-<n>" on the way out
//   (ALLOWED_DIFFS.md, "request ids").
// - At the end stdin is closed. JS does not stop on EOF (DESIGN 4.7), so the twin is killed
//   after a grace period.
import { spawn } from "node:child_process";
import * as fs from "node:fs";
import * as path from "node:path";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const [transcript, paceArg] = process.argv.slice(2);
const pace = Number(paceArg ?? 150);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const ROC_ID = /^mcp-sdk-(\d+)$/;

const lines = fs
	.readFileSync(transcript, "utf8")
	.split("\n")
	.filter((l) => l.trim() !== "" && !l.startsWith("#"));

function toJs(line) {
	let msg;
	try {
		msg = JSON.parse(line);
	} catch {
		return line;
	}
	// A client response to a server request.
	if (msg && typeof msg === "object" && !("method" in msg) && typeof msg.id === "string") {
		const m = ROC_ID.exec(msg.id);
		if (m) return JSON.stringify({ ...msg, id: Number(m[1]) });
	}
	return line;
}

function fromJs(line) {
	let msg;
	try {
		msg = JSON.parse(line);
	} catch {
		return line;
	}
	if (msg && typeof msg === "object" && "method" in msg) {
		if (typeof msg.id === "number") msg = { ...msg, id: `mcp-sdk-${msg.id}` };
		if (msg.method === "notifications/cancelled" && typeof msg.params?.requestId === "number")
			msg = { ...msg, params: { ...msg.params, requestId: `mcp-sdk-${msg.params.requestId}` } };
	}
	return JSON.stringify(msg);
}

const child = spawn(process.execPath, [path.join(here, "everything.mjs")], { stdio: ["pipe", "pipe", "inherit"] });
let out = "";
child.stdout.setEncoding("utf8");
child.stdout.on("data", (d) => (out += d));
const exited = new Promise((r) => child.on("exit", r));

await sleep(500); // module loading
for (const line of lines) {
	child.stdin.write(toJs(line) + "\n");
	await sleep(pace);
}
child.stdin.end();
const done = await Promise.race([exited.then(() => true), sleep(1000).then(() => false)]);
if (!done) child.kill("SIGTERM");
await exited;

for (const line of out.split("\n")) if (line.trim() !== "") process.stdout.write(fromJs(line) + "\n");
