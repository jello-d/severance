#!/bin/sh
# test/tray.t - libexec/severance-tray-bus, the enclave's filtered tray bus,
# end to end over a PRIVATE session bus standing in for the enclave's. A
# stub on that bus owns a StatusNotifier item name and the keyring's name;
# through the proxy the item must answer and the keyring must not, and the
# watcher name must be ownable while others are not. Nothing touches a real
# bus. Skipped, saying so, without dbus-daemon, gdbus, xdg-dbus-proxy or
# python3-gi.
set -eu

. "$(dirname "$0")/harness_lib"
harness_init tray

B=$HERE/libexec/severance-tray-bus
for c in dbus-daemon gdbus xdg-dbus-proxy; do
  command -v "$c" >/dev/null 2>&1 || { pass "skipped: no $c here"; exit 0; }
done
python3 -I -c 'import gi; gi.require_version("Gio", "2.0")' 2>/dev/null ||
  { pass "skipped: no python3-gi here"; exit 0; }

PIDS=
# Every background process is started with `&` on the command itself, so
# $! is that process; all are killed by pid. The scratch dir is BAKED into
# the trap when it is armed, never expanded at fire time.
_C="'$T'"
# shellcheck disable=SC2064
trap 'kill $PIDS 2>/dev/null || :; rm -rf '"$_C" EXIT INT TERM

UP=unix:path=$T/upbus
SOCK=$T/share/acme/enclave/tray-bus
waitfor() {   # <test> <what>
  _i=0
  until eval "$1"; do
    _i=$((_i + 1)); [ "$_i" -lt 100 ] || fail "timed out waiting for $2"
    sleep 0.1
  done
}

# --- refusals before anything runs -------------------------------------------
rc=0; SEVERANCE_SHARE_ROOT=$T/share "$B" 'Bad/Name' >/dev/null 2>&1 || rc=$?
[ "$rc" = 2 ] || fail "a malformed enclave name: rc=$rc, want 2"
rc=0; out=$(SEVERANCE_SHARE_ROOT=$T/share SEVERANCE_TRAY_UPSTREAM=$UP \
  "$B" acme 2>&1) || rc=$?
case "$rc $out" in "1 "*"missing"*) ;;
  *) fail "a missing enclave dir: rc=$rc '$out'" ;; esac

# --- the upstream bus and a stub service on it -------------------------------
mkdir -p "$T/share/acme/enclave"
dbus-daemon --session --nofork --address="$UP" > /dev/null 2>&1 &
PIDS="$PIDS $!"
waitfor '[ -S "$T/upbus" ]' "the private bus"
cat > "$T/stub.py" <<'PYEOF'
import sys
import gi
gi.require_version("Gio", "2.0")
from gi.repository import Gio, GLib
c = Gio.DBusConnection.new_for_address_sync(
    sys.argv[1], Gio.DBusConnectionFlags.AUTHENTICATION_CLIENT |
    Gio.DBusConnectionFlags.MESSAGE_BUS_CONNECTION, None, None)
for n in ("org.kde.StatusNotifierItem-1-1", "org.freedesktop.secrets"):
    c.call_sync("org.freedesktop.DBus", "/org/freedesktop/DBus",
                "org.freedesktop.DBus", "RequestName",
                GLib.Variant("(su)", (n, 4)), None, 0, -1, None)
open(sys.argv[2], "w").write("ready\n")
GLib.MainLoop().run()
PYEOF
python3 -I "$T/stub.py" "$UP" "$T/stub.ready" > "$T/stub.log" 2>&1 &
PIDS="$PIDS $!"
waitfor '[ -s "$T/stub.ready" ]' "the stub service"

# --- the proxy, exactly as the unit runs it ----------------------------------
SEVERANCE_SHARE_ROOT=$T/share SEVERANCE_TRAY_UPSTREAM=$UP \
  "$B" acme > "$T/proxy.log" 2>&1 &
PIDS="$PIDS $!"
waitfor '[ -S "$SOCK" ]' "the tray bus socket"
mode=$(stat -c %a "$SOCK")
[ "$mode" = 770 ] || fail "the tray bus socket is $mode, want 770 (umask 0007)"

via() {   # <dest> <path> <method> [args...]: call THROUGH the proxy
  _d=$1 _p=$2 _m=$3; shift 3
  timeout 5 gdbus call --address "unix:path=$SOCK" --dest "$_d" \
    --object-path "$_p" --method "$_m" "$@" 2>&1
}
ping() { via "$1" / org.freedesktop.DBus.Peer.Ping; }
own() {
  via org.freedesktop.DBus /org/freedesktop/DBus \
    org.freedesktop.DBus.RequestName "$1" 0
}

out=$(ping org.kde.StatusNotifierItem-1-1) ||
  fail "a tray item is not reachable through the tray bus: $out"
rc=0; out=$(ping org.freedesktop.secrets) || rc=$?
[ "$rc" != 0 ] || fail "the KEYRING is reachable through the tray bus: $out"
out=$(own org.kde.StatusNotifierWatcher) ||
  fail "the watcher name cannot be owned through the tray bus: $out"
case $out in *"(uint32 1,)"*) ;;
  *) fail "owning the watcher did not succeed: $out" ;; esac
rc=0; out=$(own org.freedesktop.Notifications) || rc=$?
case "$rc $out" in "0 (uint32 1,)") fail "another name was ownable: $out" ;;
esac

pass "item reachable, keyring refused, watcher ownable, others not; 0770"
