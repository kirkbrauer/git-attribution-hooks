#!/bin/sh
# PreToolUse/Bash hook: stop an agent from routing around the DCO sign-off gate.
#
# Blocks:
#   git push --no-verify      (skips the pre-push hook)
#   git commit --no-verify    (and its -n shorthand)
#   git signoff --yes         (skips the /dev/tty confirmation)
#
# You can still run any of these yourself with a leading ! in the prompt box.
# See https://github.com/kirkbrauer/git-attribution-hooks

cmd="$(jq -r '.tool_input.command // ""' 2>/dev/null)"
[ -n "$cmd" ] || exit 0

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
if printf '%s' "$cmd" | grep -qE 'git[[:space:]]+commit([[:space:]]+[^;&|]*)?[[:space:]]-[a-zA-Z]*n([[:space:]]|$)'; then
	deny "Blocked: 'git commit -n' is shorthand for --no-verify and skips the attribution hooks."
fi

# Whether an agent may apply a sign-off follows the repo's own policy, so
# `git config attribution.signoff human` tightens every layer at once:
# prepare-commit-msg stops signing, pre-push starts asking, and this hook
# stops the agent skipping the terminal prompt with --yes.
#
# Under the default (auto) an agent already signs at commit time, so blocking
# the same act afterwards would only prevent it repairing its own commits.
policy="$(git config --get attribution.signoff 2>/dev/null || echo auto)"

if [ "$policy" = "human" ]; then
	case "$cmd" in
	*git*signoff*--yes*|*git*signoff*' -y'*|*git-signoff*--yes*)
		deny "Blocked: attribution.signoff is 'human', so the DCO sign-off must be a human act. '--yes' skips the terminal confirmation. Ask the user to run 'git signoff' themselves after reviewing." ;;
	esac
fi

exit 0
