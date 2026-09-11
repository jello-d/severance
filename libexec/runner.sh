# runner.sh - per-enclave rootless-DOCKER runtime: one runner account PER work
# PROFILE. Sourced by bin/severance after
# common.sh. Each runner is a locked service account whose LOGIN gid is that
# profile's group, running rootless docker fronted by a socat relay on a
# host-visible group-<group> socket. The account name is the profile's `runner`
# (default <label>-runner) -- so `manifest` -> `manifest-runner`.
#
# newuidmap (uidmap 4.17.4) refuses a userns whose gid != the caller's
# /etc/passwd gid, and the login user's gid must stay personal (transient-group
# invariant); so a dedicated account whose LOGIN gid IS the profile group is the
# only way container-root can map to <runner>:<group> and read the 2770 tree via
# GROUP membership. Access is the runner's docker SOCKET (group <group>, 0660):
# a `work <profile>` session drives it, a personal process gets EACCES. NO
# operator sudoers grant; the group socket is the ONLY path.

SUBUID=${SUBUID:-/etc/subuid}
SUBGID=${SUBGID:-/etc/subgid}
TMPFILES_DIR=${TMPFILES_DIR:-/etc/tmpfiles.d}
SYSTEMD_TMPFILES=${SYSTEMD_TMPFILES:-systemd-tmpfiles}
RELAY_SRC=${SEVERANCE_RELAY_SRC:-$SEVERANCE_SHARE/runner/docker-sock.service}

# Per-profile vars, derived from the loaded WC_* (call right after wc_load).
_runner_vars() {
  RUNNER=${WORK_RUNNER_USER:-$WC_RUNNER}
  RUNNER_HOME=/home/$RUNNER
  SOCK_DIR=/run/$RUNNER
  TMPFILES=$TMPFILES_DIR/$RUNNER.conf
}

# The socket-dir tmpfiles line: 0710 so a group member can TRAVERSE in to the
# socket while everyone else is denied at the directory, owned runner:<group>
# so the daemon writes it and the group reads it. Its own function because it
# is pure -- derived entirely from _runner_vars and WC_GROUP -- and the apply
# path around it needs root, so this is the part a test can pin down without
# any privilege at all.
_render_tmpfiles() {
  printf 'd %s 0710 %s %s -\n' "$SOCK_DIR" "$RUNNER" "$WC_GROUP"
}

_primary_group() { id -gn "$1" 2>/dev/null; }
_has_subids() { grep -q "^$RUNNER:" "$1" 2>/dev/null; }
_has_traverse() {
  getfacl -p "$HOME" 2>/dev/null | grep -q "^user:$RUNNER:.*x"
}
_linger_on() {
  loginctl show-user "$RUNNER" 2>/dev/null | grep -q '^Linger=yes'
}

# Next free 65536-wide subordinate-id block, past the highest allocation.
_next_subid_block() {   # <file> -> "first-last"
  awk -F: 'BEGIN{m=100000}{e=$2+$3; if(e>m)m=e}
    END{printf "%d-%d\n", m, m+65535}' "$1" 2>/dev/null \
    || echo "100000-165535"
}
_ensure_subids() {
  case "$1" in
    uid) _f=$SUBUID; _opt=--add-subuids ;;
    gid) _f=$SUBGID; _opt=--add-subgids ;;
  esac
  if _has_subids "$_f"; then
    echo "severance: $RUNNER $1 range present"; return 0
  fi
  _r=$(_next_subid_block "$_f")
  sudo usermod "$_opt" "$_r" "$RUNNER"
  echo "severance: $RUNNER allocated $1 range $_r"
}

# Run a command in the lingering runner's --user systemd/session context.
_as_runner() {   # <cmd> [args...]
  sudo -u "$RUNNER" env "XDG_RUNTIME_DIR=/run/user/$_ruid" \
    "DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$_ruid/bus" \
    "PATH=/usr/bin:/bin" "$@"
}

# The proven runtime recipe: rootless dockerd as a --user service, fronted by a
# socat relay exposing a host-visible group socket that carries the Docker API
# hijack. Idempotent.
# NOTE: callers invoke this in a set-e-suppressed context (a tested return), so
# EVERY critical step checks its own failure with `|| return 1`, not set -e.
# It ends by verifying the real end-state (the socket exists).
# Bringing the runner's rootless docker up, one PHASE per function. Each can
# fail on its own terms and says why; _bring_up_docker is the order, not a
# place logic lives.

# linger enables the runner's --user systemd manager, but ASYNC; setuptool
# bails ("systemd not detected") without it. Start it and wait until it
# answers, else the whole rootless-docker install silently no-ops.
_wait_user_systemd() {
  sudo systemctl start "user@$_ruid.service" 2>/dev/null || true
  _n=0
  until _as_runner systemctl --user show --property=Version >/dev/null 2>&1; do
    _n=$((_n + 1))
    [ "$_n" -ge 15 ] && {
      echo "severance: $RUNNER --user systemd manager not responsive" >&2
      return 1; }
    sleep 1
  done
}

