#!/bin/sh
# test/provision.t - the privileged enclave verbs (lib/provision_lib), driven
# through the real CLI against a scratch registry. No root is needed or used:
# SEVERANCE_ENCLAVES_DIR is the seam that also lifts the root requirement,
# and `getent` / `id` are stubbed where a case needs an account to exist or
# the caller to look like root.
set -eu

. "$(dirname "$0")/harness_lib"
harness_init provision

SEV=$HERE/bin/severance
ED=$T/enclaves
mkdir -p "$T/bin" "$T/tmp"

# passwd knows alice-acme (the account of a PROVISIONED enclave) only.
cat > "$T/bin/getent" <<'EOF'
#!/bin/sh
[ "$1" = passwd ] || exit 2
case $2 in
  alice-acme|990) echo 'alice-acme:x:990:990::/home/alice-acme:/bin/sh' ;;
  *) exit 2 ;;
esac
EOF
chmod +x "$T/bin/getent"

# TMPDIR is pinned so a scratch dir left behind is visible.
add() {
  env SEVERANCE_ENCLAVES_DIR="$ED" TMPDIR="$T/tmp" PATH="$T/bin:$PATH" \
    sh "$SEV" enclave add "$@"
}

# --- declare, then re-declare unchanged -----------------------------------
out=$(add acme owner=alice 'git_remote_glob=*acme*') ||
  fail "a valid add failed: $out"
case $out in *"declared"*) ;; *) fail "first add did not say declared" ;; esac
[ "$(cat "$ED/acme")" = "$(printf 'owner=alice\ngit_remote_glob=*acme*')" ] ||
  fail "record content wrong: $(cat "$ED/acme")"
[ "$(stat -c %a "$ED/acme")" = 644 ] || fail "record is not 0644"
out=$(add acme owner=alice 'git_remote_glob=*acme*')
case $out in *"current"*) ;; *) fail "an identical add did not say current" ;;
esac

# --- every refusal leaves the record and the scratch dir alone ----------------
before=$(cat "$ED/acme")
refuse() {   # <want rc> <why> <args...>
  _w=$1 _y=$2; shift 2
  rc=0; add "$@" >/dev/null 2>&1 || rc=$?
  [ "$rc" = "$_w" ] || fail "$_y: exit $rc, want $_w"
  [ "$(cat "$ED/acme")" = "$before" ] || fail "$_y: the record changed"
  [ -z "$(ls -A "$T/tmp")" ] || fail "$_y: left $(ls -A "$T/tmp") in TMPDIR"
}
refuse 2 "an unknown key" acme owner=alice colour=red
refuse 2 "no owner" acme 'git_remote_glob=x'
refuse 2 "a bad name" Acme owner=alice
refuse 2 "not key=val" acme owner=alice stray
refuse 2 "no name at all"
# acme's account EXISTS (getent says so), so its owner cannot change.
refuse 1 "an owner change under a live account" acme owner=bob

# ...but an owner change for an enclave with no account yet is fine.
add beta owner=alice >/dev/null
add beta owner=bob >/dev/null || fail "owner change with no account refused"
grep -qx owner=bob "$ED/beta" || fail "beta's owner was not updated"

# --- the record lands in the REGISTRY under any POSIX shell -----------------
# The reader validates the new record by pointing at a scratch dir. Written
# as an assignment prefixed to a function call, that pointer may OUTLIVE the
# call, which would aim the write at the scratch dir and then delete it.
# POSIX leaves it unspecified. Measured: dash, bash (posix or not) and
# busybox drop it; ksh KEEPS it. So ksh is the shell that can see the bug.
if command -v ksh >/dev/null 2>&1; then
  env SEVERANCE_ENCLAVES_DIR="$ED" TMPDIR="$T/tmp" PATH="$T/bin:$PATH" \
    ksh "$SEV" enclave add gamma owner=alice >/dev/null ||
    fail "add under ksh failed"
  [ -f "$ED/gamma" ] || fail "under ksh the record never landed"
else
  echo "provision.t: note: no ksh, the prefix-assignment case is unrun" >&2
fi

# --- privilege ---------------------------------------------------------------
# With the real registry and no root: refused by name, before anything.
if [ "$(id -u)" != 0 ]; then
  rc=0; out=$(env -u SEVERANCE_ENCLAVES_DIR sh "$SEV" enclave add zz \
    owner=alice 2>&1) || rc=$?
  [ "$rc" = 1 ] || fail "a non-root add exited $rc"
  case $out in *"run it as root"*) ;; *) fail "no reason: $out" ;; esac
fi
# Looking like ROOT (a stub id) but running this user-owned checkout: refused,
# because root executing a file its user can change is escalation.
cat > "$T/bin/id" <<'EOF'
#!/bin/sh
[ "$1" = -u ] && { echo 0; exit 0; }
exec /usr/bin/id "$@"
EOF
chmod +x "$T/bin/id"
rc=0; out=$(env -u SEVERANCE_ENCLAVES_DIR PATH="$T/bin:$PATH" sh "$SEV" \
  enclave add zz owner=alice 2>&1) || rc=$?
[ "$rc" = 1 ] || fail "root from a user-writable install exited $rc"
case $out in *"not root-owned"*) ;; *) fail "no reason: $out" ;; esac

pass "add: declare, current, refusals, owner change, posix, privilege"
