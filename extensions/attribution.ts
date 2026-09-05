/** Optional Pi adapter. Git hooks still need to be installed separately. */
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

const guard = fileURLToPath(new URL("../claude-code/block-dco-bypass.sh", import.meta.url));
const quote = (value: string) => `'${value.replaceAll("'", "'\\''")}'`;

export default function (pi: ExtensionAPI) {
	pi.on("before_agent_start", (event) => ({
		systemPrompt: event.systemPrompt + "\n\nGit attribution: commit and push normally on feature branches. " +
			"The installed Git hooks supply Assisted-by and apply the repository's sign-off policy. " +
			"Do not invent a model co-author, write a human sign-off, override Git identity, " +
			"or bypass hooks. Follow the user's PR/MR workflow; local push review is opt-in. " +
			"If a hook refuses an operation, report it to the user rather than working around it.",
	}));

	pi.on("tool_call", (event, ctx) => {
		if (event.toolName !== "bash" || typeof event.input.command !== "string") return;
		const command = event.input.command;
		// Reuse the same policy/matcher as Claude Code and Codex. No shell
		// evaluation here: the pending command is JSON data on stdin.
		const result = spawnSync("sh", [guard], {
			cwd: ctx.cwd,
			input: JSON.stringify({ cwd: ctx.cwd, tool_input: { command } }),
			encoding: "utf8",
			timeout: 10_000,
		});
		if (result.error || result.status !== 0) {
			return { block: true, reason: "Attribution guard failed: " +
				(result.error?.message || result.stderr || `exit ${result.status}`) };
		}
		if (result.stdout.trim()) {
			try {
				const output = JSON.parse(result.stdout).hookSpecificOutput;
				if (output?.permissionDecision === "deny") {
					return { block: true, reason: output.permissionDecisionReason };
				}
			} catch {
				return { block: true, reason: "Attribution guard returned invalid JSON" };
			}
		}
		// Per-call context handles /model, resume and older Pi releases without
		// native PI_MODEL. Do not mutate process.env: other sessions and user !
		// commands must not inherit a cached model from this adapter.
		event.input.command = `export GIT_ATTRIBUTION_AGENT=pi GIT_ATTRIBUTION_MODEL=${quote(ctx.model?.id ?? "")}\n${command}`;
	});
}
