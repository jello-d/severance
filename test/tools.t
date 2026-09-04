#!/bin/sh
# test/tools.t - the tools table: which per-tool config dirs live behind the
# seal, and which environment variable points each tool at its own.
#
# DATA, not hooks. Every case is the same four fields, so adding a tool is a
# line -- and ownership follows /etc/profile + /etc/profile.d: severance ships
# and owns share/tools, an integrator adds its own tools in its OWN drop-in, so
# severance can rewrite its defaults without clobbering anyone and nobody edits
# a file they do not own.
set -eu

. "$(dirname "$0")/lib.sh"
harness_init tools

WCLIB=$HERE/libexec/work-context.sh
SHARE=$HERE/share
D=$T/tools.d
mkdir -p "$D"

tools() {
  env SEVERANCE_SHARE="$SHARE" WC_TOOLS_DIR="$D" \
    sh -c ". '$WCLIB'; wc_tools"
}
field() { tools | awk -v t="$1" '$1 == t { print $'"$2"' }'; }

# --- the shipped defaults --------------------------------------------------
# severance ships the tools it supports, so a standalone box does the right
# thing out of the box rather than needing an integrator to describe claude.
for t in claude gemini codex gcloud; do
  tools | grep -q "^$t " || fail "shipped table is missing '$t'"
done
[ "$(field claude 2)" = CLAUDE_CONFIG_DIR ] || fail "claude: wrong env var"
[ "$(field claude 3)" = claude ]            || fail "claude: wrong dir"
[ "$(field gemini 4)" = yes ]               || fail "gemini should be sealed"
[ "$(field codex  4)" = no ]                || fail "codex should not be sealed"

# gcloud is sealed AND routed. It was shipped with no variable, which the
# table made visible: valet-key selects CLOUDSDK_CONFIG per profile through its
# own adapter, so the routing worked, but a BARE /usr/bin/gcloud inside a work
# session -- bypassing that shim, as gcloud-migrate deliberately does -- had no
# base and fell back to the personal dir. The base closes that and agrees with
# what valet-key selects.
[ "$(field gcloud 2)" = CLOUDSDK_CONFIG ] || fail "gcloud should set a base"
[ "$(field gcloud 4)" = yes ]             || fail "gcloud should be sealed"

# `-` still means "set nothing" and must never become the literal string: a row
# may legitimately route nothing and only ask for a seal.
printf 'noenv - noenvdir no\n' > "$D/05-noenv"
[ "$(field noenv 2)" = - ] || fail "'-' did not survive as the env cell"
rm -f "$D/05-noenv"

# --- comments and blank lines are not rows ---------------------------------
tools | grep -q '^#' && fail "a comment line was emitted as a row"
tools | grep -q '^ *$' && fail "a blank line was emitted as a row"

# --- a drop-in ADDS a tool, without touching the shipped file --------------
# This is the valet-key case: it is tackup's tool, not severance's, so it must
# be addable without editing a file severance owns.
before=$(tools | wc -l)
printf '# tackup\nvalet-key VALET_KEY_POOL_ROOT valet-key-pool no\n' > "$D/50-x"
[ "$(field valet-key 2)" = VALET_KEY_POOL_ROOT ] || fail "drop-in did not add"
[ "$(tools | wc -l)" -eq $((before + 1)) ] || fail "drop-in changed other rows"
cmp -s "$SHARE/tools" "$SHARE/tools" || fail "impossible"

# --- a drop-in may CORRECT a shipped default (last wins) -------------------
# Otherwise an integrator disagreeing with one row would have to fork the file.
printf 'gcloud OVERRIDDEN_CFG gcloud yes\n' > "$D/60-fix"
[ "$(field gcloud 2)" = OVERRIDDEN_CFG ] || fail "drop-in did not override"
[ "$(tools | grep -c '^gcloud ')" = 1 ] || fail "override duplicated the row"

