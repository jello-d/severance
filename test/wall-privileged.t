#!/bin/sh
# test/wall-privileged.t - the wall actually DENIES a non-member.
#
# This is severance's central claim -- "the wall is the kernel" -- and it is
# the one thing no other test can reach. Proving it needs TWO identities and a
# real group, and every rootless route is closed:
#
#   bubblewrap  maps ONE id, so the enclave group must be gid 0 and the
#               namespace root bypasses the very bits the wall is made of.
#   unshare +   maps a full 65535-id range (newuidmap is setuid), and grants
#   newuidmap   full caps in the namespace -- but host mounts are not OWNED by
#               that namespace, so chown to a mapped id still fails EPERM, and
#               getting an owned filesystem needs `unshare -m`, which is EPERM
#               even with CAP_SYS_ADMIN wherever the kernel restricts what an
#               unprivileged user namespace may do (Ubuntu's
#               apparmor_restrict_unprivileged_userns=1).
#
# So it needs real root, and it is SKIPPED without it. It also requires an
# explicit opt-in: it creates a group and provisions a tree, and a suite that
# quietly mutated a machine the moment it was run under sudo would be a worse
# bug than the one it is testing.
#
#   SEVERANCE_TEST_PRIVILEGED=1 sudo -E sh test/wall-privileged.t
#
# Everything it makes is removed on exit, including on failure.
set -eu

. "$(dirname "$0")/lib.sh"
harness_init wall-privileged

[ "${SEVERANCE_TEST_PRIVILEGED:-}" = 1 ] || {
  echo "ok   $TEST_NAME (skipped: set SEVERANCE_TEST_PRIVILEGED=1 to opt in)"
  exit 0; }
[ "$(id -u)" = 0 ] || {
  echo "ok   $TEST_NAME (skipped: needs real root; see the header)"; exit 0; }

SEV=$HERE/bin/severance
GRP=sev-test-wall-$$
NOBODY=${SEVERANCE_TEST_NONMEMBER:-nobody}
# Its PRIMARY GID by number: `--regid=nobody` assumes a group of that name,
# which most systems do not have (nobody's group is usually nogroup), and the
# failure would look like the wall misbehaving rather than the test being
# wrong.

# Clean up whatever we made, whichever way we leave. harness_init already traps
# EXIT for $T; this adds the one thing outside it.
cleanup() { groupdel "$GRP" 2>/dev/null || true; rm -rf "$T"; }
trap cleanup EXIT INT TERM

NOBODY_GID=$(id -g "$NOBODY" 2>/dev/null || true)
id -u "$NOBODY" >/dev/null 2>&1 || {
  echo "ok   $TEST_NAME (skipped: no '$NOBODY' account to test denial with)"
  exit 0; }

groupadd "$GRP" || fail "could not create the test group"
mkdir -p "$T/pg" "$T/wt"
printf 'work_group=%s\nwork_dir=%s/wt\n' "$GRP" "$T" > "$T/pg/demo"

# The tree must be reachable BY PATH for a non-member to be denied at the gate
# rather than at some parent we happened to make private.
chmod 0755 "$T"

env WC_PROFILES_DIR="$T/pg" NO_COLOR=1 SEVERANCE_SHARE="$HERE/share" \
  "$SEV" seal demo >/dev/null 2>&1 || fail "seal failed as root"

# --- the gate is what the audit says it is ----------------------------------
mode=$(stat -c '%a' "$T/wt"); own=$(stat -c '%U:%G' "$T/wt")
[ "$mode" = 2770 ] || fail "sealed tree is mode $mode, want 2770"
[ "$own" = "root:$GRP" ] || fail "sealed tree is owned $own, want root:$GRP"

# --- THE CLAIM: a non-member cannot get in ----------------------------------
# setpriv drops to the other account with NO supplementary groups, which is
# exactly a personal process: not the owner, not in the group, and `other` has
# no bits.
if setpriv --reuid="$NOBODY" --regid="$NOBODY_GID" --clear-groups \
     sh -c "cd '$T/wt'" 2>/dev/null; then
  fail "THE WALL DOES NOT HOLD: a non-member entered the sealed tree"
fi

# Reading it is denied too, not merely traversing: a personal process must not
# be able to enumerate what is in there either.
if setpriv --reuid="$NOBODY" --regid="$NOBODY_GID" --clear-groups \
     sh -c "ls '$T/wt'" >/dev/null 2>&1; then
  fail "THE WALL DOES NOT HOLD: a non-member listed the sealed tree"
fi

# And a file INSIDE is unreachable, which is what the default ACL is for: the
# gate could hold while something written later was still world-readable.
: > "$T/wt/secret"; chmod 0644 "$T/wt/secret"
if setpriv --reuid="$NOBODY" --regid="$NOBODY_GID" --clear-groups \
     sh -c "cat '$T/wt/secret'" >/dev/null 2>&1; then
  fail "THE WALL DOES NOT HOLD: a non-member read a file inside"
fi

# --- ...and a MEMBER can ------------------------------------------------------
# The other half: a wall that denied everyone would pass every assertion above
# and be useless. Same account, same uid -- the ONLY difference is the group.
GID=$(getent group "$GRP" | cut -d: -f3)
setpriv --reuid="$NOBODY" --regid="$NOBODY_GID" --groups="$GID" \
  sh -c "cd '$T/wt'" 2>/dev/null ||
  fail "the wall is too tight: a GROUP MEMBER was denied"

# --- a file created by a member inherits the wall ---------------------------
# The default ACL's job: something written LATER is born unreachable, which is
# what survives an edit where ownership does not.
setpriv --reuid="$NOBODY" --regid="$NOBODY_GID" --groups="$GID" \
  sh -c "umask 000; : > '$T/wt/born'" 2>/dev/null ||
  fail "a group member could not write into the tree"
if setpriv --reuid="$NOBODY" --regid="$NOBODY_GID" --clear-groups \
     sh -c "cat '$T/wt/born'" >/dev/null 2>&1; then
  fail "a file born inside the wall was readable by a non-member"
fi

pass
