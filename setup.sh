#!/bin/sh
# setup.sh - install / uninstall / audit the severance package in a prefix. The
# SINGLE entry point a consumer or a provisioning layer uses, and the ONLY
# implementation of the install: the `severance install` verb delegates here.
#
#   ./setup.sh install     place the payload, link bin + man, retire the old
#   ./setup.sh uninstall   remove the links, then the payload
#   ./setup.sh check       audit the install, then `severance check`
#   ./setup.sh paths       every root this package owns (KIND<TAB>PATH)
#   ./setup.sh test        run the in-repo test suite (test/run)
#   ./setup.sh version     the packaged version
#
# POSIX sh, non-privileged. PREFIX (default ~/.local) and the XDG_* vars
# override every destination, so a test drives it against a scratch dir.
#
# THE INSTALL PLACES A COPY AND NEVER LINKS BACK INTO THE SOURCE (the fleet's
# place-not-link law, 2026-10-01; shared-notes/_install-placement.md). It used
# to leave five ~/.local symlinks pointing into the source tree, and on a
# provisioned box that source is the `pkg` clone under ~/.cache/tackup/pkgs,
# which is re-cloned on every sweep and wiped on demand. So all five were
# dangling links waiting for a cache wipe, and for THIS package that is not a
# cosmetic failure: `work` is the sole sudo entry point, `severance guard` is
# what a consumer calls in order to be REFUSED, and the reader every tackup
# module sources was reached through ~/.local/libexec/severance. A guard that
# cannot be executed does not refuse anything.
#
# WHY bin, lib, share AND man ALL LIVE INSIDE THE ONE PAYLOAD:
# bin/severance resolves its own real path and reads ../lib and ../share as
# SIBLINGS, which is the one mechanism that makes a checkout, an installed
# payload and a relocated copy all resolve the same way. Splitting them would
# break that invariant, so the nested <payload>/share is kept deliberately.
set -eu

PKG=severance
_root=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

PREFIX=${PREFIX:-$HOME/.local}
_bin=${XDG_BIN_HOME:-$PREFIX/bin}
_shr=${XDG_DATA_HOME:-$PREFIX/share}
_man=$_shr/man
_pay=$_shr/$PKG
_cfg=${XDG_CONFIG_HOME:-$HOME/.config}
# THE RETIRED ROOT, named once so install, uninstall and check all act on the
# same spelling instead of each writing it out and drifting.
_oldlib=$PREFIX/libexec/$PKG
RC=0

# Marker contract: the same plain [OK]/[FAIL]/[WARN] strings lib/common_lib
# emits, so a host's check aggregator sees one vocabulary from this package.
# Restated here rather than sourced, because setup.sh is standalone on purpose:
# it is the one entry point a provisioner calls, and a missing lib must never
# be what stops an install.
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  _e=$(printf '\033')
  _G="$_e[1;32m"; _R="$_e[1;31m"; _Y="$_e[1;33m"; _O="$_e[0m"
else _G=; _R=; _Y=; _O=; fi
ok()   { printf '  %s[OK]%s   %s\n' "$_G" "$_O" "$1"; }
bad()  { printf '  %s[FAIL]%s %s\n' "$_R" "$_O" "$1"; RC=1; }
warn() { printf '  %s[WARN]%s %s\n' "$_Y" "$_O" "$1"; }

_ln()   { mkdir -p "$(dirname "$2")"; ln -sfn "$1" "$2"; }
# Only ever removes a link we recognise, so an unrelated file at that path, or
# somebody else's link, is left exactly alone.
_rmln() { if [ "$(readlink "$2" 2>/dev/null)" = "$1" ]; then rm -f "$2"; fi; }

