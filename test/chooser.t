#!/bin/sh
# test/chooser.t - libexec/severance-share-chooser, the window picker an
# enclave's screen-share portal runs.
#
# The filter needs no display. The live half runs the chooser INSIDE an
# enclave's security context on a PRIVATE headless wayfire (as display.t
# does), with the allowlist measured on a real session on 2026-11-01, to
# prove GTK can open a window with only what an enclave is offered, and that
# an unanswered prompt declines cleanly. Skipped, saying so, without a
# wayfire carrying the plugin or without GTK 4.
set -eu

. "$(dirname "$0")/harness_lib"
harness_init chooser

C=$HERE/libexec/severance-share-chooser

# --- the filter: windows only, never an output -------------------------------
out=$(printf '%s\n' 'Monitor: DP-1 Dell U2720Q' \
  'Window: Meet - Google Chrome (google-chrome)' 'Window: Slack (Slack)' \
  'garbage' | "$C" --candidates)
want=$(printf '%s\n' 'Window: Meet - Google Chrome (google-chrome)' \
  'Window: Slack (Slack)')
[ "$out" = "$want" ] || fail "the candidates were: $out"

# --- live, inside an enclave's context ----------------------------------------
WF=${WAYFIRE:-/opt/wayfire/bin/wayfire}
_plug=$(find "${WF%/bin/wayfire}" -name 'libsecurity-context-v1.so' \
  2>/dev/null | head -1)
if [ ! -x "$WF" ] || [ -z "$_plug" ] || ! python3 -I -c \
   'import gi; gi.require_version("Gtk", "4.0")' 2>/dev/null; then
  pass "filter only: no wayfire with security-context, or no GTK 4, here"
  exit 0
fi

# The interfaces a context client was offered on a real session.
ALLOW="ext_idle_notifier_v1 org_kde_kwin_server_decoration_manager
wl_compositor wl_data_device_manager wl_output wl_seat wl_shm
wl_subcompositor wp_color_representation_manager_v1 wp_cursor_shape_manager_v1
wp_fractional_scale_manager_v1 wp_linux_drm_syncobj_manager_v1 wp_presentation
wp_single_pixel_buffer_manager_v1 wp_viewporter xdg_activation_v1 xdg_wm_base
zwp_idle_inhibit_manager_v1 zwp_linux_dmabuf_v1 zwp_pointer_constraints_v1
zwp_pointer_gestures_v1 zwp_primary_selection_device_manager_v1
zwp_relative_pointer_manager_v1 zwp_tablet_manager_v2 zxdg_decoration_manager_v1
zxdg_exporter_v2 zxdg_output_manager_v1"
RUN=$T/run; mkdir -m 0700 "$RUN"; mkdir -p "$T/share/acme"
printf '%s\n' '[core]' 'plugins = security-context-v1' 'xwayland = false' \
  '' '[security-context-v1]' \
  "allowed_protocols = $(printf '%s' "$ALLOW" | tr '\n' ' ' |
    sed 's/ \{1,\}/, /g')" > "$T/wf.ini"
env -u WAYLAND_DISPLAY -u DISPLAY -u WAYFIRE_SOCKET XDG_RUNTIME_DIR="$RUN" \
  WLR_BACKENDS=headless WLR_HEADLESS_OUTPUTS=1 WLR_LIBINPUT_NO_DEVICES=1 \
  WLR_RENDERER=pixman "$WF" -c "$T/wf.ini" > "$T/wf.log" 2>&1 &
WFP=$!
_C="'$T'"
# shellcheck disable=SC2064
trap "kill $WFP 2>/dev/null || :; rm -rf $_C" EXIT INT TERM
WLD= i=0
while [ -z "$WLD" ] && [ "$i" -lt 100 ]; do
  for s in "$RUN"/wayland-*; do [ -S "$s" ] && WLD=${s##*/}; done
  i=$((i + 1)); sleep 0.1
done
[ -n "$WLD" ] || fail "the private wayfire made no socket"
env WAYLAND_DISPLAY="$WLD" XDG_RUNTIME_DIR="$RUN" \
  SEVERANCE_SHARE_ROOT="$T/share" "$HERE/libexec/severance-display" acme \
  > "$T/display.log" 2>&1 &
DP=$!
# shellcheck disable=SC2064
trap "kill $DP $WFP 2>/dev/null || :; rm -rf $_C" EXIT INT TERM
i=0
until grep -q '^ready' "$T/display.log" 2>/dev/null; do
  i=$((i + 1)); [ "$i" -lt 50 ] || fail "no enclave socket"
  sleep 0.1
done

# Unanswered for 2 seconds: declines, which is an EMPTY stdout and exit 0.
# It must also have WAITED, i.e. actually put a window up and not crashed.
start=$(date +%s)
rc=0; out=$(printf 'Window: Meet (google-chrome)\n' | timeout 30 env \
  WAYLAND_DISPLAY="$T/share/acme/wayland-0" XDG_RUNTIME_DIR="$RUN" \
  GSK_RENDERER=cairo SEVERANCE_ENCLAVE=acme SEVERANCE_CHOOSER_TIMEOUT=2 \
  "$C" 2>"$T/chooser.err") || rc=$?
took=$(( $(date +%s) - start ))
[ "$rc" = 0 ] || fail "the chooser exited $rc: $(tail -3 "$T/chooser.err")"
[ -z "$out" ] || fail "an unanswered prompt chose '$out'"
[ "$took" -ge 2 ] ||
  fail "the chooser returned in ${took}s, so no window waited: $(tail -3 \
    "$T/chooser.err")"

pass "windows only; opens inside an enclave's context, declines unanswered"
