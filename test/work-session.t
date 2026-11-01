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

out=$(env -i HOME="$T/h" PATH=/usr/bin:/bin SHELL=/bin/sh sh "$WS" \
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

# No SEVERANCE_ENCLAVE (an unprovisioned account): a warning, not silence.
rm -f "$T/h/.config/environment.d/50-severance.conf"
err=$(env -i HOME="$T/h" PATH=/usr/bin:/bin sh "$WS" true 2>&1 >/dev/null)
case $err in *"no SEVERANCE_ENCLAVE"*) ;; *) fail "no warning: $err" ;; esac

pass "environment.d unquoted, exported as data, never evaluated"
