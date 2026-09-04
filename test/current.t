#!/bin/sh
# test/current.t - behavioral test for `severance current`, the one answer to
# "which enclave is this process in", and for the profile-name / work_group
# rules that decide what it publishes.
#
# Exercised END TO END against REAL groups: the test builds profile records
# whose work_group names a group this user actually holds, so the
# primary/supplementary ranking is read out of the real id(1) and the real
# /proc rather than a stub that could agree with a wrong implementation. The
# only stub is `sudo`, present to PROVE it is never reached: `current` is a
# query on the query binary and must never prompt, so it cannot hang with no
# TTY.
#
# Nothing outside the scratch dir is read or written: WC_PROFILES_DIR and
# WC_DEFAULT_FILE point into T, so the box's own profiles never load.
set -eu

. "$(dirname "$0")/lib.sh"
harness_init current

SEV=$HERE/bin/severance
WCLIB=$HERE/libexec/work-context.sh
PG=$T/pg
mkdir -p "$PG" "$T/bin"

# The sudo tripwire: loud, and leaves evidence a later assertion checks.
{ echo '#!/bin/sh'
  echo 'echo "current.t: sudo reached" >&2'
  printf 'touch %s/sudo-called\n' "$T"
  echo 'exit 1'
} > "$T/bin/sudo"
chmod +x "$T/bin/sudo"

