#!/bin/sh
# test/work.t - behavioral test for bin/work's two read-only verbs, `current`
# (which enclave is this?) and `check` (am I in one?).
#
# Both are exercised END TO END against REAL groups: the test builds profile
# records whose work_group names a group this user actually holds, so the
# primary/supplementary ranking is read out of the real id(1) and the real
# /proc rather than a stub that could agree with a wrong implementation. The
# only stub is `sudo`, present to PROVE it is never reached: these verbs
# dispatch above the re-exec precisely so they cannot hang on a TTY-less sudo
# prompt, and that is the load-bearing safety property here.
#
# Nothing outside the scratch dir is read or written: WC_PROFILES_DIR and
# WC_DEFAULT_FILE point into T, so the box's own profiles never load.
set -eu

. "$(dirname "$0")/lib.sh"
harness_init work

WORK=$HERE/bin/work
WCLIB=$HERE/libexec/work-context.sh
SEV=$HERE/bin/severance
PG=$T/pg
mkdir -p "$PG" "$T/bin"

# The sudo tripwire: loud, and leaves evidence a later assertion checks.
{ echo '#!/bin/sh'
  echo 'echo "work.t: sudo reached" >&2'
  printf 'touch %s/sudo-called\n' "$T"
  echo 'exit 1'
} > "$T/bin/sudo"
chmod +x "$T/bin/sudo"

# Run bin/work against the scratch profiles. The ambient work vars are unset so
# a run from INSIDE a real work session cannot leak a profile in.
work() {
  env -u WORK_PROFILE -u WORK_REEXEC -u WC_CONFIG \
    SEVERANCE_LIB="$WCLIB" WC_PROFILES_DIR="$PG" \
    WC_DEFAULT_FILE="$T/default" PATH="$T/bin:$PATH" \
    sh "$WORK" "$@"
}

# Write a record: mkprof <name> <group>
mkprof() { printf 'work_group=%s\nwork_dir=/tmp/wk-%s\n' "$2" "$1" > "$PG/$1"; }

# Real groups to rank against. PRIMARY is this process's primary group; SUPP is
# a supplementary one (any group from the full set that is not the primary).
# NONE names no group at all, so it can never match.
PRIMARY=$(id -gn)
SUPP=$(for g in $(id -Gn); do
         [ "$g" = "$PRIMARY" ] || { echo "$g"; break; }
       done)
NONE=severance-no-such-group

# --- current: no profiles provisioned ----------------------------------------
out=$(work current) || fail "current: non-zero exit with no profiles"
[ -z "$out" ] || fail "current: printed '$out' with no profiles provisioned"

# --- current: a profile whose group we do NOT hold ---------------------------
mkprof alpha "$NONE"
out=$(work current) || fail "current: non-zero exit when outside every profile"
[ -z "$out" ] || fail "current: printed '$out' while outside every profile"

# Exit 0 is the whole point of the value form: `t=$(work current)` must not
# also have to trap a status. check, the predicate, says 1 for the same state.
work check && fail "check: exit 0 while outside every profile"

# --- current: a profile on our PRIMARY group ---------------------------------
mkprof alpha "$PRIMARY"
out=$(work current) || fail "current: non-zero exit inside a profile"
[ "$out" = alpha ] || fail "current: got '$out', want 'alpha'"
work check || fail "check: exit 1 while inside profile alpha"

# --- current SCANS every profile, it does not resolve one --------------------
# The match is the LAST record and is not the default marker, so a resolve-one
# implementation (wc_load's default/sole-profile rule) would answer 'nothing'.
mkprof alpha "$NONE"
mkprof zeta "$PRIMARY"
printf 'alpha\n' > "$T/default"
out=$(work current) || fail "current: non-zero exit on a multi-profile box"
[ "$out" = zeta ] || fail "current: got '$out', want 'zeta' (scan, not resolve)"
work check || fail "check: exit 1 in a NON-default profile's group"
rm -f "$T/default"

# --- current answers with NO default marker and several profiles -------------
# wc_load alone returns 4 and prints here; the scan must still answer, silently.
err=$(work current 2>&1 >/dev/null) ||
  fail "current: non-zero exit, several profiles"

[ -z "$err" ] || fail "current: wrote to stderr on the normal path: '$err'"

