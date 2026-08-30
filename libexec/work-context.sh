# work-context.sh - shared reader for the active work PROFILE (enclave).
#
# A machine may provision N profiles (multitenant); each is one record at
# $WC_PROFILES_DIR/<name>. Source this, call wc_load [name], then use the WC_*
# vars. Parses (never sources) the record. Unknown keys fail loud; a leading ~/
# expands to $HOME/. wc_load returns non-zero (WC_* empty) when no profile
# resolves, so a box with none degrades to personal-only cleanly.
#
# Resolution -- wc_load [name]:
#   1. an explicit <name> argument        -> $WC_PROFILES_DIR/<name>
#   2. a legacy WC_CONFIG file override    (transitional; some modules set it)
#   3. $WORK_PROFILE                       -> $WC_PROFILES_DIR/$WORK_PROFILE
#   4. the DEFAULT marker (a profile name in ~/.config/severance/default,
#      written by `severance use`) -- the active enclave when several exist
#   5. the SOLE provisioned profile if exactly one exists; else fail loud
#      (multiple -> return 4 "specify one"; none -> return 1, personal-only).
#
# After a successful wc_load:
#   WC_PROFILE WC_LABEL WC_GROUP WC_DIR WC_CLAUDE_CONFIG WC_GIT_REMOTE_GLOB
#   WC_RUNNER WC_ENCLAVE_PERSONAL WC_SERVICE_USER WC_SERVICE_OVERLAY
#   WC_SERVICE_OVERLAY_WRITE WC_CONFIG_ROOT
# WC_RUNNER defaults to <label>-runner when the record omits `runner`.
# WC_CONFIG_ROOT is WORK_HOME/.config (= WC_DIR/.config); per-tool work dirs
# derive as $WC_CONFIG_ROOT/<tool>, and WC_CLAUDE_CONFIG derives from it unless
# the record sets claude_config. See docs/work-home.md.

WC_PROFILES_DIR=${WC_PROFILES_DIR:-$HOME/.config/severance/profiles}
WC_PERSONAL_DIR=${WC_PERSONAL_DIR:-$HOME/.claude}   # the fixed personal base
# The default-profile marker: a single profile name, written by `severance use`.
WC_DEFAULT_FILE=${WC_DEFAULT_FILE:-$HOME/.config/severance/default}

wc_expand() {   # expand a leading ~/ to $HOME/
  case "$1" in
    "~/"*) printf '%s\n' "$HOME/${1#\~/}" ;;
    *)     printf '%s\n' "$1" ;;
  esac
}

# List provisioned profile names (basenames), one per line.
wc_profiles() {
  [ -d "$WC_PROFILES_DIR" ] || return 0
  for _f in "$WC_PROFILES_DIR"/*; do
    [ -f "$_f" ] && printf '%s\n' "${_f##*/}"
  done
}

# Resolve the record path for wc_load: echoes it, or returns non-zero.
_wc_resolve() {   # [name]
  if [ -n "$1" ]; then
    [ -r "$WC_PROFILES_DIR/$1" ] && {
      printf '%s\n' "$WC_PROFILES_DIR/$1"; return 0; }
    echo "work-context: no such profile: $1" >&2; return 1
  fi
  if [ -n "${WC_CONFIG:-}" ] && [ -r "$WC_CONFIG" ]; then
    printf '%s\n' "$WC_CONFIG"; return 0
  fi
  if [ -n "${WORK_PROFILE:-}" ]; then
    [ -r "$WC_PROFILES_DIR/$WORK_PROFILE" ] && {
      printf '%s\n' "$WC_PROFILES_DIR/$WORK_PROFILE"; return 0; }
    echo "work-context: no such profile: $WORK_PROFILE" >&2; return 1
  fi
  # The default marker names the active profile when several are provisioned
  # (a no-op with one, which the sole-profile rule already resolves).
  if [ -r "$WC_DEFAULT_FILE" ]; then
    IFS= read -r _wc_def < "$WC_DEFAULT_FILE" 2>/dev/null || _wc_def=
    _wc_def=${_wc_def%"${_wc_def##*[![:space:]]}"}   # strip trailing space
    if [ -n "$_wc_def" ] && [ -r "$WC_PROFILES_DIR/$_wc_def" ]; then
      printf '%s\n' "$WC_PROFILES_DIR/$_wc_def"; return 0
    fi
  fi
  _wc_names=$(wc_profiles)
  _wc_n=0
  for _x in $_wc_names; do _wc_n=$((_wc_n + 1)); done
  case "$_wc_n" in
    0) return 1 ;;
    1) printf '%s\n' "$WC_PROFILES_DIR/$_wc_names"; return 0 ;;
    *) _wc_list=$(echo $_wc_names | tr '\n' ' ')
       echo "work-context: multiple profiles ($_wc_list); specify one" >&2
       return 4 ;;
  esac
}

