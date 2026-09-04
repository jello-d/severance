#!/bin/sh
# test/severance.t - behavioral test for severance, the work/personal boundary.
# Exercises the per-profile git fragment, the repo-sync audit (real throwaway
# git repos), the service overlay ACL, the CLAUDE.md placement, the
# subordinate-id allocator, and BOTH check paths (--seal / --runner) driven to
# drift. No group, ACL, user, or /etc change touches the box.
#
# This is the package's own behavioral coverage. When a host provisioner (e.g.
# tackup) drives severance as a thin delegator, its module tests shrink to
# delegation smokes and this is where the real coverage lives.
set -eu

. "$(dirname "$0")/lib.sh"
harness_init severance

SEVROOT=$HERE
WCLIB=$SEVROOT/libexec/work-context.sh
SEAL=$SEVROOT/libexec/seal.sh
RUNNER=$SEVROOT/libexec/runner.sh
SEV=$SEVROOT/bin/severance

# ============================ SEAL ==========================================

# --- render_git_gen: ITERATES profiles; one block each, includeIf keyed on the
# --- group (.inc), so grandfathered per profile ------------------------------
rgg=$(sed -n '/^render_git_gen() {/,/^}/p' "$SEAL")
mkdir -p "$T/pg"
printf 'work_group=ga\nwork_dir=/wa\nclaude_config=~/.ca\n' > "$T/pg/a"
printf 'work_group=gb\nwork_dir=/wb\nclaude_config=~/.cb\n' > "$T/pg/b"
gen=$(WC_PROFILES_DIR="$T/pg" sh -c ". '$WCLIB'
$rgg
render_git_gen")
for want in 'directory = /wa' 'directory = /wb' \
            'path = ~/.config/git/ga.inc' 'path = ~/.config/git/gb.inc' \
            '[includeIf "gitdir:/wa/"]'; do
  echo "$gen" | grep -qF "$want" || fail "render_git_gen: missing '$want'"
done

# --- audit_repos: classify repos by remote-glob vs inside-work_dir ------------
eo=$(sed -n '/^_enclave_ok() {/,/^}/p' "$SEAL")
ar=$(sed -n '/^audit_repos() {/,/^}/p' "$SEAL")
S=$T/src; WT=$S/worktree
mkrepo() {
  mkdir -p "$1"; git -C "$1" init -q; git -C "$1" remote add origin "$2"
}
mkrepo "$WT"        git@gh:acme/work-thing.git   # work-remote, in work_dir OK
mkrepo "$WT/nested" git@gh:me/personal.git       # personal-remote INSIDE  bad
mkrepo "$S/stray"   git@gh:acme/work-other.git   # work-remote OUTSIDE     bad
mkrepo "$S/mine"    git@gh:me/hobby.git          # personal outside        OK
# TOOL STATE under the enclave's own config root: a git-backed cache a tool
# made (claude's plugin marketplace), not source placed across the boundary.
mkrepo "$WT/.config/claude/plugins/marketplaces/official" git@gh:anth/plugins
audit() {
  env -i PATH="/usr/bin:/bin" WC_DIR="$WT" WC_GIT_REMOTE_GLOB='*work*' \
    WC_CONFIG_ROOT="$WT/.config" \
    WC_ENCLAVE_PERSONAL="$1" SCAN_ROOT="$S" sh -c "$eo
$ar
audit_repos"
}
find_out=$(audit '')
echo "$find_out" | grep -q "work-remote repo outside work_dir: $S/stray" \
  || fail "audit_repos: missed a work repo outside work_dir"
echo "$find_out" | grep -q "personal-remote repo inside work_dir: $WT/nested" \
  || fail "audit_repos: missed a personal repo inside work_dir"
# The config root is skipped STRUCTURALLY, with no carve-out configured: it is
# severance's own derived tree, so every profile would otherwise have to repeat
# the same exception, and every tool that caches a repo there would trip it.
echo "$find_out" | grep -q "$WT/.config" \
  && fail "audit_repos: flagged tool state under the enclave config root"

allow_out=$(audit 'nested')
echo "$allow_out" | grep -q "personal-remote repo inside work_dir: $WT/nested" \
  && fail "audit_repos: flagged a sanctioned enclave-personal repo"
echo "$allow_out" | grep -q "work-remote repo outside work_dir: $S/stray" \
  || fail "audit_repos: allowlist wrongly suppressed an outside work repo"


# --- place_claude_md: SEED a fresh enclave, never clobber its own doc ---------
pcm=$(sed -n '/^place_claude_md() {/,/^}/p' "$SEAL")
PT=$T/pcm; mkdir -p "$PT/src" "$PT/wd" "$PT/pbin"
SRC=$PT/src/CLAUDE.md
printf '<!-- Seeded by severance -->\nv1\n' > "$SRC"
cat > "$PT/pbin/sudo" <<'EOF'
#!/bin/sh
[ "$1" = install ] || exec "$@"
shift; src= dst=
while [ $# -gt 0 ]; do case "$1" in
  -m|-o|-g) shift 2 ;; -*) shift ;;
  *) [ -z "$src" ] && src=$1 || dst=$1; shift ;;
