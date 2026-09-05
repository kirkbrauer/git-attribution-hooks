import assert from "node:assert/strict";
import { test } from "node:test";
import { mkdtempSync, readFileSync, writeFileSync, existsSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { spawnSync } from "node:child_process";
import extension from "../extensions/attribution.ts";

const root = resolve(import.meta.dirname, "..");
const work = mkdtempSync(join(tmpdir(), "gah-integrations-"));
process.on("exit", () => rmSync(work, { recursive: true, force: true }));
const env = { ...process.env, GIT_CONFIG_GLOBAL: "/dev/null", GIT_CONFIG_SYSTEM: "/dev/null" };
function run(command, args, options = {}) {
  const result = spawnSync(command, args, { cwd: work, env, encoding: "utf8", ...options });
  assert.equal(result.status, 0, result.stderr);
  return result.stdout;
}
run("git", ["init", "-q", work]);
const policy = (value) => run("git", ["config", "attribution.signoff", value]);
function guard(command, agent, extra = {}) {
  return run("sh", [join(root, "claude-code/block-dco-bypass.sh"), ...(agent ? [agent] : [])], {
    input: JSON.stringify({ cwd: work, tool_name: "Bash", tool_input: { command, timeout: 30 }, ...extra }),
  });
}

test("Claude and Codex share the bypass guard without executing the command", () => {
  policy("auto");
  for (const agent of [undefined, "codex"]) {
    for (const command of ["git push --no-verify", "git commit --no-verify", "git commit -n", "git -C other commit -nm msg"]) {
      assert.equal(JSON.parse(guard(command, agent)).hookSpecificOutput.permissionDecision, "deny");
    }
  }
  assert.equal(guard("git status"), "", "Claude must retain normal tool permissions");
  assert.equal(guard("git signoff --yes"), "", "auto policy allows repair");
  policy("human");
  assert.equal(JSON.parse(guard("git signoff --yes")).hookSpecificOutput.permissionDecision, "deny");
  assert.equal(JSON.parse(guard("git-signoff -y", "codex")).hookSpecificOutput.permissionDecision, "deny");
});

test("Codex transports the active model safely and preserves tool arguments", () => {
  policy("auto");
  const model = "model'; touch SHOULD_NOT_EXIST; #";
  const output = JSON.parse(guard('printf %s "$GIT_ATTRIBUTION_MODEL"', "codex", { model })).hookSpecificOutput;
  assert.equal(output.permissionDecision, "allow");
  assert.equal(output.updatedInput.timeout, 30);
  assert.equal(run("sh", ["-c", output.updatedInput.command]), model);
  assert.equal(existsSync(join(work, "SHOULD_NOT_EXIST")), false);
  const next = JSON.parse(guard('printf %s "$GIT_ATTRIBUTION_MODEL"', "codex", { model: "new-model" })).hookSpecificOutput;
  assert.equal(run("sh", ["-c", next.updatedInput.command]), "new-model");
});

test("Codex installer preserves settings, migrates legacy hook, handles quoted paths, and uninstalls", () => {
  const dir = join(work, "Codex user's settings");
  const installer = join(root, "codex/install-codex-hook.sh");
  run("sh", [installer, "--dir", dir]);
  const settings = join(dir, "hooks.json");
  const data = JSON.parse(readFileSync(settings, "utf8"));
  data.description = "keep me";
  data.hooks.PreToolUse[0].hooks.push({ type: "command", command: "echo unrelated" });
  // Model the original manually installed Claude-compatible guard.
  data.hooks.PreToolUse[0].hooks[0].command = data.hooks.PreToolUse[0].hooks[0].command.replace(/ codex$/, "");
  writeFileSync(settings, JSON.stringify(data));
  run("sh", [installer, "--dir", dir]);
  run("sh", [installer, "--dir", dir]);
  const updated = JSON.parse(readFileSync(settings, "utf8"));
  assert.equal(updated.description, "keep me");
  const commands = updated.hooks.PreToolUse.flatMap((group) => group.hooks.map((hook) => hook.command));
  assert.equal(commands.length, 2);
  const cmd = commands.find((command) => command.includes("block-dco-bypass.sh"));
  const result = JSON.parse(run("sh", ["-c", cmd], {
    input: JSON.stringify({ cwd: work, tool_name: "Bash", model: "gpt-test", tool_input: { command: "git status" } }),
  }));
  assert.match(result.hookSpecificOutput.updatedInput.command, /gpt-test/);
  assert.ok(existsSync(settings + ".bak"));
  run("sh", [installer, "--dir", dir, "--uninstall"]);
  const removed = JSON.parse(readFileSync(settings, "utf8"));
  assert.equal(removed.description, "keep me");
  assert.equal(removed.hooks.PreToolUse[0].hooks[0].command, "echo unrelated");
  assert.equal(existsSync(join(dir, "hooks/block-dco-bypass.sh")), false);
  writeFileSync(settings, "NOT JSON");
  const failed = spawnSync("sh", [installer, "--dir", dir], { env });
  assert.notEqual(failed.status, 0);
  assert.equal(readFileSync(settings, "utf8"), "NOT JSON");
  assert.equal(existsSync(join(dir, "hooks/block-dco-bypass.sh")), false);
});

test("Pi uses per-call model context, blocks bypasses, and leaves other tools alone", () => {
  policy("auto");
  const handlers = new Map();
  extension({ on: (event, handler) => handlers.set(event, handler) });
  const call = handlers.get("tool_call");
  const ctx = { cwd: work, model: { id: "claude-opus-test" } };
  const event = () => ({ toolName: "bash", input: { command: 'printf %s "$GIT_ATTRIBUTION_MODEL"' } });
  const first = event();
  assert.equal(call(first, ctx), undefined);
  assert.equal(run("sh", ["-c", first.input.command]), "claude-opus-test");
  ctx.model.id = "gpt-test'; echo not-executed; #";
  const second = event();
  call(second, ctx);
  assert.equal(run("sh", ["-c", second.input.command]), ctx.model.id);
  assert.equal(call({ toolName: "read", input: { path: "foo" } }, ctx), undefined);
  assert.equal(call({ toolName: "bash", input: { command: "git push --no-verify" } }, ctx).block, true);
  policy("human");
  assert.equal(call({ toolName: "bash", input: { command: "git signoff --yes" } }, ctx).block, true);
  const prompt = handlers.get("before_agent_start")({ systemPrompt: "original" }).systemPrompt;
  assert.ok(prompt.startsWith("original"));
  assert.match(prompt, /local push review is opt-in/);
});