# Run severance against the scratch profiles. The ambient work vars are unset
# so a run from INSIDE a real work session cannot leak a profile in.
sev() {
  env -u WORK_PROFILE -u WORK_REEXEC -u WC_CONFIG -u SEVERANCE_PROFILES_DIR \
    WC_PROFILES_DIR="$PG" WC_DEFAULT_FILE="$T/default" \
    NO_COLOR=1 PATH="$T/bin:$PATH" \
    sh "$SEV" "$@"
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

# --- no profiles provisioned -------------------------------------------------
out=$(sev current) || fail "current: non-zero exit with no profiles"
[ -z "$out" ] || fail "current: printed '$out' with no profiles provisioned"

# --- a profile whose group we do NOT hold ------------------------------------
mkprof alpha "$NONE"
out=$(sev current) || fail "current: non-zero exit when outside every profile"
[ -z "$out" ] || fail "current: printed '$out' while outside every profile"

# --- a profile on our PRIMARY group ------------------------------------------
mkprof alpha "$PRIMARY"
out=$(sev current) || fail "current: non-zero exit inside a profile"
[ "$out" = alpha ] || fail "current: got '$out', want 'alpha'"

# --- it SCANS every profile, it does not resolve one -------------------------
# The match is the LAST record and is not the default marker, so a resolve-one
# implementation (_wc_resolve's default/sole-profile rule) would answer nothing.
mkprof alpha "$NONE"
mkprof zeta "$PRIMARY"
printf 'alpha\n' > "$T/default"
out=$(sev current) || fail "current: non-zero exit on a multi-profile box"
[ "$out" = zeta ] || fail "current: got '$out', want 'zeta' (scan, not resolve)"
rm -f "$T/default"

# --- it answers with NO default marker and several profiles ------------------
# _wc_resolve alone returns 4 and prints here; the scan must still answer,
# and must stay silent doing it.
err=$(sev current 2>&1 >/dev/null) ||
  fail "current: non-zero exit with several profiles and no default"
[ -z "$err" ] || fail "current: wrote to stderr on the normal path: '$err'"

# --- nesting: a PRIMARY match outranks a SUPPLEMENTARY one -------------------
# Entering enclave A from inside enclave B leaves the pid in both groups, with
# the inner one made primary by `sudo -g`. The innermost is the one you are in.
#
# The names are chosen so the SUPPLEMENTARY match sorts FIRST in the scan: the
# rank has to beat scan order, so a first-match-wins implementation must fail
# here rather than coincidentally agree.
if [ -n "$SUPP" ]; then
  rm -f "$PG"/*
  mkprof a-outer "$SUPP"
  mkprof z-inner "$PRIMARY"
  out=$(sev current) || fail "current: non-zero exit with two matches"
  [ "$out" = z-inner ] ||
    fail "current: got '$out', want 'z-inner' (primary outranks supplementary)"

  # ...and a supplementary match alone still counts: you ARE in that enclave.
  rm -f "$PG"/*
  mkprof a-outer "$SUPP"
  out=$(sev current) || fail "current: non-zero exit on a supplementary match"
  [ "$out" = a-outer ] ||
    fail "current: got '$out', want 'a-outer' (supplementary-only match)"
else
  echo "current.t: note: single-group user, nesting rank not exercised" >&2
fi

# --- the PID form reads /proc ------------------------------------------------
# $$ is this test shell, which holds the same groups as the severance child.
rm -f "$PG"/*
mkprof alpha "$PRIMARY"
out=$(sev current $$) || fail "current PID: non-zero exit"
[ "$out" = alpha ] || fail "current PID: got '$out', want 'alpha'"

# A pid naming NO LIVE PROCESS is unanswerable, and must be an ERROR rather
# than a silent empty answer. Silence would report a process that IS behind the
# boundary as personal, and a caller testing only [ -n "$p" ] would believe it.
# Asked WHILE alpha would match for this process, so an implementation that
# ignored the pid and answered for itself would wrongly print alpha here.
dead=999999
while [ -d "/proc/$dead" ]; do dead=$((dead + 1)); done
out=$(sev current "$dead" 2>/dev/null) && fail "current: exit 0 on a dead pid"
rc=0; sev current "$dead" >/dev/null 2>&1 || rc=$?
[ "$rc" = 2 ] || fail "current: got rc=$rc for a dead pid, want 2"
[ -z "$out" ] || fail "current: answered '$out' for a dead pid (ignored PID?)"
err=$(sev current "$dead" 2>&1 >/dev/null) || true
case $err in
  *"no such process"*) ;;
  *) fail "current: dead pid did not say why: '$err'" ;;
esac

# ...and a LIVE pid outside every enclave is silent-and-zero, the other way of
# printing nothing. The two cases must not be confused.

mkprof alpha "$NONE"
out=$(sev current $$) || fail "current PID: non-zero exit for a live pid"
[ -z "$out" ] || fail "current PID: printed '$out' while outside"

# --- it prints the PROFILE name, not the group name --------------------------
rm -f "$PG"/*
mkprof renamed "$PRIMARY"
out=$(sev current)
[ "$out" = renamed ] || fail "current: got '$out', want the profile name"
[ "$out" = "$PRIMARY" ] && [ "$PRIMARY" != renamed ] &&
  fail "current: printed the group name, not the profile name"

# --- a broken record is LOUD but does not hide a good answer -----------------
mkprof zeta "$PRIMARY"
rm -f "$PG/renamed"
printf 'bogus_key=1\nwork_dir=/tmp/wk-broken\n' > "$PG/broken"
out=$(sev current 2>/dev/null) ||
  fail "current: non-zero exit past a bad record"
[ "$out" = zeta ] || fail "current: bad record hid the answer (got '$out')"
err=$(sev current 2>&1 >/dev/null) || true
case $err in
  *bogus_key*) ;;
  *) fail "current: a record that fails to parse was silent" ;;
esac
rm -f "$PG/broken"

# --- argument validation -----------------------------------------------------
sev current notapid 2>/dev/null && fail "current: exit 0 on a non-numeric pid"
rc=0; sev current notapid 2>/dev/null || rc=$?
[ "$rc" = 2 ] || fail "current: got rc=$rc on a bad pid, want 2"
rc=0; sev current 1 2 2>/dev/null || rc=$?
[ "$rc" = 2 ] || fail "current: got rc=$rc on too many args, want 2"

# --- a query NEVER prompts ---------------------------------------------------
[ -e "$T/sudo-called" ] && fail "current reached sudo"

# --- `context` is retired LOUDLY, not silently aliased -----------------------
# A stale caller must be fixed, not quietly served by a shim that hides which
# spelling is live.
rc=0; sev context resolve >/dev/null 2>&1 || rc=$?
[ "$rc" = 1 ] || fail "context resolve: got rc=$rc, want 1 (retired)"
err=$(sev context resolve 2>&1 >/dev/null) || true
case $err in
  *"severance current"*) ;;
  *) fail "context: retirement message does not name the replacement" ;;
esac

# --- work_group DERIVES from the profile name --------------------------------
# End to end: a record with NO work_group, named after a group we really hold,
# must rank as a match on the derived name alone.
rm -f "$PG"/*
printf 'work_dir=/tmp/wk-derived\n' > "$PG/$PRIMARY"
out=$(sev current) || fail "current: non-zero exit on a derived group"
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
rep=$(sev validate derived) ||
  fail "validate: non-zero on a legal work_group override"
case $rep in
  *WARN*"differs from the profile name"*) ;;
  *) fail "validate: no warning for work_group != profile name" ;;
esac
printf 'work_dir=/tmp/wk-derived\n' > "$PG/derived"
rep=$(sev validate derived) || fail "validate: non-zero on a derived work_group"
case $rep in
  *WARN*) fail "validate: warned about a work_group that did not diverge" ;;
esac

# --- a profile name is linted as a DNS LABEL ---------------------------------
# The name is the published identity: a group, a path component, and the token
# consumers use as a socket name or namespace. Underscore is legal in a Unix
# group and illegal in a DNS label, so it must be caught HERE, at provision
# time, rather than downstream at use time.
rm -f "$PG"/*
for bad in my_work UPPER -lead trail-; do
  printf 'work_dir=/tmp/wk\n' > "$PG/$bad"
  sev validate "$bad" >/dev/null 2>&1 &&
    fail "validate: accepted '$bad' as a profile name"
  rm -f "$PG/$bad"
done
for good in manifest a a-b x9-y; do
  printf 'work_dir=/tmp/wk\n' > "$PG/$good"
  sev validate "$good" >/dev/null 2>&1 ||
    fail "validate: rejected '$good', a valid DNS label"
  rm -f "$PG/$good"
done

# `init` refuses a bad name UP FRONT, and writes nothing.
rc=0; XDG_CONFIG_HOME="$T/cfg" sev init my_work >/dev/null 2>&1 || rc=$?
[ "$rc" = 2 ] || fail "init: got rc=$rc for an illegal name, want 2"
[ -e "$T/cfg/severance/profiles/my_work" ] &&
  fail "init: scaffolded a record for an illegal name"

# --- severance ships NO adapter for any consumer -----------------------------
# It used to ship one, because a consumer's seam spoke different verbs. A copy
# of our own verbs living here for someone else's benefit could only go stale,
# and did -- a rename left every deployed copy calling a verb that no longer
# existed, silently. The CLI is the contract; a one-line hook calling it
# belongs with whoever owns the box.
[ -e "$HERE/share/hooks" ] && fail "severance is shipping an adapter again"
grep -rq "valet" "$HERE/libexec" && fail "libexec names a specific consumer"

# `install` must not write into any consumer's config, even with one on PATH.
VKC=$T/vk
mkdir -p "$VKC/bin" "$VKC/valet-key"
printf '#!/bin/sh\nexit 0\n' > "$VKC/bin/valet-key"
chmod +x "$VKC/bin/valet-key"
inst_out=$( ( . "$HERE/libexec/install.sh"
              _sev_cfg() { echo "$VKC"; }
              SEVERANCE_SHARE=$HERE/share
              PATH="$VKC/bin:$PATH" _wiring_hint ) 2>&1 )
[ -e "$VKC/valet-key/context" ] &&
  fail "install wrote into a consumer's config dir"
case $inst_out in
  *"NOT wired by install"*) ;;
  *) fail "install did not say integrations are unwired: '$inst_out'" ;;
esac
case $inst_out in
  *valet*) fail "install's hint names a specific consumer" ;;
esac

# --- wc_group_rank reports UNANSWERABLE distinctly ---------------------------
# Exercised directly, because wc_current's up-front existence check normally
# shields it. Rank 3 is the mid-scan race: the process exits between that check
# and the read. It must not collapse into rank 2 ("not a member").
dead=999999
while [ -d "/proc/$dead" ]; do dead=$((dead + 1)); done
rk="WC_GROUP=$PRIMARY; wc_group_rank"
rc=0; WC_PROFILES_DIR="$PG" sh -c ". '$WCLIB'; $rk \"$dead\"" || rc=$?
[ "$rc" = 3 ] || fail "wc_group_rank: rc=$rc for an unreadable pid, want 3"
rc=0; WC_PROFILES_DIR="$PG" sh -c ". '$WCLIB'; $rk $$" || rc=$?
[ "$rc" = 0 ] || fail "wc_group_rank: rc=$rc for our own primary group, want 0"
rc=0; WC_PROFILES_DIR="$PG" \
  sh -c ". '$WCLIB'; WC_GROUP=$NONE; wc_group_rank $$" || rc=$?
[ "$rc" = 2 ] || fail "wc_group_rank: rc=$rc for a live non-member, want 2"

# wc_current must PROPAGATE an unanswerable rank rather than let the remaining
# profiles decide the answer is personal. That path is the mid-scan race, which
# cannot be triggered on demand, so wc_group_rank is overridden to force it: a
# LIVE pid (so the up-front existence check passes) whose rank comes back 3.
rm -f "$PG"/*
mkprof one "$NONE"
mkprof two "$NONE"
rc=0
WC_PROFILES_DIR="$PG" sh -c ". '$WCLIB'
       wc_group_rank() { return 3; }
       wc_current $$" || rc=$?
[ "$rc" = 2 ] || fail "wc_current: rc=$rc when a rank was unanswerable, want 2"
# ...and a plain non-member scan still answers 1, so 2 is not just "any failure"
rc=0
WC_PROFILES_DIR="$PG" sh -c ". '$WCLIB'
       wc_group_rank() { return 2; }
       wc_current $$" || rc=$?
[ "$rc" = 1 ] || fail "wc_current: rc=$rc for a live non-member, want 1"

# --- severance does NOT audit a consumer's config ---------------------------
# It used to grade $XDG_CONFIG_HOME/valet-key/context. Reading and grading
# another tool's config file is the same shape as writing it, and worse, only
# that tool can tell an answer from a failure on its own seam. The check moved
# to the side that declared the seam; what stays here is the ARTIFACT, because
# severance alone knows its own verbs.
grep -q valet "$HERE/libexec/doctor.sh" &&
  fail "doctor still reaches into a consumer's config"
grep -rq "valet-key/context" "$HERE/libexec" &&
  fail "libexec still names a consumer's config path"

# --- the retired verb fails CLOSED -------------------------------------------
# valet-key's guard seam reads exit 2 as "warn, then PROCEED" and anything else
# as "refuse". A retired boundary verb exiting 2 turns a stale hook into a
# silently disabled ZDR guard, so it must not be 2.
rc=0; sev context guard >/dev/null 2>&1 || rc=$?
[ "$rc" != 2 ] || fail "retired 'context' exits 2 = valet-key PROCEEDS"
[ "$rc" = 1 ] || fail "retired 'context' exits $rc, want 1 (refuse)"

pass
