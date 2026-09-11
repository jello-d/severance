#!/bin/sh
# test/runner-unit.t - the runner's DERIVED VALUES, without any privilege.
#
# libexec/runner.sh is mostly a sequence of privileged operations, and its
# apply path needs root, systemd and a working docker -- so it had no coverage
# beyond its audit, which itself ran against stubs. But the privileged calls
# are only the last step; what they are TOLD to do is computed first, by pure
# functions over the loaded WC_*. Those compute the runner's identity, its
# socket path, its subordinate-id block and the tmpfiles line that decides who
# can reach the socket at all.
#
# Getting one of those wrong is a real boundary bug (a socket dir the group
# cannot traverse, or one everyone can), and none of it needs root to check.
# So they are pulled out and driven directly, the same way seal.sh's
# render_git_gen is.
set -eu

. "$(dirname "$0")/lib.sh"
harness_init runner-unit

RUNNER_LIB=$HERE/libexec/runner.sh

# Extract one function by NAME, tracking brace depth.
#
# The obvious `sed '/^name() {/,/^}/p'` is wrong here and quietly so: several of
# these are ONE-LINERS, whose closing brace is not on a line of its own, so the
# range runs on and swallows the NEXT function -- printing it twice, producing
# malformed shell, and leaving a test that "passed" while driving something
# that was never the code. Depth-counting handles both shapes.
fn() {   # <name>
  awk -v n="$1" '
    $0 ~ "^" n "\\(\\) \\{" { inf = 1 }
    inf {
      print
      d += gsub(/\{/, "{") - gsub(/\}/, "}")
      if (d <= 0) exit
    }' "$RUNNER_LIB"
}

# Drive the named functions with a given environment.
drive() {   # <env-assignments> <expression>
  for _f in _runner_vars _render_tmpfiles _render_relay_unit _has_subids \
            _next_subid_block _has_traverse; do
    fn "$_f"
  done > "$T/fns"
  # A malformed extraction must fail LOUDLY, not silently define nothing.
  sh -n "$T/fns" || { echo "extracted functions do not parse" >&2; exit 1; }
  env -i PATH="/usr/bin:/bin" HOME="${DHOME:-$T}" sh -c "
    set -eu
    $1
    . '$T/fns'
    $2"
}

# --- _runner_vars: the runner's identity and paths --------------------------
# Every privileged call downstream is aimed by these four values.
out=$(drive 'WC_RUNNER=demo-runner; TMPFILES_DIR=/etc/tmpfiles.d' \
  '_runner_vars; echo "$RUNNER|$RUNNER_HOME|$SOCK_DIR|$TMPFILES"')
want="demo-runner|/home/demo-runner|/run/demo-runner"
want="$want|/etc/tmpfiles.d/demo-runner.conf"
[ "$out" = "$want" ] || fail "_runner_vars derived wrongly: $out"

# WORK_RUNNER_USER overrides the record, and everything else follows it: a
# half-applied override would aim the socket and the tmpfiles at two different
# accounts.
out=$(drive 'WC_RUNNER=from-record; WORK_RUNNER_USER=override
             TMPFILES_DIR=/etc/tmpfiles.d' \
  '_runner_vars; echo "$RUNNER|$SOCK_DIR|$TMPFILES"')
[ "$out" = "override|/run/override|/etc/tmpfiles.d/override.conf" ] ||
  fail "WORK_RUNNER_USER did not carry through every derived path: $out"

# --- _render_tmpfiles: who can reach the socket ------------------------------
# 0710 is the whole point: a group member TRAVERSES in to the socket, everyone
# else is denied at the directory. 0750 would let the group list it, 0711 would
# let anyone through -- and neither would look wrong at a glance.
out=$(drive 'WC_RUNNER=demo-runner; WC_GROUP=wg; TMPFILES_DIR=/etc/tmpfiles.d' \
  '_runner_vars; _render_tmpfiles')
[ "$out" = "d /run/demo-runner 0710 demo-runner wg -" ] ||
  fail "tmpfiles line wrong: '$out'"

# The GROUP in that line is the enclave's, not the runner's own: the socket is
# reached by group, which is what lets a work session in and keeps a personal
# process out.
out=$(drive 'WC_RUNNER=r; WC_GROUP=manifest; TMPFILES_DIR=/x' \
  '_runner_vars; _render_tmpfiles')
case $out in
  *" r manifest -") ;;
  *) fail "tmpfiles line does not own the socket dir runner:<group>: '$out'" ;;
esac

