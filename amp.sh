#!/usr/bin/env bash
#
# amp.sh — WSO2 Agent Manager on a dedicated Colima VM.
#
# REAL snapshot/restore: backs up the VM *and* Colima's data disk
# (_disks/<instance>/datadisk), which is where /var/lib/docker lives — images,
# k3d containers, volumes and therefore all Kubernetes state.
#
# On APFS the snapshots use clonefile(2): instant, and they cost no disk space
# until the data diverges.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# amp.conf sits next to this script. Plain KEY=value lines, one per setting:
#
#     MEMORY=8
#     CPU=4
#
# Anything you export in your shell wins over the file, so you can override a
# single run without editing anything:  AMP_MEMORY=16 ./amp.sh up
AMP_CONF="${AMP_CONF:-$SCRIPT_DIR/amp.conf}"

# Settings the file may contain. Anything else is reported, not silently ignored.
AMP_CONF_KEYS="STATE_DIR PROFILE CPU MEMORY DISK IMAGE CONTAINER CONSOLE_URL BACKUP_DIR YES WAIT_PODS"

load_conf() {
  [ -f "$AMP_CONF" ] || return 0
  local line key val envvar known
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%%#*}"                                    # drop comments
    case "$line" in
      *=*) ;;
      *) continue ;;                                      # blank or junk
    esac
    key="${line%%=*}"
    val="${line#*=}"
    key="$(printf '%s' "$key" | tr -d "[:space:]" | tr "[:lower:]" "[:upper:]")"
    key="${key#AMP_}"                                     # accept AMP_MEMORY too
    val="$(printf '%s' "$val" | sed -e "s/^[[:space:]]*//" -e "s/[[:space:]]*$//" \
                                   -e "s/^\"\(.*\)\"$/\1/" -e "s/^'\(.*\)'$/\1/")"
    [ -n "$key" ] || continue
    known=0
    for k in $AMP_CONF_KEYS; do [ "$key" = "$k" ] && known=1 && break; done
    if [ "$known" = "0" ]; then
      printf "%s!%s Unknown setting '%s' in %s (ignored)\n" \
        "$(printf '\033[1;33m')" "$(printf '\033[0m')" "$key" "$AMP_CONF" >&2
      continue
    fi
    envvar="AMP_$key"
    eval "current=\${$envvar:-}"
    [ -n "$current" ] && continue                         # the environment wins
    eval "$envvar=\$val"
  done < "$AMP_CONF"
}
load_conf

# ─── Configuration ────────────────────────────────────────────────────────────
PROFILE="${AMP_PROFILE:-amp}"
CONTEXT="colima-${PROFILE}"
IMAGE="${AMP_IMAGE:-ghcr.io/wso2/amp-quick-start:v1.0.0-rc2}"
CONTAINER="${AMP_CONTAINER:-amp-quick-start}"
CPU="${AMP_CPU:-4}"
MEMORY="${AMP_MEMORY:-8}"
DISK="${AMP_DISK:-60}"
CONSOLE_URL="${AMP_CONSOLE_URL:-http://console.amp.localhost:8080}"

