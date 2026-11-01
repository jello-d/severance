#!/bin/sh
# test/display.t - libexec/severance-display, the helper that opens an
# enclave's RESTRICTED display socket through wp_security_context_v1.
#
# The live half runs a PRIVATE headless wayfire (own ini, own runtime dir,
# no output, nothing shared with a session), the way wayfire-mods' own live
# test does, with the security-context plugin and a deliberately tiny
# allowlist. Through the helper's socket a client must see EXACTLY that
# list; a plain client sees everything. Skipped, saying so, where there is
# no wayfire with that plugin or no wayland-info. The rest needs no
# compositor at all.
set -eu

. "$(dirname "$0")/harness_lib"
harness_init display

H=$HERE/libexec/severance-display

# --- what needs no compositor ------------------------------------------------
rc=0; out=$(sh -c '"$1" Bad_Name' _ "$H" 2>&1) || rc=$?
[ "$rc" = 2 ] || fail "a bad enclave name exited $rc, want 2"
rc=0; out=$(env SEVERANCE_SHARE_ROOT="$T/none" "$H" acme 2>&1) || rc=$?
[ "$rc" = 1 ] || fail "a missing share dir exited $rc"
case $out in *"is missing or not writable"*) ;; *) fail "reason: $out" ;; esac

# --- live, against a private headless wayfire ---------------------------------
WF=${WAYFIRE:-/opt/wayfire/bin/wayfire}
_plug=$(find "${WF%/bin/wayfire}" -name 'libsecurity-context-v1.so' \
  2>/dev/null | head -1)
if [ ! -x "$WF" ] || [ -z "$_plug" ] ||
   ! command -v wayland-info >/dev/null 2>&1; then
  pass "no compositor checks: no wayfire with security-context," \
    "or no wayland-info, here"
  exit 0
fi

RUN=$T/run; mkdir -m 0700 "$RUN"; mkdir -p "$T/share/acme"
ALLOW="wl_compositor wl_output wl_seat wl_shm xdg_wm_base"
printf '%s\n' '[core]' 'plugins = security-context-v1' 'xwayland = false' \
  '' '[security-context-v1]' \
  "allowed_protocols = $(printf '%s' "$ALLOW" | sed 's/ /, /g')" \
  > "$T/wf.ini"
env -u WAYLAND_DISPLAY -u DISPLAY -u WAYFIRE_SOCKET XDG_RUNTIME_DIR="$RUN" \
  WLR_BACKENDS=headless WLR_HEADLESS_OUTPUTS=1 WLR_LIBINPUT_NO_DEVICES=1 \
  WLR_RENDERER=pixman "$WF" -c "$T/wf.ini" > "$T/wf.log" 2>&1 &
WFP=$!
# Killed by its own pid, which `&` on the command itself makes it, whatever
# happens below; a leaked headless compositor would outlive the test.
# Both values are BAKED IN when the trap is armed, never expanded at fire
# time: this replaces the harness's own cleanup, and a deferred `rm -rf
# "$T"` is the shape that once removed a working tree.
_C="'$T'"
# shellcheck disable=SC2064
trap "kill $WFP 2>/dev/null; rm -rf $_C" EXIT INT TERM

WLD= i=0
while [ -z "$WLD" ] && [ "$i" -lt 100 ]; do
  for s in "$RUN"/wayland-*; do [ -S "$s" ] && WLD=${s##*/}; done
  i=$((i + 1)); sleep 0.1
done
[ -n "$WLD" ] || fail "the private wayfire made no socket: $(tail -3 \
  "$T/wf.log")"

helper() {
  exec env WAYLAND_DISPLAY="$WLD" XDG_RUNTIME_DIR="$RUN" \
    SEVERANCE_SHARE_ROOT="$T/share" "$H" "$@"
}
ifaces() {
  env WAYLAND_DISPLAY="$1" XDG_RUNTIME_DIR="$RUN" wayland-info 2>/dev/null |
    sed -n "s/.*interface: '\([^']*\)'.*/\1/p" | sort | tr '\n' ' '
}

# A non-socket file where the socket goes is REFUSED, never removed.
: > "$T/share/acme/wayland-0"
# Bounded: a helper that wrongly accepts would run forever and hang the
# suite (measured, while proving this case), so it gets 10 seconds.
rc=0; out=$(timeout 10 env WAYLAND_DISPLAY="$WLD" XDG_RUNTIME_DIR="$RUN" \
  SEVERANCE_SHARE_ROOT="$T/share" "$H" acme 2>&1) || rc=$?
[ "$rc" = 1 ] || fail "a plain file at the socket path: exit $rc"
[ -f "$T/share/acme/wayland-0" ] || fail "the plain file was removed"
rm -f "$T/share/acme/wayland-0"

( helper acme ) > "$T/helper.log" 2>&1 &
HP=$!
i=0
until grep -q '^ready' "$T/helper.log" 2>/dev/null; do
  i=$((i + 1)); [ "$i" -lt 50 ] || fail "helper never ready: $(cat \
    "$T/helper.log")"
  sleep 0.1
done
S=$T/share/acme/wayland-0
[ "$(stat -c %a "$S")" = 666 ] || fail "socket mode $(stat -c %a "$S")"

got=$(ifaces "$S")
want=$(printf '%s\n' $ALLOW | sort | tr '\n' ' ')
[ "$got" = "$want" ] ||
  fail "an enclave client sees '$got', want exactly '$want'"
plain=$(ifaces "$WLD")
case $plain in *wp_security_context_manager_v1*) ;;
  *) fail "the plain client is restricted too: $plain" ;; esac

# Stopped (systemd sends SIGTERM): the socket goes with it.
kill "$HP"
i=0
while [ -e "$S" ] && [ "$i" -lt 20 ]; do i=$((i + 1)); sleep 0.1; done
[ -e "$S" ] && fail "the socket outlived the helper"

pass "enclave socket sees exactly the allowlist; socket removed on stop"
