#!/bin/sh
# Shared Claude Code / Codex PreToolUse guard (also called by the Pi extension).
# Stop an agent from routing around the DCO sign-off gate.
#
# Blocks:
#   git push --no-verify      (skips the pre-push hook)
#   git commit --no-verify    (and its -n shorthand)
#   git signoff --yes         (skips the /dev/tty confirmation)
#
# You can still run any of these yourself with a leading ! in the prompt box.
# See https://github.com/kirkbrauer/git-attribution-hooks

input="$(cat)"
cmd="$(printf '%s' "$input" | jq -er '.tool_input.command | strings' 2>/dev/null)" || {
	echo 'Attribution guard: invalid input or missing jq; refusing tool call.' >&2
	exit 2
}
[ -n "$cmd" ] || exit 0
cwd="$(printf '%s' "$input" | jq -r '.cwd // ""')"
if [ -n "$cwd" ]; then
	cd "$cwd" || exit 2
fi

deny() {
	jq -n --arg reason "$1" '{
		hookSpecificOutput: {
			hookEventName: "PreToolUse",
			permissionDecision: "deny",
			permissionDecisionReason: $reason
		}
	}'
	exit 0
}

case "$cmd" in
*git*push*--no-verify*)
	deny "Blocked: 'git push --no-verify' skips the pre-push hook that keeps unsigned commits off protected branches. Push to a feature branch instead, or ask the user to run it themselves." ;;
esac

case "$cmd" in
*git*commit*--no-verify*)
	deny "Blocked: 'git commit --no-verify' skips the attribution hooks. Commit normally; the Assisted-by trailer is added for you." ;;
esac

# -n is the shorthand for git commit --no-verify.
if printf '%s' "$cmd" | grep -qE 'git([[:space:]]+[^;&|]+)?[[:space:]]+commit([[:space:]]+[^;&|]*)?[[:space:]]-[a-zA-Z]*n[a-zA-Z]*([[:space:]]|$)'; then
	deny "Blocked: 'git commit -n' is shorthand for --no-verify and skips the attribution hooks."
fi

# Whether an agent may apply a sign-off follows the repo's own policy, so
# `git config attribution.signoff human` withholds automatic certification,
# and this hook stops the agent skipping the terminal prompt with --yes.
# Push review is independent: PR/MR workflows do not need a local prompt.
#
# Under the default (auto) an agent already signs at commit time, so blocking
# the same act afterwards would only prevent it repairing its own commits.
policy="$(git config --get attribution.signoff 2>/dev/null || echo auto)"

if [ "$policy" = "human" ]; then
	case "$cmd" in
	*git*signoff*--yes*|*git*signoff*' -y'*)
		deny "Blocked: attribution.signoff is 'human', so the DCO sign-off must be a human act. '--yes' skips the terminal confirmation. Ask the user to run 'git signoff' themselves after reviewing." ;;
	esac
fi

# Codex displays updatedInput and includes it in the conversation. Only rewrite
# commands that may create a new commit; ordinary calls must succeed silently.
# This is deliberately a broad text match like the bypass checks above: it
# covers compound commands, Git options, and scripts containing git commit.
# Aliases/wrappers without these words retain native/trailer/config attribution.
# Codex supplies the active model in PreToolUse input. Preserve tool arguments
# and shell-quote metadata as data. Do not emit an allow decision for Claude:
# that would bypass its normal permissions. Claude uses trailer/config model
# information; Pi injects its own per-call context after calling this guard.
if [ "${1:-}" = codex ] &&
   [ "$(printf '%s' "$input" | jq -r '.tool_name // ""')" = Bash ]; then
	case "$cmd" in
	*git*commit*) ;;
	*) exit 0 ;;
	esac
	agent=codex
	printf '%s' "$input" | jq --arg agent "$agent" '{
		hookSpecificOutput: {
			hookEventName: "PreToolUse",
			permissionDecision: "allow",
			updatedInput: (.tool_input + {
				command: ("export GIT_ATTRIBUTION_AGENT=" + ($agent | @sh) +
					" GIT_ATTRIBUTION_MODEL=" + ((.model // "") | @sh) +
					"\n" + .tool_input.command)
			})
		}
	}'
fi

exit 0