# Where this project keeps all Colima/Lima state. Relative paths resolve from
# the directory holding this script, so the default keeps everything here.
AMP_STATE_DIR="${AMP_STATE_DIR:-$SCRIPT_DIR/.colima}"
case "$AMP_STATE_DIR" in
  /*) ;;
  "~"/*) AMP_STATE_DIR="$HOME/${AMP_STATE_DIR#"~"/}" ;;
  *) AMP_STATE_DIR="$SCRIPT_DIR/$AMP_STATE_DIR" ;;
esac

# Colima ignores COLIMA_HOME entirely. The only supported relocation is
# XDG_CONFIG_HOME, and Colima honours it ONLY while ~/.colima does not exist
# ("found ~/.colima, ignoring $XDG_CONFIG_HOME"). Colima then works inside
# $XDG_CONFIG_HOME/colima.
export XDG_CONFIG_HOME="$AMP_STATE_DIR"
COLIMA_HOME="$AMP_STATE_DIR/colima"

# If ~/.colima reappears, Colima silently goes back to it and this script would
# be looking in the wrong place. Catch that instead of failing mysteriously.
check_home_colima() {
  [ -d "$HOME/.colima" ] || return 0
  err "~/.colima exists again, so Colima will ignore AMP_STATE_DIR."
  err "  This project keeps its state in: $COLIMA_HOME"
  err "Fix: move it out of the way, e.g."
  die "  mv ~/.colima \"$COLIMA_HOME.home-backup\""
}

BACKUP_BASE_DIR="${AMP_BACKUP_DIR:-$SCRIPT_DIR/.colima_backups/$PROFILE}"

# macOS caps a Unix socket path at 104 bytes (sockaddr_un.sun_path). Lima and
# Colima both create sockets under the state directory, so a deeply nested
# project would silently break the VM. Fail early with a clear message.
SOCKET_LIMIT=104
# The binding constraint is not the socket file itself: ssh appends a random
# 17-character suffix to its ControlPath when it opens the master connection,
# and that full string must fit. The longest one Lima builds is
#   <COLIMA_HOME>/_lima/colima-<profile>/ssh.sock.XXXXXXXXXXXXXXXX
# which is len(COLIMA_HOME) + len(profile) + 40. Getting this wrong costs a
# 10-minute boot that ends in "did not receive an event with the running status".
SOCKET_OVERHEAD=40
check_state_path() {
  local used=$(( ${#COLIMA_HOME} + ${#PROFILE} + SOCKET_OVERHEAD )) budget
  budget=$(( SOCKET_LIMIT - SOCKET_OVERHEAD ))
  if [ "$used" -gt "$SOCKET_LIMIT" ]; then
    err "The state directory path is too long for Lima's ssh control socket."
    err "  $COLIMA_HOME"
    err "  plus profile '$PROFILE' needs $used characters; the macOS limit is $SOCKET_LIMIT."
    err "  Over by $(( used - SOCKET_LIMIT )). Budget: len(state dir) + len(profile) <= $budget."
    err ""
    err "Fix any one of these in $AMP_CONF:"
    err "  - shorten the profile:     AMP_PROFILE=amp"
    err "  - move the state outside:  AMP_STATE_DIR=~/.colima-amp"
    die "  - or move the project to a shorter path."
  fi
  [ "$used" -gt $(( SOCKET_LIMIT - 6 )) ] \
    && warn "Socket path uses $used of $SOCKET_LIMIT characters — very little room." || true
}

# ─── Real Colima/Lima paths ──────────────────────────────────────────────
# Colima >= 0.6 uses LIMA_HOME=~/.colima/_lima (NOT ~/.lima).
if [ -d "$COLIMA_HOME/_lima" ]; then
  LIMA_HOME="$COLIMA_HOME/_lima"
elif [ "$COLIMA_HOME" = "$HOME/.colima" ] && [ -d "$HOME/.lima" ]; then
  LIMA_HOME="$HOME/.lima"          # very old Colima layout
else
  LIMA_HOME="$COLIMA_HOME/_lima"
fi

# Lima names the instance "colima" for the default profile, "colima-<p>" otherwise.
if [ "$PROFILE" = "default" ]; then INSTANCE="colima"; else INSTANCE="colima-$PROFILE"; fi

INSTANCE_DIR="$LIMA_HOME/$INSTANCE"          # VM: diffdisk (root), lima.yaml, vz-efi…
DATADISK_DIR="$LIMA_HOME/_disks/$INSTANCE"   # datadisk: /var/lib/docker  ← the one that matters
PROFILE_DIR="$COLIMA_HOME/$PROFILE"          # colima.yaml + docker.sock
STORE_FILE="$COLIMA_HOME/_store/$INSTANCE.json"   # disk_formatted: true  ← critical
LIMA_CONFIG_DIR="$LIMA_HOME/_config"         # user SSH keys
LIMA_NETWORKS_DIR="$LIMA_HOME/_networks"

# ─── UI ───────────────────────────────────────────────────────────────────────
c()    { printf '\033[%sm' "$1"; }
log()  { printf '%s▸%s %s\n' "$(c '1;36')" "$(c 0)" "$*"; }
ok()   { printf '%s✔%s %s\n' "$(c '1;32')" "$(c 0)" "$*"; }
warn() { printf '%s!%s %s\n' "$(c '1;33')" "$(c 0)" "$*" >&2; }
err()  { printf '%s✗%s %s\n' "$(c '1;31')" "$(c 0)" "$*" >&2; }
die()  { err "$*"; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "'$1' is not in your PATH."; }
confirm() {
  [ "${AMP_YES:-}" = "1" ] && return 0
  local ans; read -r -p "$1 [type 'yes']: " ans; [ "$ans" = "yes" ]
}

# ─── VM state ──────────────────────────────────────────────────────────
# Returns: Running | Stopped | Broken | Absent
vm_state() {
  local line
  line="$(colima list --json 2>/dev/null | grep -F "\"name\":\"$PROFILE\"" | awk 'NR==1' || true)"
  if [ -z "$line" ]; then echo "Absent"; return 0; fi
  echo "$line" | sed -n 's/.*"status":"\([^"]*\)".*/\1/p'
}
vm_running() { [ "$(vm_state)" = "Running" ]; }
vm_exists()  { [ "$(vm_state)" != "Absent" ]; }
vm_ip()      { colima status -p "$PROFILE" 2>&1 | sed -n 's/.*address: \([0-9.]*\).*/\1/p' | awk 'NR==1'; }

wait_state() { # wait_state <state> <timeout_s>
  local want="$1" t="${2:-120}" i=0
  while [ "$i" -lt "$t" ]; do
    [ "$(vm_state)" = "$want" ] && return 0
    sleep 2; i=$((i+2))
  done
  return 1
}

# ─── Docker against this VM's context ──────────────────────────────────────
d() { docker --context "$CONTEXT" "$@"; }

ensure_context() {
  docker context inspect "$CONTEXT" >/dev/null 2>&1 && return 0
  warn "Docker context '$CONTEXT' is missing; creating it against the profile socket."
  docker context create "$CONTEXT" \
    --description "colima $PROFILE" \
    --docker "host=unix://$PROFILE_DIR/docker.sock" >/dev/null
}

# CAREFUL: multiple Docker '--filter name=' are combined with OR, not AND, so
# 'name=^k3d-' + 'name=server-0$' also returned the serverlb (the load balancer,
# which has no kubectl). Match the exact name with grep instead.
k3d_node() { d ps -a --filter 'name=k3d-' --format '{{.Names}}' 2>/dev/null | grep -E -- '-server-0$' | awk 'NR==1' || true; }
kc() { # kubectl inside the k3s node
  local node; node="$(k3d_node)"
  [ -n "$node" ] || return 1
  d exec "$node" kubectl --kubeconfig=/etc/rancher/k3s/k3s.yaml "$@"
}

