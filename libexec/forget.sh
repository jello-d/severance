# forget.sh - decommission a profile. Sourced by bin/severance.
#
# Default: tear down the RUNNER (reversible -- re-run `severance runner` to
# recreate it): stop its --user docker + relay, drop linger, delete the service
# account + its subid/subgid ranges, remove the tmpfiles + /run socket dir + the
# traverse ACL. The WALL and the profile RECORD are left intact.
#
# --purge also removes the record, clears the default marker if it named this
# profile, and regenerates the git fragment for the survivors -- but LEAVES the
# work tree SEALED (the data is yours; reclaim it deliberately) and the GROUP in
# place (removing it could orphan the still-sealed tree). The record removal is
# GUARDED: on a host-managed profiles dir (a symlink) it is left to the host.
sev_forget() {
  _profile= _purge=0
  for _a in "$@"; do
    case "$_a" in
      --purge) _purge=1 ;;
      --*) echo "severance: unknown flag: $_a" >&2; return 2 ;;
      *) _profile=$_a ;;
    esac
  done
  [ -n "$_profile" ] || {
    echo "usage: severance forget <profile> [--purge]" >&2; return 2; }
  wc_load "$_profile" || {
    echo "severance: no such profile: $_profile" >&2; return 1; }
  _r=$WC_RUNNER
  echo "severance: forgetting '$_profile' (runner '$_r')"
  sev_sudo_prime

  # Tear down the runner. Remove the traverse ACL BEFORE userdel (while the name
  # still resolves), then the --user services, then the account + id ranges.
  if id "$_r" >/dev/null 2>&1; then
    _ruid=$(id -u "$_r")
    setfacl -x "u:$_r" "$HOME" 2>/dev/null || true
    sudo -u "$_r" env "XDG_RUNTIME_DIR=/run/user/$_ruid" \
      systemctl --user disable --now docker.service work-docker-sock.service \
      2>/dev/null || true
    sudo loginctl disable-linger "$_r" 2>/dev/null || true
    sudo userdel -r "$_r" 2>/dev/null \
      || sudo userdel "$_r" 2>/dev/null || true
    sudo sed -i "/^$_r:/d" /etc/subuid /etc/subgid 2>/dev/null || true
    echo "  removed runner account $_r"
  else
    echo "  runner account $_r already absent"
  fi
  sudo rm -f "/etc/tmpfiles.d/$_r.conf"
  sudo rm -rf "/run/$_r"
  echo "  runner torn down (wall + record left intact)"

  [ "$_purge" = 1 ] || return 0

  # --purge: remove the record (unless host-managed), clear the default, and
  # regenerate the git fragment. The TREE stays sealed.
  if _sev_host_managed; then
    echo "  profiles dir is host-managed; remove the record at the host" >&2
  else
    rm -f "$WC_PROFILES_DIR/$_profile"
    echo "  removed profile record $_profile"
    if [ -r "$WC_DEFAULT_FILE" ]; then
      IFS= read -r _d < "$WC_DEFAULT_FILE" 2>/dev/null || _d=
      if [ "$_d" = "$_profile" ]; then
        rm -f "$WC_DEFAULT_FILE"; echo "  cleared the default marker"
      fi
    fi
    . "$LIBEXEC/seal.sh"
    if [ -f "$GIT_GEN" ]; then
      render_git_gen > "$GIT_GEN" 2>/dev/null || true
      echo "  regenerated the git fragment"
    fi
  fi
  echo "severance: '$_profile' purged. The work tree is left SEALED;"
  echo "  reclaim its data with: sudo chown -R $(id -un) $WC_DIR"
}
