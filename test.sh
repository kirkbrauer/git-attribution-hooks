#!/bin/sh
# Test suite for the prepare-commit-msg hook.
#
# Runs entirely inside a throwaway repo in a temp directory, with
# GIT_CONFIG_GLOBAL/GIT_CONFIG_SYSTEM neutered, so it never reads or writes
# your real git configuration.
#
# Usage: ./test.sh

set -eu

src_dir="$(cd "$(dirname "$0")" && pwd)"
hook="$src_dir/prepare-commit-msg"
[ -f "$hook" ] || { echo "cannot find $hook" >&2; exit 1; }

work="$(mktemp -d "${TMPDIR:-/tmp}/gah-test.XXXXXX")"
trap 'rm -rf "$work"' EXIT INT TERM

GIT_CONFIG_GLOBAL=/dev/null
GIT_CONFIG_SYSTEM=/dev/null
export GIT_CONFIG_GLOBAL GIT_CONFIG_SYSTEM

# These tests must decide for themselves whether a commit looks agent-driven,
# so clear anything the surrounding session may have set. (Running this suite
# from inside a coding agent would otherwise suppress every sign-off.)
unset GIT_ATTRIBUTION_AGENT AI_AGENT CLAUDECODE CLAUDE_CODE_SESSION_ID \
      CODEX_SANDBOX CODEX_SESSION_ID CODEX_THREAD_ID CURSOR_AGENT COPILOT_AGENT AIDER_CHAT \
      PI_CODING_AGENT PI_SESSION_ID PI_MODEL PI_PROVIDER GIT_ATTRIBUTION_MODEL \
      GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL || true

hooks_dir="$work/hooks"
mkdir -p "$hooks_dir"
for f in prepare-commit-msg pre-push; do
	cp "$src_dir/$f" "$hooks_dir/$f"
	chmod +x "$hooks_dir/$f"
done
PATH="$src_dir:$PATH"
export PATH

repo="$work/repo"
mkdir -p "$repo"
cd "$repo"
git init -q -b main .
git config core.hooksPath "$hooks_dir"
git config user.name "Test Person"
git config user.email "test@example.com"

pass=0
fail=0
seq_n=0

# commit_with <message> -- stages a unique file and commits the given message.
# Set AS_AGENT=1 to make the commit look agent-driven.
AS_AGENT=0
commit_with() {
	seq_n=$((seq_n + 1))
	echo "$seq_n" >"file$seq_n.txt"
	git add "file$seq_n.txt"
	if [ "$AS_AGENT" = "1" ]; then
		printf '%s\n' "$1" | AI_AGENT=test-agent git commit -q -F -
	else
		printf '%s\n' "$1" | git commit -q -F -
	fi
}

ok()   { pass=$((pass + 1)); echo "ok   - $1"; }
bad()  { fail=$((fail + 1)); echo "FAIL - $1"; }

# check <name> <message> <expected-full-message>
check() {
	_name="$1"
	commit_with "$2"
	_got="$(git log -1 --format=%B | sed -e :a -e '/^\n*$/{$d;N;ba' -e '}')"
	_want="$3"
	if [ "$_got" = "$_want" ]; then
		pass=$((pass + 1))
		echo "ok   - $_name"
	else
		fail=$((fail + 1))
		echo "FAIL - $_name"
		echo "  expected:"; printf '%s\n' "$_want" | sed 's/^/    | /'
		echo "  got:";      printf '%s\n' "$_got"  | sed 's/^/    | /'
	fi
}

SOB="Signed-off-by: Test Person <test@example.com>"

echo "# trailer rewriting"

check "claude opus, 1M context suffix dropped" \
"fix: a

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>" \
"fix: a

Assisted-by: Claude:claude-opus-5
$SOB"

check "claude sonnet" \
"fix: b

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>" \
"fix: b

Assisted-by: Claude:claude-sonnet-5
$SOB"

check "claude with no model in name collapses to agent only" \
"fix: c

Co-Authored-By: Claude <noreply@anthropic.com>" \
"fix: c

Assisted-by: Claude
$SOB"

check "claude code session-url trailer is stripped" \
"fix: c2

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01ABCDEF" \
"fix: c2

