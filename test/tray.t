#!/bin/sh
# test/tray.t - libexec/severance-tray, the enclave's tray relay, end to end
# over PRIVATE buses: one standing in for the enclave's session bus, with a
# fake app that registers its tray item by its UNIQUE name (as Chromium apps
# do, so no name filter could reach it); the relay's own tray bus; and a fake
# tray host on that bus. The host must see the item under a well-known name,
# read it, click it, open its menu, get its signals, and be REFUSED anything
# outside the tray methods; the item must go when its app does. Nothing
# touches a real bus. Skipped, saying so, without dbus-daemon or python3-gi.
set -eu

. "$(dirname "$0")/harness_lib"
harness_init tray

R=$HERE/libexec/severance-tray
command -v dbus-daemon >/dev/null 2>&1 ||
  { pass "skipped: no dbus-daemon here"; exit 0; }
python3 -I -c 'import gi; gi.require_version("Gio", "2.0")' 2>/dev/null ||
  { pass "skipped: no python3-gi here"; exit 0; }

PIDS=
# Every background process is started with `&` on the command itself, so
# $! is that process; all are killed by pid. The scratch dir is BAKED into
# the trap when it is armed, never expanded at fire time.
_C="'$T'"
# shellcheck disable=SC2064
trap 'kill $PIDS 2>/dev/null || :; rm -rf '"$_C" EXIT INT TERM

EB=unix:path=$T/encbus
SOCK=$T/share/acme/enclave/tray-bus
mkdir -p "$T/share/acme/enclave" "$T/run"
chmod 0700 "$T/run"
waitfor() {   # <test> <what>
  _i=0
  until eval "$1"; do
    _i=$((_i + 1)); [ "$_i" -lt 150 ] || fail "timed out waiting for $2"
    sleep 0.1
  done
}

# --- refusals before anything runs -------------------------------------------
rc=0; SEVERANCE_SHARE_ROOT=$T/share "$R" 'Bad/Name' >/dev/null 2>&1 || rc=$?
[ "$rc" = 2 ] || fail "a malformed enclave name: rc=$rc, want 2"
rc=0; out=$(SEVERANCE_SHARE_ROOT=$T/none "$R" acme 2>&1) || rc=$?
case "$rc $out" in "1 "*"missing"*) ;;
  *) fail "a missing enclave dir: rc=$rc '$out'" ;; esac

# --- the enclave's bus, and the relay on it ----------------------------------
dbus-daemon --session --nofork --address="$EB" > /dev/null 2>&1 &
PIDS="$PIDS $!"
waitfor '[ -S "$T/encbus" ]' "the enclave bus"
XDG_RUNTIME_DIR=$T/run SEVERANCE_SHARE_ROOT=$T/share \
  SEVERANCE_TRAY_UPSTREAM=$EB "$R" acme > "$T/relay.log" 2>&1 &
RP=$!
PIDS="$PIDS $RP"
waitfor 'grep -q "^ready:" "$T/relay.log"' "the relay"
[ -S "$SOCK" ] || fail "no tray bus socket at $SOCK"

# --- the owner's tray host, on the tray bus ----------------------------------
cat > "$T/host.py" <<'PYEOF'
import json, sys
import gi
gi.require_version("Gio", "2.0")
from gi.repository import Gio, GLib
F = Gio.DBusConnectionFlags
bus = Gio.DBusConnection.new_for_address_sync(
    sys.argv[1], F.AUTHENTICATION_CLIENT | F.MESSAGE_BUS_CONNECTION,
    None, None)
out = open(sys.argv[2], "w")
loop = GLib.MainLoop()
seen = []
def rec(**kv):
    out.write(json.dumps(kv) + "\n"); out.flush()
def call(name, path, iface, method, args, rtype=None):
    try:
        r = bus.call_sync(name, path, iface, method, args,
                          GLib.VariantType(rtype) if rtype else None,
                          0, 5000, None)
        return "ok", r.unpack() if r is not None else None
    except GLib.Error as e:
        return "err", Gio.DBusError.get_remote_error(e) or e.message
