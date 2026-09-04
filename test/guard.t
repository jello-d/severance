#!/bin/sh
# test/guard.t - the ZDR REFUSE: `severance guard` exits 1 when the process is
# inside an enclave's work tree WITHOUT that enclave's group, else 0.
#
# Driven against REAL groups and REAL directories in a scratch tree, because
# the two questions the guard asks are easy to conflate and the failure is
# SILENT: it returns 0, valet-key reads that as "proceed", and the refuse never
# fires. It regressed exactly that way once, when the guard started asking
# "which enclave do I hold the group for" (which clears its state when the
# answer is none) instead of "which enclave's tree is this".
#
# The scratch work_dirs are ordinary directories, NOT sealed 2770 trees: the
# guard must not depend on being able to traverse the tree to canonicalise it,
# since a sealed one cannot be traversed without the very group being tested.
set -eu

. "$(dirname "$0")/lib.sh"
harness_init guard

SEV=$HERE/bin/severance
PG=$T/pg
mkdir -p "$PG"

guard() {   # runs in the CURRENT directory
  env -u WORK_PROFILE -u WORK_REEXEC -u WC_CONFIG -u SEVERANCE_PROFILES_DIR \
    WC_PROFILES_DIR="$PG" WC_DEFAULT_FILE="$T/default" NO_COLOR=1 \
    sh "$SEV" guard
}
mkprof() {   # <name> <group> <dir>
  printf 'work_group=%s\nwork_dir=%s\n' "$2" "$3" > "$PG/$1"
  mkdir -p "$3/sub"
}

MINE=$(id -gn)
NONE=severance-no-such-group

mkprof theirs "$NONE" "$T/theirs"
mkprof mine   "$MINE" "$T/mine"
mkdir -p "$T/elsewhere"

# --- inside a tree WITHOUT its group: REFUSE ---------------------------------
rc=0; ( cd "$T/theirs/sub" && guard ) >/dev/null 2>&1 || rc=$?
[ "$rc" = 1 ] || fail "guard: rc=$rc inside a foreign work tree, want 1"
err=$( ( cd "$T/theirs/sub" && guard ) 2>&1 >/dev/null ) || true
case $err in
  *REFUSING*) ;;
  *) fail "guard: refused without saying why: '$err'" ;;
esac
# It must name the ENCLAVE it is refusing for, not just "a work tree". The
# profile is named distinctly from its directory, so matching the path does not
# accidentally satisfy this.
mkprof named-enclave "$NONE" "$T/plaindir"
err=$( ( cd "$T/plaindir/sub" && guard ) 2>&1 >/dev/null ) || true
case $err in
  *named-enclave*) ;;
  *) fail "guard: refusal does not name the profile: '$err'" ;;
esac
rm -f "$PG/named-enclave"

# The same, with NO profile at all whose group we hold. This is the real ZDR
# scenario -- a personal user standing in a work tree -- and it is the state
# that broke: an implementation resolving "which enclave do I hold the group
# for" gets *none*, clears its state, and finds nothing left to compare the
# path against, so it returns 0 and the refuse never fires.
mv "$PG/mine" "$T/mine.rec"
rc=0; ( cd "$T/theirs/sub" && guard ) >/dev/null 2>&1 || rc=$?
[ "$rc" = 1 ] ||
  fail "guard: rc=$rc in a work tree while holding NO enclave group, want 1"
mv "$T/mine.rec" "$PG/mine"

# --- inside a tree WITH its group: proceed -----------------------------------
rc=0; ( cd "$T/mine/sub" && guard ) >/dev/null 2>&1 || rc=$?
[ "$rc" = 0 ] || fail "guard: rc=$rc inside our OWN work tree, want 0"

# --- outside every tree: proceed ---------------------------------------------
rc=0; ( cd "$T/elsewhere" && guard ) >/dev/null 2>&1 || rc=$?
[ "$rc" = 0 ] || fail "guard: rc=$rc outside every work tree, want 0"

# --- with NO profiles at all: proceed ----------------------------------------
rm -f "$PG"/*
rc=0; ( cd "$T/theirs/sub" && guard ) >/dev/null 2>&1 || rc=$?
[ "$rc" = 0 ] || fail "guard: rc=$rc with no profiles provisioned, want 0"

# --- a NON-DEFAULT enclave's tree is guarded too -----------------------------
# Resolving a single profile (the default marker) left every other enclave's
# tree unguarded. The scan has to cover them all.
mkprof theirs "$NONE" "$T/theirs"
mkprof mine   "$MINE" "$T/mine"
printf 'mine\n' > "$T/default"
rc=0; ( cd "$T/theirs/sub" && guard ) >/dev/null 2>&1 || rc=$?
[ "$rc" = 1 ] || fail "guard: rc=$rc in a NON-default enclave's tree, want 1"
rm -f "$T/default"

# --- the work_dir prefix must not match a SIBLING ----------------------------
# "$T/theirs" must not capture "$T/theirs-other": a prefix test without the
# separator would guard an unrelated directory.
mkdir -p "$T/theirs-other"
rc=0; ( cd "$T/theirs-other" && guard ) >/dev/null 2>&1 || rc=$?
[ "$rc" = 0 ] || fail "guard: rc=$rc in a SIBLING of a work tree, want 0"

# --- an UNTRAVERSABLE work_dir is still matched ------------------------------
# The sealed tree is 2770 root:<group>: without the group it cannot be entered
# to canonicalise, which is exactly the state being guarded. So the CONFIGURED
# spelling has to be matched too, or the refuse silently never fires for a real
# sealed enclave. cwd is opened first, then the tree is locked behind us --
# getcwd(2) keeps working, `cd` into it does not.
mkdir -p "$T/locked/sub"
printf 'work_group=%s\nwork_dir=%s\n' "$NONE" "$T/locked" > "$PG/locked"
rc=0
( cd "$T/locked/sub" && chmod 000 "$T/locked" && guard ) \
  >/dev/null 2>&1 || rc=$?
chmod 755 "$T/locked"
[ "$rc" = 1 ] || fail "guard: rc=$rc inside an UNTRAVERSABLE work tree, want 1"
rm -f "$PG/locked"

# --- a SYMLINKED work_dir is matched from the real path too ------------------
# work_dir names a symlink while the cwd resolves to its target. Comparing only
# the configured spelling never matches, and the refuse silently never fires.
mkdir -p "$T/real/sub"
ln -sfn "$T/real" "$T/aliased"
printf 'work_group=%s\nwork_dir=%s\n' "$NONE" "$T/aliased" > "$PG/aliased"
rc=0; ( cd "$T/real/sub" && guard ) >/dev/null 2>&1 || rc=$?
[ "$rc" = 1 ] || fail "guard: rc=$rc under a SYMLINKED work_dir, want 1"
# ...and from the symlinked spelling as well.
rc=0; ( cd "$T/aliased/sub" && guard ) >/dev/null 2>&1 || rc=$?
[ "$rc" = 1 ] || fail "guard: rc=$rc via the symlink spelling, want 1"
rm -f "$PG/aliased"

# --- the work_dir root itself counts as inside -------------------------------
rc=0; ( cd "$T/theirs" && guard ) >/dev/null 2>&1 || rc=$?
[ "$rc" = 1 ] || fail "guard: rc=$rc at the work_dir root itself, want 1"

pass