esac; done
cp "$src" "$dst"
EOF
chmod +x "$PT/pbin/sudo"
DST=$PT/wd/CLAUDE.md
pcm_run() {
  env -i PATH="$PT/pbin:/usr/bin:/bin" SEVERANCE_ENCLAVE_MD="$SRC" \
    WC_DIR="$PT/wd" WC_PROFILE=demo WC_GROUP=wg sh -c "$pcm
place_claude_md"
}
pcm_run | grep -q 'seeded' || fail "seed: not seeded into a fresh enclave"
cmp -s "$SRC" "$DST" || fail "seed: content mismatch"
pcm_run | grep -q 'present' || fail "seed: did not leave an existing doc as-is"
printf 'enclave-owned edits\n' > "$DST"                # the enclave owns it now
pcm_run >/dev/null 2>&1
grep -q 'enclave-owned edits' "$DST" || fail "seed: clobbered the enclave doc"

# --- seal check: over a profiles dir; clean, then each wall knob driven red --
R=$T/sealchk
mkdir -p "$R/self/profiles" "$T/home/wt" "$T/bin" "$T/empty" "$R/enc"
printf 'work_group=wg\nwork_dir=~/wt\nclaude_config=~/.cw\n' \
  > "$R/self/profiles/demo"
# a git fragment matching render_git_gen over that profiles dir
WC_PROFILES_DIR="$R/self/profiles" HOME="$T/home" sh -c ". '$WCLIB'
$rgg
render_git_gen" > "$T/gitgen"

# Stubs the seal + membership verdicts read -- KNOB-DRIVEN so each wall drift
# below can be driven red. Default state is a correct seal + transient member.
cat > "$T/bin/getent" <<EOF
#!/bin/sh
[ "\$1 \$2" = "group wg" ] || exit 2
if [ -f "$T/perm_member" ]; then echo "wg:x:9:tester"; else echo "wg:x:9:"; fi
EOF
cat > "$T/bin/stat" <<EOF
#!/bin/sh
for a; do p=\$a; done                 # last arg is the path
case "\$p" in
  */.config)                          # the sealed WORK_HOME/.config root
    case "\$2" in
      '%a') cat "$T/cfg_mode"  2>/dev/null || echo 2770 ;;
      *)    cat "$T/cfg_owner" 2>/dev/null || echo root:wg ;;
    esac ;;
  *)
    case "\$2" in
      '%a') cat "$T/wc_mode"  2>/dev/null || echo 2770 ;;
      *)    cat "$T/wc_owner" 2>/dev/null || echo root:wg ;;
    esac ;;
