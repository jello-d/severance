# common.sh - shared bootstrap for the severance CLI, sourced by bin/severance
# before a verb file (seal.sh / runner.sh / check.sh / ...).
#
# It provides three things the ported provisioning logic expects:
#   1. the work-context reader (wc_load / wc_profiles / wc_account / WC_*);
#   2. report markers -- _ok/_bad/_ignore/_warn + REPORT_RC -- in the plain
#      [OK]/[FAIL] vocabulary a host's `check` aggregator can recolour, so a
#      captured `severance check` matches a host's own module checks;
#   3. a sudo() shadow honoring SEVERANCE_DRYRUN (the build-only skip), so
#      `seal`/`runner` assemble without the privileged push when asked.
: "${LIBEXEC:?common.sh: LIBEXEC unset (source via bin/severance)}"

. "$LIBEXEC/work-context.sh"        # wc_load / wc_profiles / wc_account / WC_*

# Provisioning reads profile records from the runtime dir by default; a host
# delegator can point us at its own records via SEVERANCE_PROFILES_DIR (e.g. a
# reviewed in-repo source of truth) instead.
[ -n "${SEVERANCE_PROFILES_DIR:-}" ] && WC_PROFILES_DIR=$SEVERANCE_PROFILES_DIR

# A HOST-MANAGED box: the profiles dir is a symlink a provisioner published
# (into its own reviewed source). severance's record-writing verbs
# (init/use/forget --purge) DEFER there -- the host owns the records; editing
# through the symlink would mutate its tree unreviewed, and a runtime default is
# overwritten on the next provision. Standalone (a real dir), they act normally.
_sev_host_managed() { [ -L "$WC_PROFILES_DIR" ]; }
_sev_host_note() {   # <verb>
  echo "severance: this box is host-managed -- its records come from a" >&2
  echo "  provisioner. Manage profiles at the host's source, re-provision," >&2
  echo "  not with 'severance $1'." >&2
}

# Report markers -- identical strings + format to modules/lib/report.sh. A TTY
# gets colour (NO_COLOR-aware); piped/captured stays plain so the integrator
# repaints. REPORT_RC is the drift accumulator check() returns.
REPORT_RC=0
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  _sev_e=$(printf '\033')
  _sev_g="$_sev_e[1;32m"; _sev_r="$_sev_e[1;31m"
  _sev_y="$_sev_e[1;33m"; _sev_d="$_sev_e[1;30m"; _sev_o="$_sev_e[0m"
else _sev_g=; _sev_r=; _sev_y=; _sev_d=; _sev_o=; fi
_ok()     { printf '  %s[OK]%s   %s\n' "$_sev_g" "$_sev_o" "$*"; }
_bad()    { printf '  %s[FAIL]%s %s\n' "$_sev_r" "$_sev_o" "$*"; REPORT_RC=1; }
_ignore() { printf '  %s[IGNORE]%s %s\n' "$_sev_d" "$_sev_o" "$*"; }
_warn()   { printf '  %s[WARN]%s %s\n' "$_sev_y" "$_sev_o" "$*"; }

# sudo shadow: build-only (SEVERANCE_DRYRUN, which a host delegator can set from
# its own build-only flag) makes every sudo a logged no-op so a skipped install
# is never recorded as done; otherwise the real thing via `command sudo` (never
# bare, so a host's own sudo() shadow can't catch us).
sudo() {
  if [ -n "${SEVERANCE_DRYRUN:-}" ]; then
    printf 'build-only: skip sudo %s\n' "$*" >&2
    return 0
  fi
  command sudo "$@"
}

# Prime the sudo credential ONCE for a multi-step privileged verb (one challenge
# up front, the rest ride the cache). A no-op as root, under dry-run, or when a
# cache is already warm (a host pre-authed the run). Standalone at a TTY this
# prompts once.
sev_sudo_prime() {
  [ "$(id -u)" = 0 ] && return 0
  [ -n "${SEVERANCE_DRYRUN:-}" ] && return 0
  command sudo -v || { echo "severance: sudo auth failed" >&2; exit 1; }
}
