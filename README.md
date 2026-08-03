# git-attribution-hooks

Git hooks that convert AI coding agents' `Co-authored-by:` trailers into the
Linux kernel's `Assisted-by:` format, and keep the DCO `Signed-off-by:` as
something **you** do after reading the code — not something an agent stamps in
your name.

```diff
  fix: handle empty payload

- Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
+ Assisted-by: Claude:claude-opus-5
+ Signed-off-by: Kirk Brauer <kirk@example.com>
```

## Why

Coding agents mark their work with GitHub's `Co-authored-by:` trailer, which
credits the model as a *co-author* — it appears in contributor lists and
implies an authorship claim a model can't make. The Linux kernel's
[AI coding assistants policy](https://docs.kernel.org/process/coding-assistants.html)
uses a different trailer:

```
Assisted-by: AGENT_NAME:MODEL_VERSION [TOOL1] [TOOL2]
```

It records which agent helped without granting authorship, and pairs with a
`Signed-off-by:` that keeps responsibility on a human. The kernel is explicit
that **agents must not add `Signed-off-by:` themselves** — only a human can
certify the [Developer Certificate of Origin](https://developercertificate.org/).

Which raises the obvious problem: a hook that appends your sign-off to every
commit certifies agent-written code you have never read. That is the thing
this repo is actually built around.

## What each layer can and cannot guarantee

Be clear-eyed about this. A local git hook **cannot enforce human intent** — it
runs as you, on your machine, from config you installed. Anything it does is
something you pre-authorised.

| Layer | Guarantee |
| --- | --- |
| `prepare-commit-msg` refuses to sign in an agent session | Strong by default, cooperative. Detects `AI_AGENT`, `CLAUDECODE`, `CODEX_*`, … and also strips a sign-off in your name that the agent wrote into the message itself. An agent that unsets those variables defeats it. |
| `pre-push` refuses unsigned commits on protected branches | A guardrail, not a sandbox. `git push --no-verify` skips it. |
| `git signoff` prompts on `/dev/tty` | **Genuinely un-fakeable.** A coding agent has no controlling terminal — opening `/dev/tty` fails with `No such device or address`. This is the one check an agent cannot answer. |
| CI DCO check (`.github/workflows/dco.yml`) | **Real enforcement.** It runs on the forge, not your machine, so no local flag bypasses it. Make it a required status check. |
| Commit signatures | Real *only* if the key cannot be used unattended — see below. |

### The signing trap

Cryptographic signing sounds like the answer, and it usually isn't. If your
signing key sits in `ssh-agent`, any agent you run inherits `SSH_AUTH_SOCK`
and can sign as you, silently. Verified on a stock setup:

```console
$ ssh-keygen -Y sign -f ~/.ssh/id_ed25519.pub -n git payload.txt
Signing file payload.txt          # no prompt, no touch, no passphrase
```

Signing only becomes an attestation when using the key requires a human:

```sh
ssh-add -D                      # drop unconditional keys
ssh-add -c ~/.ssh/id_ed25519    # -c: confirm each use via askpass
```

or, better, a hardware-backed key (`ssh-keygen -t ed25519-sk`) that needs a
physical touch. Then `git signoff` is the only moment a signature can be
produced, because it is the only moment you are there.

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/kirkbrauer/git-attribution-hooks/main/install.sh | sh
```

Installs `prepare-commit-msg` and `pre-push` to `~/.git-hooks`, points global
`core.hooksPath` at it, and puts `git-signoff` on your `PATH` so `git signoff`
works. macOS and Linux; POSIX `sh`, nothing beyond git, awk and sed.

It refuses to run if `core.hooksPath` already points elsewhere, moves aside any
hook it would displace, and finishes with a smoke test in a throwaway repo.

```
--dir <path>   hooks directory         (default: ~/.git-hooks)
--bin <path>   git-signoff location    (default: ~/.local/bin)
--link         symlink instead of copy (default when run from a clone)
--force        take over core.hooksPath
--uninstall    remove everything, restore anything displaced
```

## The workflow

```
agent commits      ->  Assisted-by: only. No sign-off. No signature.
git push           ->  allowed to a feature branch; a note reminds you
                       it is unsigned. Refused on main/master/trunk.
review the PR      ->  read the diff on GitHub or GitLab
git signoff        ->  shows the commits and diffstat, asks you to type
                       "yes" on the terminal, then rebases with --signoff
                       (and --gpg-sign if signing is configured)
git push --force-with-lease
                   ->  sign-off rewrote the commits, so the branch moved
CI DCO check       ->  blocks the merge if anything is still unsigned
```

Your own commits are unaffected: they get signed off automatically, the
equivalent of always passing `git commit -s`.

`git signoff --yes` skips the terminal prompt. It exists so an agent can apply
the sign-off *after* you have reviewed — but it removes the only check the
script can make, so never put it in an agent allowlist. Leave it as something
your agent must ask permission for, and treat granting that permission as the
act of certifying.

## Supported agents

Recognised by the address in the trailer, so a renamed model still matches.

| Agent | Trailer it writes | Becomes |
| --- | --- | --- |
| Claude Code | `Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>` | `Assisted-by: Claude:claude-opus-5` |
| Codex | `Co-authored-by: Codex <noreply@openai.com>` | `Assisted-by: Codex` |
| Copilot | `Co-authored-by: Copilot <…+Copilot@users.noreply.github.com>` | `Assisted-by: Copilot` |
| Cursor | `Co-authored-by: Cursor Agent <cursoragent@cursor.com>` | `Assisted-by: Cursor` |
| aider | `Co-authored-by: aider (gpt-4o) <aider@aider.chat>` | `Assisted-by: aider:gpt-4o` |

Where a model version can be derived it is; where the agent publishes none the
trailer is just `Assisted-by: AGENT_NAME` unless you configure one. Trailers
matching no known agent pass through untouched, so human co-authors keep their
credit. No optional tools are listed — the kernel reserves that field for
analysis tools like coccinelle and sparse, not the agent or editor.

**Leave your agents' attribution enabled.** These hooks consume each agent's
default trailer, so don't set Claude Code's `includeCoAuthoredBy` to `false` or
disable Codex's `commit_attribution`, or there is nothing to convert.

## Configuration

Any git config scope, so you can vary it per repo.

| Key | Default | Meaning |
| --- | --- | --- |
| `attribution.signoff` | `human` | `human` = sign your commits, never an agent's; `auto` = always sign; `off` = never |
| `attribution.push.protect` | `main master trunk` | branch patterns that refuse unsigned commits |
| `attribution.push.requireSignoff` | `true` | disable the push gate entirely |
| `attribution.push.requireSignature` | `false` | also require a valid commit signature |
| `attribution.<agent>.model` | — | `MODEL_VERSION` when the trailer carries none |
| `attribution.<agent>.match` | — | regex against the lowercased address; registers or overrides an agent |
| `attribution.<agent>.name` | — | `AGENT_NAME` to print |

```sh
git config --global attribution.codex.model gpt-5.1-codex
git config --global attribution.push.requireSignature true
```

Write `[.]` rather than `\.` in `match` patterns — awk warns about the
backslash escape on every commit otherwise.

## Repo-local hooks still work

A global `core.hooksPath` normally makes git ignore every repository's own
`.git/hooks`. To avoid that, `prepare-commit-msg` looks for a repo-local hook
of the same name and runs it first, passing through its arguments and exit
status — so a failing project hook still aborts the commit. Tools that set
`core.hooksPath` themselves per repo (husky, lefthook) take precedence, and
these hooks simply don't run there.

## Notes

- Merge commits are never rewritten and never signed off.
- The sign-off uses the identity git resolves *for the current repo*, so a
  repo-local `user.email` wins over your global one.
- Re-running on an already-converted message is a no-op, so `--amend` and
  rebases are safe.

## Dotfiles

```sh
git clone https://github.com/kirkbrauer/git-attribution-hooks ~/dotfiles/git-attribution-hooks
~/dotfiles/git-attribution-hooks/install.sh --link
```

`--link` symlinks, so `git pull` updates the hooks in place.

## Tests

```sh
./test.sh
```

38 tests, in a throwaway repo with `GIT_CONFIG_GLOBAL` and `GIT_CONFIG_SYSTEM`
neutered, so they never touch your real configuration. They clear the agent
environment variables themselves, so the suite behaves the same whether or not
you run it from inside a coding agent.

## References

- [Linux kernel: AI coding assistants](https://docs.kernel.org/process/coding-assistants.html)
- [Developer Certificate of Origin](https://developercertificate.org/)
- [git: SubmittingPatches](https://git-scm.com/docs/SubmittingPatches)
- [git-interpret-trailers](https://git-scm.com/docs/git-interpret-trailers)

## License

MIT
