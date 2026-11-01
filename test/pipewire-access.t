#!/bin/sh
# test/pipewire-access.t - share/wireplumber, the per-enclave PipeWire access
# policy, end to end against a PRIVATE PipeWire and a private STOCK
# WirePlumber (device monitors off) that loads the shipped fragment and
# script exactly as an integrator would place them. Two enclave sockets, a
# and b, each tagged as its socket declares; video test patterns only.
# Every daemon, socket and config lives under the scratch dir and a private
# session bus; nothing touches the owner's audio. Skipped, saying so,
# without pipewire, wireplumber, pw-dump or gst-launch-1.0.
set -eu

. "$(dirname "$0")/harness_lib"
harness_init pipewire-access

for c in pipewire wireplumber pw-dump gst-launch-1.0 dbus-daemon; do
  command -v "$c" >/dev/null 2>&1 || { pass "skipped: no $c here"; exit 0; }
done
gst-inspect-1.0 pipewiresink >/dev/null 2>&1 ||
  { pass "skipped: no gstreamer pipewire plugin here"; exit 0; }
STOCK=/usr/share/pipewire/pipewire.conf
[ -r "$STOCK" ] || { pass "skipped: no $STOCK here"; exit 0; }

PIDS=
# Every background process is started with `&` on the command itself, so
# $! is that process; all are killed by pid. The scratch dir is BAKED into
# the trap when it is armed, never expanded at fire time.
_C="'$T'"
# shellcheck disable=SC2064
trap 'kill $PIDS 2>/dev/null || :; rm -rf '"$_C" EXIT INT TERM

mkdir -m 0700 "$T/run"
WC=$T/config/wireplumber/wireplumber.conf.d
mkdir -p "$T/config/pipewire" "$WC" "$T/data/wireplumber/scripts" \
  "$T/state" "$T/share/a" "$T/share/b"
export XDG_RUNTIME_DIR="$T/run" XDG_CONFIG_HOME="$T/config"
export XDG_DATA_HOME="$T/data" XDG_STATE_HOME="$T/state"
export DBUS_SESSION_BUS_ADDRESS="unix:path=$T/bus" GIO_USE_VFS=local
unset PIPEWIRE_REMOTE PULSE_SERVER PIPEWIRE_RUNTIME_DIR

# The SOCKETS, as an integrator renders them into the owner's pipewire.conf:
# the stock file with one tagged socket per enclave added.
python3 -I - "$STOCK" "$T" > "$T/config/pipewire/pipewire.conf" <<'PYEOF'
import sys
stock, t = sys.argv[1:3]
s = open(stock).read()
old = '#sockets = [ { name = "pipewire-0" }, { name = "pipewire-0-manager" } ]'
if old not in s:
    sys.exit("the stock sockets line moved")
sock = ('{ name = "%s/share/%s/pipewire-0" mode = "0666" props = '
        '{ pipewire.client.access = "severance-%s" } }')
new = ('sockets = [ { name = "pipewire-0" } { name = "pipewire-0-manager" }\n'
       + sock % (t, "a", "a") + "\n" + sock % (t, "b", "b") + " ]")
sys.stdout.write(s.replace(old, new, 1))
PYEOF
cp "$HERE/share/wireplumber/wireplumber.conf.d/50-severance-access.conf" "$WC"
cp "$HERE/share/wireplumber/scripts/severance-access.lua" \
  "$T/data/wireplumber/scripts/"
cat > "$WC/10-private.conf" <<'CONFEOF'
wireplumber.profiles = {
  main = {
    monitor.alsa = disabled
    monitor.alsa-midi = disabled
    monitor.bluez = disabled
    monitor.bluez-midi = disabled
    monitor.v4l2 = disabled
    monitor.libcamera = disabled
  }
}
CONFEOF

waitfor() {   # <test> <what>
  _i=0
  until eval "$1"; do
    _i=$((_i + 1)); [ "$_i" -lt 100 ] || fail "timed out waiting for $2"
    sleep 0.1
  done
}
dbus-daemon --session --nofork --address="$DBUS_SESSION_BUS_ADDRESS" \
  > /dev/null 2>&1 &
PIDS="$PIDS $!"
waitfor '[ -S "$T/bus" ]' "the private bus"
pipewire > "$T/pw.log" 2>&1 &
PIDS="$PIDS $!"
SA=$T/share/a/pipewire-0 SB=$T/share/b/pipewire-0
waitfor '[ -S "$SA" ] && [ -S "$SB" ]' "the enclave sockets"
WIREPLUMBER_DEBUG=3 wireplumber > "$T/wp.log" 2>&1 &
PIDS="$PIDS $!"
waitfor 'grep -q "severance-access" "$T/wp.log"' "the script to load"

for n in a b own; do
  _r=; [ "$n" = own ] || _r=$T/share/$n/pipewire-0
  env ${_r:+PIPEWIRE_REMOTE="$_r"} gst-launch-1.0 -q videotestsrc \
    is-live=true ! video/x-raw,width=160,height=120 ! \
    pipewiresink mode=provide \
    stream-properties="props,node.name=sev-$n,media.class=Video/Source" \
    > /dev/null 2>&1 &
  PIDS="$PIDS $!"
done
serial() {   # <node.name>, as the owner sees it
  pw-dump 2>/dev/null | python3 -I -c '
import json, sys
for o in json.load(sys.stdin):
    p = (o.get("info") or {}).get("props") or {}
    if p.get("node.name") == sys.argv[1]:
        print(p.get("object.serial")); break' "$1"
}
waitfor '[ -n "$(serial sev-a)" ] && [ -n "$(serial sev-b)" ] &&
  [ -n "$(serial sev-own)" ]' "the test sources"
reads() {   # <remote or ""> <target> <seconds>
  timeout "$3" env ${1:+PIPEWIRE_REMOTE="$1"} gst-launch-1.0 -q \
    pipewiresrc stream-properties="props,media.class=Stream/Input/Video" \
    target-object="$2" num-buffers=10 ! fakesink > /dev/null 2>&1
}

reads "$SA" sev-a 10 || fail "enclave a cannot read its OWN source"
reads "$SB" sev-b 10 || fail "enclave b cannot read its OWN source"
# The control: reading by serial works here, so the refusals below are the
# policy and not the harness.
reads "" "$(serial sev-own)" 10 ||
  fail "control: the owner cannot read its own source by serial"
reads "$SA" "$(serial sev-own)" 4 &&
  fail "enclave a READ the owner's source by serial"
reads "$SA" "$(serial sev-b)" 4 &&
  fail "enclave a READ enclave b's source by serial"
seen=$(timeout 5 env PIPEWIRE_REMOTE="$SA" pw-dump 2>/dev/null |
  python3 -I -c '
import json, sys
n = [((o.get("info") or {}).get("props") or {}).get("node.name", "")
     for o in json.load(sys.stdin)]
print(" ".join(sorted(x for x in n if x)))')
[ "$seen" = sev-a ] || fail "enclave a sees nodes other than its own: $seen"
grep -q "admitted client .* as severance-a" "$T/wp.log" ||
  fail "the script never logged admitting an enclave client"
pass "own source read, owner's and other enclave's refused by serial"