Assisted-by: Claude:claude-opus-5
$SOB"

check "session trailer stripped even with no co-author" \
"fix: c3

Claude-Session: https://claude.ai/code/session_01ABCDEF" \
"fix: c3

$SOB"

check "codex carries no model" \
"fix: d

Co-authored-by: Codex <noreply@openai.com>" \
"fix: d

Assisted-by: Codex
$SOB"

check "copilot bot address with numeric id" \
"fix: e

Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>" \
"fix: e

Assisted-by: Copilot
$SOB"

check "cursor agent" \
"fix: f

Co-authored-by: Cursor Agent <cursoragent@cursor.com>" \
"fix: f

Assisted-by: Cursor
$SOB"

check "aider takes the model from the parenthetical" \
"fix: g

Co-authored-by: aider (gpt-4o) <aider@aider.chat>" \
"fix: g

Assisted-by: aider:gpt-4o
$SOB"

check "human co-author untouched" \
"fix: h

Co-authored-by: Dana Lee <dana@example.com>" \
"fix: h

Co-authored-by: Dana Lee <dana@example.com>
$SOB"

check "several agents, each converted" \
"fix: i

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
Co-authored-by: Codex <noreply@openai.com>
Co-authored-by: Dana Lee <dana@example.com>" \
"fix: i

Assisted-by: Claude:claude-opus-5
Assisted-by: Codex
Co-authored-by: Dana Lee <dana@example.com>
$SOB"

check "already converted, unchanged and not double signed" \
"fix: j

Assisted-by: Claude:claude-opus-5
$SOB" \
"fix: j

Assisted-by: Claude:claude-opus-5
$SOB"

echo "# configuration"

git config attribution.codex.model "gpt-5.1-codex"
check "attribution.<agent>.model supplies a missing version" \
"fix: k

Co-authored-by: Codex <noreply@openai.com>" \
"fix: k

Assisted-by: Codex:gpt-5.1-codex
$SOB"
git config --unset attribution.codex.model

git config attribution.claude.model "should-not-win"
check "a derivable model beats the configured fallback" \
"fix: l

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>" \
"fix: l

Assisted-by: Claude:claude-opus-5
$SOB"
git config --unset attribution.claude.model

git config attribution.robo.match "@robo[.]example$"
git config attribution.robo.name "RoboCoder"
git config attribution.robo.model "r1"
check "an unknown agent can be registered from config" \
"fix: m

Co-authored-by: Robo <bot@robo.example>" \
"fix: m

Assisted-by: RoboCoder:r1
$SOB"
git config --remove-section attribution.robo

echo "# sign-off"

git config user.email "repo-local@example.com"
check "sign-off follows the repo-local identity" \
"fix: n" \
"fix: n

Signed-off-by: Test Person <repo-local@example.com>"
git config user.email "test@example.com"

echo "# git plumbing"

commit_with "fix: o

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
git commit -q --amend --no-edit
got="$(git log -1 --format=%B | sed -e :a -e '/^\n*$/{$d;N;ba' -e '}')"
want="fix: o

Assisted-by: Claude:claude-opus-5
$SOB"
if [ "$got" = "$want" ]; then
	pass=$((pass + 1)); echo "ok   - amend is idempotent"
else
	fail=$((fail + 1)); echo "FAIL - amend is idempotent"
	printf '%s\n' "$got" | sed 's/^/    | /'
fi

mkdir -p .git/hooks
cat >.git/hooks/prepare-commit-msg <<'EOF'
#!/bin/sh
git interpret-trailers --in-place --trailer "Refs: TICKET-42" "$1"
EOF
chmod +x .git/hooks/prepare-commit-msg
check "a repo-local hook still runs" \
"fix: p

Co-authored-by: Codex <noreply@openai.com>" \
"fix: p

Assisted-by: Codex
Refs: TICKET-42
$SOB"

cat >.git/hooks/prepare-commit-msg <<'EOF'
#!/bin/sh
exit 3
EOF
chmod +x .git/hooks/prepare-commit-msg
before="$(git rev-parse HEAD)"
echo blocked >blocked.txt
git add blocked.txt
if git commit -q -m "should not land" 2>/dev/null; then
	fail=$((fail + 1)); echo "FAIL - a failing repo-local hook aborts the commit"
