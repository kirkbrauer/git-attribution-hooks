#!/bin/sh
# Installer for git-attribution-hooks. POSIX sh; macOS and Linux.
#
#   curl -fsSL https://raw.githubusercontent.com/kirkbrauer/git-attribution-hooks/main/install.sh | sh
#
# or, from a clone (symlinks, so `git pull` updates everything):
#
#   ./install.sh
#
# Options:
#   --dir <path>   where to install hooks   (default: ~/.git-hooks)
#   --bin <path>   where to install git-signoff (default: ~/.local/bin)
#   --link         symlink instead of copy  (default when run from a clone)
#   --copy         copy instead of symlink
#   --force        take over core.hooksPath even if it points somewhere else
#   --uninstall    remove everything and restore anything displaced
#   --no-verify    skip the post-install smoke test
#
# Environment: GIT_ATTRIBUTION_HOOKS_DIR, GIT_ATTRIBUTION_BIN_DIR,
#              GIT_ATTRIBUTION_HOOKS_REF

set -eu

REPO_RAW="https://raw.githubusercontent.com/kirkbrauer/git-attribution-hooks"
REF="${GIT_ATTRIBUTION_HOOKS_REF:-main}"
HOOKS="prepare-commit-msg pre-push"
BIN_FILES="git-signoff"
MARKER="git-attribution-hooks:"
BACKUP_SUFFIX=".pre-git-attribution-hooks"

hooks_dir="${GIT_ATTRIBUTION_HOOKS_DIR:-$HOME/.git-hooks}"
bin_dir="${GIT_ATTRIBUTION_BIN_DIR:-$HOME/.local/bin}"
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
	--bin) [ $# -ge 2 ] || die "--bin needs a path"; bin_dir="$2"; shift 2 ;;
	--bin=*) bin_dir="${1#--bin=}"; shift ;;
	--link) mode="link"; shift ;;
	--copy) mode="copy"; shift ;;
	--force) force=1; shift ;;
	--uninstall) uninstall=1; shift ;;
	--no-verify) verify=0; shift ;;
	-h|--help)
		if [ -r "$0" ]; then sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'
		else echo "see $REPO_RAW/$REF/README.md"; fi
		exit 0 ;;
	*) die "unknown option: $1" ;;
	esac
done

command -v git >/dev/null 2>&1 || die "git is not installed"
git interpret-trailers --help >/dev/null 2>&1 ||
	die "this git has no 'interpret-trailers' (need git >= 2.9)"

is_ours() { [ -f "$1" ] && grep -q "$MARKER" "$1" 2>/dev/null; }

# ---------------------------------------------------------------- uninstall
if [ "$uninstall" -eq 1 ]; then
	echo "Uninstalling git-attribution-hooks"
	for f in $HOOKS; do
		t="$hooks_dir/$f"; b="$t$BACKUP_SUFFIX"
		if [ -L "$t" ] || is_ours "$t"; then rm -f "$t"; note "removed $t"
		elif [ -e "$t" ]; then note "left $t alone (not ours)"; fi
		[ -e "$b" ] && { mv "$b" "$t"; note "restored $t from backup"; }
	done
	for f in $BIN_FILES; do
		t="$bin_dir/$f"
		if [ -L "$t" ] || is_ours "$t"; then rm -f "$t"; note "removed $t"; fi
	done
	current="$(git config --global --get core.hooksPath 2>/dev/null || true)"
	if [ "$current" = "$hooks_dir" ]; then
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
src_dir=""
case "$0" in
*/*) cand="$(cd "$(dirname "$0")" 2>/dev/null && pwd)"
     [ -f "$cand/prepare-commit-msg" ] && src_dir="$cand" ;;
esac

echo "Installing git-attribution-hooks"

staged=""
if [ -z "$src_dir" ]; then
	[ "$mode" = "link" ] && die "--link requires running from a clone"
	mode="copy"
	staged="$(mktemp -d "${TMPDIR:-/tmp}/gah.XXXXXX")"
	trap 'rm -rf "$staged"' EXIT INT TERM
	for f in $HOOKS $BIN_FILES; do
		url="$REPO_RAW/$REF/$f"
		if command -v curl >/dev/null 2>&1; then
			curl -fsSL "$url" -o "$staged/$f" || die "download failed: $url"
		elif command -v wget >/dev/null 2>&1; then
			wget -qO "$staged/$f" "$url" || die "download failed: $url"
		else
			die "need curl or wget to download"
		fi
		is_ours "$staged/$f" || die "downloaded file is not the expected hook ($url)"
	done
	src_dir="$staged"
	note "downloaded $HOOKS $BIN_FILES @ $REF"
else
	[ -n "$mode" ] || mode="link"
	note "using $src_dir"
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

install_one() {	# install_one <src> <dest>
	_s="$1"; _d="$2"
	if [ -e "$_d" ] && ! [ -L "$_d" ] && ! is_ours "$_d"; then
		[ -e "$_d$BACKUP_SUFFIX" ] && die "refusing to overwrite backup $_d$BACKUP_SUFFIX"
		mv "$_d" "$_d$BACKUP_SUFFIX"
		note "moved your existing $(basename "$_d") aside -> $_d$BACKUP_SUFFIX"
	fi
	rm -f "$_d"
	if [ "$mode" = "link" ]; then ln -s "$_s" "$_d"
	else cat "$_s" >"$_d"; fi
	chmod +x "$_d" 2>/dev/null || chmod +x "$_s"
}

mkdir -p "$hooks_dir" "$bin_dir"
for f in $HOOKS; do install_one "$src_dir/$f" "$hooks_dir/$f"; done
note "installed $HOOKS in $hooks_dir"
for f in $BIN_FILES; do install_one "$src_dir/$f" "$bin_dir/$f"; done
note "installed $BIN_FILES in $bin_dir"

git config --global core.hooksPath "$hooks_dir"
note "set global core.hooksPath = $hooks_dir"

case ":$PATH:" in
*":$bin_dir:"*) ;;
*) note "WARNING: $bin_dir is not on your PATH; 'git signoff' will not resolve" ;;
esac

# -------------------------------------------------------------- smoke test
if [ "$verify" -eq 1 ]; then
	probe="$(mktemp -d "${TMPDIR:-/tmp}/gah-verify.XXXXXX")"
	(
		cd "$probe"
		GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
		export GIT_CONFIG_GLOBAL GIT_CONFIG_SYSTEM
		unset AI_AGENT CLAUDECODE CLAUDE_CODE_SESSION_ID GIT_ATTRIBUTION_AGENT || true
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

if [ -r "$0" ]; then
	uninstall_cmd="$0 --uninstall"
else
	uninstall_cmd="curl -fsSL $REPO_RAW/$REF/install.sh | sh -s -- --uninstall"
fi

cat <<EOF

Installed.

  Every commit    ->  Assisted-by: + Signed-off-by:, whoever ran git commit
  You            ->  read the diff before pushing. Nothing enforces this;
                     see "What each layer can and cannot guarantee" in the
                     README for the opt-ins that do.
  git push        ->  refuses unsigned commits on a protected branch

Uninstall with: $uninstall_cmd
EOF