# --- nesting: a PRIMARY match outranks a SUPPLEMENTARY one -------------------
# `work A` from inside `work B` leaves the pid in both groups, with the inner
# one made primary by `sudo -g`. The innermost is the one you are in.
#
# The names are chosen so the SUPPLEMENTARY match sorts FIRST in the scan: the
# rank has to beat scan order, so a first-match-wins implementation must fail
# here rather than coincidentally agree.
if [ -n "$SUPP" ]; then
  rm -f "$PG"/*
  mkprof a-outer "$SUPP"
  mkprof z-inner "$PRIMARY"
  out=$(work current) || fail "current: non-zero exit with two matches"
  [ "$out" = z-inner ] ||
    fail "current: got '$out', want 'z-inner' (primary outranks supplementary)"

  # ...and a supplementary match alone still counts: you ARE in that enclave.
  rm -f "$PG"/*
  mkprof a-outer "$SUPP"
  out=$(work current) || fail "current: non-zero exit on a supplementary match"
  [ "$out" = a-outer ] ||
    fail "current: got '$out', want 'a-outer' (supplementary-only match)"
  work check || fail "check: exit 1 on a supplementary-only match"
else
  echo "work.t: note: single-group user, nesting rank not exercised" >&2
fi

# --- the PID form reads /proc, and agrees with the no-arg form ---------------
# $$ is this test shell, which holds the same groups as the `work` child.
rm -f "$PG"/*
mkprof alpha "$PRIMARY"
out=$(work current $$) || fail "current PID: non-zero exit"
[ "$out" = alpha ] || fail "current PID: got '$out', want 'alpha'"
work check $$ || fail "check PID: exit 1 while inside alpha"

# A pid with no /proc entry is simply not in a group, never an error. Asked
# WHILE alpha would match for this process, so an implementation that ignored
# the pid and answered for itself would wrongly print alpha here.
out=$(work current 999999) || fail "current: non-zero exit on a dead pid"
[ -z "$out" ] || fail "current: answered '$out' for a dead pid (ignored PID?)"
work check 999999 && fail "check: exit 0 for a dead pid"

mkprof alpha "$NONE"
out=$(work current $$) || fail "current PID: non-zero exit when outside"
[ -z "$out" ] || fail "current PID: printed '$out' while outside"
work check $$ && fail "check PID: exit 0 while outside"

# --- it prints the PROFILE name, not the group name --------------------------
rm -f "$PG"/*
mkprof renamed "$PRIMARY"
out=$(work current)
[ "$out" = renamed ] || fail "current: got '$out', want the profile name"
[ "$out" = "$PRIMARY" ] && [ "$PRIMARY" != renamed ] &&
  fail "current: printed the group name, not the profile name"

# --- a pinned profile arg narrows the scan to that one -----------------------
rm -f "$PG"/*
mkprof alpha "$NONE"
mkprof zeta "$PRIMARY"
out=$(work zeta current) || fail "current: non-zero exit with a pinned profile"
[ "$out" = zeta ] || fail "current: pinned zeta, got '$out'"
out=$(work alpha current) || fail "current: non-zero exit, pinned non-match"
[ -z "$out" ] || fail "current: pinned alpha (no match) but printed '$out'"

# --- a broken record is LOUD but does not hide a good answer -----------------
printf 'bogus_key=1\nwork_dir=/tmp/wk-broken\n' > "$PG/broken"
out=$(work current 2>/dev/null) ||
  fail "current: non-zero exit past a bad record"
[ "$out" = zeta ] || fail "current: bad record hid the answer (got '$out')"
err=$(work current 2>&1 >/dev/null) || true
case $err in
  *bogus_key*) ;;
  *) fail "current: a record that fails to parse was silent" ;;
esac
rm -f "$PG/broken"

# --- argument validation, shared by both verbs -------------------------------
for v in current check; do
  work "$v" notapid 2>/dev/null && fail "$v: exit 0 on a non-numeric pid"
  rc=0; work "$v" notapid 2>/dev/null || rc=$?
  [ "$rc" = 2 ] || fail "$v: got rc=$rc on a bad pid, want 2"
  rc=0; work "$v" 1 2 2>/dev/null || rc=$?
  [ "$rc" = 2 ] || fail "$v: got rc=$rc on too many args, want 2"
done

# --- THE safety property: neither verb ever reaches sudo ---------------------
# work treats an unrecognised arg1 as a command to run, which falls through to
# a sudo re-exec; without the early dispatch these verbs HANG with no TTY.
[ -e "$T/sudo-called" ] && fail "current/check reached the sudo re-exec"

# --- work_group DERIVES from the profile name --------------------------------
# End to end: a record with NO work_group, named after a group we really hold,
# must rank as a match on the derived name alone.
rm -f "$PG"/*
printf 'work_dir=/tmp/wk-derived\n' > "$PG/$PRIMARY"
out=$(work current) || fail "current: non-zero exit on a derived group"
[ "$out" = "$PRIMARY" ] ||
  fail "derive: a record with no work_group did not match (got '$out')"
rm -f "$PG"/*

printf 'work_dir=/tmp/wk-derived\n' > "$PG/derived"
rd=". '$WCLIB'; wc_load derived; echo \$WC_GROUP"
got=$(WC_PROFILES_DIR="$PG" sh -c "$rd")
[ "$got" = derived ] || fail "derive: WC_GROUP is '$got', want 'derived'"

# An explicit work_group still overrides the derived one.
printf 'work_group=other\nwork_dir=/tmp/wk-derived\n' > "$PG/derived"
got=$(WC_PROFILES_DIR="$PG" sh -c "$rd")
[ "$got" = other ] || fail "derive: override ignored, WC_GROUP is '$got'"

# ...and validate WARNS about that second name, without failing the record.
rep=$(WC_PROFILES_DIR="$PG" NO_COLOR=1 "$SEV" validate derived) ||
  fail "validate: non-zero on a legal work_group override"
case $rep in
  *WARN*"differs from the profile name"*) ;;
  *) fail "validate: no warning for work_group != profile name" ;;
esac
printf 'work_dir=/tmp/wk-derived\n' > "$PG/derived"
rep=$(WC_PROFILES_DIR="$PG" NO_COLOR=1 "$SEV" validate derived) ||
  fail "validate: non-zero on a derived work_group"
case $rep in
  *WARN*) fail "validate: warned about a work_group that did not diverge" ;;
esac

pass