wc_load() {   # [name]
  WC_PROFILE= WC_LABEL= WC_GROUP= WC_DIR= WC_CLAUDE_CONFIG= WC_GIT_REMOTE_GLOB=
  WC_RUNNER= WC_ENCLAVE_PERSONAL= WC_SERVICE_USER= WC_SERVICE_OVERLAY=
  WC_SERVICE_OVERLAY_WRITE= WC_CONFIG_ROOT=
  _cfg=$(_wc_resolve "${1:-}") || return $?
  WC_PROFILE=${_cfg##*/}
  while IFS='=' read -r k v; do
    v=${v%"${v##*[![:space:]]}"}          # strip trailing whitespace
    case "$k" in
      ''|\#*) ;;
      label)           WC_LABEL=$v ;;
      work_group)      WC_GROUP=$v ;;
      work_dir)        WC_DIR=$(wc_expand "$v") ;;
      claude_config)   WC_CLAUDE_CONFIG=$(wc_expand "$v") ;;
      git_remote_glob)  WC_GIT_REMOTE_GLOB=$v ;;
      runner)           WC_RUNNER=$v ;;
      enclave_personal) WC_ENCLAVE_PERSONAL=$v ;;
      service_user)     WC_SERVICE_USER=$v ;;
      service_overlay)  WC_SERVICE_OVERLAY=$v ;;
      service_overlay_write) WC_SERVICE_OVERLAY_WRITE=$v ;;
      *) echo "work-context: unknown key: $k ($_cfg)" >&2; return 2 ;;
    esac
  done < "$_cfg"
  [ -n "$WC_GROUP" ] || {
    echo "work-context: missing work_group ($_cfg)" >&2; return 3; }
  [ -n "$WC_DIR" ] || {
    echo "work-context: missing work_dir ($_cfg)" >&2; return 3; }
  # The per-enclave config root is WORK_HOME/.config (WORK_HOME = work_dir): all
  # work credential stores live under it, behind the work_dir gate, so ONE seal
  # protects them. Every per-tool dir derives as $WC_CONFIG_ROOT/<tool>;
  # claude_config derives too unless overridden. See docs/work-home.md.
  WC_CONFIG_ROOT=$WC_DIR/.config
  [ -n "$WC_CLAUDE_CONFIG" ] || WC_CLAUDE_CONFIG=$WC_CONFIG_ROOT/claude
  [ -n "$WC_RUNNER" ] || WC_RUNNER=${WC_LABEL:-$WC_PROFILE}-runner
  return 0
}

# wc_account - resolve the active Claude account for THIS process, the single
# source of the work/personal account rule (the `claude` wrapper and claude-
# slots both call it, rather than each open-coding the same test). Sets, with no
# subshell so the WC_* that wc_load set stay visible to the caller:
#   WC_ACCOUNT_DIR  - config dir: the work claude_config when this process holds
#                     the work group, else the personal base.
#   WC_ACCOUNT_WORK - 1 when the work account was chosen, else 0.
# No profile resolved, or not in the group, resolves to personal.
wc_account() {
  WC_ACCOUNT_DIR=$WC_PERSONAL_DIR
  WC_ACCOUNT_WORK=0
  if wc_load 2>/dev/null; then
    case " $(id -Gn) " in
      *" $WC_GROUP "*) WC_ACCOUNT_DIR=$WC_CLAUDE_CONFIG; WC_ACCOUNT_WORK=1 ;;
    esac
  fi
}
