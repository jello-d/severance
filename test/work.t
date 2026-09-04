#!/bin/sh
# test/work.t - behavioral test for bin/work's ARGUMENT GRAMMAR:
#
#   work | work enter [profile] | work run [profile] -- CMD ...
#
# The property under test is that nothing is ever GUESSED. work is the sole
# sudo entry point, so a word it fails to classify used to fall through to the
# re-exec and HANG with no TTY. The grammar removes the guess, and this test
# holds it there.
#
# `sudo` is stubbed, and reaching it is the SIGNAL rather than a failure: a
# well-formed invocation SHOULD reach the re-exec (that is work doing its job,
# and the stub stops it before anything privileged happens), while a malformed
# one must be rejected with usage BEFORE sudo is touched. The stub records each
# call so both directions are assertable.
#
# Nothing outside the scratch dir is read or written.
set -eu

. "$(dirname "$0")/lib.sh"
harness_init work

WORK=$HERE/bin/work
WCLIB=$HERE/libexec/work-context.sh
PG=$T/pg
mkdir -p "$PG" "$T/bin"

# The sudo stub: records the attempt and its argv, then fails so nothing
# privileged runs and `exec` cannot escape the test.
{ echo '#!/bin/sh'
  printf 'printf "%%s\\n" "$*" >> %s/sudo-argv\n' "$T"
  echo 'exit 97'
} > "$T/bin/sudo"
chmod +x "$T/bin/sudo"

work() {
  rm -f "$T/sudo-argv"
  env -u WORK_PROFILE -u WORK_REEXEC -u WC_CONFIG \
    SEVERANCE_LIB="$WCLIB" WC_PROFILES_DIR="$PG" \
    WC_DEFAULT_FILE="$T/default" PATH="$T/bin:$PATH" \
    sh "$WORK" "$@"
}
sudo_reached() { [ -e "$T/sudo-argv" ]; }

mkprof() { printf 'work_group=%s\nwork_dir=/tmp/wk-%s\n' "$2" "$1" > "$PG/$1"; }

# A group we do NOT hold, so work always takes the acquire-then-re-exec path
# and never runs a real session.
NONE=severance-no-such-group
mkprof alpha "$NONE"

# --- well-formed forms reach the re-exec -------------------------------------
# rc 97 is the stub's, proving work got all the way to `exec sudo`.
for form in "" "enter" "enter alpha"; do
  rc=0
  # shellcheck disable=SC2086
  work $form >/dev/null 2>&1 || rc=$?
  [ "$rc" = 97 ] || fail "work ${form:-(bare)}: rc=$rc, want 97 (reached sudo)"
  sudo_reached || fail "work ${form:-(bare)}: did not reach the re-exec"
done

rc=0; work run -- echo hi >/dev/null 2>&1 || rc=$?
[ "$rc" = 97 ] || fail "work run -- CMD: rc=$rc, want 97"
rc=0; work run alpha -- echo hi >/dev/null 2>&1 || rc=$?
[ "$rc" = 97 ] || fail "work run alpha -- CMD: rc=$rc, want 97"

# --- the re-exec forwards a NORMALISED argv, not the user's words ------------
# The profile travels in WORK_PROFILE, so re-parsing on the other side cannot
# reach a different answer than this pass did.
work run alpha -- npm test >/dev/null 2>&1 || true
argv=$(cat "$T/sudo-argv")
case $argv in
  *"WORK_PROFILE=alpha"*) ;;
  *) fail "re-exec: profile not forwarded in WORK_PROFILE: $argv" ;;
esac
case $argv in
  *"run -- npm test") ;;
  *) fail "re-exec: argv not normalised to 'run -- CMD': $argv" ;;
esac
work enter alpha >/dev/null 2>&1 || true
case $(cat "$T/sudo-argv") in
  *enter) ;;
  *) fail "re-exec: enter not normalised: $(cat "$T/sudo-argv")" ;;
esac

# --- malformed forms are rejected BEFORE sudo --------------------------------
# This is the property the old grammar lacked: an unclassifiable word became a
# command and fell through to a TTY-less sudo prompt.
for bad in \
  "npm" \
  "npm test" \
  "alpha" \
  "enter alpha extra" \
  "run" \
  "run alpha" \
  "run npm test" \
  "run --" \
  "enter --" \
  "bogusverb"; do
  rc=0
  # shellcheck disable=SC2086
  work $bad >/dev/null 2>&1 || rc=$?
  [ "$rc" = 2 ] || fail "work $bad: rc=$rc, want 2 (usage)"
  sudo_reached && fail "work $bad: reached sudo instead of printing usage"
done

# `work alpha` deserves its own note: it names a REAL profile, and under the
# old grammar that made it an enter. It is now a usage error, because the
# profile slot follows a verb. This is the deliberate breaking change.
rc=0; work alpha >/dev/null 2>&1 || rc=$?
[ "$rc" = 2 ] || fail "work <profile> should be usage now, got rc=$rc"

# --- usage goes to stderr, never stdout --------------------------------------
out=$(work bogusverb 2>/dev/null) || true
[ -z "$out" ] || fail "usage leaked to stdout: '$out'"
err=$(work bogusverb 2>&1 >/dev/null) || true
case $err in
  *"usage: work"*) ;;
  *) fail "no usage on stderr for an unknown verb: '$err'" ;;
esac

# --- the query verbs are GONE from work --------------------------------------
# They moved to `severance current`. work must not answer them, and must not
# silently treat them as a profile or a command either.
for gone in "check" "current" "check 1" "current 1"; do
  rc=0
  # shellcheck disable=SC2086
  work $gone >/dev/null 2>&1 || rc=$?
  [ "$rc" = 2 ] || fail "work $gone: rc=$rc, want 2 (verb removed)"
  sudo_reached && fail "work $gone: reached sudo"
done

# --- a missing profile on a multi-profile box fails loud, never guesses ------
mkprof beta "$NONE"
rc=0; work >/dev/null 2>&1 || rc=$?
[ "$rc" = 1 ] || fail "bare work with 2 profiles and no default: rc=$rc, want 1"
sudo_reached && fail "bare work with an unresolved profile reached sudo"

# ...and naming one resolves it.
rc=0; work enter beta >/dev/null 2>&1 || rc=$?
[ "$rc" = 97 ] || fail "work enter beta: rc=$rc, want 97 (resolved, re-exec'd)"

# --- work knows NOTHING about the box's shell framework ----------------------
# A session's environment (PATH, toolchain managers, history) is the ENCLAVE's
# business, set in its .workrc, which both paths source. work used to hardcode
# ~/lib/load_helper_funcs and call env_load/sh_history_start by name -- one
# provisioner's private dotfile convention baked into the boundary, and not
# even a public tool. It also made a standalone box's interactive session fail
# outright, because the rc emitted that source line unconditionally.
#
# Asserted against the SOURCE because the interactive rc needs a TTY to
# exercise: this is a guard against reintroduction, which is the actual risk.
for sym in load_helper_funcs env_load sh_history_start nvm tfenv; do
  grep -n "$sym" "$WORK" | grep -qv '^[0-9]*: *#' && {
    grep -n "$sym" "$WORK" | grep -v '^[0-9]*: *#' >&2
    fail "bin/work references the box shell framework: $sym"
  }
done

# Both paths must still source the enclave's own rc -- that IS the seam that
# replaced it, so losing it would strand every session with a bare environment.
[ "$(grep -c '\.workrc' "$WORK")" -ge 2 ] ||
  fail "bin/work no longer sources .workrc in both paths"

pass
