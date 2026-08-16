# check.sh - the marker-contract audit. `severance check [--seal|--runner]`
# (bare = both) runs the ported audits and returns non-zero on drift, emitting
# plain [OK]/[FAIL] lines that tackup's report.sh paint() recolours unchanged.
sev_check() {
  _do_seal=0 _do_runner=0
  case "${1:-}" in
    --seal)   _do_seal=1 ;;
    --runner) _do_runner=1 ;;
    ''|both)  _do_seal=1; _do_runner=1 ;;
    *) echo "severance: usage: severance check [--seal|--runner]" >&2; exit 2 ;;
  esac
  if [ "$_do_seal" = 1 ]; then . "$LIBEXEC/seal.sh"; sev_seal_check; fi
  if [ "$_do_runner" = 1 ]; then . "$LIBEXEC/runner.sh"; sev_runner_check; fi
  return "$REPORT_RC"
}
