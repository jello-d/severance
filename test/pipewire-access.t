#!/bin/sh
# test/pipewire-access.t - the per-enclave PipeWire socket: the conf render
# (libexec/severance-pipewire-conf) and the access policy (share/wireplumber),
# end to end against a PRIVATE PipeWire and a private STOCK
# WirePlumber (device monitors off) that loads the shipped fragment and
# script exactly as an integrator would place them. Three registered
# enclaves, each tagged as its socket declares; video test patterns only.
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
  "$T/state" "$T/share/acme" "$T/share/bravo"
export XDG_RUNTIME_DIR="$T/run" XDG_CONFIG_HOME="$T/config"
export XDG_DATA_HOME="$T/data" XDG_STATE_HOME="$T/state"
export DBUS_SESSION_BUS_ADDRESS="unix:path=$T/bus" GIO_USE_VFS=local
unset PIPEWIRE_REMOTE PULSE_SERVER PIPEWIRE_RUNTIME_DIR

# The SOCKETS: libexec/severance-pipewire-conf renders the owner's
# pipewire.conf, as it would at PipeWire's start, from three registered
# enclaves. `gone` has NO share dir, as after a forget: PipeWire refuses to
# start at all if a socket's directory is missing, so the render must skip
# it, and the daemon starting below is the proof that it did.
export SEVERANCE_ENCLAVES_DIR="$T/enclaves" SEVERANCE_SHARE_ROOT="$T/share"
mkdir -p "$T/enclaves"
for n in acme bravo gone; do
  echo "owner=$(id -un)" > "$T/enclaves/$n"
done
CONF=$T/rendered/pipewire.conf
"$HERE/libexec/severance-pipewire-conf" "$CONF" 2> "$T/render.err" ||
  fail "the render failed: $(cat "$T/render.err")"
grep -q "plus 2 enclave socket(s): acme bravo" "$T/render.err" ||
  fail "the render did not list exactly acme and bravo: $(cat "$T/render.err")"
grep -q '"severance-gone"' "$CONF" &&
  fail "the render names an enclave whose share dir does not exist"
# FAILS TOWARD AUDIO: a stock file without the expected line is written
# back unchanged, with a reason, and still exits 0.
printf 'context.properties = {}\n' > "$T/odd.conf"
SEVERANCE_PIPEWIRE_STOCK=$T/odd.conf \
  "$HERE/libexec/severance-pipewire-conf" "$T/fb/pipewire.conf" \
  2> "$T/fb.err" || fail "the fallback exited non-zero"
cmp -s "$T/odd.conf" "$T/fb/pipewire.conf" ||
  fail "the fallback did not write the stock file unchanged"
grep -q "FALLING BACK TO STOCK" "$T/fb.err" ||
  fail "the fallback was silent"

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
pipewire -c "$CONF" > "$T/pw.log" 2>&1 &
PIDS="$PIDS $!"
SA=$T/share/acme/pipewire-0 SB=$T/share/bravo/pipewire-0
waitfor '[ -S "$SA" ] && [ -S "$SB" ]' "the enclave sockets"
WIREPLUMBER_DEBUG=3 wireplumber > "$T/wp.log" 2>&1 &
PIDS="$PIDS $!"
waitfor 'grep -q "s-severance-access.*loaded:" "$T/wp.log"' \
  "the script to load"

for n in acme bravo own; do
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
waitfor '[ -n "$(serial sev-acme)" ] && [ -n "$(serial sev-bravo)" ] &&
  [ -n "$(serial sev-own)" ]' "the test sources"
reads() {   # <remote or ""> <target> <seconds>
  timeout "$3" env ${1:+PIPEWIRE_REMOTE="$1"} gst-launch-1.0 -q \
    pipewiresrc stream-properties="props,media.class=Stream/Input/Video" \
    target-object="$2" num-buffers=10 ! fakesink > /dev/null 2>&1
}

reads "$SA" sev-acme 10 || fail "enclave acme cannot read its OWN source"
reads "$SB" sev-bravo 10 || fail "enclave bravo cannot read its OWN source"
# The control: reading by serial works here, so the refusals below are the
# policy and not the harness.
reads "" "$(serial sev-own)" 10 ||
  fail "control: the owner cannot read its own source by serial"
reads "$SA" "$(serial sev-own)" 4 &&
  fail "enclave acme READ the owner's source by serial"
reads "$SA" "$(serial sev-bravo)" 4 &&
  fail "enclave acme READ enclave bravo's source by serial"
seen=$(timeout 5 env PIPEWIRE_REMOTE="$SA" pw-dump 2>/dev/null |
  python3 -I -c '
import json, sys
n = [((o.get("info") or {}).get("props") or {}).get("node.name", "")
     for o in json.load(sys.stdin)]
print(" ".join(sorted(x for x in n if x)))')
[ "$seen" = sev-acme ] ||
  fail "enclave acme sees nodes other than its own: $seen"
grep -q "admitted client .* as severance-acme" "$T/wp.log" ||
  fail "the script never logged admitting an enclave client"

# FAILS TOWARD THE OWNER: the fragment placed and the script MISSING. The
# owner's WirePlumber must still run (a REQUIRED component would make it
# exit, measured), and an enclave client must then get nothing at all.
kill $PIDS 2>/dev/null || :
PIDS=
rm -f "$T/data/wireplumber/scripts/severance-access.lua" "$T/bus"
dbus-daemon --session --nofork --address="$DBUS_SESSION_BUS_ADDRESS" \
  > /dev/null 2>&1 &
PIDS="$PIDS $!"
pipewire -c "$CONF" > "$T/pw2.log" 2>&1 &
PIDS="$PIDS $!"
waitfor '[ -S "$T/bus" ]' "the private bus, again"
waitfor 'pw-cli info 0 > /dev/null 2>&1' "PipeWire, again"
wireplumber > "$T/wp2.log" 2>&1 &
WP=$!
PIDS="$PIDS $WP"
sleep 3
kill -0 "$WP" 2>/dev/null ||
  fail "WirePlumber exited with the script missing: $(tail -1 "$T/wp2.log")"
n=$(timeout 4 env PIPEWIRE_REMOTE="$SA" pw-dump 2>/dev/null |
  python3 -I -c 'import json, sys; print(len(json.load(sys.stdin)))' \
  2>/dev/null) || n=none
case $n in
  none|0) ;;
  *) fail "with the script missing an enclave client saw $n objects" ;;
esac
pass "missing dir skipped, stock fallback; others refused by serial"