# --- _render_relay_unit: who can reach the DOCKER SOCKET ---------------------
# The relay unit is what fronts the runner's private rootless-docker socket
# with a host-visible one, and @GROUP@ becomes `group=` on the listening
# socket. A wrong value there opens the daemon to the whole box -- root inside
# a container is root on the bind mounts -- so this substitution is as
# load-bearing as the wall itself, and it is pure text.
cat > "$T/relay.in" <<'EOF'
ExecStart=/usr/bin/socat -t 86400 \
    UNIX-LISTEN:@HOSTSOCK@,fork,mode=0660,group=@GROUP@,unlink-early \
    UNIX-CONNECT:@INTSOCK@
EOF
out=$(drive "WC_RUNNER=demo-runner; WC_GROUP=wg; TMPFILES_DIR=/x
             RELAY_SRC=$T/relay.in; _ruid=4242" \
  '_runner_vars; _render_relay_unit')
case $out in
  *"group=wg,"*) ;;
  *) fail "relay unit does not gate the socket on the enclave group: $out" ;;
esac
case $out in
  *"UNIX-LISTEN:/run/demo-runner/docker.sock,"*) ;;
  *) fail "relay unit listens on the wrong host socket: $out" ;;
esac
case $out in
  *"UNIX-CONNECT:/run/user/4242/docker.sock"*) ;;
  *) fail "relay unit connects to the wrong internal socket: $out" ;;
esac
# No placeholder may survive: an unsubstituted @GROUP@ would be a literal
# group name, socat would fail to start, and the enclave would have no docker
# with nothing saying why.
case $out in
  *@*@*) fail "an unsubstituted placeholder survived: $out" ;;
esac

# mode=0660 and not 0666: the socket is reached BY GROUP, which is the same
# rule as the tree. Asserted against the SHIPPED template, since that is what
# provisioning actually renders.
grep -q 'mode=0660' "$HERE/share/runner/docker-sock.service" ||
  fail "the shipped relay template does not gate the socket 0660"

# --- _next_subid_block: never overlap an existing allocation ----------------
# Two accounts sharing a subordinate range would let one runner's containers
# act as the other's uids.
printf 'a:100000:65536\nb:165536:65536\n' > "$T/subuid"
out=$(drive '' "_next_subid_block $T/subuid")
[ "$out" = "231072-296607" ] || fail "next block wrong: $out"
# An empty file still starts at the conventional base rather than 0.
: > "$T/empty"
out=$(drive '' "_next_subid_block $T/empty")
[ "$out" = "100000-165535" ] ||
  fail "empty subuid did not start at 100000: $out"
# A file that does not exist must not yield a block starting at 0, which would
# collide with real system ids.
out=$(drive '' "_next_subid_block $T/nope")
case $out in
  0-*) fail "a missing subuid file yielded a block at 0: $out" ;;
esac

# --- _has_subids: presence is keyed on the account, not a substring ---------
printf 'demo-runner:100000:65536\n' > "$T/su"
drive 'RUNNER=demo-runner' "_has_subids $T/su" ||
  fail "_has_subids missed a present allocation"
# 'demo' must not match 'demo-runner': a prefix match would report an account
# as allocated when it is not, and skip the allocation.
drive 'RUNNER=demo' "_has_subids $T/su" &&
  fail "_has_subids matched a PREFIX of another account"

# --- _has_traverse: the ACL that lets the runner reach into $HOME -----------
# Real setfacl on a real directory -- no privilege needed for a dir we own,
# and no stub, so this is the actual predicate against the actual tool.
if command -v setfacl >/dev/null 2>&1 &&
   command -v getfacl >/dev/null 2>&1; then
  DHOME=$T/fakehome; mkdir -p "$DHOME"
  _me=$(id -un)
  DHOME=$DHOME drive "RUNNER=$_me" '_has_traverse' &&
    fail "_has_traverse saw an ACL that was never granted"
  setfacl -m "u:$_me:--x" "$DHOME"
  DHOME=$DHOME drive "RUNNER=$_me" '_has_traverse' ||
    fail "_has_traverse missed a granted traverse ACL"
  # A read-only entry is not traverse: the runner must be able to walk THROUGH
  # $HOME, and r without x cannot.
  setfacl -m "u:$_me:r--" "$DHOME"
  DHOME=$DHOME drive "RUNNER=$_me" '_has_traverse' &&
    fail "_has_traverse accepted an entry without the execute bit"
else
  echo "runner-unit.t: note: no setfacl, traverse ACL not exercised" >&2
fi

pass
