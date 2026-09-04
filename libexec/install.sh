# install.sh - the STANDALONE installer (`severance install` / `uninstall`).
# Symlinks the package into ~/.local, and NOTHING else. It does not configure
# any other tool, and ships no adapter for one: severance's CLI is the
# interface, and wiring a consumer to it is the integrator's job. NEVER needed
# on a host-managed box, where a provisioner symlinks the package itself.
# Sourced by bin/severance for the install/uninstall verbs.

# The package (clone) root: bin/severance is $SEVERANCE_SELF, so root is two up.
_sev_pkg_root() {
  _d=${SEVERANCE_SELF%/*}          # .../bin
  printf '%s\n' "${_d%/*}"         # the package root
}
_sev_bin()    { echo "${SEVERANCE_BIN:-$HOME/.local/bin}"; }
_sev_libdir() { echo "${SEVERANCE_LIBEXEC:-$HOME/.local/libexec}"; }
_sev_shrdir() { echo "${SEVERANCE_SHARE_DIR:-$HOME/.local/share}"; }
_sev_cfg()    { echo "${XDG_CONFIG_HOME:-$HOME/.config}"; }

_sev_ln() { mkdir -p "$(dirname "$2")"; ln -sfn "$1" "$2"; echo "  link $2"; }

# What severance does NOT do: wire other tools up to itself. `severance install`
# links this package into ~/.local and stops there.
#
# It used to write an include.path into the user's global git config and drop a
# hook into a consumer's config dir. Nobody installing a work/personal boundary
# expects it to edit their git config, and special-casing git -- of all things
# -- is the tell that it was the wrong layer. Which boxes get which integration
# is the integrator's call: a provisioner places these, or a human does.
#
# It also ships no adapter for anyone. A copy of severance's own verbs living
# in this repo for a consumer's benefit could only go stale -- and did. The CLI
# is the contract; a one-line hook calling it belongs with whoever owns the
# box, and checking that hook belongs to whoever declared the seam.
_wiring_hint() {
  _cfg=$(_sev_cfg)
  echo "severance: integrations are NOT wired by install (by design)."
  echo "  Run 'severance doctor' to see what is missing. To wire by hand:"
  echo "    git identity split:"
  echo "      git config --global --add include.path \\"
  echo "        $_cfg/git/work-context.gen"
  echo "  A consumer that reads severance (a credential router, a session"
  echo "  manager) drops in its own one-line hook calling 'severance"
  echo "  current' or 'severance guard'. severance ships none: its CLI is"
  echo "  the interface, and a copy of it here could only go stale."
}

_path_hint() {
  case ":$PATH:" in
    *":$1:"*) : ;;
    *) echo "  NOTE: $1 is not on PATH -- add it (e.g. in ~/.profile)" ;;
  esac
}

sev_install() {
  _root=$(_sev_pkg_root)
  _bin=$(_sev_bin)
  echo "severance: installing from $_root"
  for _b in "$_root"/bin/*; do
    [ -e "$_b" ] && _sev_ln "$_b" "$_bin/$(basename "$_b")"
  done
  [ -d "$_root/libexec" ] \
    && _sev_ln "$_root/libexec" "$(_sev_libdir)/severance"
  [ -d "$_root/share" ] \
    && _sev_ln "$_root/share" "$(_sev_shrdir)/severance"
  for _m in "$_root"/man/man*/*.[0-9]; do
    [ -e "$_m" ] || continue
    _sec=$(basename "$(dirname "$_m")")
    _sev_ln "$_m" "$(_sev_shrdir)/man/$_sec/$(basename "$_m")"
  done
  _path_hint "$_bin"
  _wiring_hint
  echo "severance: done. Next: severance init <name>, then severance seal."
}

sev_uninstall() {
  _root=$(_sev_pkg_root)
  _bin=$(_sev_bin)
  for _b in "$_root"/bin/*; do
    _t=$_bin/$(basename "$_b")
    [ -L "$_t" ] && { rm -f "$_t"; echo "  rm $_t"; }
  done
  for _d in "$(_sev_libdir)/severance" "$(_sev_shrdir)/severance"; do
    [ -L "$_d" ] && { rm -f "$_d"; echo "  rm $_d"; }
  done
  echo "severance: removed the ~/.local links. Any integration wiring was"
  echo "  never ours to write and is left alone; remove it where you"
  echo "  configured it."
}
