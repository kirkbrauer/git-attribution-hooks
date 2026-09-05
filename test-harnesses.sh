#!/bin/sh
# Real Git tests, isolated from user settings and the invoking agent.
set -eu
src="$(cd "$(dirname "$0")" && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT HUP INT TERM
export GIT_CONFIG_GLOBAL="$work/global" GIT_CONFIG_SYSTEM=/dev/null
unset GIT_ATTRIBUTION_AGENT GIT_ATTRIBUTION_MODEL AI_AGENT CLAUDECODE CLAUDE_CODE_SESSION_ID \
 CODEX_SANDBOX CODEX_SESSION_ID CODEX_THREAD_ID PI_CODING_AGENT PI_SESSION_ID PI_MODEL \
 CURSOR_AGENT COPILOT_AGENT AIDER_CHAT GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL \
 GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL || true
export PATH="$src:$PATH"
git config --global user.name 'Test Person'
git config --global user.email 'personal@example.com'
git init -q -b main "$work/repo"
cd "$work/repo"
git config core.hooksPath "$src"
pass=0
check() {
 label="$1"; shift
 if "$@"; then pass=$((pass + 1)); echo "ok - $label"
 else echo "FAIL - $label"; exit 1; fi
}
has() { git log -1 --format=%B | grep -qxF "$1"; }
no_signoff() { ! git log -1 --format=%B | grep -qi '^Signed-off-by:'; }
commit() { git commit -q --allow-empty -m "$1"; }
reject() { if "$@" >"$work/error" 2>&1; then return 1; fi; }

for marker in CODEX_THREAD_ID CODEX_SESSION_ID CODEX_SANDBOX; do
 env "$marker=test" git commit -q --allow-empty -m "$marker"
 check "$marker automatically attributes a trailer-less commit" has 'Assisted-by: Codex'
done
for marker in PI_CODING_AGENT PI_SESSION_ID AI_AGENT; do
 env "$marker=pi" PI_MODEL=claude-sonnet-4-5 git commit -q --allow-empty -m "$marker"
 check "$marker identifies Pi, not the model provider" has 'Assisted-by: Pi:claude-sonnet-4-5'
done
PI_SESSION_ID=test PI_MODEL=gpt-5.1-codex commit 'changed model'
check 'Pi model changes are reflected on the next commit' has 'Assisted-by: Pi:gpt-5.1-codex'
git config --global attribution.pi.model stale-global
git config attribution.pi.model repo-fallback
PI_SESSION_ID='test' commit 'config fallback'
check 'repo model fallback overrides global model' has 'Assisted-by: Pi:repo-fallback'
PI_SESSION_ID=test PI_MODEL=active-model commit 'native beats fallback'
check 'active model overrides configured fallback' has 'Assisted-by: Pi:active-model'
GIT_ATTRIBUTION_AGENT=codex GIT_ATTRIBUTION_MODEL=explicit PI_SESSION_ID=test PI_MODEL=wrong commit 'explicit adapter'
check 'explicit adapter overrides inherited harness metadata' has 'Assisted-by: Codex:explicit'

for trailer in 'Codex (gpt-5.1-codex) <noreply@openai.com>' 'Codex gpt-5.1-codex <noreply@openai.com>' 'Codex gpt-5.1-codex <noreply@anthropic.com>'; do
 commit "model in trailer

Co-Authored-By: $trailer"
 check "qualified $trailer" has 'Assisted-by: Codex:gpt-5.1-codex'
done
commit 'Pi trailer

CO-AUTHORED-BY: Pi (gemini-2.5-pro) <pi@agents.invalid>   '
check 'Pi trailer supports any provider and trailing whitespace' has 'Assisted-by: Pi:gemini-2.5-pro'
PI_SESSION_ID=test PI_MODEL=new-model commit 'existing attribution

Assisted-by: Claude:claude-opus-4-5
Co-authored-by: Dana <dana@example.com>'
check 'explicit historical attribution is preserved' has 'Assisted-by: Claude:claude-opus-4-5'
check 'human co-authors remain credited' has 'Co-authored-by: Dana <dana@example.com>'
check 'session fallback does not duplicate explicit attribution' test "$(git log -1 --format=%B | grep -c '^Assisted-by:')" = 1
PI_SESSION_ID=test PI_MODEL=another git commit -q --amend --allow-empty --no-edit
check 'amend does not relabel earlier assistance' has 'Assisted-by: Claude:claude-opus-4-5'

GIT_ATTRIBUTION_AGENT=claude GIT_ATTRIBUTION_MODEL=claude-opus-5 commit 'bare attribution

Assisted-By: Claude'
check 'bare matching assistance gets the current model on new commits' has 'Assisted-by: Claude:claude-opus-5'
commit 'historical bare assistance