# The shipped commands and man pages, discovered rather than listed, so adding
# one to the repo needs no edit here. Bare names by this tree's naming rule (a
# command's name is what you type), so splitting the output on whitespace is
# safe and keeps the callers out of a pipeline subshell, where a `bad` would
# set RC in a child and lose it.
_cmds() {
  for _c in "$_root"/bin/*; do
    if [ -f "$_c" ]; then printf '%s\n' "${_c##*/}"; fi
  done
}
# Payload-RELATIVE paths (man/man1/severance.1), which is both where the page
# lands inside the payload and, with the leading man/ stripped, where it lands
# under $_man.
_man_pages() {
  for _m in "$_root"/man/man*/*.[0-9]; do
    if [ -e "$_m" ]; then printf '%s\n' "${_m#"$_root"/}"; fi
  done
}

# _payload_stage: build the new payload beside the live one and swap it in.
#
# STAGED AND SWAPPED, never emptied in place. severance is not a long-running
# daemon, but `severance guard` and `severance current` are called from other
# tools' hooks at arbitrary moments, and emptying the payload first would make
# the guard UNRUNNABLE for the length of a copy. A hook that cannot run is a
# hook that does not refuse, so the window matters more here than the few
# milliseconds it lasts. Two renames is as close to atomic as a directory gets.
_payload_stage() {
  _ps_new=$_pay.new
  _ps_old=$_pay.old
  # Expanded and CHECKED before anything is removed, per the standing rule that
  # `rm -rf` never runs against an unexamined value: absolute, nested, and
  # ending in this package's own name, so no empty or surprising PREFIX can
  # aim the delete below at something else.
  case $_pay in
  /*/"$PKG") ;;
  *) bad "refusing to stage a payload at '$_pay'"; return 1 ;;
  esac
  rm -rf -- "$_ps_new" "$_ps_old"
  mkdir -p "$_ps_new" || { bad "could not create $_ps_new"; return 1; }
  for _d in bin lib share man; do
    if [ -d "$_root/$_d" ]; then
      cp -R "$_root/$_d" "$_ps_new/" || { bad "could not copy $_d"; return 1; }
    fi
  done
  # A PARTIAL PAYLOAD IS WORSE THAN NO PAYLOAD, because the commands still
  # install and still run: bin/severance self-locates ../lib, so a copy
  # missing the reader produces a severance that cannot answer and a `work`
  # that cannot find its profiles, at a path that looks installed. Checked
  # before the swap, so a failed copy leaves the live payload untouched.
  for _r in bin/severance bin/work lib/work-context_lib share/tools; do
    if [ ! -e "$_ps_new/$_r" ]; then
      bad "staged payload is missing $_r"
      rm -rf -- "$_ps_new"
      return 1
    fi
  done
  if [ -e "$_pay" ] || [ -L "$_pay" ]; then
    # `mv` on a SYMLINK moves the link, not its target, which is what retires
    # the pre-conversion `$_shr/$PKG -> <source>/share` without ever reaching
    # through it into the source tree.
    mv -- "$_pay" "$_ps_old" || { bad "could not move the old payload"
      return 1; }
  fi
  mv -- "$_ps_new" "$_pay" || {
    bad "could not swap in the new payload"
    if [ -e "$_ps_old" ] || [ -L "$_ps_old" ]; then mv -- "$_ps_old" "$_pay"; fi
    return 1; }
  rm -rf -- "$_ps_old"
}

