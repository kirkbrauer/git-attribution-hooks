#!/bin/sh
# Installer for git-attribution-hooks. POSIX sh; macOS and Linux.
#
#   curl -fsSL https://raw.githubusercontent.com/kirkbrauer/git-attribution-hooks/main/install.sh | sh
#
# or, from a clone (symlinks, so `git pull` updates the hook):
#
#   ./install.sh
#
# Options:
#   --dir <path>   where to install hooks   (default: ~/.git-hooks)
#   --link         symlink instead of copy  (default when run from a clone)
#   --copy         copy instead of symlink
#   --force        take over core.hooksPath even if it points somewhere else
#   --uninstall    remove the hook and restore anything it displaced
#   --no-verify    skip the post-install smoke test
#
# Environment: GIT_ATTRIBUTION_HOOKS_DIR, GIT_ATTRIBUTION_HOOKS_REF

set -eu

REPO_RAW="https://raw.githubusercontent.com/kirkbrauer/git-attribution-hooks"
REF="${GIT_ATTRIBUTION_HOOKS_REF:-main}"
HOOK="prepare-commit-msg"
MARKER="git-attribution-hooks: prepare-commit-msg"
BACKUP_SUFFIX=".pre-git-attribution-hooks"

hooks_dir="${GIT_ATTRIBUTION_HOOKS_DIR:-$HOME/.git-hooks}"
mode=""
force=0
uninstall=0
verify=1

die() { echo "error: $*" >&2; exit 1; }
note() { echo "  $*"; }

while [ $# -gt 0 ]; do
	case "$1" in
	--dir) [ $# -ge 2 ] || die "--dir needs a path"; hooks_dir="$2"; shift 2 ;;
	--dir=*) hooks_dir="${1#--dir=}"; shift ;;
	--link) mode="link"; shift ;;
	--copy) mode="copy"; shift ;;
	--force) force=1; shift ;;
	--uninstall) uninstall=1; shift ;;
	--no-verify) verify=0; shift ;;
	-h|--help) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
	*) die "unknown option: $1" ;;
	esac
done

command -v git >/dev/null 2>&1 || die "git is not installed"

# git interpret-trailers and core.hooksPath both predate git 2.9; anything
# shipping on a supported macOS or Linux is fine, but check rather than assume.
git interpret-trailers --help >/dev/null 2>&1 ||
	die "this git has no 'interpret-trailers' (need git >= 2.9)"

target="$hooks_dir/$HOOK"
backup="$target$BACKUP_SUFFIX"

is_ours() { [ -f "$1" ] && grep -q "$MARKER" "$1" 2>/dev/null; }

# ---------------------------------------------------------------- uninstall
if [ "$uninstall" -eq 1 ]; then
	echo "Uninstalling git-attribution-hooks"
	if [ -L "$target" ] || is_ours "$target"; then
		rm -f "$target"; note "removed $target"
	elif [ -e "$target" ]; then
		note "left $target alone (not installed by this project)"
	fi
	if [ -e "$backup" ]; then
		mv "$backup" "$target"; note "restored $target from backup"
	fi
	current="$(git config --global --get core.hooksPath 2>/dev/null || true)"
	if [ "$current" = "$hooks_dir" ] && [ ! -e "$target" ]; then
		# Only give up the setting if nothing else lives here.
		if [ -z "$(ls -A "$hooks_dir" 2>/dev/null || true)" ]; then
			git config --global --unset core.hooksPath
			note "unset global core.hooksPath"
			rmdir "$hooks_dir" 2>/dev/null || true
		else
			note "kept core.hooksPath: $hooks_dir still holds other hooks"
		fi
	fi
	echo "Done."
	exit 0
fi

