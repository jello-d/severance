#!/bin/sh
# test/seal-real.t - the seal against a REAL filesystem, with no stubs.
#
# WHY this exists. test/severance.t covers the seal audit by stubbing `getent`,
# `stat` and `getfacl`, so it proves the check's LOGIC given a set of verdicts
# -- not that severance produces those verdicts, and not that the audit reads a
# real wall correctly. The privileged apply was only ever proven by logging its
# sudo calls under SEVERANCE_DRYRUN. Between the two, nothing exercised the
# actual chown/chmod/setfacl against a filesystem.
#
# This runs the real `severance seal` as a mapped root inside a bubblewrap user
# namespace, then asserts the resulting tree with the real stat(1) and
# getfacl(1), then drives each wall knob to real drift and requires the real
# `severance check --seal` to catch it. No stubs at all.
#
# THE COMPROMISE, stated plainly: bubblewrap maps ONE id, so the enclave group
# here must be gid 0. `chown root:<other-group>` fails with EINVAL against an
# unmapped gid, and mapping a range needs newuidmap through a userns this
# system's AppArmor policy denies unprivileged processes
# (apparmor_restrict_unprivileged_userns=1). The seal code is group-agnostic --
# it uses $WC_GROUP throughout -- so a degenerate group still exercises every
# line. What it CANNOT prove is the thing that needs a second identity: that a
# non-member is actually denied. See the note at the end.
#
# SKIPPED, not failed, where bubblewrap is unavailable or userns is denied: a
# test that cannot run must not read as a test that passed.
set -eu

. "$(dirname "$0")/lib.sh"
harness_init seal-real

command -v bwrap >/dev/null 2>&1 || {
  echo "ok   $TEST_NAME (skipped: no bwrap)"; exit 0; }
# A FAITHFUL probe: the same mount shape the real run uses. A thinner one
# fails for its own reasons (no lib symlinks, so nothing can even link) and
# would report "namespaces denied" on a system where they work fine.
bwrap --unshare-user --uid 0 --gid 0 --tmpfs / --ro-bind /usr /usr \
  --symlink usr/lib /lib --symlink usr/lib64 /lib64 \
  --symlink usr/bin /bin /usr/bin/true >/dev/null 2>&1 || {
  echo "ok   $TEST_NAME (skipped: user namespaces denied here)"; exit 0; }

SEVROOT=$HERE
mkdir -p "$T/etc" "$T/home" "$T/pg" "$T/sbin"
cp /etc/group /etc/passwd "$T/etc/" 2>/dev/null || true
cp /etc/nsswitch.conf "$T/etc/" 2>/dev/null || true
# /etc/alternatives carries the symlinks awk and friends resolve through; a
# bare /etc silently breaks them mid-audit.
cp -r /etc/alternatives "$T/etc/" 2>/dev/null || true
# We ARE uid 0 in there, so sudo is a pass-through rather than a stub that
# lies: every privileged call really happens.
printf '#!/bin/sh\nexec "$@"\n' > "$T/sbin/sudo"; chmod +x "$T/sbin/sudo"
ln -sf /sev/bin/severance "$T/sbin/severance"
printf 'work_group=root\nwork_dir=/home/wt\n' > "$T/pg/demo"

inns() {   # run a script inside the namespace
  printf '%s\n' "$1" > "$T/script"
  bwrap --unshare-user --uid 0 --gid 0 \
    --tmpfs / --ro-bind /usr /usr \
    --symlink usr/bin /bin --symlink usr/sbin /sbin \
    --symlink usr/lib /lib --symlink usr/lib64 /lib64 \
    --bind "$T/etc" /etc --bind "$T/home" /home --ro-bind "$T/sbin" /sbin-shim \
    --ro-bind "$SEVROOT" /sev --ro-bind "$T/script" /script --bind "$T/pg" /pg \
    --proc /proc --dev /dev --tmpfs /tmp \
    --setenv PATH /sbin-shim:/usr/bin:/bin --setenv HOME /home \
    --setenv WC_PROFILES_DIR /pg --setenv NO_COLOR 1 \
    --setenv SEVERANCE_SHARE /sev/share \
    sh /script 2>&1
}

# --- a real seal produces a real wall ---------------------------------------
out=$(inns 'set -eu
mkdir -p /home/wt
severance seal demo >/dev/null 2>&1 || echo SEAL-FAILED
stat -c "MODE %a OWNER %U:%G" /home/wt
getfacl -p /home/wt 2>/dev/null | grep "^default:" \
  | tr "\n" " "; echo') || true
case $out in
  *SEAL-FAILED*) fail "seal errored inside the namespace: $out" ;;
esac

# The gate itself: 2770 root-owned. `other` having NO bits is what denies a
# non-member at traversal, which is the whole wall.
case $out in
  *"MODE 2770"*) ;;
  *) fail "seal did not leave work_dir at 2770: $out" ;;
esac
case $out in
  *"OWNER root:root"*) ;;
  *) fail "seal did not leave work_dir root-owned: $out" ;;