# k3d cluster name, derived from the container: k3d-<cluster>-server-0
k3d_cluster() {
  local n; n="$(k3d_node)"
  [ -n "$n" ] || return 1
  echo "$n" | sed 's/^k3d-//; s/-server-0$//'
}

# IMPORTANT: 'docker start' on the nodes is not enough. If k3s starts before the
# container network is ready it dies with:
#   "Failed to start networking: ... failed to find interface with specified node ip"
# and enters a restart loop. 'k3d cluster start' brings up server → agents →
# loadbalancer in order and re-injects host.k3d.internal into CoreDNS.
cluster_start() {
  local cl; cl="$(k3d_cluster)" || return 0
  [ -n "$cl" ] || return 0
  ensure_devcontainer
  # When the daemon comes up, nodes with a restart policy all start at once and
  # race for network IPs: the loadbalancer can end up with the server's address
  # (172.18.0.2), and then k3s dies in a loop with
  #   "failed to find interface with specified node ip".
  # Stopping them all first and starting them with k3d (server → agents → lb)
  # removes the race. Costs ~10s and avoids this whole class of failure.
  log "Restarting k3d cluster '$cl' in the correct order…"
  d exec -u wso2-amp "$CONTAINER" k3d cluster stop "$cl" >/dev/null 2>&1 || true
  d exec -u wso2-amp "$CONTAINER" k3d cluster start "$cl" 2>&1 | sed 's/^/   /' \
    || warn "'k3d cluster start' returned an error; check ./amp.sh status"
}

# Orderly shutdown. Leaves the nodes stopped on purpose, so the daemon does not
# auto-start them out of order later: cluster_start brings them up.
cluster_stop() {
  local cl; cl="$(k3d_cluster)" || return 0
  [ -n "$cl" ] || return 0
  d ps --format '{{.Names}}' | grep -qx "$CONTAINER" || return 0
  log "Stopping k3d cluster '$cl' cleanly…"
  d exec -u wso2-amp "$CONTAINER" k3d cluster stop "$cl" 2>&1 | sed 's/^/   /' || true
}

# k3s does a cordon+drain on SIGTERM and does NOT reverse it on boot: the node
# stays unschedulable and nothing gets scheduled ("1 node(s) were unschedulable").
# Orphan pods in Terminating/Unknown are also left over from the previous boot.
heal_cluster() {
  local node stuck
  node="$(k3d_node)"; [ -n "$node" ] || return 0
  if [ "$(kc get node "$node" -o jsonpath='{.spec.unschedulable}' 2>/dev/null)" = "true" ]; then
    log "Node was left cordoned after shutdown; uncordoning…"
    kc uncordon "$node" >/dev/null 2>&1 || true
  fi
  stuck="$(kc get pods -A --no-headers 2>/dev/null | awk '$4=="Terminating"||$4=="Unknown"{print $1" "$2}' || true)"
  if [ -n "$stuck" ]; then
    log "Purging zombie pods (Terminating/Unknown)…"
    echo "$stuck" | while read -r ns pod; do
      [ -n "$pod" ] && kc delete pod "$pod" -n "$ns" --force --grace-period=0 >/dev/null 2>&1 || true
    done
  fi
}

# Wait until the Kubernetes node is Ready.
wait_cluster() {
  local t="${1:-180}" i=0 node
  node="$(k3d_node)"
  if [ -z "$node" ]; then
    warn "No k3d cluster on this VM yet (did you run ./amp.sh install?)."
    return 0
  fi
  log "Waiting for node '$node' to become Ready…"
  local retried=0
  while [ "$i" -lt "$t" ]; do
    if kc get nodes --no-headers 2>/dev/null | grep -qw Ready; then
      ok "Kubernetes ready."
      heal_cluster
      return 0
    fi
    # If the node fell into a restart loop, waiting is pointless: restart the
    # cluster in the correct order, once.
    if [ "$retried" = "0" ] && [ "$i" -ge 40 ] \
       && d ps -a --format '{{.Names}} {{.Status}}' 2>/dev/null | grep -q "^${node} Restarting"; then
      retried=1
      warn "Node is in a restart loop; restarting the cluster in order."
      cluster_start
    fi
    sleep 5; i=$((i+5))
  done
  warn "Node did not become Ready within ${t}s. Check: ./amp.sh k get nodes"
  return 0
}

# A Ready node does not mean the platform is usable: AMP's ~56 pods take several
# minutes to come back after a restart or a restore.
wait_pods() {
  local t="${1:-300}" i=0 bad total
  [ "${AMP_WAIT_PODS:-1}" = "0" ] && return 0
  [ -n "$(k3d_node)" ] || return 0
  log "Waiting for pods to settle (max ${t}s)…"
  while [ "$i" -lt "$t" ]; do
    # '|| true': while the apiserver restarts kubectl fails, and with
    # 'set -o pipefail' that aborted the whole script mid-wait.
    total="$(kc get pods -A --no-headers 2>/dev/null | wc -l | tr -d ' ' || true)"
    bad="$(kc get pods -A --no-headers 2>/dev/null | awk '$4!="Running" && $4!="Completed"' | wc -l | tr -d ' ' || true)"
    if [ "${total:-0}" -gt 0 ] && [ "${bad:-1}" = "0" ]; then
      ok "Platform ready: $total pods stable."
      return 0
    fi
    sleep 10; i=$((i+10))
  done
  warn "After ${t}s, ${bad:-?} pod(s) are still unstable. Check: ./amp.sh k get pods -A"
  return 0
}

