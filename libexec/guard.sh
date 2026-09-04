# guard.sh - the ZDR REFUSE, exposed as `severance guard [profile]`. Sourced by
# bin/severance.
#
# Inside work_dir WITHOUT the enclave group is the ONE forbidden state: the
# personal, non-ZDR account must never touch work files. Exit 1 there, else 0.
# The kernel wall (work_dir root:<group> 2770 + ACL) is the real enforcement;
# this is the fail-loud reminder, so a tool that would otherwise open a work
# file under the wrong identity says so instead of failing obscurely later.
#
# valet-key reads its $VALET_KEY_CONFIG/context hook for this; the published
# hook is a thin shim that execs us, so valet-key and severance meet at one
# well-known path with no host in the loop. The guard re-derives the enclave
# itself via wc_account and never trusts the passed profile: an argument is
# advisory, the group is the fact.
#
# This is the ACTION half of what `severance context` used to be. The identity
# half retired into `severance current`, which answers the same question with
# severance's own vocabulary instead of valet-key's.
sev_guard() {   # [profile]
  wc_account 2>/dev/null || true
  [ -n "${WC_DIR:-}" ] || return 0            # no enclave -> nothing to guard
  _root=$(git rev-parse --show-toplevel 2>/dev/null || true)
  _here=$( ( cd "${_root:-$PWD}" 2>/dev/null && pwd -P ) || true )
  _wc=$( ( cd "$WC_DIR" 2>/dev/null && pwd -P ) || true )
  [ -n "$_here" ] && [ -n "$_wc" ] || return 0
  case "$_here/" in "$_wc"/*) ;; *) return 0 ;; esac   # outside the tree -> ok
  [ "${WC_ACCOUNT_WORK:-0}" = 1 ] && return 0
  echo "severance: REFUSING -- inside the work tree ($WC_DIR) without" >&2
  echo "       the '$WC_GROUP' group. The personal (non-ZDR) account must" >&2
  echo "       not touch work files. Run 'work' first." >&2
  return 1
}
