# validate.sh - lint profile RECORDS, so a malformed or dangerous record is
# caught BEFORE it provisions a broken or over-broad wall. Sourced by
# bin/severance (the `validate` verb), and reused by check + doctor + init. Uses
# the report markers from common.sh, so it folds into REPORT_RC.

# Validate ONE record: parses, required keys present, and sane bounds (a valid
# group name; work_dir an absolute path that is NOT $HOME or / -- the wall must
# be a subdirectory, never the whole home or root).
# A profile name is the enclave's PUBLISHED IDENTITY: it is the group name, a
# path component, and the token `severance current` hands to consumers that use
# it as a socket name or namespace. So it is linted as a DNS label -- lowercase
# alphanumeric and hyphen, no leading or trailing hyphen, 63 max -- which is the
# intersection every one of those uses can accept. Underscore is deliberately
# NOT allowed: it is legal in a Unix group and illegal in a DNS label, so
# allowing it here would let a record provision cleanly and then be rejected
# downstream at use time.
_dns_label() {   # <name>
  case $1 in
    ''|*[!a-z0-9-]*|-*|*-) return 1 ;;
  esac
  [ "${#1}" -le 63 ]
}

_validate_record() {   # <profile>
  if _dns_label "$1"; then
    _ok "$1: profile name"
  else
    _bad "$1: profile name is not a DNS label (a-z, 0-9, hyphen; no leading" \
         "or trailing hyphen; 63 max)"
  fi
  if ! wc_load "$1" 2>/dev/null; then
    _bad "$1: record does not parse (unknown key or missing required field)"
    return
  fi
  # work_group derives from the profile name unless the record overrides it.
  # A divergence is legal (a group name may hold characters a DNS label may
  # not) but it means the enclave has two names, so surface it rather than
  # hide it.
  case "$WC_GROUP" in
    ''|*[!a-z0-9_-]*) _bad "$1: work_group '$WC_GROUP' is not a valid group" ;;
    "$1")             _ok  "$1: work_group '$WC_GROUP'" ;;
    *) _warn "$1: work_group '$WC_GROUP' differs from the profile name" ;;
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
