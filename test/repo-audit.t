#!/bin/sh
# test/repo-audit.t - `severance enclave check`'s repo-consistency audit
# (lib/provision_lib, _pv_check_repos), over REAL git repos in a scratch
# owner home and a scratch enclave home. passwd, id and runuser are stubbed
# so both walks run here as this user; the registry is scratch.
set -eu

. "$(dirname "$0")/harness_lib"
harness_init repo-audit

command -v git >/dev/null 2>&1 || { pass "skipped: no git here"; exit 0; }
mkdir -p "$T/bin" "$T/enclaves" "$T/homes/alice-acme/src" "$T/owner/src"
printf 'owner=alice\ngit_remote_glob=*:work-org/*\n' > "$T/enclaves/acme"
printf 'owner=alice\n' > "$T/enclaves/noglob"
cat > "$T/bin/getent" <<EOF
#!/bin/sh
case "\$1 \$2" in
  "passwd alice") echo 'alice:x:1000:1000::$T/owner:/bin/sh' ;;
  "passwd alice-acme"|"passwd 990")
    echo 'alice-acme:x:990:990::$T/homes/alice-acme:/bin/sh' ;;
  *) exit 2 ;;
esac
EOF
# root, so both sides go through runuser, which here runs as us
cat > "$T/bin/id" <<'EOF'
#!/bin/sh
[ "$1" = -u ] && { echo 0; exit 0; }
[ "$1" = -un ] && { echo root; exit 0; }
exec /usr/bin/id "$@"
EOF
printf '#!/bin/sh\nshift 3\nexec "$@"\n' > "$T/bin/runuser"
chmod +x "$T/bin/getent" "$T/bin/id" "$T/bin/runuser"

repo() {   # <dir> [origin url]
  mkdir -p "$1"
  git -C "$1" init -q
  [ -z "${2:-}" ] || git -C "$1" remote add origin "$2"
}
H=$T/homes/alice-acme/src
repo "$T/owner/src/leaked" git@github.com:work-org/api.git
repo "$T/owner/src/mine" git@github.com:alice/dotfiles.git
repo "$H/api" git@github.com:work-org/api.git
repo "$H/stray" git@github.com:alice/notes.git
repo "$H/old notes" git@github.com:alice/old.git
repo "$H/carveout/side" git@github.com:alice/side.git
repo "$H/scratch"

audit() {   # <enclave> [PATH prefix]: the check's repo lines
  env PATH="${2:-$T/bin}:$PATH" SEV_LIB="$HERE/lib" \
    SEVERANCE_ENCLAVES_DIR="$T/enclaves" SEVERANCE_HOME_ROOT="$T/homes" \
    NO_COLOR=1 sh -c '. "$SEV_LIB/common_lib"; . "$SEV_LIB/provision_lib"
      en_load "$1" && _pv_check_repos' _ "$1" 2>&1
}
out=$(audit acme)
want() { printf '%s\n' "$out" | grep -qF "$1" || fail "$2: $out"; }
want "[FAIL] work-remote repo outside enclave acme: $T/owner/src/leaked" \
  "a work repo in the owner's tree was not reported"
want "[FAIL] personal-remote repo inside enclave acme: $H/stray" \
  "a personal repo in the enclave was not reported"
want "[FAIL] personal-remote repo inside enclave acme: $H/old notes" \
  "a repo path with a space was mangled"
n=$(printf '%s\n' "$out" | grep -c FAIL || :)
[ "$n" = 3 ] || fail "want exactly 3 findings, got $n: $out"
case $out in *carveout*|*scratch*|*mine*|*"$H/api"*)
  fail "a sanctioned repo was reported: $out" ;; esac

# No glob declared: off, and said so, never a finding.
out=$(audit noglob)
case $out in *"[OK]"*"repo audit off"*) ;;
  *) fail "an enclave with no glob: $out" ;; esac

# Not root and not the user whose tree it is: unverifiable, not guessed.
mkdir -p "$T/bin2"
cp "$T/bin/getent" "$T/bin2/"
out=$(audit acme "$T/bin2")
case $out in *"unverifiable"*) ;;
  *) fail "an unprivileged run guessed: $out" ;; esac
case $out in *FAIL*) fail "an unprivileged run reported a finding: $out" ;;
esac

pass "both directions, carveout exempt, no-remote silent, off without glob"
