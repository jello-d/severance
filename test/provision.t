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

# --- provision (dry-run): what it would do, and what it refuses -------------
# Every box path points into T. getent knows: the owner alice (shell ksh);
# alice-acme, a system account in its own group (provisioned); alice-reg, a
# REGULAR uid; alice-grp, a system uid whose group is not its own.
cat > "$T/bin/getent" <<'EOF2'
#!/bin/sh
case "$1 $2" in
  "passwd alice") echo 'alice:x:1000:1000::/home/alice:/bin/ksh' ;;
  "passwd alice-acme"|"passwd 990")
    echo 'alice-acme:x:990:990::/home/alice-acme:/bin/ksh' ;;
  "passwd alice-reg") echo 'alice-reg:x:1500:1500::/home/alice-reg:/bin/sh' ;;
  "passwd alice-grp") echo 'alice-grp:x:991:100::/home/alice-grp:/bin/sh' ;;
  "group 990") echo 'alice-acme:x:990:' ;;
  "group 1500") echo 'alice-reg:x:1500:' ;;
  "group 100") echo 'users:x:100:' ;;
  *) exit 2 ;;
esac
EOF2
printf 'carol:100000:65536\nother:165536:65536\n' > "$T/subuid"
cp "$T/subuid" "$T/subgid"
mkdir -p "$T/linger" "$T/tmpfiles"
printf 'UID_MIN 1000\n' > "$T/login.defs"
prov() {
  env SEVERANCE_ENCLAVES_DIR="$ED" SEVERANCE_DRYRUN=1 TMPDIR="$T/tmp" \
    SUBUID="$T/subuid" SUBGID="$T/subgid" LINGER_DIR="$T/linger" \
    TMPFILES_DIR="$T/tmpfiles" LOGIN_DEFS="$T/login.defs" \
    PATH="$T/bin:$PATH" sh "$SEV" enclave provision "$@"
}
for e in newe reg grp; do printf 'owner=alice\n' > "$ED/$e"; done
printf 'owner=nobody-here\n' > "$ED/orphan"

out=$(prov newe) || fail "provision of a new enclave failed: $out"
want() {   # <fixed string> <why>
  printf '%s\n' "$out" | grep -qF -- "$1" || fail "$2; got: $out"
}
want "dry-run: useradd --system --user-group --create-home --home-dir \
/home/alice-newe --shell /bin/ksh --comment severance enclave newe alice-newe" \
  "the account is not created as a system account with its own group"
want "dry-run: usermod --add-subuids 231072-296607 alice-newe" \
  "the subuid block is not the next free one"
want "dry-run: usermod --add-subgids 231072-296607 alice-newe" \
  "the subgid block is not the next free one"
want "dry-run: loginctl enable-linger alice-newe" "linger is not enabled"
want "$T/tmpfiles/severance-newe.conf" "the share dir is not declared"
want "dry-run: runuser -u alice-newe" \
  "environment.d is not written AS THE ACCOUNT"

# Already provisioned: nothing is created or allocated again.
grep -q '^alice-acme:' "$T/subuid" || {
  echo 'alice-acme:231072:65536' >> "$T/subuid"
  echo 'alice-acme:231072:65536' >> "$T/subgid"; }
: > "$T/linger/alice-acme"
out=$(prov acme) || fail "provision of a provisioned enclave failed: $out"
printf '%s\n' "$out" | grep -E 'dry-run: (useradd|usermod|loginctl)' &&
  fail "an already-provisioned enclave was provisioned again: $out"

# Accounts that are NOT ours are refused, never adopted.
nope() {   # <enclave> <stderr must say> <why>
  rc=0; prov "$1" >/dev/null 2>"$T/err" || rc=$?
  [ "$rc" = 1 ] || fail "$3: exit $rc"
  grep -q "$2" "$T/err" || fail "$3: $(cat "$T/err")"
}
nope reg "a REGULAR account" "a regular-range account of that name"
nope grp "not its own" "an account whose primary group is shared"
nope orphan "is not an account here" "an owner with no account"
rm -f "$ED/newe" "$ED/reg" "$ED/grp" "$ED/orphan"

# --- the renders: who may reach the share dir, and what the session sees ------
render() {   # <enclave> <function>
  env SEV_LIB="$HERE/lib" SEVERANCE_SELF="$SEV" SEVERANCE_ENCLAVES_DIR="$ED" \
    PATH="$T/bin:$PATH" sh -c '. "$SEV_LIB/common_lib"
    . "$SEV_LIB/provision_lib"; en_load "$1" && "$2"' _ "$1" "$2"
}
[ "$(render acme _pv_render_share)" = \
  "d /run/severance/acme 0710 alice alice-acme -" ] ||
  fail "share dir line wrong: $(render acme _pv_render_share)"