# ------------------------------------------------------------------ source
# Running from a clone if the hook sits next to this script. When piped from
# curl, $0 is not a real path, so guard the lookup.
src=""
case "$0" in
*/*) cand="$(cd "$(dirname "$0")" 2>/dev/null && pwd)/$HOOK"
     [ -f "$cand" ] && src="$cand" ;;
esac

echo "Installing git-attribution-hooks into $hooks_dir"

tmp=""
if [ -z "$src" ]; then
	[ "$mode" = "link" ] && die "--link requires running from a clone"
	mode="copy"
	tmp="$(mktemp "${TMPDIR:-/tmp}/gah.XXXXXX")"
	trap 'rm -f "$tmp"' EXIT INT TERM
	url="$REPO_RAW/$REF/$HOOK"
	if command -v curl >/dev/null 2>&1; then
		curl -fsSL "$url" -o "$tmp" || die "download failed: $url"
	elif command -v wget >/dev/null 2>&1; then
		wget -qO "$tmp" "$url" || die "download failed: $url"
	else
		die "need curl or wget to download the hook"
	fi
	is_ours "$tmp" || die "downloaded file is not the expected hook ($url)"
	src="$tmp"
	note "downloaded $HOOK @ $REF"
else
	[ -n "$mode" ] || mode="link"
	note "using $src"
fi

# ------------------------------------------------------------- hooksPath
current="$(git config --global --get core.hooksPath 2>/dev/null || true)"
if [ -n "$current" ] && [ "$current" != "$hooks_dir" ]; then
	if [ "$force" -eq 1 ]; then
		note "overriding existing core.hooksPath ($current)"
	else
		echo >&2
		echo "error: global core.hooksPath is already set to:" >&2
		echo "    $current" >&2
		echo >&2
		echo "Install into that directory instead:" >&2
		echo "    $0 --dir '$current'" >&2
		echo "or take it over with --force." >&2
		exit 1
	fi
fi

mkdir -p "$hooks_dir"

# Preserve anything already sitting at the target that we did not put there.
if [ -e "$target" ] && ! [ -L "$target" ] && ! is_ours "$target"; then
	[ -e "$backup" ] && die "refusing to overwrite existing backup $backup"
	mv "$target" "$backup"
	note "moved your existing hook aside -> $backup"
fi
rm -f "$target"

if [ "$mode" = "link" ]; then
	ln -s "$src" "$target"
	note "linked $target -> $src"
else
	cat "$src" >"$target"
	note "wrote $target"
fi
chmod +x "$target" 2>/dev/null || chmod +x "$src"

git config --global core.hooksPath "$hooks_dir"
note "set global core.hooksPath = $hooks_dir"

# -------------------------------------------------------------- smoke test
if [ "$verify" -eq 1 ]; then
	probe="$(mktemp -d "${TMPDIR:-/tmp}/gah-verify.XXXXXX")"
	(
		cd "$probe"
		GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
		export GIT_CONFIG_GLOBAL GIT_CONFIG_SYSTEM
		git init -q .
		git config core.hooksPath "$hooks_dir"
		git config user.name "Probe"
		git config user.email "probe@example.invalid"
		echo hi >f
		git add f
		printf 'test\n\nCo-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>\n' |
			git commit -q -F -
		git log -1 --format=%B
	) >"$probe/out" 2>/dev/null || { rm -rf "$probe"; die "smoke test could not commit"; }
	if grep -q '^Assisted-by: Claude:claude-opus-5$' "$probe/out" &&
	   grep -q '^Signed-off-by: Probe <probe@example.invalid>$' "$probe/out"; then
		note "verified"
	else
		rm -rf "$probe"
		die "smoke test produced unexpected output"
	fi
	rm -rf "$probe"
fi

cat <<EOF

Installed. Commits now end with, for example:

    Assisted-by: Claude:claude-opus-5
    Signed-off-by: $(git config --get user.name 2>/dev/null || echo 'Your Name') <$(git config --get user.email 2>/dev/null || echo 'you@example.com')>

Uninstall with: $0 --uninstall
EOF
