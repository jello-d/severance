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

# Show the resolved settings for a profile (or the resolved default). A HUMAN
# report for debugging a record: read it, do not parse it.
#
# `--shell` (an eval-able dump of every WC_*) is RETIRED. It was advertised as
# a stable contract for external consumers and had none: every one of them
# reach severance through `current` and `guard`, which are one word and one
# exit code. A twelve-variable promise nobody made use of is not free -- it
# pins every internal name in the reader as public API, and calling it stable
# is a commitment. Exported internals are not an interface.
sev_show() {
  _prof=
  for _a in "$@"; do
    case "$_a" in
      --shell)
        echo "severance: 'show --shell' is retired." >&2
        echo "  Which enclave is this process in? -> severance current" >&2
        echo "  Is this process allowed here?     -> severance guard" >&2
        echo "  Debugging a record?               -> severance show" >&2
        return 2 ;;
      *) _prof=$_a ;;
    esac
  done
  wc_load "$_prof" || { echo "severance: no profile resolves" >&2; return 1; }
  printf 'profile=%s\n' "$WC_PROFILE"
  printf 'group=%s\n' "$WC_GROUP"
  printf 'dir=%s\n' "$WC_DIR"
  printf 'claude_config=%s\n' "$WC_CLAUDE_CONFIG"
  printf 'runner=%s\n' "$WC_RUNNER"
}

# Which enclave is this process (or PID) in? Prints the profile name, or
# nothing. This is a value, not a predicate, so a caller does
# `p=$(severance current)` and tests [ -n "$p" ]. The predicate form is that
# test; there is deliberately no second verb for it, so the two can never
# disagree.
#
# Exit codes distinguish the two ways of printing nothing:
#   0  answered. Empty output means "not in an enclave", which is not an error.
#   2  could NOT answer: the pid is malformed, or names no live process.
#
# That second case is why this is not unconditionally exit 0. A mangled pid
# that silently printed nothing would report a process which IS behind the
# boundary as personal, and a caller testing only [ -n "$p" ] would believe it.
# A false negative on a ZDR wall is the one direction this must never fail in,
# so an unanswerable question is loud. The no-argument form asks about a
# process that self-evidently exists, so it cannot hit the error path.
#
# A STABLE contract: one word on stdout, nothing on stderr on the normal path.
# mux consumes it directly as its context-command (a non-zero exit reads as
# `global` there, which is correct: mux must not name a context we could not
# determine).
sev_current() {   # [pid]
  [ "$#" -le 1 ] || { echo "usage: severance current [PID]" >&2; return 2; }
  case ${1:-} in
    '') ;;
    *[!0-9]*) echo "severance: current: not a pid: $1" >&2; return 2 ;;
  esac
  _rc=0; wc_current "${1:-}" || _rc=$?
  case $_rc in
    0) printf '%s\n' "$WC_CURRENT" ;;
    1) ;;                                 # outside every enclave: silent, ok
    *) echo "severance: current: no such process: $1" >&2; return 2 ;;
  esac
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
  # Reject a bad name HERE rather than scaffolding a record that only fails at
  # validate: the name is the enclave's published identity, so it has to be
  # legal everywhere it lands before anything is written.
  . "$LIBEXEC/validate.sh"
  _dns_label "$_name" || {
    echo "severance: '$_name' is not a valid profile name. Use a DNS" >&2
    echo "  label: a-z, 0-9 and hyphen, no leading or trailing hyphen," >&2
    echo "  63 max. It becomes the group name, a path component, and the" >&2
    echo "  token 'severance current' publishes." >&2
    return 2; }
  _sev_host_managed && { _sev_host_note init; return 1; }
  shift
  _dir=$(_sev_config_dir)/profiles
  mkdir -p "$_dir"
  _f=$_dir/$_name
  [ -e "$_f" ] && { echo "severance: profile exists: $_f" >&2; return 1; }
  {
    printf '# severance profile: %s\n' "$_name"
    printf 'work_dir=~/src/%s\n' "$_name"
    for _kv in "$@"; do printf '%s\n' "$_kv"; done
  } > "$_f"
  echo "severance: wrote $_f"
  # Validate the scaffold parses + is sane, then point at the next steps.
  # (validate.sh is already sourced above, for the name check.)
  _validate_record "$_name"
  echo "severance: edit it (work_dir), then:"
  echo "  severance seal        # provision the wall"
  echo "  severance runner      # provision the rootless-docker runner"
}
