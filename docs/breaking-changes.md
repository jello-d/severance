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

> **If you are reading this because something broke: check
> `severance doctor` first.** A shim still calling `severance context` leaves
> valet-key's ZDR guard a NO-OP -- valet-key reads a failing hook's exit as
> "warn, then proceed". severance now exits 1 (refuse) rather than 2 (proceed)
> from the retired verb, so it fails closed, and `doctor` reports the stale
> shim as a FAILURE instead of "present".

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

`severance current` prints the profile name or nothing. Exit 0 means it
answered (empty then means "not in an enclave"); exit 2 means it could not
answer, because the pid was malformed or named no live process. Do not collapse
those: `work check` returned 1 for both, which is exactly the conflation being
removed.

## 3. `work` takes a closed verb set

    work                          # unchanged: enter the sole/default enclave
    work <profile>                ->  work enter <profile>
    work <cmd> ...                ->  work run -- <cmd> ...
    work <profile> <cmd> ...      ->  work run <profile> -- <cmd> ...

An unrecognised first word is now a usage error (exit 2) instead of being
treated as a command. That is the fix for the real defect: an unclassifiable
word used to fall through to the sudo re-exec and HANG with no TTY.

## 4. Profile names are linted as DNS labels

`a-z`, `0-9` and hyphen; no leading or trailing hyphen; 63 characters max.
Underscore is now rejected. It is legal in a Unix group and illegal in a DNS
label, so a name like `my_work` used to provision cleanly and then be refused
downstream at use time. `severance init` refuses such a name up front and
writes nothing.

Nothing in the fleet is affected today: the only provisioned profile anywhere
is `manifest`, which is already a valid label.

## 5. `label` is retired, and so is `WORK_CONTEXT`

An enclave has exactly ONE name: the record's filename. `label` was a second,
prettier alias for it, and every read was presentation -- the `work` prompt,
the entry banner, two `seal` progress lines, and the `WORK_CONTEXT` export.

Remove `label=` from every record. It is now an unknown key and records fail
loud, so **update records BEFORE deploying this severance**: the reverse order
is a hard parse failure. (An old severance reading a record without `label`
merely prints a duller prompt, so record-first is the safe direction.)

`WORK_CONTEXT` was exported by `work` and read by NOTHING -- not in severance,
mux, valet-key, tackup, or any shell rc. It is deleted.

The prompt now uses the profile name. An enclave that wants a different one
sets `PS1` in its own `<work_dir>/.workrc`, which `work` sources last: a
display preference belongs with the enclave, not in the boundary's record.

`runner` now defaults to `<profile>-runner` rather than `<label>-runner`.
Identical wherever label equalled the profile name, which was everywhere.

## 6. `show --shell` is retired

It was advertised as a stable contract for external consumers and had none.
Every integrator reaches severance through `current` and `guard` -- one word
and one exit code. A twelve-variable promise nobody used still pinned every
internal name in the reader as public API.

    eval "$(severance show --shell)"   ->  p=$(severance current)

`severance show` remains as a human report. `show --shell` exits 2 and names
the replacement rather than being silently reinterpreted as a profile name.

## 7. service_user / service_overlay / service_overlay_write are removed

The record's own comment already called them dormant ("the retired podman
model used service_user / service_overlay ... unused now"), no profile
anywhere set them, and both code paths were fully guarded on
`[ -n "$WC_SERVICE_USER" ]` -- so they were inert. Removed along with
`grant_overlay_acl` and `seal_service_overlay` (~43 lines) and the matching
`check` audit. They are now unknown keys.

## 8. `work_group` and `claude_config` derive

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

**This one is urgent, not cosmetic.** tackup's shim is the one installed on a
provisioned box (severance defers to the symlink), it still calls the retired
verb, and until it is fixed valet-key's ZDR guard does nothing there.

**Decide whether to keep shipping `link/config/valet-key/context` at all.**
severance's own `install` publishes exactly this hook
(`libexec/install.sh:_wire_valet_key`) and now generates the correct version
for the new verbs. tackup ships a second copy as a symlink, and severance
detects the symlink and defers to it ("host-managed; leaving it"), so the
tackup copy wins on this box and would keep calling the retired `context`.

Either drop tackup's copy and let `severance install` own it, or update
tackup's copy to match what severance now generates:

    set -eu
    command -v severance >/dev/null 2>&1 || {
      case "${1:-}" in resolve) echo personal ;; esac; exit 0; }
    case "${1:-}" in
      resolve) p=$(severance current) || exit 1
               printf '%s\n' "${p:-personal}" ;;
      guard)   shift; exec severance guard "$@" ;;
    esac
    exit 0

Both the `${p:-personal}` and the `|| exit 1` are load-bearing, not cosmetic.
See the valet-key note.

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

**No code change is needed.** mux validates the token as a DNS label already,
and severance now lints profile names to the same shape, so the two agree by
construction instead of by luck.

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

**The deeper fix is in the hook contract, not the shim.** `resolve` conflates
two different answers into "empty": "I have no opinion" and "I definitely have
no special context". A provider that knows the answer is personal cannot say so
without inventing a token. Consider: exit 0 with a token means that context,
exit 0 with empty means *definitely baseline* (do not run the cwd matcher), and
a NON-ZERO exit means "cannot answer" and is the only thing that should fall
through to heuristics. That deletes the need for the `${p:-personal}` mapping
in every shim, everywhere.

**Consider adding name validation.** valet-key currently validates profile
names not at all. If the fleet is standardising on DNS labels as identity,
this is the remaining gap.
