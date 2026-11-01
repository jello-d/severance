#!/bin/sh
# test/notify.t - libexec/severance-notify, the notification relay, end to
# end over TWO PRIVATE session buses: one standing in for the owner's, one
# for the enclave's. A stub notification daemon on the owner's bus records
# what reaches it and "clicks" on request. Nothing touches a real bus.
# Skipped, saying so, without dbus-daemon, gdbus or python3-gi.
set -eu

. "$(dirname "$0")/harness_lib"
harness_init notify

N=$HERE/libexec/severance-notify
for c in dbus-daemon gdbus; do
  command -v "$c" >/dev/null 2>&1 || { pass "skipped: no $c here"; exit 0; }
done
python3 -I -c 'import gi; gi.require_version("Gio", "2.0")' 2>/dev/null ||
  { pass "skipped: no python3-gi here"; exit 0; }

OB=unix:path=$T/ownbus EB=unix:path=$T/enclbus
mkdir -p "$T/share/acme"
PIDS=
# Every background process is started with `&` on the command itself, so
# $! is that process; all are killed by pid. The scratch dir is BAKED into
# the trap when it is armed, never expanded at fire time.
_C="'$T'"
# shellcheck disable=SC2064
# `|| :` because some have exited by then, and in dash a failing command
# in an EXIT trap becomes the script's exit status (measured: ok, then 1).
trap 'kill $PIDS 2>/dev/null || :; rm -rf '"$_C" EXIT INT TERM

dbus-daemon --session --nofork --address="$OB" > /dev/null 2>&1 &
PIDS="$PIDS $!"
dbus-daemon --session --nofork --address="$EB" > /dev/null 2>&1 &
PIDS="$PIDS $!"
waitfor() {   # <test> <what>
  _i=0
  until eval "$1"; do
    _i=$((_i + 1)); [ "$_i" -lt 100 ] || fail "timed out waiting for $2"
    sleep 0.1
  done
}
waitfor '[ -S "$T/ownbus" ] && [ -S "$T/enclbus" ]' "the private buses"

# The stub daemon: records each Notify as one JSON line; a summary
# containing please-click is answered with ActionInvoked(id, "default").
cat > "$T/daemon.py" <<'PYEOF'
import json, sys
import gi
gi.require_version("Gio", "2.0")
from gi.repository import Gio, GLib
XML = """<node><interface name="org.freedesktop.Notifications">
<method name="Notify">
<arg type="s" direction="in"/><arg type="u" direction="in"/>
<arg type="s" direction="in"/><arg type="s" direction="in"/>
<arg type="s" direction="in"/><arg type="as" direction="in"/>
<arg type="a{sv}" direction="in"/><arg type="i" direction="in"/>
<arg type="u" direction="out"/></method>
<method name="CloseNotification"><arg type="u" direction="in"/></method>
<signal name="ActionInvoked"><arg type="u"/><arg type="s"/></signal>
</interface></node>"""
out = open(sys.argv[1], "a")
state = {"n": 100}
def method(conn, sender, path, iface, name, params, inv):
    if name == "Notify":
        app, rep, icon, summ, body, acts, hints, exp = params.unpack()
        state["n"] += 1
        oid = state["n"]
        out.write(json.dumps({"app": app, "summary": summ, "body": body,
                              "actions": acts, "hints": sorted(hints),
                              "id": oid}) + "\n")
        out.flush()
        inv.return_value(GLib.Variant("(u)", (oid,)))
        if "please-click" in summ:
            GLib.timeout_add(300, lambda: conn.emit_signal(
                None, "/org/freedesktop/Notifications",
                "org.freedesktop.Notifications", "ActionInvoked",
                GLib.Variant("(us)", (oid, "default"))) and False)
    else:
        inv.return_value(None)
info = Gio.DBusNodeInfo.new_for_xml(XML).interfaces[0]
def acquired(conn, name):
    conn.register_object("/org/freedesktop/Notifications", info, method,
                         None, None)
    print("ready", flush=True)
Gio.bus_own_name(Gio.BusType.SESSION, "org.freedesktop.Notifications",
                 Gio.BusNameOwnerFlags.NONE, acquired, None, None)
GLib.MainLoop().run()
PYEOF
# The listener: prints the first ActionInvoked on the enclave's bus, exits.
cat > "$T/listen.py" <<'PYEOF'
import gi
gi.require_version("Gio", "2.0")
from gi.repository import Gio, GLib
loop = GLib.MainLoop()
bus = Gio.bus_get_sync(Gio.BusType.SESSION, None)
def sig(conn, sender, path, iface, name, params):
    print("%s %d %s" % ((name,) + tuple(params.unpack())), flush=True)
    loop.quit()
