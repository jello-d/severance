# validate.sh - lint profile RECORDS, so a malformed or dangerous record is
# caught BEFORE it provisions a broken or over-broad wall. Sourced by
# bin/severance (the `validate` verb), and reused by check + doctor + init. Uses
# the report markers from common.sh, so it folds into REPORT_RC.

# Validate ONE record: parses, required keys present, and sane bounds (a valid
# group name; work_dir an absolute path that is NOT $HOME or / -- the wall must
# be a subdirectory, never the whole home or root).
_validate_record() {   # <profile>
  if ! wc_load "$1" 2>/dev/null; then
    _bad "$1: record does not parse (unknown key or missing required field)"
    return
  fi
  case "$WC_GROUP" in
    ''|*[!a-z0-9_-]*) _bad "$1: work_group '$WC_GROUP' is not a valid group" ;;
    *)               _ok  "$1: work_group '$WC_GROUP'" ;;
  esac
  case "$WC_DIR" in
    "$HOME"|"$HOME"/|/|'') _bad "$1: work_dir '$WC_DIR' too broad" ;;
    /*)                    _ok  "$1: work_dir $WC_DIR" ;;
    *)                     _bad "$1: work_dir '$WC_DIR' not an absolute path" ;;
  esac
  [ -n "$WC_CLAUDE_CONFIG" ] \
    && _ok "$1: claude_config $WC_CLAUDE_CONFIG"
}

sev_validate() {   # [profile]
  echo "== severance validate (profile records) =="
  if [ -n "${1:-}" ]; then
    _validate_record "$1"
  else
    _any=0
    for _p in $(wc_profiles); do _validate_record "$_p"; _any=1; done
    [ "$_any" = 1 ] || _ok "no profiles to validate"
  fi
  return "$REPORT_RC"
}
