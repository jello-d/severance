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
#
# wc_load answers "what is profile X". The other question, "which enclave is
# this PROCESS in", is wc_current: it scans every profile and ranks the caller's
# group membership. Both live here so no command reimplements either.
# WC_GROUP defaults to the PROFILE NAME when the record omits `work_group`.
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

# Clear every WC_*, so no caller can read a stale profile's settings after a
# failed or empty resolve. wc_load calls it first; wc_current calls it when the
# scan finds nothing.
wc_reset() {
  WC_PROFILE= WC_LABEL= WC_GROUP= WC_DIR= WC_CLAUDE_CONFIG= WC_GIT_REMOTE_GLOB=
  WC_RUNNER= WC_ENCLAVE_PERSONAL= WC_SERVICE_USER= WC_SERVICE_OVERLAY=
  WC_SERVICE_OVERLAY_WRITE= WC_CONFIG_ROOT=
}

wc_load() {   # [name]
  wc_reset
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
  # work_group DERIVES from the profile name, so the enclave has ONE name
  # rather than the same name stored twice where the two can drift. The key
  # remains an override, because a profile name is a filename while a group
  # name is constrained ([a-z0-9_-]), so a legal profile name is not always a
  # legal group name. `severance validate` warns when the two differ.
  [ -n "$WC_GROUP" ] || WC_GROUP=$WC_PROFILE
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

# --- "which enclave is this process in?" -------------------------------------
# THE single answer to that question, for every caller in every package. It
# lives in the reader, not in a command, so `severance current`, wc_account and
# anything else are one implementation rather than several that can disagree.

# Rank a process's membership in $WC_GROUP: 0 = the group is PRIMARY, 1 =
# supplementary only, 2 = not a member, 3 = UNANSWERABLE (the pid's /proc entry
# cannot be read, so the process is gone or never existed). 3 is distinct from
# 2 on purpose: "I could not look" must never be reported as "not in an
# enclave". The distinction is what makes wc_current
# correct under NESTING: entering enclave A from inside enclave B leaves the pid
# holding BOTH groups, and `sudo -g` made the inner one primary, so a primary
# match is the enclave you are actually in and a supplementary one is merely an
# enclave you are still under.
#
# With no pid it speaks for THIS process through id(1). With a pid it must read
# /proc instead: id(1) can only speak for the caller. Same two-tier question
# either way -- Gid: is the primary, Groups: the supplementary set.
wc_group_rank() {   # [pid]
  if [ -z "${1:-}" ]; then
    [ "$(id -gn)" = "$WC_GROUP" ] && return 0
    case " $(id -Gn) " in *" $WC_GROUP "*) return 1 ;; esac
    return 2
  fi
  _wc_st=/proc/$1/status
  [ -r "$_wc_st" ] || return 3
  _wc_gid=$(getent group "$WC_GROUP" 2>/dev/null | cut -d: -f3)
  [ -n "$_wc_gid" ] || return 2
  [ "$(awk '/^Gid:/ { print $3; exit }' "$_wc_st")" = "$_wc_gid" ] && return 0
  case " $(awk '/^Groups:/ { $1 = ""; print; exit }' "$_wc_st") " in
    *" $_wc_gid "*) return 1 ;;
  esac
  return 2
}

# wc_current - which enclave is a process in? Sets WC_CURRENT to the profile
# name (empty when none) and returns:
#   0  in an enclave (WC_CURRENT set, WC_* LOADED for that profile)
#   1  not in one (WC_CURRENT empty, WC_* cleared, so a caller can never read a
#      stale profile's settings)
#   2  UNANSWERABLE: the pid does not exist, so there is nothing to rank
#
# 2 is not a pedantic distinction. A mangled or stale pid that silently ranked
# as "not in an enclave" would report a process that IS behind the boundary as
# personal -- a false negative on a ZDR wall, which is the one direction this
# must never fail in. Callers turn 2 into an error; only 1 means personal.
#
# It SCANS every provisioned profile rather than resolving one, because "which
# am I in" is not "am I in the default one": on a multitenant box a process in a
# non-default profile's group is still in an enclave, and _wc_resolve cannot
# pick it (with several profiles and no default marker it just fails).
#
# The GROUP is the ground truth, never $WORK_PROFILE: that var survives into a
# session as state, so trusting it would report what was asserted rather than
# what the kernel granted.
#
# Two passes, because a primary match outranks a supplementary one and the
# winner is not known until every profile has been ranked. A record that fails
# to parse is real drift: let wc_load say so on stderr and keep scanning, so one
# broken record can neither hide a good answer nor make this lie.
wc_current() {   # [pid]
  WC_CURRENT= _wc_supp=
  # Establish the pid EXISTS before ranking it. Without this the scan would
  # rank a dead pid as "not a member" of every profile and answer personal.
  if [ -n "${1:-}" ] && [ ! -d "/proc/$1" ]; then wc_reset; return 2; fi
  for _wc_p in $(wc_profiles); do
    wc_load "$_wc_p" || continue
    _wc_r=0
    if [ -n "${1:-}" ]; then wc_group_rank "$1" || _wc_r=$?
    else wc_group_rank || _wc_r=$?; fi
    # Rank 3 = the /proc entry went away mid-scan (the process exited between
    # the check above and now). Still unanswerable, so bail rather than let the
    # remaining profiles decide the answer is personal.
    [ "$_wc_r" = 3 ] && { wc_reset; return 2; }
    [ "$_wc_r" = 0 ] && { WC_CURRENT=$WC_PROFILE; return 0; }
    [ "$_wc_r" = 1 ] && [ -z "$_wc_supp" ] && _wc_supp=$WC_PROFILE
  done
  if [ -n "$_wc_supp" ] && wc_load "$_wc_supp"; then
    WC_CURRENT=$WC_PROFILE; return 0
  fi
  wc_reset
  return 1
}

# wc_account - resolve the active Claude account for THIS process, the single
# source of the work/personal account rule (the `claude` wrapper and claude-
# slots both call it, rather than each open-coding the same test). Sets, with no
# subshell so the WC_* that wc_current set stay visible to the caller:
#   WC_ACCOUNT_DIR  - config dir: the work claude_config when this process is in
#                     an enclave, else the personal base.
#   WC_ACCOUNT_WORK - 1 when the work account was chosen, else 0.
# Not in any enclave resolves to personal. Built on wc_current, so a process in
# a NON-DEFAULT profile's group gets that profile's account rather than the
# default profile's (or personal, which is what resolving one used to give).
wc_account() {
  WC_ACCOUNT_DIR=$WC_PERSONAL_DIR
  WC_ACCOUNT_WORK=0
  if wc_current 2>/dev/null; then
    WC_ACCOUNT_DIR=$WC_CLAUDE_CONFIG
    WC_ACCOUNT_WORK=1
  fi
}