Assisted-by: Claude'
GIT_ATTRIBUTION_AGENT=claude GIT_ATTRIBUTION_MODEL=claude-opus-5 git commit -q --amend --allow-empty --no-edit
check 'historical bare assistance is not assigned a guessed version' has 'Assisted-by: Claude'

# Git identity: global personal -> conditional corporate -> local/worktree.
git config --file "$work/corporate" user.email 'corporate+git@example.com'
git config --global "includeIf.gitdir:$work/repo/.git.path" "$work/corporate"
commit 'conditional identity'
check 'includeIf supplies the corporate sign-off' has 'Signed-off-by: Test Person <corporate+git@example.com>'
check 'commit author follows the same config' test "$(git log -1 --format=%ae)" = 'corporate+git@example.com'
git config user.email local@example.com
commit 'local identity'
check 'repo-local identity overrides includeIf' has 'Signed-off-by: Test Person <local@example.com>'
git config extensions.worktreeConfig true
git config --worktree user.email worktree@example.com
commit 'worktree identity'
check 'worktree-specific identity is respected' has 'Signed-off-by: Test Person <worktree@example.com>'
git config --worktree --unset user.email
git config --unset user.email
GIT_AUTHOR_NAME=Dana GIT_AUTHOR_EMAIL=dana@example.com commit 'imported author

Signed-off-by: Dana <dana@example.com>'
check 'the signer is not the original author' has 'Signed-off-by: Test Person <corporate+git@example.com>'
check 'the original author is preserved' test "$(git log -1 --format=%ae)" = dana@example.com
git commit -q --amend --allow-empty --no-edit
check 'amend preserves the original author too' test "$(git log -1 --format=%ae)" = dana@example.com
check 'another sign-off does not suppress ours or cause duplicates' test "$(git log -1 --format=%B | grep -c '^Signed-off-by:')" = 2
check 'conflicting committer email is refused' reject env GIT_COMMITTER_EMAIL=personal@example.com git commit -q --allow-empty -m wrong
check 'identity failure is actionable' grep -q 'differs from user.email' "$work/error"

# Human policy applies to all native markers, and strips case variants.
git config attribution.signoff human
for marker in CODEX_THREAD_ID CODEX_SANDBOX CODEX_SESSION_ID PI_CODING_AGENT PI_SESSION_ID; do
 env "$marker=test" git commit -q --allow-empty -m "$marker

signed-off-by: Test Person <corporate+git@example.com>"
 check "$marker withholds/strips sign-off under human policy" no_signoff
 check "$marker cannot auto-certify under human policy" reject env "$marker=test" git signoff --yes
 git config attribution.push.agent deny
 check "$marker cannot push under deny policy" reject env "$marker=test" sh "$src/pre-push" </dev/null
 check 'push failed for agent policy' grep -q 'push refused' "$work/error"
 git config --unset attribution.push.agent
done
# rebase --signoff must use the configured certifier, not inherited overrides.
check 'git signoff pins the confirmed config identity' env GIT_COMMITTER_EMAIL=wrong@example.com git signoff --yes >"$work/signoff" 2>&1
check 'certification uses corporate identity' has 'Signed-off-by: Test Person <corporate+git@example.com>'
check 'rebase committer uses corporate identity' test "$(git log -1 --format=%ce)" = 'corporate+git@example.com'

# Only send the tip to the gate to keep the identity-switching fixtures out
# of scope. This is the exact stdin protocol used by a real Git push.
printf 'refs/heads/main %s refs/heads/main %s\n' "$(git rev-parse HEAD)" "$(git rev-parse HEAD^)" >"$work/refs"
check 'push gate matches a literal plus in corporate email' sh "$src/pre-push" <"$work/refs"
git config attribution.signoff auto
PI_SESSION_ID=test PI_MODEL=gpt-5 commit 'remote review default'
printf 'refs/heads/feature/test %s refs/heads/feature/test %s\n' "$(git rev-parse HEAD)" "$(git rev-parse HEAD^)" >"$work/refs"
check 'default assisted feature push never asks for local review' env PI_SESSION_ID=test sh "$src/pre-push" <"$work/refs"
git config attribution.push.confirm always
check 'local review remains an opt-in gate' reject sh "$src/pre-push" <"$work/refs"
check 'local review asks to review commits, not authorize a command' grep -q 'have not been reviewed' "$work/error"
git config attribution.push.confirm protected
check 'protected-only confirmation permits feature publication' sh "$src/pre-push" <"$work/refs"
git config attribution.push.requireSignature true
check 'sign-off cannot bypass the optional cryptographic signature gate' reject sh "$src/pre-push" <"$work/refs"
check 'missing signature is reported even with a DCO trailer' grep -q 'no valid signature' "$work/error"

echo "$pass harness/identity tests passed"
