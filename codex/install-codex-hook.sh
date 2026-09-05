#!/bin/sh
# Register the shared PreToolUse/Bash guard in Codex's hooks.json.
# Usage: ./codex/install-codex-hook.sh [--dir PATH] [--uninstall]
# Requires a Codex version supporting PreToolUse hooks and jq.
set -eu

src="$(cd "$(dirname "$0")/.." && pwd)"
dir="${CODEX_HOME:-$HOME/.codex}"
uninstall=0
while [ $# -gt 0 ]; do
	case "$1" in
	--dir) [ $# -ge 2 ] || { echo '--dir needs a path' >&2; exit 1; }; dir="$2"; shift 2 ;;
	--uninstall) uninstall=1; shift ;;
	-h|--help) echo "Usage: $0 [--dir PATH] [--uninstall]"; exit 0 ;;
	*) echo "unknown option: $1" >&2; exit 1 ;;
	esac
done
command -v jq >/dev/null 2>&1 || { echo 'jq is required' >&2; exit 1; }
mkdir -p "$dir"
dir="$(cd "$dir" && pwd)"
settings="$dir/hooks.json"
target="$dir/hooks/block-dco-bypass.sh"
# Shell-quote the absolute path, including spaces and apostrophes.
legacy_cmd="'$(printf '%s' "$target" | sed "s/'/'\\\\''/g")'"
cmd="$legacy_cmd codex"
# Refuse to replace an unrelated script at the same path.
if [ -e "$target" ] && ! grep -q 'github.com/kirkbrauer/git-attribution-hooks' "$target"; then
	echo "refusing to replace unrelated $target" >&2; exit 1
fi

# Validate before touching the script or registration. Never replace unrelated
# hooks or config.toml. A backup is made only after the new JSON is valid.
if [ -e "$settings" ]; then
	jq -e 'type == "object"' "$settings" >/dev/null 2>&1 || {
		echo "$settings must contain a JSON object; nothing changed" >&2; exit 1;
	}
fi
tmp="$(mktemp "$dir/.attribution-hooks.XXXXXX")"
trap 'rm -f "$tmp"' EXIT HUP INT TERM
if [ -e "$settings" ]; then cp "$settings" "$tmp"; else printf '{}\n' >"$tmp"; fi
result="$(jq --arg cmd "$cmd" --arg legacy "$legacy_cmd" --argjson uninstall "$uninstall" '
	# Remove only our registration, preserving siblings in the same group.
	if .hooks.PreToolUse then
		.hooks.PreToolUse |= (map(
			.hooks |= map(select(.command != $cmd and .command != $legacy))
		) | map(select(.hooks | length > 0)))
	else . end
	| if $uninstall == 0 then
		.hooks.PreToolUse = ((.hooks.PreToolUse // []) + [{
			matcher: "Bash", hooks: [{type: "command", command: $cmd, timeout: 10}]
		}])
	else
		if .hooks.PreToolUse == [] then del(.hooks.PreToolUse) else . end
		| if .hooks == {} then del(.hooks) else . end
	end
' "$tmp")"
printf '%s\n' "$result" >"$tmp"
if [ "$uninstall" -eq 0 ]; then
	mkdir -p "$dir/hooks"
	cp "$src/claude-code/block-dco-bypass.sh" "$target"
	chmod +x "$target"
fi
[ ! -e "$settings" ] || cp "$settings" "$settings.bak"
mv "$tmp" "$settings"
if [ "$uninstall" -eq 1 ]; then
	rm -f "$target"
	echo "Removed attribution guard from $settings"
else
	echo "Registered attribution guard in $settings"
	echo 'Open /hooks in Codex and review/trust the hook before using it.'
fi
