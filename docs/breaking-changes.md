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

`severance context <anything>` now exits **1** and prints the mapping. Not the
conventional 2 for a usage error: 2 means "warn, then proceed" in a veto
contract, and a retired boundary verb must fail CLOSED. Exiting 2 turned a
stale hook into a silently disabled guard, which is the precise failure the
verb existed to prevent.

**The behaviour is not identical.** `context resolve` printed the literal word
`personal` outside an enclave; `severance current` prints **nothing**. That is
deliberate: `personal` was a consumer's word for its own default, invented here
because the old seam had no way to say "I looked, and there is no enclave".
Empty-with-exit-0 says it, and mapping it to whatever a consumer calls its
baseline is the consumer's business.

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

## 8. `severance install` configures nothing but itself

It used to write an `include.path` into the user's global git config and drop a
hook into valet-key's config dir. Both are gone. Nobody installing a
work/personal boundary expects it to edit their git config, and special-casing
git -- of all things -- was the tell that it was the wrong layer.

It also ships no adapter for anyone, and audits nobody's config. severance
briefly shipped `share/hooks/` and had `doctor` grade a consumer's hook file;
both are gone. A copy of severance's own verbs living here for a consumer's
benefit could only go stale -- and did, leaving deployed copies calling a
retired verb with a guard silently a no-op. And only the tool that DECLARED a
seam can tell a hook that answered from one that merely failed, because it is
the tool that decided what a non-zero exit means there.

severance's CLI is the interface. A one-line hook calling it belongs with
whoever owns the box; checking that hook belongs to whoever declared the seam.

On a provisioned box the install change is a no-op: both were already deferred
to the host. A STANDALONE box wires the git include itself -- `severance
install` prints the command.

## 9. `work` knows nothing about the box's shell framework

`bin/work` hardcoded `~/lib/load_helper_funcs` and called `env_load` /
`sh_history_start` by name: one provisioner's private dotfile convention baked
into the boundary, and not even a public tool. It also broke the standalone
case outright, because the interactive rc emitted that source line
UNCONDITIONALLY while the `run` path guarded it -- an asymmetry that shows it
was an oversight rather than a decision.

A session's environment (PATH, toolchains, history) is the ENCLAVE's business
and belongs in `<work_dir>/.workrc`, which `work` already sourced last in both
paths. **Move that content there**, or a work session loses it.

## 10. Per-tool config dirs are a TABLE

`share/tools` (severance's defaults) plus `~/.config/severance/tools.d/*`
drop-ins, on the `/etc/profile` + `/etc/profile.d` model. The hardcoded
per-tool code in `seal.sh` and `bin/work` is gone.

`valet-key` is no longer a severance default -- severance has no reason to know
a credential-slot pooler exists. An integrator that wants it adds a drop-in:

    # tool       env                   dir              seal
    valet-key    VALET_KEY_POOL_ROOT   valet-key-pool   no

Without that drop-in, `VALET_KEY_POOL_ROOT` is not set and valet-key falls back
to its own default pool root -- outside the seal. Add it.

## 11. `work_group` and `claude_config` derive

`work_group` defaults to the profile name; `claude_config` defaults to
`<work_dir>/.config/claude`. `severance init` no longer scaffolds either.
Existing records that set them keep working; `severance validate` warns when
`work_group` differs from the profile name.

---

# What a consumer needs

The fleet migration these notes describe is **complete**; what follows is the
resulting shape, not a to-do list. An earlier draft of this section prescribed
an intermediate one -- a `context` file answering `resolve` and `guard` -- and
kept prescribing it after nothing read that any more, which is exactly the
failure mode the notes above are about.

**The whole interface is two commands.**

    severance current [PID]   which enclave is this process in?
                              exit 0 answered (a name, or nothing when it is in
                              none); exit 2 could not answer
    severance guard           may this proceed here?
                              exit 0 ok; exit 1 refuse, message on stderr

Nothing else is a contract. `show` is a human report, and there is no
eval-able dump of internals.

**A session manager** that wants to name the context runs `severance current`
and takes the word. mux does exactly that as its `context-command`, with no
hook file: empty output or a non-zero exit means its baseline, which is what
"not in an enclave" and "could not tell" should both produce there.

**A credential router** that wants to select an account and refuse an
incoherent launch calls both verbs. valet-key does that through two hook
DIRECTORIES -- a selector and a veto, where a hook's directory is the verb --
so its integration is one line in each, and neither package names the other.
Those files belong to whoever configures the box.

**Anything else** is the same shape: call the verb, read the exit status.
severance ships no adapter, hook or shim for any consumer, and audits none of
their config. If a consumer's seam has a shape severance's CLI does not fit,
the adapter for it lives with the consumer or the integrator -- never here,
where it would be a copy of our own verbs going stale behind our back.