esac
# The DEFAULT ACL is what makes a file created LATER inherit the wall. Without
# it the gate holds but everything written inside is born reachable.
case $out in
  *"default:group:root:rwx"*) ;;
  *) fail "seal did not set the default group ACL: $out" ;;
esac
case $out in
  *"default:other::---"*) ;;
  *) fail "seal did not deny 'other' on new entries: $out" ;;
esac

# --- the PER-TOOL sealed dirs, which the gate's assertions do not cover -----
# work_dir is the wall, but the config root and each tool dir under it are
# sealed too (belt-and-braces: the gate's traversal denial is what actually
# keeps a personal process out, so inner state stays safe whatever its owner).
# Asserting only the gate left a mutation that dropped the identity dirs' ACL
# entirely passing, which is why these are here.
out=$(inns 'set -eu
mkdir -p /home/wt
severance seal demo >/dev/null 2>&1
for d in /home/wt/.config /home/wt/.config/gcloud; do
  [ -d "$d" ] || { echo "MISSING $d"; continue; }
  printf "%s %s " "$d" "$(stat -c "%U:%G/%a" "$d")"
  getfacl -p "$d" 2>/dev/null | grep -c "^default:other::---" 
done') || true
for d in /home/wt/.config /home/wt/.config/gcloud; do
  echo "$out" | grep -q "^$d root:root/2770 " ||
    fail "sealed dir $d is not root:root 2770: $out"
done
# One `default:other::---` per dir: a new file born inside must not be
# world-reachable.
#
# Note what this does NOT distinguish, verified rather than assumed: removing
# the explicit setfacl from the identity-dir seal changes nothing here, because
# these dirs are created UNDER the already-sealed gate and INHERIT its default
# ACL. The explicit call is the "belt-and-braces" the code claims, and it is
# genuinely redundant on this path -- it earns its keep only for a dir that
# predates the gate's seal.
[ "$(echo "$out" | grep -c '^/home/wt/.config.* 1$')" = 2 ] ||
  fail "a sealed dir is missing its default other::--- ACL: $out"

# --- the real check passes on that real wall --------------------------------
# Nothing is stubbed here: stat, getfacl and getent are the real programs
# reading the tree the seal just made.
out=$(inns 'severance check --seal 2>&1') || true
for want in "work_dir owner root:root" "work_dir mode 2770" \
            "work_dir default group ACL" "work_dir default other ACL"; do
  echo "$out" | grep -q "\[OK\].*$want" ||
    fail "check did not pass on a real sealed wall: missing '$want'"
done

# --- each wall knob, driven to REAL drift -----------------------------------
# The stubbed version of this proves the check reacts to a verdict it was
# handed. This proves it reacts to the filesystem.
drift() {   # <mutation> <expected FAIL fragment>
  # `|| true`: check exits non-zero BY DESIGN here -- that is the case under
  # test -- and must not trip this script's own set -e.
  out=$(inns "set -eu
mkdir -p /home/wt
severance seal demo >/dev/null 2>&1
$1
severance check --seal 2>&1") || true
  echo "$out" | grep -q "\[FAIL\].*$2" ||
    fail "check missed real drift: $1 (wanted FAIL '$2')"
}
drift 'chmod 0755 /home/wt'                    'work_dir mode'
drift 'setfacl -k /home/wt'                    'default group ACL'
drift 'setfacl -d -m o::rx /home/wt'           'default other ACL'

# --- seal is IDEMPOTENT against a real tree ---------------------------------
# Provisioning twice must be indistinguishable from once, or re-running it is
# a gamble rather than a repair.
out=$(inns 'set -eu
mkdir -p /home/wt
severance seal demo >/dev/null 2>&1
stat -c "%a %U:%G" /home/wt > /tmp/a
getfacl -p /home/wt 2>/dev/null | grep "^default:" >> /tmp/a
severance seal demo >/dev/null 2>&1
stat -c "%a %U:%G" /home/wt > /tmp/b
getfacl -p /home/wt 2>/dev/null | grep "^default:" >> /tmp/b
cmp -s /tmp/a /tmp/b && echo IDEMPOTENT || { echo CHANGED; diff /tmp/a /tmp/b; }
severance check --seal >/dev/null 2>&1 && echo STILL-CLEAN || echo DRIFTED')
case $out in
  *IDEMPOTENT*) ;;
  *) fail "a second seal changed the real wall: $out" ;;
esac
case $out in
  *STILL-CLEAN*) ;;
  *) fail "check drifted after a second seal: $out" ;;
esac

# --- what this CANNOT prove --------------------------------------------------
# That a non-member is DENIED. It needs a second identity: inside the namespace
# we are root, and root bypasses the permission bits the wall is made of.
# Mapping a second id needs newuidmap through a user namespace this system's
# AppArmor policy denies unprivileged processes, so the only ways to prove
# denial are real root or a VM. Asserted here so the limit is recorded next to
# the coverage rather than remembered:
[ "$(id -u)" = 0 ] && fail "running as real root: extend this to test DENIAL"

pass
