# git-attribution-hooks

Git hooks that convert AI coding agents' `Co-authored-by:` trailers into the
Linux kernel's `Assisted-by:` format, and add a DCO `Signed-off-by:` from the
git identity of whatever repo you are in.

By default this is a convenience: the sign-off goes on every commit, agents
can push feature branches and open GitHub PRs / GitLab MRs, and you review on
the forge before merging. Local push confirmation and human-only sign-off are
independent opt-ins. Neither a local hook nor a harness permission prompt is
proof that a human reviewed the code.

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
commit certifies agent-written code you have never read. There is no way for a
tool on your machine to fix that for you — see the table below for what is
actually achievable — so the default keeps the convenience and names the
trade, and the opt-ins tighten it if you want.

## What each layer can and cannot guarantee

Be clear-eyed about this. A local git hook **cannot enforce human intent** — it
runs as you, on your machine, from config you installed. Anything it does is
something you pre-authorised.

| Layer | Guarantee |
| --- | --- |
| PR/MR review (the default workflow) | Enforced only when the forge requires human approvals and prevents direct/administrative bypass of protected branches. |
| `pre-push` confirmation on `/dev/tty` (`attribution.push.confirm always`) | An optional local guardrail. Non-interactive tools normally cannot answer it, but some harnesses can operate a PTY. A terminal is not proof of human intent. |
| `pre-push` refuses unsigned commits on protected branches | A guardrail, not a sandbox. `git push --no-verify` skips it. |
| `prepare-commit-msg` refuses to sign in an agent session (`attribution.signoff human`) | Detects `AI_AGENT`, `CLAUDECODE`, `CODEX_*`, … and strips a sign-off in your name the agent wrote itself. An agent that unsets those variables defeats it. |
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

Out of the box every commit is signed off as it is made, by you or by an
agent. Push and PR/MR creation remain agent-friendly; review happens on the
forge before merge. The hooks do not create PRs/MRs themselves.

```
commits            ->  Assisted-by: + Signed-off-by:, whoever ran git commit
agent pushes       ->  feature branch + GitHub PR / GitLab MR; no local prompt
you review         ->  forge diff, required human approval, required CI checks
merge              ->  protected branch, subject to forge policy
```

No history is rewritten and no force-push is needed.

Be honest with yourself about the trade: the sign-off is written before you
have read anything, so it means what you make it mean. If you want a mechanism
rather than a habit, both of the following are one config away.

### Forge-side review (recommended)

In GitHub branch protection/rulesets, require approving reviews, dismiss stale
approvals (or require approval of the latest push), require CI/DCO checks, and
restrict direct pushes and bypass actors. In GitLab, configure protected
branches, MR approval rules and successful pipelines; reset approvals when
new commits arrive. Keep the agent's token out of approval/bypass roles.
These settings must be configured on the forge; local hooks cannot enforce them.

The included `.github/workflows/dco.yml` checks author sign-offs. GitLab users
can run an equivalent DCO check in an MR pipeline and require it before merge.
A DCO check certifies trailer presence, not code review. Imported commits may
need the original author's sign-off as well as the current submitter's.

### Optional human-only certification

Withhold the sign-off until after you review, locally or on the forge:

```sh
git config --global attribution.signoff human
```

`prepare-commit-msg` stops signing agent commits and strips a sign-off in your
configured identity that an agent wrote itself. The harness guards and
`git signoff` refuse agent-driven `--yes` certification under this policy.
Unsigned commits can still reach feature branches for PR/MR review. After
review, run `git signoff` yourself and push with `--force-with-lease`.

This **does not enable local push confirmation**. Add either option separately:

```sh
git config --global attribution.push.confirm always   # confirm every publish
git config --global attribution.push.agent   deny     # agents may not push at all
```

`attribution.push.agent deny` is the blunt one. It keeps an agent from pushing
anything, which also keeps its work from reaching a pull request, so it costs
you a real amount of agentic workflow. That is why it is off by default.

### Prompting at push time

`attribution.push.confirm always` makes `pre-push` list every assisted commit
that already carries your sign-off and ask you to type "yes" on the terminal.
A non-interactive tool without a terminal must hand the push back to you.
Some harnesses can control terminals, so this is not an authentication boundary.
Answers are recorded per commit in
`.git/attribution-reviewed`, so re-pushing a branch does not ask again. Use
`protected` instead to be asked only when something reaches `main`.

### Withholding the sign-off entirely

`attribution.signoff human` makes agent commits arrive with **no** sign-off at
all. You then certify them afterwards with `git signoff`, which shows the
commits and diffstat, confirms on the terminal, and rebases with `--signoff`
(and `--gpg-sign` when signing is configured). This is closer to the letter of
the DCO — nothing is certified before it is read — at the cost of rewriting
commits, so the follow-up push needs `--force-with-lease`.

