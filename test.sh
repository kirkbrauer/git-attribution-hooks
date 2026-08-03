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

hooks_dir="$work/hooks"
mkdir -p "$hooks_dir"
cp "$hook" "$hooks_dir/prepare-commit-msg"
chmod +x "$hooks_dir/prepare-commit-msg"

repo="$work/repo"
mkdir -p "$repo"
cd "$repo"
git init -q .
git config core.hooksPath "$hooks_dir"
git config user.name "Test Person"
git config user.email "test@example.com"

pass=0
fail=0
seq_n=0

# commit_with <message> -- stages a unique file and commits the given message.
commit_with() {
	seq_n=$((seq_n + 1))
	echo "$seq_n" >"file$seq_n.txt"
	git add "file$seq_n.txt"
	printf '%s\n' "$1" | git commit -q -F -
}

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

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
