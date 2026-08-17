# check.sh - the marker-contract audit. `severance check [--seal|--runner]`
# (bare = both) runs the ported audits and returns non-zero on drift, emitting
# plain [OK]/[FAIL] lines that a host's marker painter recolours unchanged.
sev_check() {
  _do_seal=0 _do_runner=0 _do_val=0
  case "${1:-}" in
    --seal)   _do_seal=1 ;;
    --runner) _do_runner=1 ;;
    ''|both)  _do_seal=1; _do_runner=1; _do_val=1 ;;
    *) echo "severance: usage: severance check [--seal|--runner]" >&2; exit 2 ;;
  esac
  # A bare check also VALIDATES the records (a malformed profile before the
  # wall); the focused --seal/--runner forms stay narrow (delegators call them).
  if [ "$_do_val" = 1 ]; then . "$LIBEXEC/validate.sh"; sev_validate; fi
  if [ "$_do_seal" = 1 ]; then . "$LIBEXEC/seal.sh"; sev_seal_check; fi
  if [ "$_do_runner" = 1 ]; then . "$LIBEXEC/runner.sh"; sev_runner_check; fi
  return "$REPORT_RC"
}