# _retire_old_layout: a LAYOUT switch removes the layout it replaces. A
# surviving ~/.local/libexec/severance is the two-copies hazard in another
# dress: it is where every integrator was told to find the reader, so leaving
# it means half the fleet keeps sourcing a copy that no longer moves.
_retire_old_layout() {
  if [ ! -e "$_oldlib" ] && [ ! -L "$_oldlib" ]; then return 0; fi
  case $_oldlib in
  /*/libexec/"$PKG") ;;
  *) warn "not retiring '$_oldlib': unexpected shape"; return 0 ;;
  esac
  rm -rf -- "$_oldlib"
  rmdir "$PREFIX/libexec" 2>/dev/null || :
  echo "$PKG: retired the old layout at $_oldlib"
}

_path_hint() {
  case ":$PATH:" in
  *":$_bin:"*) : ;;
  *) echo "$PKG: NOTE $_bin is not on PATH; add it (e.g. in ~/.profile)" ;;
  esac
}

# What severance does NOT do: wire other tools up to itself. install places this
# package and stops there.
#
# It used to write an include.path into the user's global git config and drop a
# hook into a consumer's config dir. Nobody installing a work/personal boundary
# expects it to edit their git config, and special-casing git, of all things, is
# the tell that it was the wrong layer. Which boxes get which integration is the
# integrator's call: a provisioner places these, or a human does.
#
# It also ships no adapter for anyone. A copy of severance's own verbs living in
# this repo for a consumer's benefit could only go stale, and did. The CLI is
# the contract; a one-line hook calling it belongs with whoever owns the box,
# and checking that hook belongs to whoever declared the seam.
_wiring_hint() {
  echo "$PKG: integrations are NOT wired by install (by design)."
  echo "  Run 'severance doctor' to see what is missing. To wire by hand:"
  echo "    git identity split:"
  echo "      git config --global --add include.path \\"
  echo "        $_cfg/git/work-context.gen"
  echo "  A consumer that reads severance (a credential router, a session"
  echo "  manager) drops in its own one-line hook calling 'severance"
  echo "  current' or 'severance guard'. severance ships none: its CLI is"
  echo "  the interface, and a copy of it here could only go stale."
}

do_install() {
  mkdir -p "$_bin" "$_shr"
  _payload_stage || return 1
  for _c in $(_cmds); do _ln "$_pay/bin/$_c" "$_bin/$_c"; done
  for _m in $(_man_pages); do _ln "$_pay/$_m" "$_man/${_m#man/}"; done
  _retire_old_layout
  echo "$PKG: installed to $_pay (+ bin and man links under $PREFIX)"
  _path_hint
  _wiring_hint
  echo "$PKG: next: severance init <name>, then severance seal."
}

do_uninstall() {
  for _c in $(_cmds); do
    _rmln "$_pay/bin/$_c" "$_bin/$_c"
    _rmln "$_root/bin/$_c" "$_bin/$_c"       # a pre-conversion install's target
  done
  for _m in $(_man_pages); do
    _rmln "$_pay/$_m" "$_man/${_m#man/}"
    _rmln "$_root/$_m" "$_man/${_m#man/}"
  done
  _retire_old_layout
  if [ -L "$_pay" ]; then
    rm -f -- "$_pay"                 # the pre-conversion share link, not a tree
  elif [ -d "$_pay" ]; then
    # The literal is PRINTED before it is removed, so the exact command that
    # ran is in the output, and the shape is checked first. Same guard as the
    # stage above, for the same reason.
    case $_pay in
    /*/"$PKG") echo "$PKG: removing the payload $_pay"; rm -rf -- "$_pay" ;;
    *) bad "refusing to remove a payload at '$_pay'" ;;
    esac
  fi
  echo "$PKG: removed the links under $PREFIX."
  # A REMOVAL THAT KEPT THINGS MUST SAY SO, or "uninstalled" reads as "gone"
  # while a profile record and a generated git fragment sit on disk. These are
  # not the package's to delete: a record names a sealed tree that still
  # exists, and the wall itself is kernel state no uninstall can undo.
  echo "$PKG: KEPT what is yours, including the SEALED WORK TREES. Delete"
  echo "  these by hand if you mean to, and note the wall outlives the"
  echo "  package: a 2770 root:<group> tree stays sealed until root changes"
  echo "  it ('severance forget <profile> --purge' before uninstalling is"
  echo "  the orderly route)."
  do_paths | while IFS="$(printf '\t')" read -r _k _v; do
    case $_k in
    config) if [ -e "$_v" ]; then echo "$PKG:   $_k  $_v"; fi ;;
    esac
  done
}