`git signoff --yes` skips the terminal prompt. It is available for repairs
under `auto`, but detected agent sessions cannot use it under `human`.
Never treat a harness's “allow command” prompt as code review or DCO consent.
Local confirmation remains `/dev/tty`-based in all harnesses; there is no
implicit conversion into a Claude/Codex permission dialog or a Pi UI approval.

## Claude Code

`claude-code/block-dco-bypass.sh` is a `PreToolUse` hook that stops an agent
skipping the git hooks with `git push --no-verify`, `git commit --no-verify`
or `-n`. It reads `attribution.signoff`, so under `human` it also blocks
`git signoff --yes`, and under the default it does not — an agent that already
signs at commit time should be able to repair its own commits.

```sh
./claude-code/install-claude-hook.sh              # register it
./claude-code/install-claude-hook.sh --uninstall  # remove it
```

It is kept separate from the main installer, which never touches your Claude
Code settings. It merges into `~/.claude/settings.json` with `jq` rather than
replacing it, so other hooks and every unrelated setting survive; it is
idempotent; it refuses to run against a settings file that is not valid JSON;
and it keeps the previous file as `settings.json.bak`. `claude-code/test-install.sh`
covers all of that against throwaway sandboxes.

Open `/hooks` in Claude Code once, or restart it, if the hook does not take
effect immediately.

It matches on the command string, so it will also block a command that merely
*contains* those flags — echoing them into a file, say. That is a deliberate
trade for a simple, auditable matcher. You can always run the command yourself
with a leading `!` in the Claude Code prompt box.

This layer is worth what an agent's cooperation is worth: it is enforced by
the harness rather than by the model, but it only covers tools routed through
that harness.

## Codex

```sh
./codex/install-codex-hook.sh              # merge into $CODEX_HOME/hooks.json
./codex/install-codex-hook.sh --uninstall
```

Requires `jq` and a Codex version with `PreToolUse` hooks and `updatedInput`
support. Open `/hooks` in Codex and **review/trust the new definition**; the
installer does not approve trust or modify `config.toml`. If a previous hook
was disabled, re-enable it in `/hooks` as well. Existing hooks and
unrelated JSON are preserved, the previous file is saved as `hooks.json.bak`,
and `--dir PATH` supports a non-default config directory.

The same bypass guard is used as in Claude Code. On allowed Bash calls, the
Codex adapter passes the hook event's active `model` into the shell via
`GIT_ATTRIBUTION_AGENT=codex` and `GIT_ATTRIBUTION_MODEL`. This follows model
switches without parsing config files or private transcripts. Native
`CODEX_THREAD_ID`, `CODEX_SESSION_ID`, and `CODEX_SANDBOX` markers also detect
Codex without the adapter, but may not supply a model.

## Pi

```sh
pi install /absolute/path/to/git-attribution-hooks
# /reload in Pi, or start a new session
pi remove /absolute/path/to/git-attribution-hooks
```

This optional package loads `extensions/attribution.ts`. It requires `jq` for
the shared bypass guard; install the Git hooks separately with `./install.sh`.
The extension intercepts the built-in `bash` tool, applies the same guard as
Claude/Codex, and passes the current `ctx.model.id` on **each command**. It does
not replace the bash tool, alter global environment variables, or gate
user-entered `!` commands. Custom shell tools/remote execution need their own
adapter and Git-hook installation on the machine where Git runs.

Recent Pi versions work without the extension for attribution: the Git hook
recognizes `PI_CODING_AGENT`, `PI_SESSION_ID`, or `AI_AGENT=pi`, and reads
`PI_MODEL`. The extension also supports versions lacking that native model
environment and adds the bypass guard. Pi running an OpenAI or Anthropic
model is attributed to **Pi**, not to the provider's coding harness.

## Supported agents

Explicit co-author trailers are recognized by address. For new, trailer-less
commits, known harness session metadata supplies attribution automatically.
Explicit model-bearing trailers remain authoritative. On new commits, a bare
`Assisted-by: Pi` (or another matching harness) can be completed from current
model metadata. Amends and replays are not relabeled with the current model.

| Agent | Trailer it writes | Becomes |
| --- | --- | --- |
| Claude Code | `Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>` | `Assisted-by: Claude:claude-opus-5` |
| Codex | `Co-authored-by: Codex (gpt-5.1-codex) <noreply@openai.com>` | `Assisted-by: Codex:gpt-5.1-codex` |
| Pi | native `PI_MODEL=claude-sonnet-4-5` or extension context | `Assisted-by: Pi:claude-sonnet-4-5` |
| Copilot | `Co-authored-by: Copilot <…+Copilot@users.noreply.github.com>` | `Assisted-by: Copilot` |
| Cursor | `Co-authored-by: Cursor Agent <cursoragent@cursor.com>` | `Assisted-by: Cursor` |
| aider | `Co-authored-by: aider (gpt-4o) <aider@aider.chat>` | `Assisted-by: aider:gpt-4o` |