elif [ "$(git rev-parse HEAD)" = "$before" ]; then
	pass=$((pass + 1)); echo "ok   - a failing repo-local hook aborts the commit"
else
	fail=$((fail + 1)); echo "FAIL - a failing repo-local hook aborts the commit"
fi
git reset -q
rm -f .git/hooks/prepare-commit-msg blocked.txt

branch="$(git rev-parse --abbrev-ref HEAD)"
git checkout -q -b side
echo side >side.txt && git add side.txt && git commit -q -m "side"
git checkout -q "$branch"
echo trunk >trunk.txt && git add trunk.txt && git commit -q -m "trunk"
git merge --no-ff -q side -m "Merge branch 'side'"
if [ "$(git log -1 --format=%B | sed -e :a -e '/^\n*$/{$d;N;ba' -e '}')" = "Merge branch 'side'" ]; then
	pass=$((pass + 1)); echo "ok   - merge messages are left alone"
else
	fail=$((fail + 1)); echo "FAIL - merge messages are left alone"
	git log -1 --format=%B | sed 's/^/    | /'
fi

if ls .git/COMMIT_EDITMSG.attr* >/dev/null 2>&1; then
	fail=$((fail + 1)); echo "FAIL - no temp files left behind"
else
	pass=$((pass + 1)); echo "ok   - no temp files left behind"
fi

echo "# agent sessions"

AS_AGENT=1
check "by default an agent signs off too" \
"fix: default policy

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>" \
"fix: default policy

Assisted-by: Claude:claude-opus-5
$SOB"

# The rest of this section exercises the stricter opt-in policy.
git config attribution.signoff human
check "an agent commit is attributed but not signed off" \
"fix: q

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>" \
"fix: q

Assisted-by: Claude:claude-opus-5"

check "a sign-off the agent wrote in your name is stripped" \
"fix: r

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
$SOB" \
"fix: r

Assisted-by: Claude:claude-opus-5"

check "someone else's sign-off is left alone" \
"fix: s

Signed-off-by: Dana Lee <dana@example.com>" \
"fix: s

Signed-off-by: Dana Lee <dana@example.com>"

git config attribution.signoff auto
check "attribution.signoff=auto signs even for an agent" \
"fix: t

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>" \
"fix: t

Assisted-by: Claude:claude-opus-5
$SOB"
git config attribution.signoff human

AS_AGENT=0
git config attribution.signoff off
check "attribution.signoff=off never signs" \
"fix: u" \
"fix: u"
# Everything below exercises the stricter policy, where agent commits arrive
# unsigned and are certified later.
git config attribution.signoff human

echo "# push gate"

origin="$work/origin.git"
git init -q --bare "$origin"
git remote add origin "$origin"

AS_AGENT=1
commit_with "feat: unsigned agent work

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
AS_AGENT=0

if git push -q origin HEAD 2>"$work/pusherr"; then
	bad "push is rejected when a commit is unsigned"
else
	if grep -q "push rejected" "$work/pusherr"; then
		ok "push is rejected when a commit is unsigned"
	else
		bad "push is rejected when a commit is unsigned (wrong error)"
		sed 's/^/    | /' "$work/pusherr"
	fi
fi

if git signoff --yes >"$work/so.log" 2>&1; then
	ok "git signoff --yes certifies the outstanding commits"
else
	bad "git signoff --yes certifies the outstanding commits"
	sed 's/^/    | /' "$work/so.log"
fi

# Not just HEAD: certifying some of the range and silently leaving the rest
# is the failure mode this guards.
missing=0
for s in $(git rev-list "origin/$branch..HEAD" 2>/dev/null || git rev-list HEAD); do
	p="$(git show -s --format=%P "$s")"
	case "$p" in *' '*) continue ;; esac
	git show -s --format=%B "$s" | grep -qF "$SOB" || missing=$((missing + 1))
done
if [ "$missing" -eq 0 ]; then
	ok "every commit in the range is signed, not just the tip"
else
	bad "every commit in the range is signed, not just the tip ($missing missing)"
fi