_install_rootless_docker() {
  if _as_runner test -f "$_ud/docker.service"; then
    echo "severance: $RUNNER rootless docker --user service present"
    return 0
  fi
  _as_runner dockerd-rootless-setuptool.sh install || true
  _as_runner test -f "$_ud/docker.service" || {
    echo "severance: $RUNNER setuptool did NOT install docker.service" \
         "(systemd not detected?)" >&2; return 1; }
  echo "severance: $RUNNER installed rootless docker --user service"
}

# The relay unit, templated. PURE -- a filter over RELAY_SRC -- so the part
# that decides who can reach the docker socket is testable without a runner,
# a daemon or root. @GROUP@ is the load-bearing substitution: it becomes
# `group=` on the listening socket, and a wrong value there opens the daemon
# to the whole box.
_render_relay_unit() {
  sed -e "s#@HOSTSOCK@#$SOCK_DIR/docker.sock#" \
      -e "s#@INTSOCK@#/run/user/$_ruid/docker.sock#" \
      -e "s#@GROUP@#$WC_GROUP#" "$RELAY_SRC"
}

# Install it if it differs, and REPORT whether it changed: `enable --now` does
# not restart an already-running unit, so a content change would otherwise not
# take effect until the next boot.
_install_relay_unit() {
  _rt=$(mktemp); _relay_changed=0
  _render_relay_unit > "$_rt"
  if _as_runner cmp -s "$_rt" "$_ud/work-docker-sock.service" 2>/dev/null; then
    echo "severance: $RUNNER socat relay unit current"
  else
    sudo install -o "$RUNNER" -g "$WC_GROUP" -m 0644 "$_rt" \
      "$_ud/work-docker-sock.service" || {
        rm -f "$_rt"
        echo "severance: $RUNNER relay unit install failed" >&2; return 1; }
    _relay_changed=1
    echo "severance: $RUNNER installed socat relay unit"
  fi
  rm -f "$_rt"
}

_start_units() {
  _as_runner systemctl --user daemon-reload || true
  _as_runner systemctl --user enable --now docker.service \
    work-docker-sock.service || {
      echo "severance: $RUNNER failed to enable dockerd/relay units" >&2
      return 1; }
  if [ "$_relay_changed" = 1 ]; then
    _as_runner systemctl --user restart work-docker-sock.service || true
    echo "severance: $RUNNER restarted socat relay (unit changed)"
  fi
}

# The socket is the whole point: until it exists, the enclave has no docker.
_wait_socket() {
  _n=0
  until sudo test -S "$SOCK_DIR/docker.sock"; do
    _n=$((_n + 1))
    [ "$_n" -ge 10 ] && {
      echo "severance: $RUNNER socket $SOCK_DIR/docker.sock not up" >&2
      return 1; }
    sleep 1
  done
  echo "severance: $RUNNER dockerd + relay up ($SOCK_DIR/docker.sock)"
}

_bring_up_docker() {
  _ruid=$(id -u "$RUNNER")
  _ud=$RUNNER_HOME/.config/systemd/user
  _wait_user_systemd || return 1
  sudo -u "$RUNNER" mkdir -p "$_ud"
  _install_rootless_docker || return 1
  _install_relay_unit || return 1
  _start_units || return 1
  _wait_socket
}
# Global (profile-independent) prerequisites.
_deps_ok() {
  command -v docker >/dev/null 2>&1 || {
    echo "severance: docker missing; install it first" >&2; return 1; }
  command -v dockerd-rootless.sh >/dev/null 2>&1 \
    || [ -x /usr/bin/dockerd-rootless.sh ] || {
      echo "severance: docker-ce-rootless-extras missing" >&2
      return 1; }
  command -v socat >/dev/null 2>&1 || {
    echo "severance: socat missing" >&2; return 1; }
}

# Provision the CURRENT profile's runner (WC_* + _runner_vars already set).
# The runner ACCOUNT: the profile group as its PRIMARY (login) group, which is
# what makes newuidmap map it and what lets it reach work_dir at all.
_ensure_account() {
  if id "$RUNNER" >/dev/null 2>&1; then
    echo "severance: user '$RUNNER' present"
  else
    sudo useradd --create-home --home-dir "$RUNNER_HOME" \
      --gid "$WC_GROUP" --shell /usr/sbin/nologin \
      --comment "rootless-docker runner for $WC_PROFILE" "$RUNNER"
    echo "severance: created '$RUNNER' ($RUNNER_HOME)"
  fi
  if [ "$(_primary_group "$RUNNER")" = "$WC_GROUP" ]; then
    echo "severance: $RUNNER primary group is '$WC_GROUP'"
  else
    sudo usermod -g "$WC_GROUP" "$RUNNER"
    echo "severance: $RUNNER primary group set '$WC_GROUP'"
  fi
}

