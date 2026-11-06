#!/bin/sh
# test/work-session.t - libexec/work-session, which runs AS an enclave account
# and brings the enclave's environment.d values into a `sudo -i` shell.
#
# Driven against the REAL systemd environment.d generator with HOME pointed at
# a scratch dir, because what is under test is how its OUTPUT is read: it
# shell-quotes a value with spaces (KEY="a b") and backslash-escapes inside
# that, and the helper must undo exactly one level of it without eval. A box
# with no generator skips with a note, because there is nothing to read.
set -eu

. "$(dirname "$0")/harness_lib"
harness_init work-session

WS=$HERE/libexec/work-session
_rel=user-environment-generators/30-systemd-environment-d-generator
if [ ! -x "/usr/lib/systemd/$_rel" ] && [ ! -x "/lib/systemd/$_rel" ]; then
  pass "skipped: no systemd environment.d generator here"
  exit 0
fi
# The cases below read ONLY the real environment.d generator's directory,
# never the box's whole search path: a box may carry other generators (a
# per-account token, say), and a test has no business running those.
GD=/usr/lib/systemd/user-environment-generators
[ -x "/usr/lib/systemd/$_rel" ] || GD=/lib/systemd/user-environment-generators
wsenv() { env -i SEVERANCE_ENV_GENERATOR_DIRS="$GD" "$@"; }

mkdir -p "$T/h/.config/environment.d"
cat > "$T/h/.config/environment.d/50-severance.conf" <<'EOF'
SEVERANCE_ENCLAVE=acme
DOCKER_HOST=unix:///run/severance-docker-alice-acme/docker.sock
SPACED=one two
QUOTED=say "hi" there
BACKSLASH=a\\b
EOF
# A value that LOOKS like code must arrive as data: if it were eval'd, the
# marker file would appear.
printf 'TRAP=$(touch %s/evaluated)\n' "$T" \
  >> "$T/h/.config/environment.d/50-severance.conf"

out=$(wsenv HOME="$T/h" PATH=/usr/bin:/bin SHELL=/bin/sh sh "$WS" \
  sh -c 'for v in SEVERANCE_ENCLAVE DOCKER_HOST SPACED QUOTED BACKSLASH; do
           eval "printf \"%s=[%s]\\n\" \$v \"\$$v\""; done; pwd') ||
  fail "work-session failed: $out"
want() { printf '%s\n' "$out" | grep -qxF "$1" || fail "want '$1'; got: $out"; }
want 'SEVERANCE_ENCLAVE=[acme]'
want 'DOCKER_HOST=[unix:///run/severance-docker-alice-acme/docker.sock]'
want 'SPACED=[one two]'
want 'QUOTED=[say "hi" there]'
want "$T/h"
[ -e "$T/evaluated" ] && fail "a value was EXECUTED, not exported as data"

# The CALLER's session pointers never reach the enclave: sudo keeps some
# (DISPLAY among them), and an app handed the owner's X display tries it and
# dies. Foreign runtime dir and bus are dropped too, never trusted.
out=$(wsenv HOME="$T/h" PATH=/usr/bin:/bin DISPLAY=:0 XAUTHORITY=/x/auth \
  WAYFIRE_SOCKET=/run/user/1/wf.sock SSH_AUTH_SOCK=/run/user/1/agent \
  XDG_RUNTIME_DIR=/run/user/999999 \
  DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/999999/bus sh "$WS" \
  sh -c 'printf "[%s]" "${DISPLAY-}" "${XAUTHORITY-}" "${WAYFIRE_SOCKET-}" \
    "${SSH_AUTH_SOCK-}"; echo; echo "${XDG_RUNTIME_DIR-}"
    echo "${DBUS_SESSION_BUS_ADDRESS-}"' 2>/dev/null) ||
  fail "work-session failed with a caller's session set: $out"
[ "$(printf '%s\n' "$out" | sed -n 1p)" = "[][][][]" ] ||
  fail "a caller's session pointer reached the enclave: $out"
case $out in *999999*)
  fail "a foreign runtime dir or bus reached the enclave: $out" ;; esac

# A NON-login sudo (how `work run` arrives) opens no session: the runtime
# dir is supplied from the account's own /run/user/<uid> when it exists.
_rt=/run/user/$(id -u)
if [ -d "$_rt" ] && [ -O "$_rt" ]; then
  out=$(wsenv HOME="$T/h" PATH=/usr/bin:/bin sh "$WS" \
    sh -c 'echo "$XDG_RUNTIME_DIR"' 2>/dev/null)
  [ "$out" = "$_rt" ] || fail "XDG_RUNTIME_DIR not supplied: '$out'"
  if [ -S "$_rt/bus" ]; then
    out=$(wsenv HOME="$T/h" PATH=/usr/bin:/bin sh "$WS" \
      sh -c 'echo "$DBUS_SESSION_BUS_ADDRESS"' 2>/dev/null)
    [ "$out" = "unix:path=$_rt/bus" ] || fail "session bus not supplied: $out"
  fi
fi

# No SEVERANCE_ENCLAVE (an unprovisioned account): a warning, not silence.
rm -f "$T/h/.config/environment.d/50-severance.conf"
err=$(wsenv HOME="$T/h" PATH=/usr/bin:/bin sh "$WS" true 2>&1 >/dev/null)
case $err in *"no SEVERANCE_ENCLAVE"*) ;; *) fail "no warning: $err" ;; esac