# ─── clonefile snapshot (APFS) with fallback ───────────────────────────────
SNAP_SKIP='*.sock|*.pid|ha.stdout.log|ha.stderr.log|serial*.log|.DS_Store|in_use_by'

snap_dir() { # snap_dir <src_dir> <dst_dir>
  local src="$1" dst="$2" f base
  [ -d "$src" ] || return 0
  mkdir -p "$dst"
  shopt -s nullglob dotglob
  for f in "$src"/*; do
    base="$(basename "$f")"
    case "$base" in
      *.sock|*.pid|ha.stdout.log|ha.stderr.log|serial*.log|.DS_Store|in_use_by) continue ;;
    esac
    [ -S "$f" ] && continue
    cp -Rc "$f" "$dst/$base" 2>/dev/null || cp -R "$f" "$dst/$base" || {
      shopt -u nullglob dotglob; die "Could not copy $f"; }
  done
  shopt -u nullglob dotglob
}

restore_dir() { # restore_dir <src_dir> <dst_dir>
  local src="$1" dst="$2"
  [ -d "$src" ] || return 0
  rm -rf "$dst"
  mkdir -p "$(dirname "$dst")"
  cp -Rc "$src" "$dst" 2>/dev/null || cp -R "$src" "$dst"
}

human_du() { du -sh "$1" 2>/dev/null | awk '{print $1}'; }

# Disk size (GiB) to request from Colima: if a datadisk already exists we must
# match it — Lima will not shrink an existing disk and the boot would fail.
disk_gib() {
  local f="$DATADISK_DIR/datadisk" sz
  if [ -f "$f" ]; then
    sz="$(stat -f %z "$f" 2>/dev/null || echo 0)"
    if [ "$sz" -gt 0 ]; then echo $(( sz / 1073741824 )); return 0; fi
  fi
  echo "$DISK"
}

# Lima's network daemon (limactl usernet) is global and its sockets live in
# _networks/. If the .pid points at a live process but the sockets are gone,
# Lima will not relaunch it and every boot dies with:
#   "dial unix .../user-v2_fd.sock: connect: no such file or directory"
# Lima's network daemon holds sockets inside _networks/. Kill it before removing
# the state directory, otherwise it survives with no files behind it.
stop_usernet() {
  local nd="$LIMA_NETWORKS_DIR/user-v2" pid
  [ -f "$nd/usernet_user-v2.pid" ] || return 0
  pid="$(cat "$nd/usernet_user-v2.pid" 2>/dev/null || true)"
  [ -n "$pid" ] && kill "$pid" 2>/dev/null || true
}

repair_usernet() {
  local nd="$LIMA_NETWORKS_DIR/user-v2" pid
  [ -d "$nd" ] || return 0
  [ -f "$nd/usernet_user-v2.pid" ] || return 0
  [ -S "$nd/user-v2_fd.sock" ] && return 0
  pid="$(cat "$nd/usernet_user-v2.pid" 2>/dev/null || true)"
  warn "Lima network daemon lost its sockets; restarting it (affects all profiles)."
  [ -n "$pid" ] && kill "$pid" 2>/dev/null || true
  rm -f "$nd/usernet_user-v2.pid"
}

# ─── Logical Kubernetes dump (cheap extra, very useful) ─────────────────────
k8s_dump() { # k8s_dump <dir>
  local out="$1" node ns
  node="$(k3d_node)" || return 0
  [ -n "$node" ] || { warn "No k3d cluster: skipping the logical Kubernetes dump."; return 0; }
  mkdir -p "$out"
  log "Dumping Kubernetes manifests (logical dump)…"
  kc get nodes -o wide            > "$out/nodes.txt"        2>/dev/null || true
  kc get all -A -o yaml           > "$out/all.yaml"         2>/dev/null || true
  kc get ns -o yaml               > "$out/namespaces.yaml"  2>/dev/null || true
  kc get pv,pvc -A -o yaml        > "$out/storage.yaml"     2>/dev/null || true
  kc get cm,secret -A -o yaml     > "$out/config.yaml"      2>/dev/null || true
  kc get ingress -A -o yaml       > "$out/ingress.yaml"     2>/dev/null || true
  kc get crd -o yaml              > "$out/crds.yaml"        2>/dev/null || true
  for ns in $(kc get ns -o name 2>/dev/null | sed 's|namespace/||'); do
    kc get all,cm,secret,pvc,ingress -n "$ns" -o yaml > "$out/ns-$ns.yaml" 2>/dev/null || true
  done
  d images --format '{{.Repository}}:{{.Tag}}' > "$out/images.txt" 2>/dev/null || true
  ok "Logical dump saved to $out"
}

# ─── Commands ─────────────────────────────────────────────────────────────────
cmd_up() {
  need colima; need docker; check_home_colima; check_state_path
  case "$(vm_state)" in
    Running) ok "VM '$PROFILE' is already running." ;;
    Absent)
      repair_usernet
      log "Creating Colima VM '$PROFILE' (vz+rosetta · ${CPU} CPU · ${MEMORY} GB · $(disk_gib) GB disk)…"
      colima start --profile "$PROFILE" \
        --vm-type=vz --vz-rosetta --network-address \
        --cpus "$CPU" --memory "$MEMORY" --disk "$(disk_gib)"
      ;;
    *)
      repair_usernet
      log "Starting VM '$PROFILE' with its saved configuration…"
      colima start --profile "$PROFILE"
      ;;
  esac
  ensure_context
  ok "VM ready."
  local ip; ip="$(vm_ip || true)"
  [ -n "${ip:-}" ] && echo "   VM IP: $ip"
  cluster_start
  wait_cluster 180
  wait_pods 300
  # What to do next depends on whether the platform is installed yet.
  echo
  if [ -z "$(k3d_node)" ]; then
    echo "   No platform on this VM yet. Install it:"
    echo "     ./amp.sh install      (takes ~20 min)"
  else
    echo "   Platform already installed. Next steps:"
    echo "     $CONSOLE_URL   (admin/admin)"
    echo "     ./amp.sh amp             open the dev container"
    echo "     ./amp.sh k get pods -A   check the state"
  fi
}

# The dev container is created detached with a restart policy: it survives
# 'stop'/'up' and closing the terminal. 'amp' just opens a shell inside it.
ensure_devcontainer() {
  ensure_context
  if d ps --format '{{.Names}}' | grep -qx "$CONTAINER"; then return 0; fi
  if d ps -a --format '{{.Names}}' | grep -qx "$CONTAINER"; then
    log "Resuming dev container '$CONTAINER' (keeps whatever you installed)…"
    d start "$CONTAINER" >/dev/null
    return 0
  fi
  log "Creating dev container '$CONTAINER' on the VM…"
  d run -d -it --name "$CONTAINER" --restart unless-stopped \
    -v /var/run/docker.sock:/var/run/docker.sock \
    --network=host \
    "$IMAGE" >/dev/null
}

cmd_amp() {
  need colima; need docker
  vm_running || cmd_up
  ensure_devcontainer
  echo
  ok  "Inside the dev container, run:  ./install.sh"
  echo "   (or exit and use './amp.sh install' to run it non-interactively)"
  echo "   Console: $CONSOLE_URL   (admin/admin)"
  echo
  exec docker --context "$CONTEXT" exec -it -u wso2-amp -w /home/wso2-amp "$CONTAINER" bash -l
}

# Runs ./install.sh inside the dev container, non-interactively (idempotent).
cmd_install() {
  need colima; need docker
  vm_running || cmd_up
  ensure_devcontainer
  log "Running ./install.sh inside the dev container (this takes a while)…"
  d exec -u wso2-amp -w /home/wso2-amp "$CONTAINER" bash -lc './install.sh'
  wait_cluster 600
  ok "Installation finished."
  echo "   Console: $CONSOLE_URL   (admin/admin)"
  echo "   Take a backup NOW:  ./amp.sh backup clean-install"
}

cmd_uninstall() {
  need docker; vm_running || die "VM is stopped."
  ensure_devcontainer
  confirm "This uninstalls AMP and deletes the k3d cluster. Are you sure?" || die "Cancelled."
  d exec -u wso2-amp -w /home/wso2-amp "$CONTAINER" bash -lc './uninstall.sh'
}

cmd_reset_container() {
  need docker; ensure_context
  d rm -f "$CONTAINER" >/dev/null 2>&1 || true
  ok "Dev container '$CONTAINER' removed. './amp.sh amp' will create a fresh one."
}

cmd_shell() { need colima; vm_running || die "VM is stopped. Run: ./amp.sh up"; exec colima ssh -p "$PROFILE"; }

cmd_stop() {
  need colima
  if vm_running; then
    # We do NOT remove the containers by hand: k3d uses a restart policy and
    # they come back on their own. Killing them manually is exactly what left
    # the cluster down after a restore.
    cluster_stop
    log "Stopping VM '$PROFILE'…"
    colima stop -p "$PROFILE"
    wait_state Stopped 120 || warn "VM took too long to stop; check with ./amp.sh status"
    ok "VM stopped (all state preserved)."
  else
    warn "VM '$PROFILE' was not running (state: $(vm_state))."
  fi
}

cmd_status() {
  need colima
  echo "Profile:   $PROFILE   (state: $(vm_state))"
  echo "Instance:  $INSTANCE_DIR"
  echo "Data disk: $DATADISK_DIR  ($(human_du "$DATADISK_DIR" 2>/dev/null || echo n/a))"
  echo
  colima status -p "$PROFILE" 2>&1 || true
  if vm_running; then
    echo; echo "── Containers ──"; d ps -a || true
    echo; echo "── Kubernetes nodes ──"; kc get nodes -o wide 2>/dev/null || echo "  (no k3d cluster)"
    echo; echo "── Pods ──"; kc get pods -A 2>/dev/null | awk 'NR<=40' || true
  fi
}

cmd_ip()      { local ip; ip="$(vm_ip || true)"; [ -n "${ip:-}" ] && echo "$ip" || die "Could not get the IP (is the VM stopped, or started without --network-address?)"; }
cmd_console() { command -v open >/dev/null 2>&1 && open "$CONSOLE_URL" || echo "$CONSOLE_URL"; }
cmd_kubectl() { vm_running || die "VM is stopped."; ensure_context; kc "$@"; }

# ── backup ────────────────────────────────────────────────────────────────────
cmd_backup() {
  need colima
  local name="${1:-default}"
  local dest="$BACKUP_BASE_DIR/$name"

  vm_exists || die "Profile '$PROFILE' does not exist. Nothing to back up."

  if [ -d "$dest" ]; then
    confirm "Backup '$name' already exists and will be OVERWRITTEN. Are you sure?" \
      || die "Cancelled."
    rm -rf "$dest"
  fi
  mkdir -p "$dest"

  # 1) Logical Kubernetes dump while the VM is alive (best-effort, great for inspection).
  if vm_running; then
    ensure_context
    k8s_dump "$dest/k8s" || true
  else
    warn "VM is stopped: skipping the logical Kubernetes dump."
  fi

  # 2) Stop the VM: without this the diffdisk/datadisk would be inconsistent.
  if vm_running; then
    log "Stopping the VM for a consistent snapshot…"
    cmd_stop
  fi

  # 3) Snapshot EVERY piece of the state.
  log "Snapshotting into $dest (clonefile on APFS: instant, no disk cost)…"
  snap_dir "$INSTANCE_DIR"      "$dest/instance"
  snap_dir "$DATADISK_DIR"      "$dest/datadisk"
  snap_dir "$PROFILE_DIR"       "$dest/profile"
  snap_dir "$LIMA_CONFIG_DIR"   "$dest/lima_config"
  [ -f "$STORE_FILE" ] && cp -c "$STORE_FILE" "$dest/store.json" 2>/dev/null \
                       || { [ -f "$STORE_FILE" ] && cp "$STORE_FILE" "$dest/store.json"; } || true

  [ -d "$dest/instance" ] || die "VM not found at $INSTANCE_DIR — snapshot aborted."
  [ -d "$dest/datadisk" ] || warn "No datadisk at $DATADISK_DIR (VM without a data disk?)."

  # 4) Manifest.
  cat > "$dest/manifest.txt" <<EOF
profile=$PROFILE
instance=$INSTANCE
created=$(date '+%Y-%m-%d %H:%M:%S %z')
colima=$(colima version 2>/dev/null | awk 'NR==1')
host=$(hostname)
instance_dir=$INSTANCE_DIR
datadisk_dir=$DATADISK_DIR
size_instance=$(human_du "$dest/instance")
size_datadisk=$(human_du "$dest/datadisk")
k8s_dump=$([ -d "$dest/k8s" ] && echo yes || echo no)
EOF

  ok "Backup '$name' complete."
  sed 's/^/   /' "$dest/manifest.txt"
  echo "   Restore with:  ./amp.sh restore $name"
}

cmd_backups() {
  [ -d "$BACKUP_BASE_DIR" ] || { warn "No backups in $BACKUP_BASE_DIR"; return 0; }
  local dir n
  printf '%-28s %-22s %-10s %-10s\n' NAME CREATED VM DATA
  for dir in "$BACKUP_BASE_DIR"/*/; do
    [ -d "$dir" ] || continue
    n="$(basename "$dir")"
    printf '%-28s %-22s %-10s %-10s\n' "$n" \
      "$(sed -n 's/^created=//p' "$dir/manifest.txt" 2>/dev/null | cut -c1-19)" \
      "$(sed -n 's/^size_instance=//p' "$dir/manifest.txt" 2>/dev/null)" \
      "$(sed -n 's/^size_datadisk=//p' "$dir/manifest.txt" 2>/dev/null)"
  done
}