esac
EOF
cat > "$T/bin/getfacl" <<EOF
#!/bin/sh
[ -f "$T/no_gacl" ] || printf 'default:group:wg:rwx\n'
[ -f "$T/no_oacl" ] || printf 'default:other::---\n'
EOF
printf '#!/bin/sh\necho tester\n' > "$T/bin/id"
printf '<!-- Managed by tackup -->\nx\n' > "$R/enc/CLAUDE.md"
cp "$R/enc/CLAUDE.md" "$T/home/wt/CLAUDE.md"
printf '#!/bin/sh\n[ "$1" = -n ] && shift\nexec "$@"\n' > "$T/bin/sudo"
chmod +x "$T/bin"/*

seal_run() {
  env -i PATH="$T/bin:/usr/bin:/bin" HOME="$T/home" \
    WC_PROFILES_DIR="$R/self/profiles" SUDOERS="$T/sudoers" \
    GIT_GEN="$T/gitgen" SCAN_ROOT="$T/empty" \
    SEVERANCE_ENCLAVE_MD="$R/enc/CLAUDE.md" "$SEV" check --seal
}
rm -f "$T/sudoers"
seal_run >/dev/null 2>&1 || fail "seal check reported drift on a correct wall"
printf 'GRANT\n' > "$T/sudoers"
seal_run >/dev/null 2>&1 && fail "seal check passed with a legacy work grant"
rm -f "$T/sudoers"                                  # heal the grant

# The kernel-wall seal + the transient-member invariant are the ZDR boundary;
# each verdict must be drivable to drift (else check is blind to a broken wall).
echo other:wg > "$T/wc_owner"
seal_run >/dev/null 2>&1 && fail "seal check passed: work_dir not root-owned"
rm -f "$T/wc_owner"
echo 2775 > "$T/wc_mode"
seal_run >/dev/null 2>&1 && fail "seal check passed with work_dir mode not 2770"
rm -f "$T/wc_mode"
: > "$T/no_gacl"
seal_run >/dev/null 2>&1 && fail "seal check passed with default group ACL gone"
rm -f "$T/no_gacl"
: > "$T/no_oacl"
seal_run >/dev/null 2>&1 && fail "seal check passed: default other ACL loose"
rm -f "$T/no_oacl"
echo 2775 > "$T/cfg_mode"
seal_run >/dev/null 2>&1 && fail "seal check passed: config root not 2770"
rm -f "$T/cfg_mode"
echo tester:wg > "$T/cfg_owner"
seal_run >/dev/null 2>&1 && fail "seal check passed: config root not root-owned"
rm -f "$T/cfg_owner"
: > "$T/perm_member"
seal_run >/dev/null 2>&1 && fail "seal check passed with a permanent member"
rm -f "$T/perm_member"
seal_run >/dev/null 2>&1 || fail "seal check drifted after healing every knob"

# ============================ RUNNER ========================================

# --- _next_subid_block: next free 65536 block past the highest allocation ----
nsb=$(sed -n '/^_next_subid_block() {/,/^}/p' "$RUNNER")
printf 'foo:100000:65536\nbar:165536:65536\n' > "$T/subuid"   # ends at 231072
got=$(sh -c "$nsb
_next_subid_block $T/subuid")
[ "$got" = "231072-296607" ] \
  || fail "_next_subid_block: got '$got', want 231072-296607"

# --- runner check: iterate one profile 'demo' whose runner is 'r' ------------
RR=$T/runchk
mkdir -p "$RR/self/profiles" "$T/rbin" "$T/rhome"
printf 'work_group=wg\nwork_dir=~/wt\n' > "$RR/self/profiles/demo"
printf 'claude_config=~/.cw\nrunner=r\n' >> "$RR/self/profiles/demo"
printf 'r:100000:65536\n' > "$T/subuid.f"
printf 'r:100000:65536\n' > "$T/subgid.f"

for c in docker socat dockerd-rootless.sh; do
  printf '#!/bin/sh\nexit 0\n' > "$T/rbin/$c"
done
cat > "$T/rbin/id" <<EOF
#!/bin/sh
if [ "\$1" = -gn ]; then
  if [ -f "$T/wrong_pg" ]; then echo other; else echo wg; fi
  exit 0
fi
[ -f "$T/no_user" ] && exit 1      # the runner account is absent
exit 0
EOF
cat > "$T/rbin/getent" <<'EOF'
#!/bin/sh
[ "$1 $2" = "group wg" ] && { echo "wg:x:9:"; exit 0; }
exit 2
EOF
cat > "$T/rbin/getfacl" <<EOF
#!/bin/sh
[ -f "$T/no_traverse" ] && exit 0
echo "user:r:--x"
EOF
cat > "$T/rbin/loginctl" <<EOF
#!/bin/sh
if [ -f "$T/no_linger" ]; then echo "Linger=no"; else echo "Linger=yes"; fi
EOF
chmod +x "$T/rbin"/*
: > "$T/r.conf"   # socket-dir tmpfiles present (TMPFILES_DIR=$T)

run_r() {
  env -i PATH="$T/rbin:/usr/bin:/bin" HOME="$T/rhome" \
    WC_PROFILES_DIR="$RR/self/profiles" SUBUID="$T/subuid.f" \
    SUBGID="$T/subgid.f" TMPFILES_DIR="$T" "$SEV" check --runner
}

run_r >/dev/null 2>&1 || fail "runner check reported drift on a correct runner"

: > "$T/wrong_pg"                   # primary group not the profile group
run_r >/dev/null 2>&1 && fail "runner check passed with the wrong primary group"
rm -f "$T/wrong_pg"

: > "$T/no_linger"
run_r >/dev/null 2>&1 && fail "runner check passed with lingering disabled"
rm -f "$T/no_linger"

rm -f "$T/r.conf"                  # socket-dir tmpfiles missing
run_r >/dev/null 2>&1 && fail "runner check passed: socket-dir tmpfiles gone"
: > "$T/r.conf"                    # heal tmpfiles

: > "$T/no_user"                   # the runner service account absent
run_r >/dev/null 2>&1 && fail "runner check passed with the runner account gone"
rm -f "$T/no_user"

: > "$T/no_traverse"               # no traverse ACL on $HOME (can't reach tree)
run_r >/dev/null 2>&1 && fail "runner check passed: traverse ACL missing"
rm -f "$T/no_traverse"

run_r >/dev/null 2>&1 || fail "runner check drifted after healing every knob"

# ============================ INSTALL (standalone) ==========================
# A valet-key stub so the hook-publish path runs; git is real (via PATH).
IB=$T/ibin; mkdir -p "$IB"
printf '#!/bin/sh\nexit 0\n' > "$IB/valet-key"; chmod +x "$IB/valet-key"
inst() {   # <home> <verb>
  env -i PATH="$IB:/usr/bin:/bin" HOME="$1" "$SEV" "$2"
}
gget() {   # <home> -> the global include.path values
  env -i PATH="$IB:/usr/bin:/bin" HOME="$1" \
    git config --global --get-all include.path 2>/dev/null
}

# fresh install into an empty HOME: LINKS ONLY. `severance install` configures
# no other tool -- nobody installing a work/personal boundary expects it to
# edit their git config, and which boxes get which integration is the
# integrator's call. severance publishes the artifacts and audits the result;
# placing them is somebody else's job.
H1=$T/h1; mkdir -p "$H1"
inst "$H1" install >/dev/null 2>&1 || fail "install exited non-zero"
[ -L "$H1/.local/bin/severance" ] || fail "install: severance not linked"
[ -L "$H1/.local/bin/work" ]      || fail "install: work not linked"
[ -L "$H1/.local/libexec/severance" ] || fail "install: libexec not linked"
[ -L "$H1/.local/share/severance" ]   || fail "install: share not linked"

# ...and it touched NOTHING else. These are the two it used to write.
gget "$H1" | grep -q work-context.gen \
  && fail "install wrote an include into the user's git config"
[ -e "$H1/.config/valet-key/context" ] \
  && fail "install wrote into valet-key's config dir"

# It must SAY so rather than leaving the user to wonder why nothing is wired.
hint=$(inst "$H1" install 2>&1) || fail "install (rerun) exited non-zero"
case $hint in
  *"NOT wired by install"*) ;;
  *) fail "install did not report that integrations are unwired" ;;
esac
case $hint in
  *"severance doctor"*) ;;
  *) fail "install's hint does not point at doctor" ;;
esac

# idempotent: a second run is still links-only and still errors on nothing.
[ -L "$H1/.local/bin/severance" ] || fail "install (rerun): link lost"

# uninstall removes the ~/.local links.
inst "$H1" uninstall >/dev/null 2>&1 || fail "uninstall exited non-zero"
[ -L "$H1/.local/bin/severance" ] && fail "uninstall: left the severance link"
[ -L "$H1/.local/libexec/severance" ] && fail "uninstall: left the libexec link"

# ============================ VALIDATE ======================================
VD=$T/vd; mkdir -p "$VD"
val() { env -i PATH="/usr/bin:/bin" HOME="$T" WC_PROFILES_DIR="$VD" "$SEV" \
  validate "$1"; }
printf 'work_group=g\nwork_dir=/w/g\nclaude_config=~/.cg\n' > "$VD/good"
val good >/dev/null 2>&1 || fail "validate: rejected a good record"
# work_dir == HOME is too broad (the wall must be a subdir)
printf 'work_group=b\nwork_dir=%s\nclaude_config=~/.cb\n' "$T" > "$VD/broad"
val broad >/dev/null 2>&1 && fail "validate: passed work_dir == HOME"
# an invalid group name
printf 'work_group=Bad Grp\nwork_dir=/w/x\nclaude_config=~/.cx\n' \
  > "$VD/badgrp"
val badgrp >/dev/null 2>&1 && fail "validate: passed an invalid group name"
# a record that does not parse (missing required work_dir)
printf 'work_group=m\nclaude_config=~/.cm\n' > "$VD/nowd"
val nowd >/dev/null 2>&1 && fail "validate: passed a record missing work_dir"

# ============================ FORGET ========================================
# SEVERANCE_DRYRUN makes every `sudo` a logged no-op, so the teardown is proven
# by its dry-run log without touching any account, /etc, or /run.
FB=$T/fbin; mkdir -p "$FB"
cat > "$FB/id" <<'EOF'
#!/bin/sh
[ "$1" = -u ]  && { echo 4242;   exit 0; }
[ "$1" = -un ] && { echo tester; exit 0; }
exit 0
EOF
printf '#!/bin/sh\nexit 0\n' > "$FB/setfacl"
chmod +x "$FB"/*
FP=$T/fp; mkdir -p "$FP"
printf 'work_group=k\nwork_dir=/w/k\nclaude_config=~/.ck\nrunner=k-run\n' \
  > "$FP/keep"
printf 'work_group=g\nwork_dir=/w/g\nclaude_config=~/.cg\nrunner=g-run\n' \
  > "$FP/gone"
fgt() { env -i PATH="$FB:/usr/bin:/bin" HOME="$T" WC_PROFILES_DIR="$FP" \
  SEVERANCE_DRYRUN=1 "$SEV" forget "$@" 2>&1; }

# default forget tears down the runner (logged) and LEAVES the record.
out=$(fgt gone)
echo "$out" | grep -q 'removed runner account g-run' \
  || fail "forget: did not tear down the runner"
echo "$out" | grep -q 'rm -rf /run/g-run' \
  || fail "forget: did not clean the runner socket dir"
[ -f "$FP/gone" ] || fail "forget (no --purge): removed the record"

# --purge removes the record, keeps the survivor.
fgt gone --purge >/dev/null 2>&1 || fail "forget --purge exited non-zero"
[ -e "$FP/gone" ] && fail "forget --purge: left the record"
[ -f "$FP/keep" ] || fail "forget --purge: removed the wrong record"

# GUARD: a host-managed (symlink) profiles dir keeps its record.
ln -s "$FP" "$T/fp-link"
printf 'work_group=h\nwork_dir=/w/h\nclaude_config=~/.ch\n' > "$FP/host"
env -i PATH="$FB:/usr/bin:/bin" HOME="$T" WC_PROFILES_DIR="$T/fp-link" \
  SEVERANCE_DRYRUN=1 "$SEV" forget host --purge >/dev/null 2>&1 \
  || fail "forget (guarded) errored"
[ -f "$FP/host" ] || fail "forget --purge: removed a host-managed record"

# init + use DEFER on a host-managed (symlink) profiles dir ($T/fp-link above).
hm() { env -i PATH="/usr/bin:/bin" HOME="$T" WC_PROFILES_DIR="$T/fp-link" \
  "$SEV" "$@"; }
hm init nope >/dev/null 2>&1 && fail "init: wrote on a host-managed box"
[ -e "$FP/nope" ] && fail "init: created a record on a host-managed box"
hm use keep >/dev/null 2>&1 && fail "use: wrote on a host-managed box"

# `show --shell` is RETIRED: it was advertised as a stable contract for
# external consumers and had none. It must fail LOUDLY and name what replaced
# it, not be silently reinterpreted as a profile name.
SD=$T/sd; mkdir -p "$SD"
printf 'work_group=zg\nwork_dir=/w/z\nclaude_config=~/.z\n' > "$SD/zz"
sh_rc=0
sh_err=$(env -i PATH="/usr/bin:/bin" HOME="$T" WC_PROFILES_DIR="$SD" \
  "$SEV" show --shell 2>&1 >/dev/null) || sh_rc=$?
[ "$sh_rc" = 2 ] || fail "show --shell: rc=$sh_rc, want 2 (retired)"
case $sh_err in
  *"severance current"*) ;;
  *) fail "show --shell: retirement does not name the replacement: $sh_err" ;;
esac

# The human form still reports a record, and carries NO label field: an enclave
# has one name, the profile name.
sh_out=$(env -i PATH="/usr/bin:/bin" HOME="$T" WC_PROFILES_DIR="$SD" \
  "$SEV" show) || fail "show exited non-zero"
case $sh_out in
  *"profile=zz"*) ;; *) fail "show: no profile line: $sh_out" ;;
esac
case $sh_out in
  *label*) fail "show still reports a label field" ;;
esac

# claude_config DERIVES from work_dir when the record omits it (work-home): the
# per-enclave config root is WORK_HOME/.config and claude lives under it.
printf 'work_group=dg\nwork_dir=/w/dv\n' > "$SD/dv"
dv_out=$(env -i PATH="/usr/bin:/bin" HOME="$T" WC_PROFILES_DIR="$SD" \
  "$SEV" show dv) || fail "show (derive) exited non-zero"
case $dv_out in
  *"claude_config=/w/dv/.config/claude"*) ;;
  *) fail "derive: claude_config did not derive: $dv_out" ;;
esac
# ...and the runner name derives from the PROFILE, now that label is gone.
case $dv_out in
  *"runner=dv-runner"*) ;;
  *) fail "derive: runner did not derive from the profile name: $dv_out" ;;
esac

# --- RETIRED record keys fail loud, and say what to do -----------------------
# A record is edited by a human, so a key we removed should point at the
# replacement rather than emit a bare "unknown key".
RD=$T/rd; mkdir -p "$RD"
for pair in "label:.workrc" "service_user:GROUP" \
            "service_overlay:GROUP" "service_overlay_write:GROUP"; do
  _k=${pair%%:*}; _want=${pair#*:}
  printf '%s=x\nwork_dir=/w/r\n' "$_k" > "$RD/r"
  rc=0
  err=$(env -i PATH="/usr/bin:/bin" HOME="$T" WC_PROFILES_DIR="$RD" \
    "$SEV" show r 2>&1 >/dev/null) || rc=$?
  [ "$rc" = 0 ] && fail "retired key '$_k' was accepted"
  case $err in
    *"'$_k' is retired"*) ;;
    *) fail "retired key '$_k' gave a bare error: $err" ;;
  esac
  case $err in
    *"$_want"*) ;;
    *) fail "retired key '$_k' did not point at the replacement: $err" ;;
  esac
done

# A genuinely unknown key still gets the generic message.
printf 'nonsense=x\nwork_dir=/w/r\n' > "$RD/r"
err=$(env -i PATH="/usr/bin:/bin" HOME="$T" WC_PROFILES_DIR="$RD" \
  "$SEV" show r 2>&1 >/dev/null) || true
case $err in
  *"unknown key: nonsense"*) ;;
  *) fail "an unknown key lost its generic diagnostic: $err" ;;
esac

pass
