#!/bin/sh
# setup.sh - install / uninstall / check / test severance into a prefix. The
# SINGLE entry point a consumer or provisioning layer uses. severance already
# owns its install as a CLI verb (`severance install`): it symlinks the package
# into ~/.local AND wires the host integrations (git includeIf, valet-key hook),
# with every host-owned step GUARDED to be a safe no-op on a host-managed box.
# So this just delegates; nothing outside needs to know the layout.
#
#   ./setup.sh install     severance install   (link ~/.local + host hooks)
#   ./setup.sh uninstall   severance uninstall
#   ./setup.sh check       severance check     (audit; drift rc; [OK]/[FAIL])
#   ./setup.sh test        run the in-repo test suite (test/run)
#   ./setup.sh version     the packaged version
#
# POSIX sh, non-privileged. The <pkg> namespace lives in the install prefix
# (~/.local/libexec/severance), applied by the installer; the source tree
# carries none (libexec/, share/), and bin/severance self-locates ../libexec.
set -eu

_root=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
SEV="$_root/bin/severance"
_U="usage: setup.sh [install|uninstall|check|test|version]"

case "${1:-help}" in
  install)   exec "$SEV" install ;;
  uninstall) exec "$SEV" uninstall ;;
  check)     exec "$SEV" check ;;
  test)      exec sh "$_root/test/run" ;;
  version)   _v=$(git -C "$_root" describe --tags --always 2>/dev/null || true)
             echo "${_v:-severance (unversioned)}" ;;
  -h|--help|help) echo "$_U" ;;
  *) echo "setup.sh: unknown command '${1:-}'" >&2; echo "$_U" >&2; exit 2 ;;
esac