cmd_rmbackup() {
  local name="${1:-}"; [ -n "$name" ] || die "Usage: ./amp.sh rmbackup <name>"
  local dest="$BACKUP_BASE_DIR/$name"
  [ -d "$dest" ] || die "Backup '$name' does not exist."
  confirm "Delete backup '$name'?" || die "Cancelled."
  rm -rf "$dest"; ok "Backup '$name' deleted."
}

# ── restore ───────────────────────────────────────────────────────────────────
cmd_restore() {
  need colima
  local name="${1:-default}"
  local src="$BACKUP_BASE_DIR/$name"
  [ -d "$src" ] || die "Backup '$name' does not exist. List them: ./amp.sh backups"
  [ -d "$src/instance" ] || die "Backup '$name' is incomplete (VM missing)."

  echo "About to restore:"; sed 's/^/   /' "$src/manifest.txt" 2>/dev/null || true
  confirm "This replaces the CURRENT state of profile '$PROFILE'. Are you sure?" || die "Cancelled."

  if vm_running; then
    log "Stopping the VM before restoring…"
    cmd_stop
  fi

  # Safety net: save the current state before overwriting it (clonefile: free).
  if [ -d "$INSTANCE_DIR" ]; then
    local safety="$BACKUP_BASE_DIR/_pre-restore-$(date +%Y%m%d-%H%M%S)"
    log "Saving current state to $safety (just in case)…"
    snap_dir "$INSTANCE_DIR" "$safety/instance"
    snap_dir "$DATADISK_DIR" "$safety/datadisk"
    snap_dir "$PROFILE_DIR"  "$safety/profile"
    [ -f "$STORE_FILE" ] && cp "$STORE_FILE" "$safety/store.json" || true
  fi

  log "Restoring the VM, the data disk and the configuration…"
  restore_dir "$src/instance"      "$INSTANCE_DIR"
  restore_dir "$src/datadisk"      "$DATADISK_DIR"
  restore_dir "$src/profile"       "$PROFILE_DIR"
  # _config holds the SSH keys and is GLOBAL to every Lima instance. Restore it
  # only when this machine has none of its own (case: moving the backup to
  # another Mac). Overwriting them here would break access to other profiles.
  if [ ! -d "$LIMA_CONFIG_DIR" ]; then
    restore_dir "$src/lima_config" "$LIMA_CONFIG_DIR"
  fi

  # disk_formatted=true stops Colima from REFORMATTING the datadisk (= losing everything).
  mkdir -p "$COLIMA_HOME/_store"
  if [ -f "$src/store.json" ]; then
    cp "$src/store.json" "$STORE_FILE"
  else
    printf '{\n  "disk_formatted": true,\n  "disk_runtime": "docker"\n}\n' > "$STORE_FILE"
  fi

  check_home_colima
  check_state_path
  repair_usernet
  log "Starting the restored VM…"
  colima start --profile "$PROFILE"
  ensure_context

  # Kernel network modules k3d/kube-proxy need, which do not always persist.
  log "Ensuring kernel network modules…"
  colima ssh -p "$PROFILE" -- sudo modprobe br_netfilter >/dev/null 2>&1 || true
  colima ssh -p "$PROFILE" -- sudo sysctl -w net.bridge.bridge-nf-call-iptables=1 >/dev/null 2>&1 || true
  colima ssh -p "$PROFILE" -- sudo sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || true

  cluster_start
  wait_cluster 300
  wait_pods 420

  ok "Restore complete."
  echo "   Status:  ./amp.sh status"
  echo "   Enter:   ./amp.sh amp"
}

