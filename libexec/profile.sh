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

# single-quote $1 so an `eval` of the output reproduces it exactly.
_sev_shq() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }

# Show the resolved settings for a profile (or the resolved default). With
# --shell, emit the WC_* as eval-able shell -- a STABLE read-only contract so an
# external consumer (mux, any tool) does `eval "$(severance show --shell)"`
# instead of sourcing severance's internal reader. Non-zero if none resolves.
sev_show() {
  _shell=0 _prof=
  for _a in "$@"; do
    case "$_a" in --shell) _shell=1 ;; *) _prof=$_a ;; esac
  done
  if ! wc_load "$_prof"; then
    [ "$_shell" = 1 ] && return 1
    echo "severance: no profile resolves" >&2; return 1
  fi
  if [ "$_shell" = 1 ]; then
    for _v in WC_PROFILE WC_LABEL WC_GROUP WC_DIR WC_CONFIG_ROOT \
              WC_CLAUDE_CONFIG WC_GIT_REMOTE_GLOB WC_RUNNER \
              WC_ENCLAVE_PERSONAL WC_SERVICE_USER WC_SERVICE_OVERLAY \
              WC_SERVICE_OVERLAY_WRITE; do
      eval "_val=\${$_v-}"
      printf '%s=%s\n' "$_v" "$(_sev_shq "$_val")"
    done
    return 0
  fi
  printf 'profile=%s\n' "$WC_PROFILE"
  printf 'label=%s\n' "$WC_LABEL"
  printf 'group=%s\n' "$WC_GROUP"
  printf 'dir=%s\n' "$WC_DIR"
  printf 'claude_config=%s\n' "$WC_CLAUDE_CONFIG"
  printf 'runner=%s\n' "$WC_RUNNER"
}

# Which enclave is this process (or PID) in? Prints the profile name, or
# nothing, and exits 0 EITHER WAY: this is a value, not a predicate, so a caller
# does `p=$(severance current)` and tests [ -n "$p" ] without also trapping a
# status. The predicate form is that test; there is deliberately no second verb
# for it, so the two can never disagree.
#
# A STABLE contract: one word on stdout, nothing on stderr on the normal path.
# mux consumes it directly as its context-command.
sev_current() {   # [pid]
  case ${1:-} in
    '') ;;
    *[!0-9]*) echo "severance: current: not a pid: $1" >&2; return 2 ;;
  esac
  [ "$#" -le 1 ] || { echo "usage: severance current [PID]" >&2; return 2; }
  wc_current "${1:-}" || return 0
  printf '%s\n' "$WC_CURRENT"
}

# Set (or clear) the default-profile marker.
sev_use() {
  _sev_host_managed && { _sev_host_note use; return 1; }
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

# Write a new profile record from a name + optional key=val pairs. work_dir is
# stubbed for editing when not supplied, so `wc_load` fails loud until it is
# filled in. work_group is NOT written: it derives from the profile name, and
# scaffolding it would re-introduce the second copy that can drift.
sev_init() {
  _name=${1:-}
  [ -n "$_name" ] || {
    echo "usage: severance init <name> [key=val ...]" >&2; return 2; }
  _sev_host_managed && { _sev_host_note init; return 1; }
  shift
  _dir=$(_sev_config_dir)/profiles
  mkdir -p "$_dir"
  _f=$_dir/$_name
  [ -e "$_f" ] && { echo "severance: profile exists: $_f" >&2; return 1; }
  {
    printf '# severance profile: %s\n' "$_name"
    printf 'label=%s\n' "$_name"
    printf 'work_dir=~/src/%s\n' "$_name"
    for _kv in "$@"; do printf '%s\n' "$_kv"; done
  } > "$_f"
  echo "severance: wrote $_f"
  # Validate the scaffold parses + is sane, then point at the next steps.
  . "$LIBEXEC/validate.sh"
  _validate_record "$_name"
  echo "severance: edit it (work_dir), then:"
  echo "  severance seal        # provision the wall"
  echo "  severance runner      # provision the rootless-docker runner"
}