def exercise(name):
    p = "/StatusNotifierItem"
    st, v = call(name, p, "org.freedesktop.DBus.Properties", "GetAll",
                 GLib.Variant("(s)", ("org.kde.StatusNotifierItem",)),
                 "(a{sv})")
    rec(step="getall", st=st, id=v[0].get("Id") if st == "ok" else v,
        menu=v[0].get("Menu") if st == "ok" else None)
    st, v = call(name, p, "org.kde.StatusNotifierItem", "Activate",
                 GLib.Variant("(ii)", (3, 4)))
    rec(step="activate", st=st, why=v)
    st, v = call(name, p, "org.kde.StatusNotifierItem",
                 "ProvideXdgActivationToken", GLib.Variant("(s)", ("tok-1",)))
    rec(step="token", st=st, why=v)
    st, v = call(name, "/com/canonical/dbusmenu", "com.canonical.dbusmenu",
                 "GetLayout", GLib.Variant("(iias)", (0, -1, [])),
                 "(u(ia{sv}av))")
    rec(step="layout", st=st, rev=v[0] if st == "ok" else v)
    rec(step="private", r=call(name, p, "org.example.Private", "Secret",
                               GLib.Variant("()", ())))
    rec(step="privprop", r=call(name, p, "org.freedesktop.DBus.Properties",
                                "GetAll", GLib.Variant(
                                    "(s)", ("org.example.Private",)),
                                "(a{sv})"))
    rec(step="otherpath", r=call(name, "/org/example", "org.kde."
                                 "StatusNotifierItem", "Activate",
                                 GLib.Variant("(ii)", (0, 0))))
    st, v = call("org.freedesktop.DBus", "/org/freedesktop/DBus",
                 "org.freedesktop.DBus", "ListNames", None, "(as)")
    rec(step="names", names=[n for n in v[0] if not n.startswith(":")])
    GLib.timeout_add(1500, lambda: (rec(step="signals", seen=seen),
                                    loop.quit()) and False)
    return False
def on_sig(c, sender, path, iface, member, params):
    seen.append(member)
xml = ('<node><interface name="org.kde.StatusNotifierWatcher">'
       '<method name="RegisterStatusNotifierItem">'
       '<arg type="s" direction="in"/></method></interface></node>')
def method(c, sender, path, iface, member, params, inv):
    name = params.unpack()[0]
    rec(step="registered", name=name, sender=sender)
    inv.return_value(None)
    bus.signal_subscribe(name, "org.kde.StatusNotifierItem", None, None,
                         None, 0, on_sig)
    GLib.idle_add(exercise, name)
bus.register_object("/StatusNotifierWatcher",
                    Gio.DBusNodeInfo.new_for_xml(xml).interfaces[0],
                    method, None, None)
bus.call_sync("org.freedesktop.DBus", "/org/freedesktop/DBus",
              "org.freedesktop.DBus", "RequestName",
              GLib.Variant("(su)", ("org.kde.StatusNotifierWatcher", 4)),
              None, 0, -1, None)
rec(step="host-up")
GLib.timeout_add(20000, lambda: loop.quit() or False)
loop.run()
PYEOF
python3 -I "$T/host.py" "unix:path=$SOCK" "$T/host.out" > "$T/host.log" 2>&1 &
PIDS="$PIDS $!"
waitfor 'grep -q host-up "$T/host.out" 2>/dev/null' "the tray host"

# --- the enclave app: an item served by a connection that owns NO name -------
cat > "$T/app.py" <<'PYEOF'
import sys
import gi
gi.require_version("Gio", "2.0")
from gi.repository import Gio, GLib
F = Gio.DBusConnectionFlags
bus = Gio.DBusConnection.new_for_address_sync(
    sys.argv[1], F.AUTHENTICATION_CLIENT | F.MESSAGE_BUS_CONNECTION,
    None, None)