# ── rescue: recover an orphaned data disk ────────────────────────────────────
cmd_rescue() {
  need colima; check_home_colima; check_state_path
  [ -d "$DATADISK_DIR" ] || die "No datadisk at $DATADISK_DIR — nothing to rescue."
  if vm_exists; then
    die "Profile '$PROFILE' already exists (state: $(vm_state)). 'rescue' is only for an orphaned data disk."
  fi

  local size; size="$(human_du "$DATADISK_DIR")"
  log "Orphaned data disk found: $DATADISK_DIR ($size)"
  log "It holds /var/lib/docker: images, k3d containers and all Kubernetes state."

  local safety="$BACKUP_BASE_DIR/_rescue-$(date +%Y%m%d-%H%M%S)"
  log "Taking a safety copy in $safety…"
  snap_dir "$DATADISK_DIR" "$safety/datadisk"
  [ -f "$STORE_FILE" ] && cp "$STORE_FILE" "$safety/store.json" || true
  ok "Copy done."

  # Without this flag Colima formats the datadisk when creating the VM.
  mkdir -p "$COLIMA_HOME/_store"
  printf '{\n  "disk_formatted": true,\n  "disk_runtime": "docker"\n}\n' > "$STORE_FILE"
  log "Set disk_formatted=true so Colima will NOT reformat the disk."

  log "Recreating the VM on top of the existing data disk…"
  colima start --profile "$PROFILE" \
    --vm-type=vz --vz-rosetta --network-address \
    --cpus "$CPU" --memory "$MEMORY" --disk "$(disk_gib)"
  ensure_context

  echo; log "Images found on the recovered disk:"
  d images 2>/dev/null | awk 'NR<=20' || warn "Could not list images."
  echo; log "Containers found:"
  d ps -a 2>/dev/null || true

  wait_cluster 240
  ok "Rescue finished. If you see your images/containers above, your work is back."
  echo "   Back it up NOW:  ./amp.sh backup rescued"
}

