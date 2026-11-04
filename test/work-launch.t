#!/bin/sh
# test/work-launch.t - libexec/work-launch, which runs AS an enclave account
# under pkexec and hands a command to that account's running user manager.
# Stubs stand in for the account (`id`, `getent`) and for systemd-run, which
# records what it was asked to start; the registry and share dir are
# scratch. Nothing is started for real.
set -eu

. "$(dirname "$0")/harness_lib"
harness_init work-launch

L=$HERE/libexec/work-launch
ME=$(id -u)
mkdir -p "$T/bin" "$T/enclaves" "$T/share/acme" "$T/ru/990"
printf 'owner=alice\n' > "$T/enclaves/acme"
printf 'owner=alice\n' > "$T/enclaves/beta"
# This process "is" alice-acme, uid 990.
cat > "$T/bin/id" <<'EOF'
#!/bin/sh
[ "$1" = -u ] && { echo 990; exit 0; }
exec /usr/bin/id "$@"
EOF
cat > "$T/bin/getent" <<'EOF'
#!/bin/sh
case "$1 $2" in
  "passwd 990"|"passwd alice-acme")
    echo 'alice-acme:x:990:990::/home/alice-acme:/bin/sh' ;;
  *) exit 2 ;;
esac
EOF
{ echo '#!/bin/sh'
  printf 'printf "%%s\\n" "$*" > %s/run-argv\n' "$T"
  printf 'printf "%%s %%s\\n" "$XDG_RUNTIME_DIR" "$DBUS_SESSION_BUS_ADDRESS"'
  printf ' > %s/run-env\n' "$T"
} > "$T/bin/systemd-run"
chmod +x "$T/bin/id" "$T/bin/getent" "$T/bin/systemd-run"
# The enclave's session bus: a real socket, so the "is it running" test is
# asked of the thing it asks about.
python3 -I -c '
import socket, sys
socket.socket(socket.AF_UNIX).bind(sys.argv[1])' "$T/ru/990/bus"

launch() {   # <PKEXEC_UID or -> <args...>: sets rc and err
  _pu=$1; shift
  rm -f "$T/run-argv"
  rc=0
  err=$(env -i PATH="$T/bin:/usr/bin:/bin" HOME=/home/alice-acme \
    SEVERANCE_ENCLAVES_DIR="$T/enclaves" SEVERANCE_SHARE_ROOT="$T/share" \
    SEVERANCE_RUN_USER_ROOT="$T/ru" ${_pu:+PKEXEC_UID=$_pu} \
    sh "$L" "$@" 2>&1) || rc=$?
}

launch "$ME" acme -- make test
[ "$rc" = 0 ] || fail "a good launch failed: rc=$rc $err"
want="--user --quiet --collect --property=ExitType=cgroup"
want="$want --property=Description=work: an app in enclave acme -- make test"
[ "$(cat "$T/run-argv")" = "$want" ] ||
  fail "systemd-run argv: $(cat "$T/run-argv")"
[ "$(cat "$T/run-env")" = "$T/ru/990 unix:path=$T/ru/990/bus" ] ||
  fail "the enclave's runtime dir and bus were not used: $(cat "$T/run-env")"

# Asked for ANOTHER enclave than this account is: refused, nothing started.
launch "$ME" beta -- make test
[ "$rc" = 2 ] && [ ! -e "$T/run-argv" ] ||
  fail "a launch into another enclave: rc=$rc $err"
# Asked by someone who does NOT own the enclave, or not through pkexec.
for pu in 12345 ""; do
  launch "$pu" acme -- make test
  [ "$rc" = 2 ] && [ ! -e "$T/run-argv" ] ||
    fail "PKEXEC_UID='$pu' was not refused: rc=$rc $err"
done
# The enclave's session is not running: said so, nothing started.
mv "$T/ru/990/bus" "$T/ru/990/bus.off"
launch "$ME" acme -- make test
case "$rc $err" in "1 "*"no running session"*) ;;
  *) fail "no session: rc=$rc $err" ;; esac
mv "$T/ru/990/bus.off" "$T/ru/990/bus"
for bad in "acme" "acme make" "acme --"; do
  # shellcheck disable=SC2086
  launch "$ME" $bad
  [ "$rc" = 2 ] || fail "usage '$bad': rc=$rc"
done

# AGAINST A REAL USER MANAGER: the caller's own, posing as an enclave whose
# account is this uid. The command DETACHES (`setsid -f`, as a launcher's
# does) and its child must still be alive a second later: with a default
# service the unit ends with its main process and takes the child along,
# which is how launches from a bar menu died silently. Skipped where there
# is no user manager to ask; the one process started is killed by pid.
if [ -S "/run/user/$ME/bus" ] && command -v systemd-run >/dev/null 2>&1; then
  cat > "$T/bin/getent" <<EOF
#!/bin/sh
case "\$1 \$2" in
  "passwd $ME"|"passwd alice-acme")
    echo 'alice-acme:x:$ME:$ME::/home/alice-acme:/bin/sh' ;;
  *) exit 2 ;;
esac
EOF
  rm -f "$T/bin/id" "$T/bin/systemd-run"
  mark=$((40000 + $$ % 20000))
  rc=0
  err=$(env -i PATH="$T/bin:/usr/bin:/bin" HOME="$HOME" \
    SEVERANCE_ENCLAVES_DIR="$T/enclaves" SEVERANCE_SHARE_ROOT="$T/share" \
    PKEXEC_UID="$ME" sh "$L" acme -- \
    sh -c "exec setsid -f sleep $mark" 2>&1) || rc=$?
  [ "$rc" = 0 ] || fail "a real launch failed: rc=$rc $err"
  sleep 1
  pid=$(pgrep -u "$ME" -f "^sleep $mark\$" || :)
  [ -n "$pid" ] && kill $pid
  [ -n "$pid" ] ||
    fail "the detached app did not survive its launch (ExitType?)"
  real=" and a detached app survives"
else
  real=" (no user manager: real launch skipped)"
fi

pass "starts in the enclave's manager; wrong enclave or owner refused$real"
