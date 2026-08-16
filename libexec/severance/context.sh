# context.sh - the valet-key discovery seam: the work/personal ZDR resolve +
# guard, exposed as `severance context resolve|guard`. Sourced by bin/severance.
#
# valet-key reads its $VALET_KEY_CONFIG/context hook for this seam; the
# published hook is a thin shim that execs us, so valet-key and severance meet
# at one well-known path, no tackup in the loop -- each degrades to personal.
# The reader (sourced by common.sh) provides wc_account and the WC_* vars; the
# guard re-derives the group itself and never trusts the passed profile.
#
#   context resolve         -> the active account: the work GROUP (this process
#                              holds it, e.g. `manifest`) or `personal`. valet-
#                              key maps <group> -> ~/.claude-<group>, personal
#                              -> ~/.claude via its <base>-<profile> rule.
#   context guard [profile]  -> the ZDR REFUSE: inside work_dir WITHOUT the work
#                              group is the ONE forbidden state (the personal,
#                              non-ZDR account must never touch work files);
#                              exit 1 there, else 0. The kernel wall (work_dir
#                              root:<group> 2770 + ACL) is the real enforcement;
#                              this is the fail-loud reminder.
sev_context() {
  case "${1:-}" in
  resolve)
    wc_account 2>/dev/null || true
    [ "${WC_ACCOUNT_WORK:-0}" = 1 ] && echo "${WC_GROUP:-work}" || echo personal
    ;;
  guard)
    wc_account 2>/dev/null || true
    [ -n "${WC_DIR:-}" ] || exit 0            # no work context -> nothing to do
    _root=$(git rev-parse --show-toplevel 2>/dev/null || true)
    _here=$( ( cd "${_root:-$PWD}" 2>/dev/null && pwd -P ) || true )
    _wc=$( ( cd "$WC_DIR" 2>/dev/null && pwd -P ) || true )
    [ -n "$_here" ] && [ -n "$_wc" ] || exit 0
    case "$_here/" in "$_wc"/*) ;; *) exit 0 ;; esac   # outside work tree -> ok
    if [ "${WC_ACCOUNT_WORK:-0}" != 1 ]; then
      echo "severance: REFUSING -- inside the work tree ($WC_DIR) without" >&2
      echo "       the '$WC_GROUP' group. The personal (non-ZDR) account" >&2
      echo "       not touch work files. Run 'work' first." >&2
      exit 1
    fi
    exit 0
    ;;
  *) echo "usage: severance context resolve|guard [profile]" >&2; exit 2 ;;
  esac
}
