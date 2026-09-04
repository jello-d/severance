# severance

A kernel-enforced work/personal boundary for a single machine. Some of your
work is confidential (treat it as zero-data-retention); the rest of what you do
on the box is not. severance keeps the non-confidential side from ever touching
the confidential side, and it does so with the *kernel* (Unix groups + ACLs),
not with a rule a tool is asked to honor.

Each confidential context is a **profile** (an "enclave"): a group, a sealed
work tree, a matching account. You enter one with `work`; a personal process,
lacking the group, is denied by the filesystem.

## What it does

- **Seals the enclave.** The enclave's top directory is `root:<group>`, mode
  `2770`, with a default ACL: only members of the enclave group can enter it,
  and new files inherit the group. That one directory is the whole wall.
- **`work`** acquires the group for a session (via `sudo -g`, a real human
  prompt, never passwordless) and drops you into the enclave with its account
  and environment. Nothing persists; leave and the group is gone.
- **A per-enclave rootless-docker runner** (optional) so work containers run
  under a locked service account whose login group *is* the enclave group,
  reachable only through a group-gated socket, never the login user's daemon.
- **A git identity split** so commits in the enclave use the right identity.
- **Multi-profile**, with a `default` marker for when you do not name one.

## Install

    ./bin/severance install      # symlink into ~/.local, wire host hooks
    # ensure ~/.local/bin is on PATH

`install` is only for a standalone box. Under a provisioning layer (e.g. tackup)
that already symlinks the package and owns the git/valet-key hooks, it is a
guarded no-op. `severance uninstall` removes the links.

## Use

    severance init work                 # scaffold a profile record
    $EDITOR ~/.config/severance/profiles/work   # set work_dir, ...
    severance seal                      # provision the wall (prompts for sudo)
    severance runner                    # provision the rootless-docker runner
    severance check                     # audit; non-zero on drift

    work                                # enter the (sole/default) enclave
    work enter <profile>                # ...naming it explicitly
    work run -- <cmd> ...               # run one command in it
    work run <profile> -- <cmd> ...     # ...in a named enclave

    severance current                   # which enclave is this process in?
    severance current "$PID"            # ...or another process

With several profiles, mark the active one:

    severance list                      # '*' marks the default
    severance use work                  # set the default
    work enter otherjob                 # or name one explicitly

Health, and tearing one down:

    severance doctor                    # whole-boundary health, one report
    severance validate                  # lint records before provisioning
    severance forget work               # tear down a profile's runner
    severance forget work --purge       # ...also drop the record (tree stays)

## Profile record

`~/.config/severance/profiles/<name>`, one `key=value` per line:

    label=work
    work_dir=~/src/work
    work_group=work                     # optional (default: the profile name)
    claude_config=~/.claude-work        # optional: default is inside the seal,
                                        #   at <work_dir>/.config/claude
    git_remote_glob=*work*              # optional: repo-consistency audit
    runner=work-runner                  # optional (default <label>-runner)
    enclave_personal=carveout/*         # optional: sanctioned personal subtrees

A profile name is the enclave's **published identity**: the group name, a path
component, and the token `severance current` hands to consumers that use it as
a socket name or namespace. So it is linted as a **DNS label** (`a-z`, `0-9`,
hyphen; no leading or trailing hyphen; 63 max), the intersection every one of
those uses accepts. Underscore is deliberately rejected even though it is legal
in a Unix group, so a name cannot provision cleanly and then be refused
downstream.

`work_group` derives from that name, so an enclave has ONE name rather than the
same name stored twice where the two can drift. Set the key only when you need
a group a DNS label cannot spell; `severance validate` warns when the two
differ. Likewise `claude_config` derives from `work_dir`, so the work account
lands behind the same gate as everything else.

## Two commands, one job each

**`severance`** is the boundary: declare it, provision it, audit it, and answer
questions about it. Config, admin, and query. Every non-human consumer talks to
this binary and only this binary.

**`work`** is the one privileged action: acquire the group and hand a human a
session, or run one command in it. It is the sole sudo entry point, and it
answers no questions. "Which enclave is this process in" is `severance
current`, not `work current`, so an integrator needs to know about one command
rather than two.

### Machine interface

Stable contracts consumed by other tools. Their output shape and exit codes
will not change without a major version bump. Everything else in this README is
a human report or a mutation, free to change its wording.

- `severance current [PID]` -- the profile name on stdout, or nothing.
  Exit **0** answered (empty output means "not in an enclave", which is not an
  error); **2** could not answer (the pid is malformed or names no live
  process).
- `severance guard` -- exit 0 ok, 1 refuse; the message goes to stderr.
- `severance show --shell` -- eval-able `WC_*` assignments.

`current` is a value, not a predicate, so a caller does
`p=$(severance current)` and tests `[ -n "$p" ]`. There is deliberately no
separate predicate verb, so the two can never disagree.

Not being in an enclave is not an error, so it is empty output and exit 0. But
being *unable to tell* is: a mangled pid that silently printed nothing would
report a process which IS behind the boundary as personal, and a caller testing
only `[ -n "$p" ]` would believe it. A false negative on a ZDR wall is the one
direction this must never fail in, so an unanswerable question exits 2.

## Integrations

- **valet-key** (credential-slot pooling): if installed, severance publishes a
  `~/.config/valet-key/context` shim so valet-key routes each agent to the right
  account and refuses a personal agent launched inside the enclave. Both find
  each other at that well-known path; each also works alone.

## Layout

    bin/severance       management + provisioning CLI (self-locating)
    bin/work            the enclave-entry command
    libexec/  the implementation (work-context reader, seal, runner,
                        check, ZDR guard, profile mgmt, installer)
    share/    the generic enclave note + the runner relay unit

## Safety notes

- The wall is the kernel. `.ignore` files, permission lists, and git config are
  NOT the boundary; never rely on them for it.
- The enclave group is TRANSIENT: the login user is never a permanent member,
  only a per-session one. `severance check` refuses if that is violated.
- Entering the enclave is always a human sudo prompt. There is deliberately no
  passwordless `work`.

## Development

An 80-column limit is enforced by a tracked pre-commit hook. Enable it once
per clone:

    git config core.hooksPath .githooks
