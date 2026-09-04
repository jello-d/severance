# Breaking changes, and what each consumer must do

severance's command surface was reorganised around one rule:

> **`severance` is the boundary** -- declare it, provision it, audit it, and
> answer questions about it. Config, admin, and query.
> **`work` is the one privileged action** -- acquire the group and hand a human
> a session. It answers no questions.

Every non-human consumer now talks to `severance` and only `severance`. That
is the point: an integrator should not have to know about two commands to ask
one question.

All of the following are breaking. Nothing is silently aliased, because a stale
caller must be FIXED rather than quietly served by a shim that hides which
spelling is live.

## 1. `severance context` is retired

    context resolve   ->  severance current
    context guard     ->  severance guard

`severance context <anything>` now exits 2 and prints the mapping.

**The behaviour is not identical.** `context resolve` printed the literal word
`personal` outside an enclave. `severance current` prints **nothing**. That
matters to valet-key specifically; see below.

## 2. `work check` and `work current` are gone

Both moved to `severance current`. There is no predicate verb any more: the
predicate is a test on the value, so the two cannot disagree.

    work check "$PID"        ->  [ -n "$(severance current "$PID")" ]
    work current             ->  severance current

`severance current` prints the profile name or nothing, and **always exits 0**.

## 3. `work` takes a closed verb set

    work                          # unchanged: enter the sole/default enclave
    work <profile>                ->  work enter <profile>
    work <cmd> ...                ->  work run -- <cmd> ...
    work <profile> <cmd> ...      ->  work run <profile> -- <cmd> ...

An unrecognised first word is now a usage error (exit 2) instead of being
treated as a command. That is the fix for the real defect: an unclassifiable
word used to fall through to the sudo re-exec and HANG with no TTY.

## 4. `work_group` and `claude_config` derive

`work_group` defaults to the profile name; `claude_config` defaults to
`<work_dir>/.config/claude`. `severance init` no longer scaffolds either.
Existing records that set them keep working; `severance validate` warns when
`work_group` differs from the profile name.

---

# Per-consumer handoff

## tackup

**Delete `link/config/mux/context-token`.** Its whole body was the
reconstruction that `severance current` now does in one call, and it had to
invoke BOTH binaries (`work check` for the predicate, `severance show --shell`
for the value) precisely because the query was split. Point mux's config
straight at severance instead:

    # link/config/mux/config
    context-command   severance current

`link/config/mux/context` (the older 70-line hook that supplied a tmux style
string) can go at the same time if every machine is on mux 0.3.

**Update `link/config/valet-key/context`.** It currently execs
`severance context "$@"`. It must now map the two verbs, and supply the
`personal` token that `current` no longer prints:

    set -eu
    command -v severance >/dev/null 2>&1 || {
      case "${1:-}" in resolve) echo personal ;; esac; exit 0; }
    case "${1:-}" in
      resolve) p=$(severance current); printf '%s\n' "${p:-personal}" ;;
      guard)   shift; exec severance guard "$@" ;;
      *)       exit 0 ;;
    esac

That `${p:-personal}` is load-bearing, not cosmetic. See the valet-key note.

**Audit for the old `work` grammar.** Any `work <cmd>` in a script becomes
`work run -- <cmd>`. Scripted callers fail loudly (exit 2, usage on stderr)
rather than silently, so a grep plus a test run will find them all.

## mux

**Fix the README.** It documents

    context-command   severance mux-context

There is no `mux-context` verb in severance and there never was. The working
example is:

    context-command   severance current

which needs no hook file at all. `severance current` already satisfies mux's
contract exactly: one word on stdout, empty output meaning `global`, exit 0.

**No code change is needed.** mux validates the token as a DNS label already.

## valet-key

**One behaviour change to be aware of.** `resolve_profile` treats a non-empty
answer from the hook as authoritative and an **empty** answer as "no opinion",
after which it falls through to its own cwd matcher and then `DEFAULT_PROFILE`.
`severance context resolve` used to return the positive token `personal`, which
short-circuited that matcher. `severance current` returns empty.

So a shim that forwards `current` verbatim would **silently re-enable cwd
matching in the personal case** -- a quiet behaviour change, which is why the
tackup shim above maps empty to `personal` explicitly rather than passing it
through.

**Consider adding name validation.** valet-key currently validates profile
names not at all. If the fleet is standardising on DNS labels as identity,
this is the remaining gap.