if git log -1 --format=%B | grep -qF "$SOB"; then
	ok "the signed commit carries exactly one sign-off"
	if [ "$(git log -1 --format=%B | grep -c '^Signed-off-by:')" = "1" ]; then
		ok "sign-off is not duplicated by the rebase"
	else
		bad "sign-off is not duplicated by the rebase"
		git log -1 --format=%B | sed 's/^/    | /'
	fi
else
	bad "the signed commit carries exactly one sign-off"
	git log -1 --format=%B | sed 's/^/    | /'
fi

if git push -q origin HEAD 2>"$work/pusherr2"; then
	ok "push succeeds once everything is signed"
else
	bad "push succeeds once everything is signed"
	sed 's/^/    | /' "$work/pusherr2"
fi

if git signoff >"$work/so2.log" 2>&1; then
	ok "git signoff is a no-op when nothing is outstanding"
else
	bad "git signoff is a no-op when nothing is outstanding"
	sed 's/^/    | /' "$work/so2.log"
fi

AS_AGENT=1
commit_with "feat: more unsigned work

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
AS_AGENT=0
if git signoff </dev/null >"$work/so3.log" 2>&1; then
	bad "git signoff without a terminal refuses to certify"
else
	if grep -q "must be answered by a human" "$work/so3.log"; then
		ok "git signoff without a terminal refuses to certify"
	else
		bad "git signoff without a terminal refuses to certify (wrong error)"
		sed 's/^/    | /' "$work/so3.log"
	fi
fi

git config attribution.push.requireSignoff false
if git push -q origin HEAD 2>"$work/pusherr3"; then
	ok "the push gate can be turned off"
else
	bad "the push gate can be turned off"
	sed 's/^/    | /' "$work/pusherr3"
fi
git config --unset attribution.push.requireSignoff

# Unsigned work must still be able to reach a branch, or it can never be
# reviewed in a pull request.
main_branch="$(git rev-parse --abbrev-ref HEAD)"
git checkout -q -b feature/agent-work
AS_AGENT=1
commit_with "feat: work for review

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
AS_AGENT=0
if git push -q origin HEAD 2>"$work/pushfeat"; then
	ok "unsigned commits reach an unprotected branch for review"
else
	bad "unsigned commits reach an unprotected branch for review"
	sed 's/^/    | /' "$work/pushfeat"
fi
if grep -q "unsigned commit" "$work/pushfeat"; then
	ok "pushing unsigned work warns that it still needs sign-off"
else
	bad "pushing unsigned work warns that it still needs sign-off"
	sed 's/^/    | /' "$work/pushfeat"
fi
git checkout -q "$main_branch"

echo "# agent pushing"

git checkout -q -b feature/agent-push
commit_with "feat: pushable work"
if AI_AGENT=test-agent git push -q origin HEAD 2>"$work/ap1"; then
	ok "an agent may push by default"
else
	bad "an agent may push by default"
	sed 's/^/    | /' "$work/ap1"
fi

git config attribution.push.agent deny
commit_with "feat: more work"
if AI_AGENT=test-agent git push -q origin HEAD 2>"$work/ap2"; then
	bad "attribution.push.agent=deny refuses an agent's push"
elif grep -q "push refused" "$work/ap2"; then
	ok "attribution.push.agent=deny refuses an agent's push"
else
	bad "attribution.push.agent=deny refuses an agent's push (wrong error)"
	sed 's/^/    | /' "$work/ap2"
fi

if git push -q origin HEAD 2>"$work/ap3"; then
	ok "you can still push while agents are denied"
else
	bad "you can still push while agents are denied"
	sed 's/^/    | /' "$work/ap3"
fi
git config --unset attribution.push.agent
git checkout -q "$main_branch"

echo "# commit signatures"

git config attribution.push.requireSignature true
AS_AGENT=1
commit_with "feat: unsigned by key

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
AS_AGENT=0
if git push -q origin HEAD 2>"$work/sigerr"; then
	bad "push is rejected when a commit carries no signature"
elif grep -q "no valid signature" "$work/sigerr"; then
	ok "push is rejected when a commit carries no signature"
else
	bad "push is rejected when a commit carries no signature (wrong error)"
	sed 's/^/    | /' "$work/sigerr"
fi

