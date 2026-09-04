# guard.sh - the ZDR REFUSE, exposed as `severance guard [profile]`. Sourced by
# bin/severance.
#
# Inside an enclave's work_dir WITHOUT its group is the ONE forbidden state: the
# personal, non-ZDR account must never touch work files. Exit 1 there, else 0.
# The kernel wall (work_dir root:<group> 2770 + ACL) is the real enforcement;
# this is the fail-loud reminder, so a tool that would otherwise open a work
# file under the wrong identity says so instead of failing obscurely later. It
# matters most BEFORE `severance seal` has run, when the tree exists and the
# wall does not.
#
# valet-key reads its $VALET_KEY_CONFIG/context hook for this; the published
# hook is a thin shim that execs us, so valet-key and severance meet at one
# well-known path with no host in the loop. The guard re-derives everything
# itself and never trusts a passed profile: an argument is advisory, the
# filesystem and the group are the facts.
#
# This is the ACTION half of what `severance context` used to be. The identity
# half retired into `severance current`.

# Two DIFFERENT questions, and conflating them is how this went wrong once
# already:
#
#   1. WHICH enclave's tree am I standing in?  A PATH question. It has an
#      answer whether or not I hold any group, so it cannot be asked through
#      wc_current -- that reports the enclave whose group I HOLD, and clears
#      the WC_* when I hold none, which left this with nothing to compare.
#   2. Do I hold THAT enclave's group?  A membership question, asked second,
#      about the profile question 1 selected.
#
# Scanning every profile (rather than resolving one) also means a non-default
# enclave's tree is guarded too; resolving only the default left those
# unguarded.
sev_guard() {   # [profile] -- advisory, ignored
  # Where are we? NOT via `cd "$PWD"`: that needs traverse permission on every
  # ancestor, and a sealed work_dir (2770 root:<group>) denies exactly that to
  # the process being guarded. getcwd(2) still answers, so ask the shell
  # directly and only cd for a git root, which is a path we could reach.
  _root=$(git rev-parse --show-toplevel 2>/dev/null || true)
  if [ -n "$_root" ]; then
    _here=$( ( cd "$_root" 2>/dev/null && pwd -P ) || printf '%s' "$_root" )
  else
    _here=$(pwd -P 2>/dev/null || printf '%s' "$PWD")
  fi
  [ -n "$_here" ] || return 0
  for _p in $(wc_profiles); do
    wc_load "$_p" 2>/dev/null || continue
    # Match against BOTH spellings of work_dir, because each alone has a
    # false-negative and this must not have one:
    #
    #   the CONFIGURED path      -- needed when the tree cannot be traversed to
    #                               canonicalise it, which is precisely the
    #                               sealed state being guarded.
    #   the CANONICAL path       -- needed when work_dir contains a symlink and
    #                               the cwd resolved to the real path, so the
    #                               configured spelling never matches it.
    _wd=$( ( cd "$WC_DIR" 2>/dev/null && pwd -P ) || true )
    case "$_here/" in
      "$WC_DIR"/*) ;;
      *) [ -n "$_wd" ] || continue
         case "$_here/" in "$_wd"/*) ;; *) continue ;; esac ;;
    esac
    _r=0; wc_group_rank || _r=$?
    [ "$_r" -lt 2 ] && return 0            # in the tree AND in its group: ok
    echo "severance: REFUSING -- inside the '$WC_PROFILE' work tree" >&2
    echo "  ($WC_DIR) without the '$WC_GROUP' group. The personal" >&2
    echo "  (non-ZDR) account must not touch work files. Run 'work' first." >&2
    return 1
  done
  return 0                          # in no enclave's tree: nothing to guard
}
