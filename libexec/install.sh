# install.sh - the STANDALONE installer (`severance install` / `uninstall`).
# Symlinks the package into ~/.local and wires the host integrations a
# provisioner (a host) would otherwise provide: the git includeIf and the
# valet-key context shim. NEVER needed on a host-managed box -- a host already
# symlinks the package and publishes the hooks -- so every host-owned step is
# GUARDED (skips a managed symlink) and a stray run there is a safe no-op.
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

# Ensure git includes the generated fragment. SKIP when ~/.config/git/config is
# a managed symlink (a host owns the include) -- never write into its repo.
_wire_git_include() {
  command -v git >/dev/null 2>&1 || return 0
  _gc=$(_sev_cfg)/git/config
  _gen=$(_sev_cfg)/git/work-context.gen
  if [ -L "$_gc" ]; then
    echo "  git config is host-managed; leaving the include to the host"
    return 0
  fi
  if git config --global --get-all include.path 2>/dev/null \
     | grep -qxF "$_gen"; then
    echo "  git include present"
  else
    git config --global --add include.path "$_gen"
    echo "  git include added -> $_gen"
  fi
}

# Publish the valet-key context shim so valet-key discovers our ZDR seam. Only
# when valet-key is installed, and never over a host-managed (symlink) hook.
_wire_valet_key() {
  command -v valet-key >/dev/null 2>&1 || {
    echo "  valet-key absent; skipping its context hook"; return 0; }
  _hook=$(_sev_cfg)/valet-key/context
  if [ -L "$_hook" ]; then
    echo "  valet-key hook is host-managed; leaving it"; return 0; fi
  if [ -f "$_hook" ] && grep -q 'severance context' "$_hook" 2>/dev/null; then
    echo "  valet-key hook present"; return 0; fi
  mkdir -p "$(dirname "$_hook")"
  cat > "$_hook" <<'EOF'
#!/bin/sh
# valet-key context hook -> severance (published by `severance install`).
if command -v severance >/dev/null 2>&1; then exec severance context "$@"; fi
case "${1:-}" in resolve) echo personal ;; esac
EOF
  chmod +x "$_hook"
  echo "  valet-key hook published -> $_hook"
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
  _wire_git_include
  _wire_valet_key
  _path_hint "$_bin"
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
  echo "severance: removed the ~/.local links. The git include and valet-key"
  echo "  hook (if any) are left in place; remove them by hand if desired."
}
