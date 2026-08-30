#!/bin/sh
# setup.t - the root setup.sh delegates to the severance CLI installer: install
# lands the ~/.local links, uninstall removes them. severance.t covers the
# installer itself in depth (host-hook guards, idempotence, git include); this
# only proves the thin wrapper reaches it. `check` is not exercised here -- it
# audits a provisioned work boundary, not a bare sandbox.
. "$(dirname "$0")/lib.sh"
harness_init setup        # sets HERE (repo root) + T (scratch) + fail/pass

# Isolated HOME; git on PATH (install wires a git include into it).
run() { env -i PATH="/usr/bin:/bin" HOME="$T" sh "$HERE/setup.sh" "$@"; }

run install >/dev/null 2>&1 || fail "setup.sh install errored"
[ -L "$T/.local/bin/severance" ]      || fail "install: severance not linked"
[ -L "$T/.local/bin/work" ]           || fail "install: work not linked"
[ -L "$T/.local/libexec/severance" ]  || fail "install: libexec not linked"
[ -L "$T/.local/share/severance" ]    || fail "install: share not linked"

run uninstall >/dev/null 2>&1 || fail "setup.sh uninstall errored"
[ -L "$T/.local/bin/severance" ] && fail "uninstall: severance link left"
[ -L "$T/.local/libexec/severance" ] && fail "uninstall: left the libexec link"

pass