Model priority is: explicit trailer model, current matching harness metadata,
then `attribution.<agent>.model`. If none is known, emit the harness name alone
rather than invent a version. Codex/Pi trailers also accept `Agent MODEL` and
`Agent (MODEL)`; Pi's optional co-author address is `pi@agents.invalid`.
The legacy `Codex ... <noreply@anthropic.com>` spelling is recognized as Codex,
not Claude. Claude's default model-bearing co-author trailer should remain
enabled; the Claude guard deliberately does not auto-allow Bash calls to
inject metadata, since that would override normal tool permissions. Trailers
matching no known agent pass through untouched, so human co-authors keep their
credit. No optional tools are listed — the kernel reserves that field for
analysis tools like coccinelle and sparse, not the agent or editor.

Claude Code also appends a `Claude-Session:` trailer linking back to the chat
session. The kernel AI-assistance format defines no such field, so the hook
drops it — commit trailers stay `Assisted-by:` + `Signed-off-by:`.

**Leave your agents' attribution enabled.** In particular, Claude's default
trailer carries the model. Native session detection is a fallback for missing
trailers, not a way to reconstruct which models helped before this commit.

## Configuration

Any git config scope, so you can vary it per repo.

| Key | Default | Meaning |
| --- | --- | --- |
| `attribution.signoff` | `auto` | `auto` = always sign, review before merge; `human` = never sign an agent's commit, certify later with `git signoff`; `off` = never sign |
| `attribution.push.confirm` | `never` | `never` = no prompt; `always` = confirm any push carrying an assisted, already-signed commit; `protected` = only for `main` etc. |
| `attribution.push.agent` | `allow` | `deny` refuses any push made from a coding agent's session, whatever its sign-off state |
| `attribution.push.protect` | `main master trunk` | branch patterns that refuse unsigned commits |
| `attribution.push.requireSignoff` | `true` | disable the push gate entirely |
| `attribution.push.requireSignature` | `false` | also require a valid commit signature |
| `attribution.<agent>.model` | — | `MODEL_VERSION` when the trailer carries none |
| `attribution.<agent>.match` | — | regex against the lowercased address; registers or overrides an agent |
| `attribution.<agent>.name` | — | `AGENT_NAME` to print |

```sh
# Optional fallback, only if this is the model you actually use:
git config --global attribution.codex.model gpt-5.1-codex
git config --global attribution.push.requireSignature true
```

Write `[.]` rather than `\.` in `match` patterns — awk warns about the
backslash escape on every commit otherwise.

Adapters for other harnesses can export `GIT_ATTRIBUTION_AGENT` and
`GIT_ATTRIBUTION_MODEL` per command. Explicit adapter metadata wins over native
harness detection (important for nested agents); keep it current when models
change. `AI_AGENT` also detects agent sessions for sign-off/push policy, but
unknown generic values do not manufacture attribution.

## Corporate and personal identity

All sign-offs and push checks use `git config user.name` / `user.email` in the
**target repository**: local and worktree config and `includeIf` are respected.
Neither model-provider addresses nor `GIT_AUTHOR_*` determine your sign-off.
A conflicting `GIT_COMMITTER_EMAIL` aborts the commit with a diagnostic instead
of silently publishing with the wrong identity. `git signoff` pins rebase
committer identity to the configuration shown in its review prompt.

For example (replace these addresses and paths with your own):

```gitconfig
# ~/.gitconfig
[user]
    name = Your Name
    email = you@personal.example
[includeIf "gitdir:~/work/"]
    path = ~/.gitconfig-work
```

```gitconfig
# ~/.gitconfig-work
[user]
    email = you@company.example
```

Or set `git config --local user.email you@company.example` inside one repo.
Inspect the resolved value with `git config --show-origin --get user.email`.
The installer never guesses a corporate domain or overwrites identity config.

Original commit authors are preserved on `--author`, amend and cherry-pick;
the hook adds **your** configured sign-off alongside other people's sign-offs,
not a fabricated certification from the original author. This is not an
author-email rewrite policy. Old commits with an obsolete address are not
silently rewritten; review and repair them deliberately before publishing.

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
./test-harnesses.sh
./claude-code/test-install.sh
node --experimental-strip-types --test tests/integrations.mjs  # Node >= 22.6 + jq
```

Tests use throwaway repositories/configuration, so they never touch your real
configuration. The integration tests cover Codex installation/upgrade/removal,
shared guard payloads, shell-safe model transport and Pi model switching. They clear the agent
environment variables themselves, so the suite behaves the same whether or not
you run it from inside a coding agent.

## References

- [Linux kernel: AI coding assistants](https://docs.kernel.org/process/coding-assistants.html)
- [Developer Certificate of Origin](https://developercertificate.org/)
- [git: SubmittingPatches](https://git-scm.com/docs/SubmittingPatches)
- [git-interpret-trailers](https://git-scm.com/docs/git-interpret-trailers)

## License

MIT
