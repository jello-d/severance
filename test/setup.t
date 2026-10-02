#!/bin/sh
# setup.t - setup.sh is the package installer, and what it must produce is a
# PAYLOAD: a self-contained copy at <data>/severance with bin, libexec, share
# and man inside it, plus links from <bin> and <man> INTO it. Nothing under the
# prefix may resolve back into the source tree, which is the whole point of the
# conversion: on a provisioned box the source is a cache clone that is
# re-cloned on every sweep, so a link into it is a dangling `work` and a
# dangling `severance guard` waiting for a cache wipe.
#
# Driven against a scratch PREFIX with HOME faked for EVERY invocation, not
# only the steps that are about HOME. A sandbox must not depend on the
# installer being correct: this suite's job is to break setup.sh, and the one
# variable that bounds the blast radius of a wrong delete is HOME.
#
# `check` is not run here. It ends in `severance check`, which audits a
# provisioned work boundary (groups, ACLs, a rootless-docker runner) and has
# nothing to say about a scratch dir; severance.t covers that audit with stubs.
# The install assertions `check` makes are made directly below instead.
set -eu

. "$(dirname "$0")/harness_lib"
harness_init setup

TAB=$(printf '\t')
H=$T/home
mkdir -p "$H"

# Each scenario gets its OWN prefix, so none has to clean up after another and
# this file never needs an `rm -rf` of its own against a derived path.
P1=$T/p1 P2=$T/p2 P3=$T/p3 P4=$T/p4

# run <prefix> <verb>...
run() {
  _p=$1; shift
  env -i PATH="/usr/bin:/bin" HOME="$H" PREFIX="$_p" \
    XDG_BIN_HOME="$_p/bin" XDG_DATA_HOME="$_p/share" \
    XDG_CONFIG_HOME="$H/.config" NO_COLOR=1 sh "$HERE/setup.sh" "$@"
}

# --- install: a payload, and links into it -----------------------------------
run "$P1" install >/dev/null 2>&1 || fail "setup.sh install errored"
PAY=$P1/share/severance

[ -d "$PAY" ] && [ ! -L "$PAY" ] || fail "no payload DIRECTORY at $PAY"
# All four roots, because bin/severance self-locates ../libexec and ../share:
# a payload missing one installs a command that cannot find its own reader.
for _d in bin libexec share man; do
  [ -d "$PAY/$_d" ] || fail "payload is missing $_d/"
done
for _f in bin/severance bin/work libexec/work-context_lib share/tools \
          man/man1/severance.1; do
  [ -e "$PAY/$_f" ] || fail "payload is missing $_f"
done
# COPIES, not links into the source. bin/severance is the one that matters
# most, and one file is enough to prove which mode the stage used.
[ -L "$PAY/bin/severance" ] && fail "the payload's severance is a symlink"
[ -x "$PAY/bin/severance" ] || fail "the payload's severance is not executable"

# BOTH commands, because an install that linked one of the two and reported
# success is the exact failure usher's conversion found in itself. `work` is
# the sole sudo entry point, so a missing link there is a boundary with no door.
for _c in severance work; do
  [ "$(readlink "$P1/bin/$_c")" = "$PAY/bin/$_c" ] \
    || fail "$_c does not link into the payload"
done
[ "$(readlink "$P1/share/man/man1/severance.1")" \
  = "$PAY/man/man1/severance.1" ] \
  || fail "the man page does not link into the payload"

# THE RETIRED ROOT IS NOT CREATED. ~/.local/libexec/severance was the
# PUBLISHED path for the reader, so its absence is the breaking half of this
# change and has to be asserted rather than assumed.
[ -e "$P1/libexec/severance" ] && fail "install recreated the retired libexec"

