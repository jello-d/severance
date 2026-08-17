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
    $EDITOR ~/.config/severance/profiles/work   # set work_group, work_dir, ...
    severance seal                      # provision the wall (prompts for sudo)
    severance runner                    # provision the rootless-docker runner
    severance check                     # audit; non-zero on drift

    work                                # enter the (default) enclave
    work <cmd>                          # run one command in it
    work check $$                       # predicate: in the enclave group?

With several profiles, mark the active one:

    severance list                      # '*' marks the default
    severance use work                  # set the default
    work otherjob                       # or name one explicitly

## Profile record

`~/.config/severance/profiles/<name>`, one `key=value` per line:

    label=work
    work_group=work
    work_dir=~/src/work
    claude_config=~/.claude-work        # per-account agent config dir
    git_remote_glob=*work*              # optional: repo-consistency audit
    runner=work-runner                  # optional (default <label>-runner)
    enclave_personal=carveout/*         # optional: sanctioned personal subtrees

## Integrations

- **valet-key** (credential-slot pooling): if installed, severance publishes a
  `~/.config/valet-key/context` shim so valet-key routes each agent to the right
  account and refuses a personal agent launched inside the enclave. Both find
  each other at that well-known path; each also works alone.

## Layout

    bin/severance       management + provisioning CLI (self-locating)
    bin/work            the enclave-entry command
    libexec/severance/  the implementation (work-context reader, seal, runner,
                        check, context seam, profile mgmt, installer)
    share/severance/    the generic enclave note + the runner relay unit

## Safety notes

- The wall is the kernel. `.ignore` files, permission lists, and git config are
  NOT the boundary; never rely on them for it.
- The enclave group is TRANSIENT: the login user is never a permanent member,
  only a per-session one. `severance check` refuses if that is violated.
- Entering the enclave is always a human sudo prompt. There is deliberately no
  passwordless `work`.