# ...and drop-ins are ordered by NAME, so precedence is predictable.
printf 'gcloud EARLIER gcloud yes\n' > "$D/10-early"
[ "$(field gcloud 2)" = OVERRIDDEN_CFG ] \
  || fail "a later-named drop-in did not win"
rm -f "$D"/*

# --- no table at all: empty, not an error ----------------------------------
# A box with no share/tools should degrade to "route nothing", not fail: the
# boundary itself does not depend on any tool being described.
out=$(env SEVERANCE_SHARE="$T/nope" WC_TOOLS_DIR="$D" \
  sh -c ". '$WCLIB'; wc_tools") || fail "wc_tools errored with no table"
[ -z "$out" ] || fail "wc_tools invented rows with no table: '$out'"

# --- a missing SEVERANCE_SHARE is LOUD, not silently default-less ----------
# Composing "$SEVERANCE_SHARE/tools" from an unset variable yields "/tools",
# which reads fine and silently drops every shipped default -- a caller would
# get drop-ins only, with no sign the defaults had vanished.
printf 'only-a-dropin ONLY_ENV onlydir no\n' > "$D/70-only"
err=$(env -u SEVERANCE_SHARE WC_TOOLS_DIR="$D" \
  sh -c ". '$WCLIB'; wc_tools" 2>&1 >/dev/null) || true
case $err in
  *"SEVERANCE_SHARE unset"*) ;;
  *) fail "an unset SEVERANCE_SHARE was silent: '$err'" ;;
esac
# ...and it still answers with what it DOES have, rather than failing shut.
out=$(env -u SEVERANCE_SHARE WC_TOOLS_DIR="$D" \
  sh -c ". '$WCLIB'; wc_tools" 2>/dev/null)
[ "$out" = "only-a-dropin ONLY_ENV onlydir no" ] ||
  fail "drop-ins lost when SEVERANCE_SHARE is unset: '$out'"
rm -f "$D"/*

# --- the seal selection: seal=yes AND the tool installed -------------------
# "the right thing if the crumbs are there, otherwise skip" -- an absent tool
# must not have a dir provisioned for it.
#
# Driven with SYNTHETIC tool names, so the result cannot depend on which real
# tools this box happens to have installed.
printf 'sevtest-on  SEVTEST_ON  ton  yes\n' >  "$D/90-t"
printf 'sevtest-off SEVTEST_OFF toff yes\n' >> "$D/90-t"
printf 'sevtest-nos SEVTEST_NOS tnos no\n'  >> "$D/90-t"
mkdir -p "$T/bin"
# Drives the REAL seal_tool_dirs, extracted from seal.sh, with the privileged
# actuator stubbed. A helper that reimplemented the selection could not catch
# that selection drifting, which is the whole point of testing it.
std=$(sed -n '/^seal_tool_dirs() {/,/^}/p' "$HERE/libexec/seal.sh")
[ -n "$std" ] || fail "could not extract seal_tool_dirs from seal.sh"
seal_targets() {
  env SEVERANCE_SHARE="$T/nope" WC_TOOLS_DIR="$D" PATH="$T/bin:/usr/bin:/bin" \
    WC_CONFIG_ROOT=/w/.config \
    sh -c ". '$WCLIB'
           _seal_identity_dir() { echo \"\${1##*/}\"; }
           $std
           seal_tool_dirs"
}
[ -z "$(seal_targets)" ] || fail "sealed a dir for an absent tool"

printf '#!/bin/sh\nexit 0\n' > "$T/bin/sevtest-on"
printf '#!/bin/sh\nexit 0\n' > "$T/bin/sevtest-nos"
chmod +x "$T/bin/sevtest-on" "$T/bin/sevtest-nos"
[ "$(seal_targets)" = ton ] ||
  fail "want only 'ton' sealed, got: $(seal_targets)"
# sevtest-nos is INSTALLED but marked no: presence alone must not seal it.
seal_targets | grep -q tnos && fail "sealed a seal=no tool that was present"
# sevtest-off is marked yes but ABSENT: must stay unsealed.
seal_targets | grep -q toff && fail "sealed a seal=yes tool that was absent"

pass