# --- nothing under the prefix resolves into the source -----------------------
# The law itself, asserted directly rather than inferred from the shape above.
for _l in "$P1/bin/severance" "$P1/bin/work" \
          "$P1/share/man/man1/severance.1" "$PAY"; do
  _rp=$(readlink -f "$_l")
  case $_rp in
    "$HERE"/*) fail "$_l resolves into the source tree ($_rp)" ;;
  esac
done

# --- install configures nothing else -----------------------------------------
# It used to write a git include and a consumer's hook file. Nobody installing
# a work/personal boundary expects it to edit their git config.
[ -e "$H/.gitconfig" ] && fail "install wrote the user's git config"
[ -e "$H/.config/valet-key" ] && fail "install wrote into a consumer's config"
hint=$(run "$P1" install 2>&1) || fail "install (rerun) errored"
case $hint in
  *"NOT wired by install"*) ;;
  *) fail "install did not report that integrations are unwired" ;;
esac

# --- idempotent, and the swap REPLACES rather than merges --------------------
# A copying install re-copies on every provision sweep, so running it twice
# must be exactly running it once. The canary proves the new tree was swapped
# in whole rather than copied over a half-deleted one.
echo canary > "$PAY/CANARY"
run "$P1" install >/dev/null 2>&1 || fail "install over a populated payload"
[ -e "$PAY/CANARY" ] && fail "the swap merged into the old payload"
for _c in severance work; do
  [ "$(readlink "$P1/bin/$_c")" = "$PAY/bin/$_c" ] \
    || fail "$_c link lost on re-install"
done

# --- a pre-conversion install is MIGRATED, not left beside the new one -------
# The state every box is in right now: five symlinks into the source, one of
# them the whole-dir share link that the payload must now occupy. Planted
# exactly as the old installer left it, in its own prefix.
mkdir -p "$P2/bin" "$P2/libexec" "$P2/share/man/man1"
ln -sfn "$HERE/bin/severance" "$P2/bin/severance"
ln -sfn "$HERE/bin/work" "$P2/bin/work"
ln -sfn "$HERE/libexec" "$P2/libexec/severance"
ln -sfn "$HERE/share" "$P2/share/severance"
ln -sfn "$HERE/man/man1/severance.1" "$P2/share/man/man1/severance.1"

run "$P2" install >/dev/null 2>&1 || fail "install over the old layout errored"
[ -d "$P2/share/severance" ] && [ ! -L "$P2/share/severance" ] \
  || fail "install did not replace the old share link with a payload"
# Reaching THROUGH the old link instead of replacing it would have written
# into the source tree, which is the gotcha this conversion exists to avoid.
[ -e "$HERE/share/bin" ] && fail "install wrote through the old link into src"
[ -e "$P2/libexec/severance" ] || [ -L "$P2/libexec/severance" ] \
  && fail "install left the retired libexec root in place"
for _c in severance work; do
  [ "$(readlink "$P2/bin/$_c")" = "$P2/share/severance/bin/$_c" ] \
    || fail "$_c still links into the source after install"
done

# --- uninstall removes the payload and both generations of link --------------
run "$P2" uninstall >/dev/null 2>&1 || fail "setup.sh uninstall errored"
[ -e "$P2/share/severance" ] || [ -L "$P2/share/severance" ] \
  && fail "uninstall left the payload behind"
for _c in severance work; do
  [ -e "$P2/bin/$_c" ] || [ -L "$P2/bin/$_c" ] \
    && fail "uninstall left the $_c link"
done
[ -L "$P2/share/man/man1/severance.1" ] && fail "uninstall left the man link"

# It must SAY what it kept, and the sealed tree is the part a user will not
# guess: the wall is kernel state that outlives the package entirely.
mkdir -p "$H/.config/severance"
run "$P3" install >/dev/null 2>&1 || fail "install before the kept-files check"
kept=$(run "$P3" uninstall 2>&1) || fail "uninstall (kept-files) errored"
case $kept in
  *KEPT*"SEALED WORK TREES"*) ;;
  *) fail "uninstall did not say the sealed trees survive it" ;;
esac
case $kept in
  *"$H/.config/severance"*) ;;
  *) fail "uninstall did not name the config root it kept" ;;
esac

# --- uninstall touches only links it placed ----------------------------------
# Somebody else's `work` on PATH, or a real file, must survive: this runs in
# ~/.local/bin, which is shared with every other package on the box.
run "$P4" install >/dev/null 2>&1 || fail "install before the foreign check"
rm -f "$P4/bin/work"; printf '#!/bin/sh\n' > "$P4/bin/work"
run "$P4" uninstall >/dev/null 2>&1 || fail "uninstall (foreign file) errored"
[ -f "$P4/bin/work" ] && [ ! -L "$P4/bin/work" ] \
  || fail "uninstall removed a real file it did not place"

# --- paths declares every root, and DERIVES each one -------------------------
# The contract verb: KIND<TAB>PATH, so a consumer acts per kind without
# parsing prose. Asserted against the scratch prefix, which is what proves the
# values are derived rather than written out by hand.
run "$P1" install >/dev/null 2>&1 || fail "install before the paths check"
p=$(run "$P1" paths) || fail "setup.sh paths errored"
for _w in "payload=$PAY" "bin=$P1/bin/severance" "bin=$P1/bin/work" \
          "man=$P1/share/man/man1/severance.1" \
          "config=$H/.config/severance" \
          "config=$H/.config/git/work-context.gen"; do
  printf '%s\n' "$p" | grep -qxF "${_w%%=*}$TAB${_w#*=}" \
    || fail "paths does not declare: $_w"
done
_rel=$(printf '%s\n' "$p" | while IFS="$TAB" read -r _k _v; do
  case $_v in /*) ;; *) printf '%s\n' "$_k $_v" ;; esac
done)
[ -z "$_rel" ] || fail "paths emitted a relative path: $_rel"

pass "payload + both command links + migration + uninstall + paths"
