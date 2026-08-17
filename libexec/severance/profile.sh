# profile.sh - profile record management + the default marker. Sourced by
# bin/severance for the list / show / use / init verbs. The reader (sourced by
# common.sh) provides WC_PROFILES_DIR, WC_DEFAULT_FILE, wc_profiles, wc_load.
#
# On a host-managed box the host may drive the active profile (publishing
# ~/.config/severance/default from its own source each run), so `severance use`
# is authoritative on a STANDALONE box; under such a host it is transient
# (re-published on the next provision).

_sev_config_dir() { echo "${XDG_CONFIG_HOME:-$HOME/.config}/severance"; }

# List provisioned profiles, marking the resolved default with a leading '*'.
sev_list() {
  _names=$(wc_profiles)
  [ -n "$_names" ] || { echo "severance: no profiles" >&2; return 0; }
  _def=
  [ -r "$WC_DEFAULT_FILE" ] &&
    IFS= read -r _def < "$WC_DEFAULT_FILE" 2>/dev/null
  for _p in $_names; do
    if [ "$_p" = "$_def" ]; then printf '* %s\n' "$_p"
    else printf '  %s\n' "$_p"; fi
  done
}

# Show the resolved WC_* for a profile (or the resolved default).
sev_show() {
  wc_load "${1:-}" || { echo "severance: no profile resolves" >&2; return 1; }
  printf 'profile=%s\n' "$WC_PROFILE"
  printf 'label=%s\n' "$WC_LABEL"
  printf 'group=%s\n' "$WC_GROUP"
  printf 'dir=%s\n' "$WC_DIR"
  printf 'claude_config=%s\n' "$WC_CLAUDE_CONFIG"
  printf 'runner=%s\n' "$WC_RUNNER"
}

# Set (or clear) the default-profile marker.
sev_use() {
  case "${1:-}" in
    --clear) rm -f "$WC_DEFAULT_FILE"; echo "severance: default cleared"
             return 0 ;;
    '') echo "usage: severance use <profile>|--clear" >&2; return 2 ;;
  esac
  [ -r "$WC_PROFILES_DIR/$1" ] || {
    echo "severance: no such profile: $1" >&2; return 1; }
  mkdir -p "$(dirname "$WC_DEFAULT_FILE")"
  printf '%s\n' "$1" > "$WC_DEFAULT_FILE"
  echo "severance: default profile = $1"
}

# Write a new profile record from a name + optional key=val pairs. The three
# required keys (work_group, work_dir, claude_config) are stubbed for editing
# when not supplied, so `wc_load` fails loud until they are filled in.
sev_init() {
  _name=${1:-}
  [ -n "$_name" ] || {
    echo "usage: severance init <name> [key=val ...]" >&2; return 2; }
  shift
  _dir=$(_sev_config_dir)/profiles
  mkdir -p "$_dir"
  _f=$_dir/$_name
  [ -e "$_f" ] && { echo "severance: profile exists: $_f" >&2; return 1; }
  {
    printf '# severance profile: %s\n' "$_name"
    printf 'label=%s\n' "$_name"
    printf 'work_group=%s\n' "$_name"
    printf 'work_dir=~/src/%s\n' "$_name"
    printf 'claude_config=~/.claude-%s\n' "$_name"
    for _kv in "$@"; do printf '%s\n' "$_kv"; done
  } > "$_f"
  echo "severance: wrote $_f"
  # Validate the scaffold parses + is sane, then point at the next steps.
  . "$LIBEXEC/validate.sh"
  _validate_record "$_name"
  echo "severance: edit it (work_group, work_dir, claude_config), then:"
  echo "  severance seal        # provision the wall"
  echo "  severance runner      # provision the rootless-docker runner"
}