bus.signal_subscribe(None, "org.freedesktop.Notifications", "ActionInvoked",
                     None, None, Gio.DBusSignalFlags.NONE, sig)
print("ready", flush=True)
loop.run()
PYEOF

env DBUS_SESSION_BUS_ADDRESS="$OB" python3 -I "$T/daemon.py" \
  "$T/notified" > "$T/daemon.log" 2>&1 &
PIDS="$PIDS $!"
waitfor 'grep -q ready "$T/daemon.log"' "the stub daemon"
env DBUS_SESSION_BUS_ADDRESS="$OB" SEVERANCE_SHARE_ROOT="$T/share" \
  "$N" owner acme > "$T/owner.log" 2>&1 &
OWNER=$!; PIDS="$PIDS $OWNER"
waitfor 'grep -q ready "$T/owner.log"' "the owner relay"
[ "$(stat -c %a "$T/share/acme/relay")" = 666 ] || fail "relay socket mode"
env DBUS_SESSION_BUS_ADDRESS="$EB" SEVERANCE_SHARE_ROOT="$T/share" \
  "$N" enclave acme > "$T/enclave.log" 2>&1 &
PIDS="$PIDS $!"
waitfor 'grep -q linked "$T/enclave.log"' "the enclave relay to link"
env DBUS_SESSION_BUS_ADDRESS="$EB" python3 -I "$T/listen.py" \
  > "$T/listen.log" 2>&1 &
PIDS="$PIDS $!"
waitfor 'grep -q ready "$T/listen.log"' "the listener"
# The enclave relay owns the name on the enclave bus once it is up.
waitfor 'gdbus call --address "$EB" --dest org.freedesktop.Notifications \
  --object-path /org/freedesktop/Notifications \
  --method org.freedesktop.Notifications.GetServerInformation \
  >/dev/null 2>&1' "the enclave relay to own the name"

notify() {   # <app> <summary> <body>
  gdbus call --address "$EB" --dest org.freedesktop.Notifications \
    --object-path /org/freedesktop/Notifications \
    --method org.freedesktop.Notifications.Notify "$1" 0 '' "$2" "$3" \
    "['default', 'Open']" \
    "{'urgency': <byte 2>, 'image-path': <'/etc/shadow'>}" 5000
}
out=$(notify Slack 'please-click hello' world) || fail "Notify failed: $out"
waitfor '[ -s "$T/notified" ]' "the notification to reach the owner"
python3 -I - "$T/notified" <<'PYEOF' || fail "the relayed notification"
import json, sys
n = json.loads(open(sys.argv[1]).readline())
assert n["app"] == "acme", n            # the MARKER: the enclave's name
assert n["summary"] == "Slack: please-click hello", n
assert n["body"] == "world", n
assert n["actions"] == ["default", "Open"], n
# image-path pointed at a file on the OWNER's side: dropped.
assert n["hints"] == ["urgency", "x-severance-enclave"], n
PYEOF
# The click travels back to the app that posted it.
waitfor 'grep -q ActionInvoked "$T/listen.log"' "the click to come back"
[ "$(cat "$T/listen.log" | tail -1)" = "ActionInvoked 1 default" ] ||
  fail "the click arrived as: $(tail -1 "$T/listen.log")"

# Caps: an enclave cannot push an arbitrarily large summary across.
long=$(python3 -I -c 'print("x" * 10000)')
notify Slack "$long" b > /dev/null
waitfor '[ "$(wc -l < "$T/notified")" -ge 2 ]' "the long notification"
_len=$(tail -1 "$T/notified" | python3 -I -c \
  'import json,sys; print(len(json.loads(sys.stdin.read())["summary"]))')
[ "$_len" -le 520 ] || fail "a 10000-char summary arrived as $_len chars"

# A stop removes the socket.
kill "$OWNER"
waitfor '[ ! -e "$T/share/acme/relay" ]' "the relay socket to go"

# A non-socket file where the socket goes is refused, never removed.
: > "$T/share/acme/relay"
rc=0; timeout 10 env DBUS_SESSION_BUS_ADDRESS="$OB" \
  SEVERANCE_SHARE_ROOT="$T/share" "$N" owner acme > /dev/null 2>&1 || rc=$?
[ "$rc" = 1 ] && [ -f "$T/share/acme/relay" ] ||
  fail "a plain file at the relay path: exit $rc"

pass "marker, hint allowlist, caps, click round trip, stop"
