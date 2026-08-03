#!/bin/sh
# Install block-dco-bypass.sh into a Claude Code install and register it as a
# PreToolUse/Bash hook.
#
#   ./claude-code/install-claude-hook.sh
#   ./claude-code/install-claude-hook.sh --uninstall
#
# Merges into ~/.claude/settings.json rather than replacing it: anything else
# in the file, including other PreToolUse hooks, is preserved. Idempotent, and
# the previous settings.json is kept as settings.json.bak.
#
# Options:
#   --dir <path>   Claude config directory (default: ~/.claude)
#   --uninstall    remove the hook and its registration
#
# https://github.com/kirkbrauer/git-attribution-hooks

set -eu

claude_dir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
uninstall=0
HOOK="block-dco-bypass.sh"

die() { echo "error: $*" >&2; exit 1; }
note() { echo "  $*"; }

while [ $# -gt 0 ]; do
	case "$1" in
	--dir) [ $# -ge 2 ] || die "--dir needs a path"; claude_dir="$2"; shift 2 ;;
	--dir=*) claude_dir="${1#--dir=}"; shift ;;
	--uninstall) uninstall=1; shift ;;
	-h|--help) sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
	*) die "unknown option: $1" ;;
	esac
done

command -v jq >/dev/null 2>&1 ||
	die "jq is required to edit settings.json safely (brew install jq / dnf install jq)"

settings="$claude_dir/settings.json"
hooks_dir="$claude_dir/hooks"
target="$hooks_dir/$HOOK"
# For the default location, register the command as $HOME/... so the same
# settings.json works on machines with different home directories. For a
# custom --dir there is nothing portable to write, so use the real path.
if [ "$claude_dir" = "$HOME/.claude" ]; then
	cmd='$HOME/.claude/hooks/'"$HOOK"
else
	cmd="$target"
fi

# ------------------------------------------------------------------ helpers
write_settings() {	# write_settings <jq-program> [jq args...]
	_prog="$1"; shift
	[ -f "$settings" ] || echo '{}' >"$settings"
	jq -e . "$settings" >/dev/null 2>&1 ||
		die "$settings is not valid JSON; fix it before running this"
	_tmp="$settings.tmp$$"
	jq "$@" "$_prog" "$settings" >"$_tmp" || { rm -f "$_tmp"; die "jq failed"; }
	jq -e . "$_tmp" >/dev/null 2>&1 || { rm -f "$_tmp"; die "produced invalid JSON, aborted"; }
	cp "$settings" "$settings.bak"
	mv "$_tmp" "$settings"
}

# ---------------------------------------------------------------- uninstall
if [ "$uninstall" -eq 1 ]; then
	echo "Removing the Claude Code hook"
	[ -e "$target" ] && { rm -f "$target"; note "removed $target"; }
	if [ -f "$settings" ]; then
		write_settings '
			(.hooks.PreToolUse // []) as $p
			| if ($p | length) == 0 then .
			  else .hooks.PreToolUse = (
			      $p
			      | map(.hooks = ((.hooks // []) | map(select((.command // "") != $c))))
			      | map(select((.hooks | length) > 0)))
			  end
			| if (.hooks.PreToolUse | length) == 0 then del(.hooks.PreToolUse) else . end
			| if (.hooks | length) == 0 then del(.hooks) else . end
		' --arg c "$cmd"
		note "deregistered from $settings (previous kept as settings.json.bak)"
	fi
	echo "Done."
	exit 0
fi

# ------------------------------------------------------------------ install
src_dir="$(cd "$(dirname "$0")" && pwd)"
[ -f "$src_dir/$HOOK" ] || die "cannot find $src_dir/$HOOK"

echo "Installing the Claude Code hook into $claude_dir"
mkdir -p "$hooks_dir"
cat "$src_dir/$HOOK" >"$target"
chmod +x "$target"
note "installed $target"

write_settings '
	.hooks //= {}
	| .hooks.PreToolUse //= []
	| if any(.hooks.PreToolUse[]; .matcher == "Bash")
	  then .hooks.PreToolUse |= map(
	      if .matcher == "Bash"
	      then .hooks = ((.hooks // [])
	           | if any(.[]; (.command // "") == $c) then .
	             else . + [{type: "command", command: $c, timeout: 10}] end)
	      else . end)
	  else .hooks.PreToolUse += [{
	      matcher: "Bash",
	      hooks: [{type: "command", command: $c, timeout: 10}]
	    }]
	  end
' --arg c "$cmd"
note "registered in $settings (previous kept as settings.json.bak)"

cat <<EOF

Done. Claude Code will refuse, in its own sessions:

    git push --no-verify
    git commit --no-verify   (and -n)
    git signoff --yes        (only when attribution.signoff is 'human')

Open /hooks in Claude Code once, or restart it, if the hook does not take
effect immediately.

Remove with: $0 --uninstall
EOF