log = open(sys.argv[2], "w")
SNI = """<node><interface name="org.kde.StatusNotifierItem">
<property name="Id" type="s" access="read"/>
<property name="Menu" type="o" access="read"/>
<method name="Activate"><arg type="i" direction="in"/>
<arg type="i" direction="in"/></method>
<method name="ProvideXdgActivationToken"><arg type="s" direction="in"/>
</method><signal name="NewIcon"/></interface>
<interface name="org.example.Private"><property name="x" type="s"
access="read"/><method name="Secret"/></interface></node>"""
MENU = """<node><interface name="com.canonical.dbusmenu">
<method name="GetLayout"><arg type="i" direction="in"/>
<arg type="i" direction="in"/><arg type="as" direction="in"/>
<arg type="u" direction="out"/><arg type="(ia{sv}av)" direction="out"/>
</method></interface></node>"""
def method(c, sender, path, iface, member, params, inv):
    log.write("%s.%s %s\n" % (iface, member, params.unpack())); log.flush()
    if member == "GetLayout":
        inv.return_value(GLib.Variant("(u(ia{sv}av))", (7, (0, {}, []))))
        return
    inv.return_value(None)
    if member == "Activate":
        bus.emit_signal(None, "/StatusNotifierItem",
                        "org.kde.StatusNotifierItem", "NewIcon", None)
def prop(c, sender, path, iface, name):
    return {"Id": GLib.Variant("s", "fake_status_icon_1"),
            "Menu": GLib.Variant("o", "/com/canonical/dbusmenu"),
            "x": GLib.Variant("s", "private")}[name]
for i in Gio.DBusNodeInfo.new_for_xml(SNI).interfaces:
    bus.register_object("/StatusNotifierItem", i, method, prop, None)
bus.register_object("/com/canonical/dbusmenu",
                    Gio.DBusNodeInfo.new_for_xml(MENU).interfaces[0],
                    method, None, None)
bus.call_sync("org.kde.StatusNotifierWatcher", "/StatusNotifierWatcher",
              "org.kde.StatusNotifierWatcher", "RegisterStatusNotifierItem",
              GLib.Variant("(s)", (bus.get_unique_name(),)), None, 0, 5000,
              None)
log.write("registered as %s\n" % bus.get_unique_name()); log.flush()
GLib.MainLoop().run()
PYEOF
python3 -I "$T/app.py" "$EB" "$T/app.out" > "$T/app.log" 2>&1 &
AP=$!
PIDS="$PIDS $AP"
waitfor 'grep -q signals "$T/host.out" 2>/dev/null' "the host's exercise"

H=$(cat "$T/host.out")
got() { printf '%s\n' "$H" | grep "\"step\": \"$1\""; }
case $(got registered) in *'"name": "org.kde.StatusNotifierItem-'*) ;;
  *) fail "the item was not re-published under a well-known name: $H" ;;
esac
case $(got getall) in *'"id": "fake_status_icon_1"'*) ;;
  *) fail "the item's properties did not come through: $(got getall)" ;; esac
case $(got activate) in *'"st": "ok"'*) ;;
  *) fail "Activate was not relayed: $(got activate)" ;; esac
case $(got token) in *'"st": "ok"'*) ;;
  *) fail "ProvideXdgActivationToken was not relayed: $(got token)" ;; esac
case $(got layout) in *'"rev": 7'*) ;;
  *) fail "the menu was not relayed: $(got layout)" ;; esac
for s in private privprop otherpath; do
  case $(got "$s") in *AccessDenied*) ;;
    *) fail "a call outside the tray methods was not refused ($s): $H" ;;
  esac
done
grep -q 'Secret\|Private' "$T/app.out" &&
  fail "a refused call reached the app: $(cat "$T/app.out")"
grep -q 'Activate (3, 4)' "$T/app.out" ||
  fail "the click did not reach the app: $(cat "$T/app.out")"
grep -q "ProvideXdgActivationToken ('tok-1',)" "$T/app.out" ||
  fail "the activation token did not reach the app"
case $(got signals) in *NewIcon*) ;;
  *) fail "the item's signal did not come back: $(got signals)" ;; esac
case $(got names) in *'"names": ["org.freedesktop.DBus", '*) ;;
  *) fail "unexpected names on the tray bus: $(got names)" ;; esac
case $(got names) in *secrets*|*Notifications*|*portal*)
  fail "an enclave service is on the tray bus: $(got names)" ;; esac

# --- the item goes with its app ----------------------------------------------
kill "$AP"
waitfor 'grep -q "dropped" "$T/relay.log"' "the relay to drop the item"
# --- and the relay takes its bus with it -------------------------------------
kill "$RP"
waitfor '[ ! -e "$SOCK" ]' "the tray bus socket to go"

pass "unique-name item relayed, clicked, menu, signal; others refused"