# Rootless id mapping + lingering: the subordinate ranges rootless docker maps
# containers into, and the --user manager that survives having no session.
_ensure_mapping_and_linger() {
  _ensure_subids uid
  _ensure_subids gid
  if _linger_on; then
    echo "severance: $RUNNER lingering enabled"
  else
    sudo loginctl enable-linger "$RUNNER"
    echo "severance: $RUNNER lingering on"
  fi
}

# Traverse-ONLY ACL so the runner can walk $HOME (0750) to reach the tree. Not
# read: it needs to pass through, not to look around.
_ensure_traverse_acl() {
  if _has_traverse; then
    echo "severance: $RUNNER traverse ACL present"
  else
    setfacl -m u:"$RUNNER":--x "$HOME"
    echo "severance: $RUNNER traverse ACL set"
  fi
}

# The socket dir, via tmpfiles so it survives a reboot: 0710 owner:group =
# runner:<group>, so a group member traverses in and everyone else is denied
# at the directory.
_ensure_socket_dir() {
  _tf=$(mktemp)
  _render_tmpfiles > "$_tf"
  if cmp -s "$_tf" "$TMPFILES" 2>/dev/null; then
    echo "severance: $RUNNER tmpfiles $TMPFILES current"
  else
    sudo install -m 0644 -o root -g root "$_tf" "$TMPFILES"
    sudo "$SYSTEMD_TMPFILES" --create "$TMPFILES" >/dev/null 2>&1 || true
    echo "severance: $RUNNER installed $TMPFILES"
  fi
  rm -f "$_tf"
}

_provision_one() {
  echo "severance: provisioning '$RUNNER' ($WC_PROFILE, login gid $WC_GROUP)"
  getent group "$WC_GROUP" >/dev/null 2>&1 || {
    echo "severance: group '$WC_GROUP' missing (run 'severance seal')" >&2
    return 1; }
  _ensure_account
  _ensure_mapping_and_linger
  _ensure_traverse_acl
  _ensure_socket_dir
  _bring_up_docker
}
sev_runner() {
  _deps_ok || exit 1
  _any=0; _fail=0
  for _p in $(wc_profiles); do
    wc_load "$_p" || continue
    _runner_vars
    _any=1
    if _provision_one; then
      echo "severance: $RUNNER ready"
    else
      echo "severance: '$_p' provisioning FAILED" >&2; _fail=1
    fi
  done
  [ "$_any" = 1 ] || echo "severance: no work profiles; nothing to do"
  [ "$_fail" = 0 ] || exit 1
}

_runner_check_one() {
  if id "$RUNNER" >/dev/null 2>&1; then _ok "$RUNNER: user present"
  else _bad "$RUNNER: user missing"; return; fi
  if [ "$(_primary_group "$RUNNER" 2>/dev/null)" = "$WC_GROUP" ]; then
    _ok "$RUNNER: primary group '$WC_GROUP'"
  else _bad "$RUNNER: primary group not '$WC_GROUP' (newuidmap needs it)"; fi
  if _has_subids "$SUBUID" && _has_subids "$SUBGID"; then
    _ok "$RUNNER: subuid/subgid ranges present"
  else _bad "$RUNNER: subuid/subgid range missing"; fi
  if _linger_on; then _ok "$RUNNER: lingering enabled"
  else _bad "$RUNNER: lingering not enabled"; fi
  if _has_traverse; then _ok "$RUNNER: traverse ACL on $HOME"
  else _bad "$RUNNER: traverse ACL missing"; fi
  if [ -f "$TMPFILES" ]; then _ok "$RUNNER: socket-dir tmpfiles"
  else _bad "$RUNNER: socket-dir tmpfiles $TMPFILES missing"; fi
}

sev_runner_check() {
  echo "== severance runner (per-profile rootless docker) =="
  if command -v docker >/dev/null 2>&1; then _ok "docker present"
  else _bad "docker missing"; fi
  if command -v dockerd-rootless.sh >/dev/null 2>&1 \
     || [ -x /usr/bin/dockerd-rootless.sh ]; then
    _ok "rootless docker extras present"
  else _bad "docker-ce-rootless-extras missing"; fi
  if command -v socat >/dev/null 2>&1; then _ok "socat present (relay)"
  else _bad "socat missing (relay)"; fi
  for _p in $(wc_profiles); do
    wc_load "$_p" || continue
    _runner_vars
    _runner_check_one
  done
}
