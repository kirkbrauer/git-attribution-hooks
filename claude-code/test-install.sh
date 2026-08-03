#!/bin/sh
# Tests for install-claude-hook.sh. Runs against throwaway --dir sandboxes, so
# it never touches a real Claude Code install.

set -eu

src_dir="$(cd "$(dirname "$0")" && pwd)"
installer="$src_dir/install-claude-hook.sh"
work="$(mktemp -d "${TMPDIR:-/tmp}/gah-cc.XXXXXX")"
trap 'rm -rf "$work"' EXIT INT TERM

pass=0
fail=0
ok()  { pass=$((pass + 1)); echo "ok   - $1"; }
bad() { fail=$((fail + 1)); echo "FAIL - $1"; }

CMD_RE='block-dco-bypass.sh'

# count_cmd <settings> -- how many times our hook is registered
count_cmd() {
	jq "[.hooks.PreToolUse[]?.hooks[]? | select((.command // \"\") | test(\"$CMD_RE\"))] | length" "$1"
}

sandbox() {	# sandbox <name> [initial settings json]
	d="$work/$1"
	mkdir -p "$d"
	[ $# -ge 2 ] && printf '%s' "$2" >"$d/settings.json"
	echo "$d"
}

echo "# fresh install"

d="$(sandbox fresh)"
"$installer" --dir "$d" >/dev/null 2>&1
[ -x "$d/hooks/block-dco-bypass.sh" ] &&
	ok "hook script is installed and executable" ||
	bad "hook script is installed and executable"
[ "$(count_cmd "$d/settings.json")" = "1" ] &&
	ok "registered once in a new settings.json" ||
	bad "registered once in a new settings.json"

echo "# merging"

d="$(sandbox existing '{"model":"opus[1m]","theme":"dark","enabledPlugins":{"x@y":true}}')"
"$installer" --dir "$d" >/dev/null 2>&1
if [ "$(jq -r '.model' "$d/settings.json")" = "opus[1m]" ] &&
   [ "$(jq -r '.theme' "$d/settings.json")" = "dark" ] &&
   [ "$(jq -r '.enabledPlugins["x@y"]' "$d/settings.json")" = "true" ]; then
	ok "unrelated settings are preserved"
else
	bad "unrelated settings are preserved"
	jq -c . "$d/settings.json" | sed 's/^/    | /'
fi

d="$(sandbox othermatcher '{"hooks":{"PreToolUse":[{"matcher":"Write","hooks":[{"type":"command","command":"prettier"}]}]}}')"
"$installer" --dir "$d" >/dev/null 2>&1
if [ "$(jq '[.hooks.PreToolUse[]] | length' "$d/settings.json")" = "2" ] &&
   [ "$(jq -r '.hooks.PreToolUse[] | select(.matcher=="Write") | .hooks[0].command' "$d/settings.json")" = "prettier" ]; then
	ok "a hook on another matcher is untouched"
else
	bad "a hook on another matcher is untouched"
	jq -c . "$d/settings.json" | sed 's/^/    | /'
fi

d="$(sandbox samematcher '{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"logger"}]}]}}')"
"$installer" --dir "$d" >/dev/null 2>&1
if [ "$(jq '[.hooks.PreToolUse[] | select(.matcher=="Bash") | .hooks[]] | length' "$d/settings.json")" = "2" ] &&
   [ "$(jq -r '[.hooks.PreToolUse[] | select(.matcher=="Bash") | .hooks[].command] | index("logger")' "$d/settings.json")" != "null" ]; then
	ok "an existing Bash hook is kept alongside ours"
else
	bad "an existing Bash hook is kept alongside ours"
	jq -c . "$d/settings.json" | sed 's/^/    | /'
fi

echo "# idempotence"

d="$(sandbox twice)"
"$installer" --dir "$d" >/dev/null 2>&1
"$installer" --dir "$d" >/dev/null 2>&1
"$installer" --dir "$d" >/dev/null 2>&1
[ "$(count_cmd "$d/settings.json")" = "1" ] &&
	ok "running it three times registers one hook" ||
	bad "running it three times registers one hook (got $(count_cmd "$d/settings.json"))"

echo "# uninstall"

d="$(sandbox removal '{"model":"opus[1m]","hooks":{"PreToolUse":[{"matcher":"Write","hooks":[{"type":"command","command":"prettier"}]}]}}')"
"$installer" --dir "$d" >/dev/null 2>&1
"$installer" --dir "$d" --uninstall >/dev/null 2>&1
[ "$(count_cmd "$d/settings.json")" = "0" ] &&
	ok "uninstall deregisters the hook" ||
	bad "uninstall deregisters the hook"
[ ! -e "$d/hooks/block-dco-bypass.sh" ] &&
	ok "uninstall removes the script" ||
	bad "uninstall removes the script"
if [ "$(jq -r '.model' "$d/settings.json")" = "opus[1m]" ] &&
   [ "$(jq -r '.hooks.PreToolUse[] | select(.matcher=="Write") | .hooks[0].command' "$d/settings.json")" = "prettier" ]; then
	ok "uninstall leaves everything else alone"
else
	bad "uninstall leaves everything else alone"
	jq -c . "$d/settings.json" | sed 's/^/    | /'
fi

d="$(sandbox pruned)"
"$installer" --dir "$d" >/dev/null 2>&1
"$installer" --dir "$d" --uninstall >/dev/null 2>&1
if [ "$(jq -r 'has("hooks")' "$d/settings.json")" = "false" ]; then
	ok "an empty hooks block is pruned rather than left behind"
else
	bad "an empty hooks block is pruned rather than left behind"
	jq -c . "$d/settings.json" | sed 's/^/    | /'
fi

echo "# safety"

d="$(sandbox broken '{"model": "opus", NOT JSON')"
if "$installer" --dir "$d" >/dev/null 2>&1; then
	bad "malformed settings.json is refused, not clobbered"
else
	grep -q 'NOT JSON' "$d/settings.json" &&
		ok "malformed settings.json is refused, not clobbered" ||
		bad "malformed settings.json is refused, not clobbered"
fi

d="$(sandbox backup '{"model":"opus"}')"
"$installer" --dir "$d" >/dev/null 2>&1
[ -f "$d/settings.json.bak" ] &&
	ok "the previous settings.json is kept as .bak" ||
	bad "the previous settings.json is kept as .bak"

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
