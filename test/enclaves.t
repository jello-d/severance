#!/bin/sh
# test/enclaves.t - `severance enclaves`, the registry MACHINE INTERFACE, and
# the en_load rules behind it (docs/enclave-user.md).
#
# Driven through the real CLI against a scratch registry. The one stub is
# `getent`, standing in for passwd so "this account exists" can be planted
# without creating one. Nothing outside T is read: SEVERANCE_ENCLAVES_DIR
# points into it.
set -eu

. "$(dirname "$0")/harness_lib"
harness_init enclaves

SEV=$HERE/bin/severance
ED=$T/enclaves
mkdir -p "$ED" "$T/bin"

# passwd knows two accounts, by name or uid: alice-acme (990), and
# alice-broke (991), whose registry record will be unreadable.
cat > "$T/bin/getent" <<'EOF'
#!/bin/sh
[ "$1" = passwd ] || exit 2
case $2 in
  alice-acme|990) echo 'alice-acme:x:990:990::/home/alice-acme:/bin/sh' ;;
  alice-broke|991) echo 'alice-broke:x:991:991::/home/alice-broke:/bin/sh' ;;
  *) exit 2 ;;
esac
EOF
chmod +x "$T/bin/getent"

sev() {
  env SEVERANCE_ENCLAVES_DIR="$ED" PATH="$T/bin:$PATH" NO_COLOR=1 \
    sh "$SEV" "$@"
}
TAB=$(printf '\t')

# --- no registry at all is NO enclaves, not an error ------------------------
rc=0; out=$(env SEVERANCE_ENCLAVES_DIR="$T/nope" sh "$SEV" enclaves) || rc=$?
[ "$rc" = 0 ] && [ -z "$out" ] ||
  fail "a missing registry: rc=$rc out='$out', want 0 and nothing"

# --- the line format: five TAB-separated fields -----------------------------
printf 'owner=alice\ngit_remote_glob=*acme*\n' > "$ED/acme"
printf '# a comment\nowner=alice\ndocker=no\n' > "$ED/beta"
out=$(sev enclaves) || fail "a clean registry exited non-zero: $out"
want="acme${TAB}alice-acme${TAB}990${TAB}/home/alice-acme"
want="$want${TAB}/run/severance/acme"
printf '%s\n' "$out" | grep -qxF "$want" ||
  fail "acme line wrong; got: $out"
# beta's account does not exist yet, so its uid is '-', never empty: an empty
# field would shift every later column for a consumer splitting on TAB.
want="beta${TAB}alice-beta${TAB}-${TAB}/home/alice-beta"
want="$want${TAB}/run/severance/beta"
printf '%s\n' "$out" | grep -qxF "$want" ||
  fail "an unprovisioned enclave's uid is not '-'; got: $out"
n=$(printf '%s\n' "$out" | awk -F'\t' 'NF != 5' | wc -l)
[ "$n" -eq 0 ] || fail "a line without exactly five fields: $out"

# SEVERANCE_SHARE_ROOT moves the share dir, and only that.
out=$(env SEVERANCE_SHARE_ROOT=/srv/sev sh -c '
  SEVERANCE_ENCLAVES_DIR="$1" PATH="$2:$PATH" sh "$3" enclaves' _ \
  "$ED" "$T/bin" "$SEV" | grep '^acme')
case $out in
  *"${TAB}/srv/sev/acme") ;;
  *) fail "SEVERANCE_SHARE_ROOT not honoured: $out" ;;
esac

# --- a bad record is NAMED, fails the list, and spares the good ones --------
bad() {   # <file> <content> <what stderr must say> <why>
  printf '%b' "$2" > "$ED/$1"
  rc=0; out=$(sev enclaves 2>"$T/err") || rc=$?
  [ "$rc" = 1 ] || fail "$4: exit $rc, want 1"
  grep -q "$3" "$T/err" || fail "$4: stderr lacks '$3': $(cat "$T/err")"
  printf '%s\n' "$out" | grep -q '^acme' ||
    fail "$4: a good record vanished alongside the bad one"
  printf '%s\n' "$out" | grep -q "^$1" && fail "$4: the bad record was listed"
  rm -f "$ED/$1"
}
bad zz 'owner=alice\ncolour=red\n' "unknown key 'colour'" "an unknown key"
bad zz 'git_remote_glob=x\n' 'missing owner' "a record with no owner"
bad zz 'owner=Alice\n' "is not a user name" "an owner that is no user name"
bad zz 'owner=alice\ndocker=maybe\n' 'docker must be yes or no' \
  "a docker value that is neither"
bad Acme 'owner=alice\n' 'is not a DNS label' "an upper-case enclave name"
bad -x 'owner=alice\n' 'is not a DNS label' "a leading-hyphen name"
# alice- plus 27 = 33 characters: one over useradd's limit, caught by name.
bad aaaaaaaaaaaaaaaaaaaaaaaaaaa 'owner=alice\n' 'over 32 characters' \
  "an account name useradd would refuse"

# --- current, by uid ----------------------------------------------------------
# A fake /proc (SEV_PROC) plants a process with any uid, without one existing.
# The group model is pointed at an EMPTY profiles dir, so a fall-through can
# only answer "personal".
# The broken-record case uses THIS shell's real pid, so if the uid check
# wrongly says "not mine", the group model can genuinely answer "personal"
# (exit 0) instead of failing to find the pid, which would pass by accident.
mkdir -p "$T/proc/4242" "$T/proc/$$" "$T/nopro"
printf 'Name:\tx\nUid:\t990\t990\t990\t990\n' > "$T/proc/4242/status"
printf 'Name:\tx\nUid:\t991\t991\t991\t991\n' > "$T/proc/$$/status"
cur() {
  env SEV_PROC="${CP:-$T/proc}" WC_PROFILES_DIR="$T/nopro" \
    WC_DEFAULT_FILE="$T/nodefault" SEVERANCE_ENCLAVES_DIR="$ED" \
    PATH="$T/bin:$PATH" sh "$SEV" current "$@"
}
out=$(cur 4242) || fail "current for an enclave account exited non-zero"
[ "$out" = acme ] || fail "current for uid 990: '$out', want acme"

# A personal process (this test's own shell, real /proc): nothing, exit 0.
rc=0; out=$(CP=/proc cur "$$") || rc=$?
[ "$rc" = 0 ] && [ -z "$out" ] ||
  fail "current for a personal process: rc=$rc out='$out'"

# An account that would belong to an UNREADABLE record cannot be called
# personal: exit 2, never an empty "not in an enclave".
printf 'owner=alice\ncolour=red\n' > "$ED/broke"
rc=0; out=$(cur "$$" 2>/dev/null) || rc=$?
[ "$rc" = 2 ] || fail "current behind a broken record: rc=$rc out='$out'"
rm -f "$ED/broke"

rc=0; cur 999999 >/dev/null 2>&1 || rc=$?
[ "$rc" = 2 ] || fail "current for a missing pid exited $rc, want 2"

# --- usage ------------------------------------------------------------------
rc=0; sev enclaves extra >/dev/null 2>&1 || rc=$?
[ "$rc" = 2 ] || fail "an extra argument exited $rc, want 2"

pass "registry list, bad records named, current by uid"
