# Enclave users: one account per enclave (DESIGN, for review)

Status: PROPOSED. Nothing here is built. It replaces the group model
(sealed tree, transient group, separate runner account) with one dedicated
account per enclave, and it changes published contracts, so it is written
down for review before any code. Each decision says why; each open question
says what would settle it.

## Why the group model goes

Under the group model a work session is the LOGIN user's uid plus the
enclave group. That makes the wall one-directional:

- personal processes cannot read the sealed tree, which is the part that
  works;
- the work session can read EVERYTHING the login user owns, because it is
  that uid;
- anything the work session writes outside the tree (caches, history, a
  package manager's store) lands in the personal home, readable by personal
  processes. The tools table and its env routing exist to plug that one tool
  at a time, and a per-tool list can never be complete;
- containers need a second identity anyway, because `newgidmap` refuses a
  caller whose real gid differs from its passwd gid, and because any
  container run as the login user lives in a user namespace that user owns:
  measured, an unrelated personal process can `strace` it and `nsenter` into
  it with full capabilities, while Yama refuses the same attach on a plain
  process. So each enclave already costs a group AND a runner account.

One account per enclave closes all of it structurally. The uid is the wall,
in both directions, and the account can run its own containers because
nothing personal owns its namespaces.

## The model

    enclave     a name, a DNS label (unchanged rule): `acme`
    account     <login-user>-<enclave>, e.g. `alice-acme`
                SYSTEM uid range (below UID_MIN), its own user-private group,
                a real login shell, home /home/<account> mode 0700
    registry    /etc/severance/enclaves/<enclave>, root-owned, world-readable
    share dir   /run/severance/<enclave>/, <login-user>:<account> 0710
    docker      a SYSTEM unit running rootless dockerd as the account
    session     the account LINGERS, so its user manager is always up

### Why a system uid

Measured on a current Ubuntu desktop: an account below UID_MIN runs a user
manager with its own session bus and stops cleanly; the user units that skip
system accounts (`ConditionUser=!@system`) are first-login setup, a file
indexer, `mpris-proxy` and a screensaver, none of which an enclave needs. It
is hidden from the greeter and account lists, which is wanted: an enclave is
not something anyone logs in to. And it is the ONLY handle a unit has for
"not a person": `ConditionUser=@system` matches on the range, and
`ConditionGroup=` accepts no such value. An integrator gating the audio stack
on `!@system` keeps every enclave from starting its own PipeWire (a lingering
regular-range account did exactly that, and won a race for the sound card).

Costs, all handled: `useradd --system` allocates no subordinate ids
(severance does, as today), and the account needs a real shell for `sudo -i`.
Not yet verified: an application that refuses to run under a system uid. The
end-to-end proof is where that gets settled.

### Why the registry moves to /etc

`severance current` must answer the same way whoever asks, and the enclave
account cannot read the login user's home. So the list of enclaves lives in
a root-owned, world-readable place both identities can read, which is also
what the install-placement rule requires of anything root acts on. Enclave
names are not secret. One record per enclave, `key=value`, parsed and never
sourced, as today:

    # /etc/severance/enclaves/acme
    owner=alice                    # REQUIRED: the login user it belongs to
    git_remote_glob=*acme*         # optional: the repo-consistency audit
    docker=yes                     # optional, default yes

The account name, home and share dir DERIVE from the name and the owner, so
they are not stored twice. uid is read from passwd, never recorded. `owner`
is a key, not "whoever runs this", because the account name has to come out
the same whether root, the owner or the enclave asks; it also lets a second
person on the box own enclaves of their own. BUILT: the reader and
`severance enclaves` (lib/enclave_lib, test/enclaves.t).

### Why docker stays a system unit

Measured: rootless dockerd runs as a system unit with `User=`, `Delegate=yes`
and `RuntimeDirectory=`, with no user manager, with cgroup limits working,
and with a container writing files that land owned by the account. One
TEMPLATE serves every enclave, `severance-dockerd@<account>.service`,
root-owned, so the enclave cannot edit its own daemon's definition, and root
audits see it. The socket lives in the unit's runtime dir, owned by the
account, so the account's own shell reaches it directly: no group socket, no
socat relay, no tmpfiles line, and no traverse ACL on the login user's home.

The enclave now HAS a user manager (it lingers, below), so a `--user` dockerd
would also work. The system unit is kept anyway: its definition is
root-owned, and teardown does not depend on a user manager having exited.

## The share dir: what crosses, and how

The enclave's apps run in the login user's desktop session. Nothing in the
session's runtime dir may be opened to them: its sockets are world-writable
and the 0700 directory is the only gate, so any grant there hands out every
socket by its well-known name, the audio graph's manager socket included.
Instead each enclave gets its own directory of narrowed sockets:

    /run/severance/<enclave>/          <login-user>:<account> 0710
        wayland-0     a security-context display socket (restricted)
        pulse         an audio socket for this enclave only
        relay         the notification relay's login-user end

0710 with the ACCOUNT's own group lets the enclave traverse to a socket it
names and nothing else in. Created by a tmpfiles line at boot (root); filled
by the login user's session. Every socket in it is created and served by the
LOGIN user's side; the enclave only ever connects.

- DISPLAY: a small helper in the login user's session binds `wayland-0` and
  registers it through `wp_security_context_manager_v1`, as Flatpak does
  (sandbox engine `severance`, app id and instance id = the enclave). The
  compositor then offers clients on it only an ALLOWLIST of protocols: no
  screen capture, no clipboard reading, no synthetic input, and window
  capture of the enclave's OWN windows only, so screen sharing from an
  enclave browser shows that enclave and nothing else. The allowlist is the
  compositor's job; this package only creates the socket. UNTIL THE
  COMPOSITOR SUPPORTS THE ALLOWLIST, ENCLAVES GET NO DISPLAY AT ALL; there is
  no interim "open the socket" fallback.
- AUDIO: one pulse address for the enclave, with ordinary access. The
  socket existing is the gate. Narrower audio (no capture of the login
  user's playback) is proven possible and deliberately deferred.
- NOTIFICATIONS: see the relay, below.

## The notification relay (owned here)

Enclave apps post notifications to THEIR OWN session bus. The login user's
bus admits only the login user's uid, so they cannot reach the login user's
notification daemon directly. The relay bridges exactly that, and nothing
else:

    enclave bus                         login user's bus
    severance-relay (as the account)    severance-relay (as the login user)
    owns org.freedesktop.Notifications  posts to the real daemon
              \                         /
               +--- share dir: relay ---+     line-delimited JSON

- Enclave to login user: notify (app name, summary, body, actions, a fixed
  subset of hints, expiry), close.
- Login user to enclave: action invoked, notification closed. Without the
  return path, clicking a chat notification does nothing.
- ONE daemon on the login user's side keeps placement, do-not-disturb and
  history coherent.

THE MARKER CONTRACT: every relayed notification carries the ENCLAVE NAME as
its app name, with the originating app's name carried into the summary. A
notification daemon such as mako matches app names exactly, so this gives an
integrator one stable criterion: anything with an enclave's name came
through the relay and is that enclave's work, whatever the app. Published
like `current`.

No URL relay: an enclave runs its own browser, so a link opened inside it
opens there, which is where work links belong. (An earlier draft had one,
for sign-in flows when the enclave had no browser.)

## Detection and entry

DETECTION is `severance current [PID]`: read the pid's real uid from
`/proc`, map it through the registry to an enclave name, print the name or
nothing. `/proc/<pid>/status` is readable by anyone, so either identity gets
the same answer. Output and exit codes UNCHANGED (one word or nothing; exit 2
when it cannot answer).

`guard` keeps its contract (exit 0 ok, 1 refuse). A personal process cannot
enter an enclave home at all now, so the guard becomes a backstop rather than
the wall; its rule is restated by uid.

ENTRY is `work`, which stays even where it is one line, because there are
right and wrong ways to become the enclave and the machinery may grow:

- WITH A TTY: `sudo -iu <account>`. `-i` matters: on a stock Debian or
  Ubuntu PAM setup it runs the full session stack, including `pam_systemd`;
  plain `sudo -u` runs the non-interactive one. Still a human prompt.
- WITHOUT A TTY (a launcher, a bar): polkit, so every launch is still a human
  prompt. It needs an authentication agent in the session. The app is handed
  to the enclave's ALREADY RUNNING user manager, which is why the enclave
  lingers: neither `pkexec` nor `run0` reliably opens a session for the
  target on such a setup.
- The enclave's session environment (display and audio socket paths, its
  docker host) is written ONCE, into the enclave's own `environment.d`, by
  severance, because every value derives from the enclave name. Terminal
  entry and launched apps then see the same environment.

## Provisioning and teardown

Privileged, idempotent, per enclave:

1. the account: `useradd --system`, user-private group, shell, home 0700;
2. subordinate uid and gid ranges, the next free 65536 block;
3. linger;
4. the registry record, the share dir's tmpfiles line, the docker unit
   instance, the `environment.d` file.

Teardown is the reverse, and VERIFIED, not announced: stop the docker
instance and the user manager, wait for the account's processes to exit, and
ask passwd whether the account is gone. A freed uid or gid is reissued to the
next account created, so nothing an enclave owned may survive it.

severance owns the mechanism; an integrator decides which enclaves exist and
provisions the tools and config inside one (a second identity's own pins and
placed files). The installed `severance` must be runnable by root and by every
enclave account, so it moves to a root-owned system prefix rather than the
login user's home.

## Contracts

    severance current [PID]   UNCHANGED output and exits; decides by uid
    severance guard           UNCHANGED exits; restated by uid
    severance enclaves        NEW. One line per enclave, tab-separated:
                              name, account, uid, home, share dir.
                              uid is `-` until the account exists.
    relay marker              NEW. App name = enclave name (see above)
    share dir layout          NEW. Names of the three sockets
    the WC_* reader           RETIRED at the contract step, below

Each change is a `docs/breaking-changes.md` entry.

## Transition: expand, prove, contract

1. EXPAND. Both models live side by side. Registry enclaves use the new
   model; existing profile records keep the group model. `current` answers
   for both (uid first, then group membership). `severance enclaves` lists
   registry enclaves only. `work` dispatches by model.
2. PROVE one enclave end to end: a browser and a chat client with display,
   sound, microphone, camera and window sharing of their own windows; the
   wall holding in BOTH directions; surviving a fresh login.
3. RETIRE the group-model enclaves with `forget`, whose teardown is
   verified, and which removes the group only once the tree is gone.
4. CONTRACT. Remove the seal, the runner, the tools table's env routing, the
   group half of `current`, the profile records and the WC_* reader.

## Open questions

1. LAUNCH WITHOUT A TTY: a transient unit in the enclave's user manager
   (polkit-authorised) or `pkexec` with the enclave's environment. Settled by
   a spike.
2. WHO WRITES REGISTRY RECORDS: a severance verb run as root, called by the
   integrator's root-scope provisioning, is the proposal.
3. THE SYSTEM INSTALL: prefix and how a provisioner places it.
4. CAMERAS: device access always (group) or only while the login user's
   session is active (ACL). The integrator's call.
5. THE DISPLAY HELPER: language and dependencies; it is one protocol
   request plus keeping a file descriptor open.
6. THE REPO AUDIT (`git_remote_glob`): a work-remote clone on the personal
   side is still a leak worth reporting. Kept, restated for the new layout.