do_check() {
  echo "== $PKG (package install) =="
  # THE PAYLOAD IS A TREE, NOT A LINK, which is the whole conversion: a symlink
  # here means the install still resolves into a source checkout and dies the
  # moment that checkout moves or is re-cloned.
  if [ -L "$_pay" ]; then
    bad "$_pay is a SYMLINK: this install still depends on a source tree"
  elif [ -d "$_pay" ] && [ -f "$_pay/bin/$PKG" ] && [ -d "$_pay/lib" ] \
      && [ -d "$_pay/share" ]; then
    ok "payload is a self-contained tree ($_pay)"
  else
    bad "no payload tree at $_pay: reinstall severance"
  fi
  # EVERY command, not just the headline one: `work` is the sole sudo entry
  # point, and an install that linked one of the two and reported success is
  # exactly the failure usher's conversion found in itself.
  for _c in $(_cmds); do
    if [ "$(readlink "$_bin/$_c" 2>/dev/null)" = "$_pay/bin/$_c" ]; then
      ok "bin/$_c links into the payload"
    else
      bad "$_bin/$_c does not link to $_pay/bin/$_c"
    fi
  done
  for _m in $(_man_pages); do
    if [ "$(readlink "$_man/${_m#man/}" 2>/dev/null)" = "$_pay/$_m" ]; then
      ok "${_m##*/} links into the payload"
    else
      bad "$_man/${_m#man/} does not link to $_pay/$_m"
    fi
  done
  # A RETIRED LAYOUT PATH THAT SURVIVED. A FAIL rather than a WARN, unlike
  # mux's equivalent, because this one is a PUBLISHED path: integrators were
  # told to source ~/.local/libexec/severance/work-context_lib, so a surviving
  # copy is not merely stale, it is a second reader that other tools may still
  # be reading while this payload moves on without it.
  if [ -e "$_oldlib" ] || [ -L "$_oldlib" ]; then
    bad "retired layout path survives: $_oldlib (re-run install to drop it)"
  else
    ok "no retired layout path"
  fi
  "$_root/bin/$PKG" check || RC=1      # the live boundary, severance's own verb
}

# --- paths: the ONE declaration of every root this package owns --------------
# Part of the package contract (the fleet's install-placement rule): one
# declaration feeds the four things that would each otherwise guess, which is
# the argument for a verb over prose: the install audit, a stale-path sweep,
# uninstall saying what it kept, and plain discoverability.
#
# KIND<TAB>PATH per line, two fields, so a consumer can act per KIND (remove a
# payload, never a config) without parsing sentences. Tab-separated because a
# path may contain a space.
#
# EVERY VALUE IS DERIVED from the same expressions the installer and severance
# itself resolve, so a root cannot be renamed in one place and still reported
# from here. A hand-written list would reintroduce exactly that drift.
#
# NO state, cache or runtime root: severance keeps none. Its durable state is
# the KERNEL's (a group, a sealed tree's mode and ACLs) plus the per-profile
# records below, which is the whole point of the design and is why there is
# nothing here to clean up but config.
do_paths() {
  for _c in $(_cmds); do printf 'bin\t%s\n' "$_bin/$_c"; done
  printf 'payload\t%s\n' "$_pay"
  for _m in $(_man_pages); do printf 'man\t%s\n' "$_man/${_m#man/}"; done
  printf 'config\t%s\n' "$_cfg/$PKG"
  printf 'config\t%s\n' "$_cfg/git/work-context.gen"
}

_U="usage: setup.sh [install|uninstall|check|paths|test|version]"
case "${1:-help}" in
  install)   do_install ;;
  uninstall) do_uninstall ;;
  check)     do_check; exit "$RC" ;;
  paths)     do_paths ;;
  test)      exec sh "$_root/test/run" ;;
  version)   _v=$(git -C "$_root" describe --tags --always 2>/dev/null || true)
             echo "${_v:-$PKG (unversioned)}" ;;
  -h|--help|help) echo "$_U" ;;
  *) echo "setup.sh: unknown command '${1:-}'" >&2; echo "$_U" >&2; exit 2 ;;
esac