# EVERY GENERATOR, as the manager runs them, over two scratch directories:
# name order, each seeing what the earlier ones exported; the FIRST
# directory holding a name wins; an empty file MASKS a name; a failing one
# warns and the rest still apply. The environment.d generator is stood in by
# a script of its name, since its presence is what makes a run complete.
G1=$T/gen1 G2=$T/gen2
mkdir -p "$G1" "$G2"
gen() {   # <dir> <name> <body>
  printf '#!/bin/sh\n%s\n' "$3" > "$1/$2"; chmod +x "$1/$2"
}
gen "$G1" 10-first 'echo A=one'
gen "$G2" 30-systemd-environment-d-generator 'echo "B=saw-$A"'
gen "$G1" 20-dup 'echo DUP=first-dir'
gen "$G2" 20-dup 'echo DUP=second-dir'
: > "$G1/40-masked"
gen "$G2" 40-masked 'echo MASKED=yes'
gen "$G2" 50-fails 'echo NEVER=1; exit 3'
gen "$G2" 60-last 'echo C=last'
rc=0
out=$(env -i SEVERANCE_ENV_GENERATOR_DIRS="$G1
$G2" HOME="$T/h" PATH=/usr/bin:/bin sh "$WS" sh -c \
  'echo "[$A][$B][$DUP][${MASKED-}][${NEVER-}][$C]"' 2>"$T/gen.err") ||
  rc=$?
[ "$rc" = 0 ] || fail "a run with a failing generator stopped: rc=$rc"
[ "$out" = "[one][saw-one][first-dir][][][last]" ] ||
  fail "generator rules: got '$out', want [one][saw-one][first-dir][][][last]"
grep -q "generator $G2/50-fails failed" "$T/gen.err" ||
  fail "a failing generator was silent: $(cat "$T/gen.err")"
# Without the environment.d generator the enclave has no environment: fatal.
rm -f "$G2/30-systemd-environment-d-generator"
rc=0
err=$(env -i SEVERANCE_ENV_GENERATOR_DIRS="$G1
$G2" HOME="$T/h" PATH=/usr/bin:/bin sh "$WS" true 2>&1) || rc=$?
case "$rc $err" in "1 "*"environment.d generator not found"*) ;;
  *) fail "no environment.d generator: rc=$rc $err" ;; esac

pass "environment.d as data; every generator, in order, first dir wins"