[ "$(render acme _pv_render_parent)" = "d /run/severance 0755 root root -" ] ||
  fail "share parent line wrong"
env_out=$(render acme _pv_render_env)
for l in SEVERANCE_ENCLAVE=acme WAYLAND_DISPLAY=/run/severance/acme/wayland-0 \
         PULSE_SERVER=unix:/run/severance/acme/pulse; do
  printf '%s\n' "$env_out" | grep -qx "$l" || fail "environment lacks $l"
done

# --- forget an enclave: retire keeps the data, purge does not ----------------
# The home root is moved into T (SEVERANCE_HOME_ROOT), so the KEEP path, the
# one that matters most, is exercised against a real directory.
HR=$T/home; mkdir -p "$HR/alice-acme"; : > "$HR/alice-acme/work-file"
fgt() {
  env SEVERANCE_ENCLAVES_DIR="$ED" SEVERANCE_HOME_ROOT="$HR" \
    SEVERANCE_SHARE_ROOT="$T/run" TMPDIR="$T/tmp" \
    SUBUID="$T/subuid" SUBGID="$T/subgid" LINGER_DIR="$T/linger" \
    TMPFILES_DIR="$T/tmpfiles" WC_PROFILES_DIR="$T/profiles" \
    PATH="$T/bin:$PATH" ${DRY+SEVERANCE_DRYRUN=1} ${GONE+GONE=$GONE} \
    sh "$SEV" forget "$@"
}
DRY=1; out=$(fgt acme) || fail "forget (dry) failed: $out"
want "dry-run: loginctl disable-linger alice-acme" "linger not turned off"
want "dry-run: mv $HR/alice-acme $HR/alice-acme.retired-" \
  "the home is not RETIRED (kept) by default"
want "dry-run: chown -R root:root $HR/alice-acme.retired-" \
  "the retired home is not taken away from the freed uid"
want "dry-run: userdel alice-acme" "the account is not removed"
want "record kept" "the record should survive a plain forget"
printf '%s\n' "$out" | grep -q 'userdel -r' &&
  fail "a plain forget deleted the home (userdel -r)"
out=$(fgt acme --purge) || fail "forget --purge (dry) failed: $out"
want "dry-run: userdel -r alice-acme" "purge does not delete the home"
want "dry-run: rm -f $ED/acme" "purge does not remove the record"

# A name that is both a profile and an enclave is refused, not guessed.
mkdir -p "$T/profiles"; printf 'work_dir=/w/acme\n' > "$T/profiles/acme"
rc=0; out=$(fgt acme 2>&1) || rc=$?
[ "$rc" = 1 ] || fail "an ambiguous forget exited $rc"
case $out in *"both an enclave and a profile"*) ;; *) fail "$out" ;; esac
rm -f "$T/profiles/acme"

# THE REAL PATH, stubbed: the account is gone only when passwd says so.
unset DRY
for c in loginctl chown groupdel; do
  printf '#!/bin/sh\nexit 0\n' > "$T/bin/$c"; done
printf '#!/bin/sh\nexit 1\n' > "$T/bin/pgrep"
printf '#!/bin/sh\n[ -n "$GONE" ] && : > "$GONE"\nexit 0\n' > "$T/bin/userdel"
chmod +x "$T/bin"/*
# getent answers "absent" for alice-acme once the GONE marker exists.
mv "$T/bin/getent" "$T/bin/getent.real"
cat > "$T/bin/getent" <<EOF2
#!/bin/sh
[ -e "$T/gone" ] && [ "\$2" = alice-acme ] && exit 2
exec "$T/bin/getent.real" "\$@"
EOF2
chmod +x "$T/bin/getent"
rc=0; out=$(fgt acme 2>&1) || rc=$?
[ "$rc" = 1 ] || fail "forget exited $rc with the account still there"
case $out in *"FAILED to remove account alice-acme"*) ;;
  *) fail "a surviving account was not named: $out" ;; esac
mkdir -p "$HR/alice-acme"; : > "$HR/alice-acme/work-file"
GONE=$T/gone
rc=0; out=$(fgt acme 2>&1) || rc=$?
unset GONE
[ "$rc" = 0 ] || fail "forget failed after userdel worked: $out"
case $out in *"removed account alice-acme"*) ;; *) fail "$out" ;; esac
ls "$HR" | grep -q '^alice-acme\.retired-' ||
  fail "the retired home is not there: $(ls "$HR")"
[ -f "$HR"/alice-acme.retired-*/work-file ] ||
  fail "the retired home lost its contents"
[ -f "$ED/acme" ] || fail "a plain forget removed the record"

pass "add, provision, renders, forget (retire, purge, verified), privilege"