if ssh-keygen -q -t ed25519 -N "" -C "test@example.com" -f "$work/signkey" 2>/dev/null; then
	printf 'test@example.com %s\n' "$(cat "$work/signkey.pub")" >"$work/allowed_signers"
	git config gpg.format ssh
	git config user.signingkey "$work/signkey.pub"
	git config gpg.ssh.allowedSignersFile "$work/allowed_signers"
	git config commit.gpgsign true

	if git signoff --yes >"$work/so4.log" 2>&1; then
		ok "git signoff signs and certifies in one act"
	else
		bad "git signoff signs and certifies in one act"
		sed 's/^/    | /' "$work/so4.log"
	fi

	verdict="$(git log -1 --format='%G?')"
	if [ "$verdict" = "G" ] || [ "$verdict" = "U" ]; then
		ok "the resulting commit has a valid signature ($verdict)"
	else
		bad "the resulting commit has a valid signature (got '$verdict')"
	fi

	if git push -q origin HEAD 2>"$work/sigerr2"; then
		ok "push succeeds once commits are signed and certified"
	else
		bad "push succeeds once commits are signed and certified"
		sed 's/^/    | /' "$work/sigerr2"
	fi

	git config --unset commit.gpgsign
	git config --unset user.signingkey
	git config --unset gpg.format
	git config --unset gpg.ssh.allowedSignersFile
else
	echo "skip - ssh-keygen unavailable, signature tests not run"
fi
git config --unset attribution.push.requireSignature

echo "# review prompt at push time"

git config attribution.push.requireSignature false

# By default there is no prompt at all: an agent commits, signs, and pushes,
# and you review locally.
git config attribution.signoff auto
git checkout -q -b feature/default-push
AS_AGENT=1
commit_with "feat: signed by the agent

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
AS_AGENT=0
if git push -q origin HEAD 2>"$work/free0"; then
	ok "by default an agent pushes its own signed work with no prompt"
else
	bad "by default an agent pushes its own signed work with no prompt"
	sed 's/^/    | /' "$work/free0"
fi
git checkout -q "$main_branch"

# Opting in to the stricter policy: an unsigned assisted commit certifies
# nothing, so it still needs no confirmation.
git config attribution.signoff human
git config attribution.push.confirm always
git checkout -q -b feature/unsigned-push
AS_AGENT=1
commit_with "feat: unsigned assisted work

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
AS_AGENT=0
if git push -q origin HEAD 2>"$work/free1"; then
	ok "an agent can push unsigned assisted work with no prompt"
else
	bad "an agent can push unsigned assisted work with no prompt"
	sed 's/^/    | /' "$work/free1"
fi
git checkout -q "$main_branch"

git config attribution.signoff auto
git checkout -q -b feature/review-prompt
AS_AGENT=1
commit_with "feat: assisted and already signed

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
AS_AGENT=0

git config attribution.push.confirm always
if git push -q origin HEAD 2>"$work/confirm1"; then
	bad "an assisted commit already signed blocks the push"
elif grep -q "have not been reviewed" "$work/confirm1"; then
	ok "an assisted commit already signed blocks the push"
else
	bad "an assisted commit already signed blocks the push (wrong error)"
	sed 's/^/    | /' "$work/confirm1"
fi

if grep -q "No terminal available" "$work/confirm1"; then
	ok "with no terminal the prompt cannot be answered by an agent"
else
	bad "with no terminal the prompt cannot be answered by an agent"
fi

git config attribution.push.confirm never
if git push -q origin HEAD 2>"$work/confirm2"; then
	ok "confirm=never pushes without asking"
else
	bad "confirm=never pushes without asking"
	sed 's/^/    | /' "$work/confirm2"
fi

# Simulate having answered the prompt, then confirm it is not asked again.
git rev-list "origin/$main_branch..HEAD" >"$(git rev-parse --git-dir)/attribution-reviewed"
git config attribution.push.confirm always
git commit -q --allow-empty -m "chore: nudge the branch"
if git push -q origin HEAD 2>"$work/confirm3"; then
	ok "already-reviewed commits are not queried again"
else
	bad "already-reviewed commits are not queried again"
	sed 's/^/    | /' "$work/confirm3"
fi

git config attribution.push.confirm never
git checkout -q "$main_branch"

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