# ── doctor ────────────────────────────────────────────────────────────────────
cmd_doctor() {
  local sock_len
  echo "── Environment ──"
  printf '%-16s %s\n' colima "$(command -v colima || echo MISSING)"
  printf '%-16s %s\n' docker "$(command -v docker || echo MISSING)"
  printf '%-16s %s\n' limactl "$(command -v limactl || echo MISSING)"
  colima version 2>/dev/null | awk 'NR==1'
  case "$(command -v docker || true)" in
    */.rd/bin/docker) warn "Your 'docker' is Rancher Desktop's. It works via --context, but the default context fails while Rancher is stopped." ;;
  esac
  echo
  echo "── State directory ──"
  echo "$COLIMA_HOME"
  sock_len=$(( ${#COLIMA_HOME} + ${#PROFILE} + SOCKET_OVERHEAD ))
  printf 'ssh socket path: %s of %s (state dir + profile + %s) ' "$sock_len" "$SOCKET_LIMIT" "$SOCKET_OVERHEAD"
  if   [ "$sock_len" -gt "$SOCKET_LIMIT" ];      then echo "-> TOO LONG, the VM cannot start"
  elif [ "$sock_len" -gt $((SOCKET_LIMIT-10)) ]; then echo "-> tight, consider a shorter path"
  else echo "-> fine"; fi
  [ -f "$AMP_CONF" ] && echo "config file: $AMP_CONF" || echo "config file: none (using defaults)"
  if [ -d "$HOME/.colima" ]; then
    warn "~/.colima exists — Colima will IGNORE this directory and use it instead."
  else
    ok "~/.colima absent, so Colima uses this project's directory."
  fi
  echo
  echo "── Paths ──"
  for p in "$LIMA_HOME" "$INSTANCE_DIR" "$DATADISK_DIR" "$PROFILE_DIR" "$STORE_FILE" "$LIMA_CONFIG_DIR"; do
    printf '%-58s %s\n' "$p" "$([ -e "$p" ] && echo "OK ($(human_du "$p" 2>/dev/null || echo file))" || echo MISSING)"
  done
  echo "(Lima state: $LIMA_HOME)"
  echo
  echo "── Profiles ──"; colima list 2>&1
  echo
  echo "── State of '$PROFILE': $(vm_state) ──"
  if [ -f "$STORE_FILE" ]; then
    grep -q '"disk_formatted": *true' "$STORE_FILE" \
      && ok "disk_formatted=true (Colima will NOT reformat the datadisk)" \
      || warn "disk_formatted is not true: Colima could FORMAT the datadisk on boot."
  fi
  if [ -d "$DATADISK_DIR" ] && ! vm_exists; then
    warn "There is an orphaned data disk ($(human_du "$DATADISK_DIR")) with no VM. Recover it with: ./amp.sh rescue"
  fi
  echo
  echo "── Disk space ──"; df -h "$HOME" | tail -2
  echo
  echo "── Backups ──"; cmd_backups
}

cmd_nuke() {
  need colima
  if [ "${1:-}" != "-y" ]; then
    warn "This DELETES the VM and the data disk. Your work is lost unless you have a backup."
    confirm "Really destroy profile '$PROFILE'?" || exit 0
  fi
  colima delete -p "$PROFILE" -f || true
  rm -rf "$DATADISK_DIR" "$STORE_FILE" "$PROFILE_DIR" "$INSTANCE_DIR"
  ok "VM and data disk deleted."

  # If no Colima profile is left, remove the whole state directory so the
  # project folder goes back to just its own files. Lima regenerates the
  # shared bits (SSH keys, network config) on the next start.
  local remaining
  remaining="$(colima list --json 2>/dev/null | grep -c '"name"' || true)"
  if [ "${remaining:-0}" -gt 0 ]; then
    warn "Other Colima profiles still live in $AMP_STATE_DIR, so it is kept:"
    colima list 2>&1 | sed 's/^/   /'
    echo "   Remove one with:  XDG_CONFIG_HOME=\"$AMP_STATE_DIR\" colima delete -p <name> -f"
    return 0
  fi

  # Safety: never let a misconfigured AMP_STATE_DIR delete something important.
  case "$AMP_STATE_DIR" in
    ""|"/"|"$HOME"|"$HOME/") die "Refusing to delete '$AMP_STATE_DIR'." ;;
  esac
  [ -d "$AMP_STATE_DIR" ] || return 0

  stop_usernet
  rm -rf "$AMP_STATE_DIR"
  ok "State directory removed: $AMP_STATE_DIR"
  echo "   Your backups are untouched:  ./amp.sh backups"
}

usage() {
  cat <<EOF
amp.sh — WSO2 Agent Manager on Colima (profile: $PROFILE)

  Normal cycle
    ./amp.sh up                 Create/start the VM and wait for the cluster
    ./amp.sh amp                Open the dev container (persistent) → inside: ./install.sh
    ./amp.sh install            Run ./install.sh non-interactively (idempotent)
    ./amp.sh uninstall          Uninstall AMP and delete the k3d cluster
    ./amp.sh stop               Stop the VM, keeping everything
    ./amp.sh status             VM, containers, nodes and pods
    ./amp.sh shell              SSH into the VM
    ./amp.sh k <args>           kubectl against the cluster (e.g. ./amp.sh k get pods -A)
    ./amp.sh ip | console       VM IP / open the console

  Backups
    ./amp.sh backup <name>      FULL snapshot (VM + datadisk + config + k8s dump)
    ./amp.sh backups            List snapshots
    ./amp.sh restore <name>     Restore a snapshot and bring the cluster back up
    ./amp.sh rmbackup <name>    Delete a snapshot

  Diagnostics and rescue
    ./amp.sh doctor             Check paths, profiles, disk space and consistency
    ./amp.sh rescue             Recover an orphaned data disk (VM gone, data alive)
    ./amp.sh reset-container    Delete the dev container (VM and cluster stay)
    ./amp.sh nuke [-y]          DELETE the VM and wipe the state directory

  Config file: amp.conf next to this script
    AMP_STATE_DIR sets where the VM lives - defaults to .colima HERE, not ~/.colima

  Variables: AMP_STATE_DIR AMP_PROFILE AMP_IMAGE AMP_CPU AMP_MEMORY AMP_DISK AMP_BACKUP_DIR AMP_YES=1 AMP_WAIT_PODS=0
EOF
}

case "${1:-help}" in
  up)              cmd_up ;;
  amp)             cmd_amp ;;
  install)         cmd_install ;;
  uninstall)       cmd_uninstall ;;
  shell|ssh)       cmd_shell ;;
  stop)            cmd_stop ;;
  restart)         cmd_stop; cmd_up ;;
  status)          cmd_status ;;
  ip)              cmd_ip ;;
  console)         cmd_console ;;
  k|kubectl)       shift; cmd_kubectl "$@" ;;
  backup)          shift || true; cmd_backup "${1:-default}" ;;
  backups|list)    cmd_backups ;;
  restore)         shift || true; cmd_restore "${1:-default}" ;;
  rmbackup)        shift || true; cmd_rmbackup "${1:-}" ;;
  rescue)          cmd_rescue ;;
  doctor)          cmd_doctor ;;
  reset-container) cmd_reset_container ;;
  nuke|reset)      shift || true; cmd_nuke "${1:-}" ;;
  help|-h|--help)  usage ;;
  *)               err "Unknown command: $1"; echo; usage; exit 1 ;;
esac
