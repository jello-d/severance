# doctor.sh - a whole-boundary health check in one report: installation, PATH,
# the profile records, the integrations (git includeIf, valet-key shim), and the
# live wall + runner. Higher-level than `check --seal|--runner` (which audit
# only the provisioned wall): doctor answers "is my boundary intact end to end,"
# the question a fresh install or a friend's first run wants. Non-zero on any
# failure. Sourced by bin/severance.
sev_doctor() {
  echo "== severance doctor =="

  # 1. installation + PATH
  if command -v severance >/dev/null 2>&1; then _ok "severance on PATH"
  else _bad "severance not on PATH (run 'severance install'?)"; fi
  if command -v work >/dev/null 2>&1; then _ok "work on PATH"
  else _bad "work not on PATH"; fi

  # 2. profiles + record validity
  _n=0; for _p in $(wc_profiles); do _n=$((_n + 1)); done
  if [ "$_n" -gt 0 ]; then _ok "$_n profile(s) provisioned"
  else _warn "no profiles provisioned (personal-only box)"; fi
  . "$LIBEXEC/validate.sh"
  for _p in $(wc_profiles); do _validate_record "$_p"; done

  # 3. the default marker resolves
  if [ -r "$WC_DEFAULT_FILE" ]; then
    IFS= read -r _d < "$WC_DEFAULT_FILE" 2>/dev/null || _d=
    if [ -n "$_d" ] && [ -r "$WC_PROFILES_DIR/$_d" ]; then
      _ok "default profile -> $_d"
    else _bad "default marker names a missing profile: '$_d'"; fi
  fi

  # 4. integrations: git includeIf + the valet-key shim
  if command -v git >/dev/null 2>&1 && git config --global --get-all \
       include.path 2>/dev/null | grep -q 'work-context.gen'; then
    _ok "git includeIf wired"
  else _warn "git includeIf not wired (a host, or 'severance install')"; fi
  if command -v valet-key >/dev/null 2>&1; then
    _vh=${XDG_CONFIG_HOME:-$HOME/.config}/valet-key/context
    if [ -e "$_vh" ] && grep -q 'severance context' "$_vh" 2>/dev/null; then
      _ok "valet-key context shim present"
    else _warn "valet-key present but its context shim is not wired"; fi
  fi

  # 5. the live wall + runner (delegate to the existing audits)
  . "$LIBEXEC/seal.sh";   sev_seal_check
  . "$LIBEXEC/runner.sh"; sev_runner_check

  return "$REPORT_RC"
}
