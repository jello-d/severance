# doctor.sh - a whole-boundary health check in one report: installation, PATH,
# the profile records, the integrations (git includeIf, valet-key shim), and the
# live wall + runner. Higher-level than `check --seal|--runner` (which audit
# only the provisioned wall): doctor answers "is my boundary intact end to end,"
# the question a fresh install or a friend's first run wants. Non-zero on any
# failure. Sourced by bin/severance.

# Audit the valet-key shim for CORRECTNESS, not mere presence. A hook pinned to
# a verb severance has retired is worse than a missing one: valet-key's guard
# seam reads a failing hook as "warn, then proceed", so the ZDR refuse silently
# becomes a no-op while everything still looks wired. Presence was the old test,
# and it reported exactly that broken state as [OK].
#
# Its own function so the test suite can drive the REAL logic rather than a
# copy of it -- the drift this whole audit exists to catch is the same drift a
# reimplemented test would hide.
_doctor_valet_key() {
  _vh=${XDG_CONFIG_HOME:-$HOME/.config}/valet-key/context
  if [ ! -e "$_vh" ]; then
    _warn "valet-key present but its context shim is not wired"
  elif grep -q 'severance context' "$_vh" 2>/dev/null; then
    _bad "valet-key shim calls the RETIRED 'severance context'"
    _bad "  -> $_vh"
    _bad "  Its ZDR guard is a NO-OP. Rewire it to 'severance current' +"
    _bad "  'severance guard' -- see docs/breaking-changes.md."
  elif grep -q 'severance current' "$_vh" 2>/dev/null &&
       grep -q 'severance guard' "$_vh" 2>/dev/null; then
    # Naming the verbs is not enough. The hook execs whatever `severance` is on
    # PATH, which on a provisioned box is the DEPLOYED copy, not this one. If
    # that copy predates the verbs the hook fails, and valet-key reads a failed
    # guard as "warn, then proceed" -- so a deploy skew disables the ZDR refuse
    # exactly the way a stale hook did. Check the verbs RESOLVE, not that the
    # text mentions them.
    if severance current >/dev/null 2>&1; then
      _ok "valet-key context shim wired to the current verbs"
    else
      _bad "valet-key shim: the 'severance' on PATH lacks 'current'"
      _bad "  -> $(command -v severance 2>/dev/null || echo 'not on PATH')"
      _bad "  The hook names the right verbs but they do not resolve there,"
      _bad "  so its ZDR guard is a NO-OP. Update the deployed copy."
    fi
  else
    _warn "valet-key shim at $_vh calls neither 'severance current' nor"
    _warn "  'severance guard'; severance cannot confirm it is wired"
  fi
}

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
  command -v valet-key >/dev/null 2>&1 && _doctor_valet_key

  # 5. the live wall + runner (delegate to the existing audits)
  . "$LIBEXEC/seal.sh";   sev_seal_check
  . "$LIBEXEC/runner.sh"; sev_runner_check

  return "$REPORT_RC"
}
