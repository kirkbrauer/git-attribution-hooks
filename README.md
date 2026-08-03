# git-attribution-hooks

A `prepare-commit-msg` hook that converts AI coding agents' `Co-authored-by:`
trailers into the Linux kernel's `Assisted-by:` format, and adds a DCO
`Signed-off-by:` from your own git identity.

```diff
  fix: handle empty payload

- Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
+ Assisted-by: Claude:claude-opus-5
+ Signed-off-by: Kirk Brauer <kirk@example.com>
```

## Why

Coding agents mark their work with GitHub's `Co-authored-by:` trailer, which
credits the model as a *co-author* — it shows up in contributor lists and
implies an authorship claim the model can't make. The Linux kernel's
[AI coding assistants policy](https://docs.kernel.org/process/coding-assistants.html)
uses a different trailer for this:

```
Assisted-by: AGENT_NAME:MODEL_VERSION [TOOL1] [TOOL2]
```

It records which agent helped without granting authorship, and it pairs with a
`Signed-off-by:` that keeps responsibility on the human. The kernel is explicit
that **agents must not add `Signed-off-by:` themselves** — only a human can
certify the [Developer Certificate of Origin](https://developercertificate.org/).
This hook honours that: the sign-off is generated locally by git from your
identity, never written by an agent.

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/kirkbrauer/git-attribution-hooks/main/install.sh | sh
```

This installs the hook to `~/.git-hooks` and points global `core.hooksPath`
at it. macOS and Linux; POSIX `sh`, no dependencies beyond git, awk and sed.

The installer refuses to run if `core.hooksPath` already points somewhere
else, moves aside any `prepare-commit-msg` it finds instead of clobbering it,
and finishes with a smoke test in a throwaway repo.

```
--dir <path>   where to install        (default: ~/.git-hooks)
--link         symlink instead of copy (default when run from a clone)
--copy         copy instead of symlink
--force        take over core.hooksPath even if it points elsewhere
--uninstall    remove the hook and restore anything it displaced
--no-verify    skip the smoke test
```

## Supported agents

Recognised by the address in the trailer, so a renamed model still matches.

| Agent | Trailer it writes | Becomes |
| --- | --- | --- |
| Claude Code | `Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>` | `Assisted-by: Claude:claude-opus-5` |
| Codex | `Co-authored-by: Codex <noreply@openai.com>` | `Assisted-by: Codex` |
| Copilot | `Co-authored-by: Copilot <…+Copilot@users.noreply.github.com>` | `Assisted-by: Copilot` |
| Cursor | `Co-authored-by: Cursor Agent <cursoragent@cursor.com>` | `Assisted-by: Cursor` |
| aider | `Co-authored-by: aider (gpt-4o) <aider@aider.chat>` | `Assisted-by: aider:gpt-4o` |

Where a model version can be derived it is; where the agent doesn't publish one
(Codex, Copilot, Cursor) the trailer is just `Assisted-by: AGENT_NAME` unless
you configure one. Trailers matching no known agent are left alone, so human
co-authors keep their credit.

No optional tools are listed — the kernel reserves that field for specialised
analysis tools like coccinelle and sparse, not the agent or editor.

### Agent-side setup

Nothing to do. The hook deliberately consumes each agent's *default* trailer,
so leave attribution enabled — don't set Claude Code's `includeCoAuthoredBy`
to `false` or disable Codex's `commit_attribution`, or there'll be nothing to
convert.

## Configuration

All optional, in any git config scope, so you can vary them per repo.

| Key | Meaning |
| --- | --- |
| `attribution.<agent>.model` | `MODEL_VERSION` to use when the trailer carries none |
| `attribution.<agent>.match` | extended regex matched against the lowercased address; registers a new agent or overrides a built-in |
| `attribution.<agent>.name` | `AGENT_NAME` to print (default: `<agent>` capitalised) |

```sh
# Codex doesn't name its model; say which one you drive it with.
git config --global attribution.codex.model gpt-5.1-codex
```

```sh
# Teach it an agent it doesn't know.
git config --global attribution.robo.match '@robo[.]example$'
git config --global attribution.robo.name  'RoboCoder'
```

Write `[.]` rather than `\.` in `match` patterns — awk warns about the
backslash escape on every commit otherwise.

## Repo-local hooks still work

Setting global `core.hooksPath` normally makes git ignore every repository's
own `.git/hooks`. To avoid that, this hook looks for a repo-local
`prepare-commit-msg` and runs it first, passing through its arguments and exit
status — so a failing project hook still aborts the commit. Tools that manage
`core.hooksPath` themselves (husky, lefthook) set it per-repo, which takes
precedence over the global value; in those repos this hook simply doesn't run.

## Notes

- **Every commit gets signed off**, not just AI-assisted ones — the equivalent
  of always passing `git commit -s`. Merge commit messages are left untouched.
- The sign-off uses the identity git resolves *for the current repo*, so a
  repo-local `user.email` wins over your global one.
- Re-running on an already-converted message is a no-op, so `--amend` and
  rebases are safe.

## Uninstall

```sh
curl -fsSL https://raw.githubusercontent.com/kirkbrauer/git-attribution-hooks/main/install.sh | sh -s -- --uninstall
```

or `./install.sh --uninstall` from a clone. It removes the hook, restores any
hook it displaced, and gives up `core.hooksPath` only if nothing else is left
in the directory.

## Dotfiles

Clone it wherever your dotfiles live and install with `--link`, so the hook is
a symlink and `git pull` updates it in place:

```sh
git clone https://github.com/kirkbrauer/git-attribution-hooks ~/dotfiles/git-attribution-hooks
~/dotfiles/git-attribution-hooks/install.sh --link
```

Or skip the installer entirely and commit the two lines it would have written:

```sh
git config --global core.hooksPath ~/.git-hooks
ln -s ~/dotfiles/git-attribution-hooks/prepare-commit-msg ~/.git-hooks/prepare-commit-msg
```

## Tests

```sh
./test.sh
```

Runs in a throwaway repo with `GIT_CONFIG_GLOBAL` and `GIT_CONFIG_SYSTEM`
neutered, so it never touches your real configuration.

## References

- [Linux kernel: AI coding assistants](https://docs.kernel.org/process/coding-assistants.html)
- [Developer Certificate of Origin](https://developercertificate.org/)
- [git: SubmittingPatches](https://git-scm.com/docs/SubmittingPatches)
- [git-interpret-trailers](https://git-scm.com/docs/git-interpret-trailers)

## License

MIT
