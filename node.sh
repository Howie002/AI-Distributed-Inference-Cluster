#!/bin/bash
# node.sh — AI Distributed Inference Cluster Node Manager
# Usage:
#   ./node.sh                  — interactive menu (first run = full setup)
#   ./node.sh start            — start services for this node's role
#   ./node.sh stop             — stop all local services
#   ./node.sh setup            — (re)configure + install (auto-wires systemd unless VLLM_SKIP_SYSTEMD=1)
#   ./node.sh add-node         — register a new child node
#   ./node.sh status           — show what's running
#   ./node.sh install-systemd  — install systemd units for auto-restart + boot bring-up
#   ./node.sh remove-systemd   — remove systemd units (back to manual start/stop)
#   ./node.sh check            — end-to-end self-check: config validity, agent
#                                health, master reachability, cluster token,
#                                proxy + dashboard. Run automatically at end
#                                of `setup`; also available standalone.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/node_config.json"
VENV_DIR="$HOME/.vllm-venv"
mkdir -p "$SCRIPT_DIR/logs"
LOG_FILE="$SCRIPT_DIR/logs/node.log"

# ── Logging: terminal gets colour; log file gets timestamped plain text ───────
_log_file_writer() {
    while IFS= read -r line; do
        # Strip ANSI colour codes before writing to file
        printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" \
            "$(printf '%s' "$line" | sed 's/\x1b\[[0-9;]*[mK]//g')" >> "$LOG_FILE"
    done
}
exec > >(tee >(_log_file_writer)) 2>&1
echo "" >> "$LOG_FILE"
echo "════════════════════════════════════════" >> "$LOG_FILE"
echo "[$(date '+%Y-%m-%d %H:%M:%S')] node.sh ${*:-menu}" >> "$LOG_FILE"

# ── Keep terminal open on unexpected exit ─────────────────────────────────────
_CLEAN_EXIT=false
trap '
  if [ "$_CLEAN_EXIT" != "true" ]; then
    echo ""
    echo "────────────────────────────────────────────"
    echo "  node.sh exited unexpectedly (line $LINENO)"
    echo "  Full log: '"$LOG_FILE"'"
    echo "────────────────────────────────────────────"
    read -rp "  Press Enter to close... " _
  fi
' EXIT

# ── Colours ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

info()    { echo -e "${CYAN}▸ $*${RESET}"; }
success() { echo -e "${GREEN}✓ $*${RESET}"; }
warn()    { echo -e "${YELLOW}⚠  $*${RESET}"; }
err()     { echo -e "${RED}✗ $*${RESET}" >&2; }
bail()    { echo -e "${RED}✗ $*${RESET}"; echo "Log: $LOG_FILE"; read -rp "Press Enter to close... " _; _CLEAN_EXIT=true; exit 1; }
header()  { echo -e "\n${BOLD}── $* ─────────────────────────────────────────${RESET}"; }

# ── systemd integration ──────────────────────────────────────────────────────
# Auto-restart on crash + automatic boot-time bring-up. Installed by `setup`
# unless VLLM_SKIP_SYSTEMD=1. Three units, role-aware:
#   vllm-cluster-agent.service       — agent (every role)
#   vllm-cluster-dashboard.service   — dashboard (every role)
#   vllm-cluster-litellm.service     — LiteLLM proxy (master + both only)
SYSTEMD_DIR="/etc/systemd/system"
SYSTEMD_UNIT_AGENT="vllm-cluster-agent.service"
SYSTEMD_UNIT_DASHBOARD="vllm-cluster-dashboard.service"
SYSTEMD_UNIT_LITELLM="vllm-cluster-litellm.service"

_systemd_available() {
    command -v systemctl >/dev/null 2>&1 && [ -d "$SYSTEMD_DIR" ] && \
        systemctl list-units --type=service >/dev/null 2>&1
}

# Validate a string as either a dotted IPv4, a CIDR, or a DNS hostname.
# Reject single-character noise like "y" or empty strings — the setup wizard
# previously took "y" (intended as "yes, accept default") and saved it as the
# literal IP, breaking every downstream service.
_valid_ip_or_host() {
    local s="$1"
    [ -z "$s" ] && return 1
    # IPv4 with optional /prefix
    if [[ "$s" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}(/[0-9]{1,2})?$ ]]; then
        # Validate each octet is 0-255
        local addr="${s%%/*}"
        local IFS='.'
        local octets=($addr)
        local o
        for o in "${octets[@]}"; do
            [ "$o" -gt 255 ] 2>/dev/null && return 1
        done
        return 0
    fi
    # DNS hostname — must have at least one dot OR be "localhost"
    if [ "$s" = "localhost" ] || \
       [[ "$s" =~ ^[a-zA-Z]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)+$ ]]; then
        return 0
    fi
    return 1
}

# Validate CIDR or a comma-separated list of CIDRs (the discovery_range field).
_valid_cidr_list() {
    local s="$1"
    [ -z "$s" ] && return 1
    local IFS=','
    local parts=($s)
    local p
    for p in "${parts[@]}"; do
        # trim spaces
        p="${p# }"; p="${p% }"
        [[ "$p" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$ ]] || return 1
    done
    return 0
}

# Validate a numeric port (1-65535).
_valid_port() {
    local s="$1"
    [[ "$s" =~ ^[0-9]+$ ]] && [ "$s" -ge 1 ] && [ "$s" -le 65535 ]
}

_systemd_units_for_role() {
    case "$1" in
        master|both) echo "$SYSTEMD_UNIT_AGENT $SYSTEMD_UNIT_DASHBOARD $SYSTEMD_UNIT_LITELLM" ;;
        child)       echo "$SYSTEMD_UNIT_AGENT $SYSTEMD_UNIT_DASHBOARD" ;;
        *)           echo "$SYSTEMD_UNIT_AGENT $SYSTEMD_UNIT_DASHBOARD" ;;
    esac
}

# Returns 0 (true) if at least one of our unit files is installed.
_systemd_is_managed() {
    _systemd_available || return 1
    [ -f "$SYSTEMD_DIR/$SYSTEMD_UNIT_AGENT" ] || \
    [ -f "$SYSTEMD_DIR/$SYSTEMD_UNIT_DASHBOARD" ] || \
    [ -f "$SYSTEMD_DIR/$SYSTEMD_UNIT_LITELLM" ]
}

# Write one unit file via sudo. Args: unit_name, description, exec_start_cmd,
# exec_stop_cmd, pid_file_path, extra_env_lines (newline-separated)
_write_systemd_unit() {
    local unit_name="$1" desc="$2" exec_start="$3" exec_stop="$4" pid_file="$5" extra_env="$6"
    local tmp
    tmp=$(mktemp)
    # Note: StartLimitIntervalSec/StartLimitBurst belong in [Unit] per systemd
    # docs (they bound how often the unit as a whole can be restarted). Putting
    # them in [Service] makes systemd ignore them silently — caught via
    # `systemd-analyze verify` during local testing.
    {
        echo "[Unit]"
        echo "Description=$desc"
        echo "After=network-online.target"
        echo "Wants=network-online.target"
        echo "StartLimitIntervalSec=120"
        echo "StartLimitBurst=3"
        echo ""
        echo "[Service]"
        echo "Type=forking"
        echo "User=$USER"
        # WorkingDirectory + PIDFile take a literal path — DO NOT quote.
        # systemd's verifier rejects quoted values here ("path is not
        # absolute"). Only ExecStart/ExecStop need quoting because those
        # tokenize on whitespace.
        echo "WorkingDirectory=$SCRIPT_DIR"
        [ -n "$extra_env" ] && echo "$extra_env"
        echo "PIDFile=$pid_file"
        # ExecStart/ExecStop tokenize on whitespace unless quoted.
        # SCRIPT_DIR has spaces in our deployed path; the callers wrap the
        # script reference in escaped double-quotes so the value coming in
        # already looks like:  /bin/bash "/path/with spaces/script.sh"
        echo "ExecStart=$exec_start"
        echo "ExecStop=$exec_stop"
        echo "Restart=on-failure"
        echo "RestartSec=10"
        echo "TimeoutStartSec=180"
        echo ""
        echo "[Install]"
        echo "WantedBy=multi-user.target"
    } > "$tmp"
    sudo install -m 644 "$tmp" "$SYSTEMD_DIR/$unit_name" || { rm -f "$tmp"; return 1; }
    rm -f "$tmp"
}

do_install_systemd() {
    [ ! -f "$CONFIG_FILE" ] && bail "No config found. Run './node.sh setup' first."

    if ! _systemd_available; then
        info "systemd not detected; skipping auto-restart wiring."
        return 0
    fi

    local role agent_port
    role=$(cfg_get "['role']" "both")
    agent_port=$(cfg_get ".get('agent_port', 5000)" "5000")

    header "Installing systemd units (role: $role)"
    info "Requires sudo to write to $SYSTEMD_DIR/ — prompting now to cache credentials."

    # Prime sudo up front so the rest of the function runs cleanly. Failing here
    # means we abort BEFORE stopping any running services — leaving the cluster
    # in its current state rather than mid-install limbo.
    if ! sudo -v; then
        bail "sudo authentication failed — aborting install. Cluster left untouched."
    fi

    # Stop any manually-started services first so systemd is the sole manager.
    # Ignore failures — they may not be running.
    [ -f "$SCRIPT_DIR/dashboard/stop_dashboard.sh" ] && bash "$SCRIPT_DIR/dashboard/stop_dashboard.sh" 2>/dev/null || true
    [ -f "$SCRIPT_DIR/litellm/stop_proxy.sh" ]       && bash "$SCRIPT_DIR/litellm/stop_proxy.sh"       2>/dev/null || true
    [ -f "$SCRIPT_DIR/agent/stop_agent.sh" ]         && bash "$SCRIPT_DIR/agent/stop_agent.sh"         2>/dev/null || true
    sleep 1

    # NB: $SCRIPT_DIR has spaces in our deployed path ("Github Projects/Vllm
    # Start Point"). systemd splits ExecStart on whitespace unless the path
    # is double-quoted, so we wrap every script reference. Without this,
    # bash receives `bash /home/admin/Github` as argv[0..1] and dies trying
    # to exec the first word.
    _write_systemd_unit "$SYSTEMD_UNIT_AGENT" \
        "vLLM Cluster Control Agent" \
        "/bin/bash \"$SCRIPT_DIR/agent/start_agent.sh\"" \
        "/bin/bash \"$SCRIPT_DIR/agent/stop_agent.sh\"" \
        "$SCRIPT_DIR/agent/.agent_pid" \
        "Environment=AGENT_PORT=$agent_port" \
        || bail "Failed to write $SYSTEMD_UNIT_AGENT"
    success "Wrote $SYSTEMD_UNIT_AGENT"

    _write_systemd_unit "$SYSTEMD_UNIT_DASHBOARD" \
        "vLLM Cluster Dashboard" \
        "/bin/bash \"$SCRIPT_DIR/dashboard/start_dashboard.sh\"" \
        "/bin/bash \"$SCRIPT_DIR/dashboard/stop_dashboard.sh\"" \
        "$SCRIPT_DIR/dashboard/.dashboard_pid" \
        "Environment=DASHBOARD_PORT=3005
Environment=AGENT_URL=http://localhost:$agent_port" \
        || bail "Failed to write $SYSTEMD_UNIT_DASHBOARD"
    success "Wrote $SYSTEMD_UNIT_DASHBOARD"

    if [ "$role" = "master" ] || [ "$role" = "both" ]; then
        _write_systemd_unit "$SYSTEMD_UNIT_LITELLM" \
            "vLLM Cluster LiteLLM Proxy" \
            "/bin/bash \"$SCRIPT_DIR/litellm/start_proxy.sh\"" \
            "/bin/bash \"$SCRIPT_DIR/litellm/stop_proxy.sh\"" \
            "$SCRIPT_DIR/litellm/.proxy_pid" \
            "Environment=LITELLM_PORT=4000" \
            || bail "Failed to write $SYSTEMD_UNIT_LITELLM"
        success "Wrote $SYSTEMD_UNIT_LITELLM"
    elif [ -f "$SYSTEMD_DIR/$SYSTEMD_UNIT_LITELLM" ]; then
        # Role downgraded from master → child; remove stale LiteLLM unit.
        sudo systemctl disable --now "$SYSTEMD_UNIT_LITELLM" 2>/dev/null || true
        sudo rm -f "$SYSTEMD_DIR/$SYSTEMD_UNIT_LITELLM"
        info "Removed stale $SYSTEMD_UNIT_LITELLM (role no longer needs it)"
    fi

    sudo systemctl daemon-reload || bail "systemctl daemon-reload failed"
    local units
    units=$(_systemd_units_for_role "$role")
    info "Enabling + starting: $units"
    # `enable --now` can return 0 even when start fails on some systemctl
    # versions (enable succeeds; start fails but the failure is reported
    # to stderr without flipping the exit code). Don't rely on the exit
    # code alone — verify each unit is actually active afterwards.
    # shellcheck disable=SC2086
    sudo systemctl enable --now $units 2>&1 | grep -v "^Created symlink" || true

    # Give systemd a beat to finish bringing the units up, then verify.
    sleep 2
    local unit failed_units=""
    for unit in $units; do
        if sudo systemctl is-active --quiet "$unit"; then
            success "  $unit  active"
        else
            failed_units="$failed_units $unit"
            err "  $unit  NOT active"
        fi
    done

    if [ -n "$failed_units" ]; then
        err ""
        err "systemd units written but not all started cleanly:$failed_units"
        # Build the journalctl helper without the substitution gotcha that
        # previously produced "-xeu -xeu name1 -xeu name2".
        local journal_cmd="sudo journalctl"
        local u
        for u in $failed_units; do
            journal_cmd="$journal_cmd -xeu $u"
        done
        info "Inspect with: $journal_cmd"
        info "Common causes:"
        info "  • Bad node_config.json (validate IP fields)"
        info "  • Path has spaces and old unit file is cached — re-run 'sudo systemctl daemon-reload'"
        info "  • Port already in use by an older non-systemd process"
        info "  • Missing venv (~/.vllm-venv) or missing node_modules"
        bail "Aborting — fix the failing unit(s) before claiming setup complete."
    fi

    success "systemd units installed and active — services will auto-restart on crash and on boot."
    echo ""
    info "Manage with: sudo systemctl status <unit-name>"
    info "Live logs:   sudo journalctl -u <unit-name> -f"
    info "Disable:     ./node.sh remove-systemd"
}

_maybe_offer_systemd_install() {
    # Conditions to skip: systemd unavailable, already managed, user opted out,
    # or we don't have an interactive TTY for the sudo prompt.
    [ -n "$VLLM_SKIP_SYSTEMD" ] && return 0
    _systemd_available || return 0
    _systemd_is_managed && return 0
    if [ -n "$VLLM_NONINTERACTIVE" ] || [ ! -t 0 ]; then
        warn "systemd is available but cluster units aren't installed."
        warn "  Run 'sudo bash node.sh install-systemd' from a TTY to enable auto-restart + boot bring-up."
        return 0
    fi

    echo ""
    header "Auto-restart + boot bring-up not yet wired"
    info "systemd is available on this host but cluster units aren't installed."
    echo "  Installing them adds:"
    echo "    • Auto-restart on crash (agent, dashboard, proxy)"
    echo "    • Boot-time start — cluster comes back after a reboot without manual login"
    echo ""
    local ans
    read -rp "Install systemd units now? Requires sudo. [Y/n] " ans
    case "${ans,,}" in
        n|no)
            info "Skipped — install later with: sudo bash node.sh install-systemd"
            info "  Set VLLM_SKIP_SYSTEMD=1 to suppress this prompt on subsequent starts."
            return 0
            ;;
        *)
            # If install fails (sudo denied, etc.), fall through to manual start
            # rather than aborting — do_install_systemd uses `bail` only after
            # its own state mutations would have started, and we haven't yet.
            do_install_systemd || warn "systemd install failed; continuing with manual start."
            ;;
    esac
}

do_self_check() {
    # End-to-end verification that this node's cluster role is actually
    # working. Run automatically at the end of `node.sh setup` and available
    # as a standalone subcommand. Returns 0 only when every applicable check
    # passes. Each failure prints what to fix.
    [ ! -f "$CONFIG_FILE" ] && bail "No config found. Run './node.sh setup' first."

    local role agent_port this_ip master_ip cluster_token proxy_ip proxy_port
    role=$(cfg_get "['role']" "?")
    agent_port=$(cfg_get ".get('agent_port', 5000)" "5000")
    this_ip=$(cfg_get ".get('this_ip', 'localhost')" "localhost")
    master_ip=$(cfg_get "['master']['ip']" "")
    cluster_token=$(cfg_get "['cluster'].get('token', '')" "")
    proxy_ip=$(cfg_get "['cluster_proxy']['ip']" "$master_ip")
    proxy_port=$(cfg_get "['cluster_proxy']['port']" "4000")

    echo ""
    header "Self-check (role: $role)"

    local failures=0 passes=0
    _check_pass()  { success "  $*"; passes=$((passes + 1)); }
    _check_fail()  { err     "  $*"; failures=$((failures + 1)); }
    _check_info()  { info    "  $*"; }

    # ── Config sanity ─────────────────────────────────────────────────────────
    if _valid_ip_or_host "$this_ip"; then
        _check_pass "this_ip $this_ip is a valid address"
    else
        _check_fail "this_ip='$this_ip' is not a valid IP/hostname — re-run setup."
    fi
    if [ "$role" = "child" ] || [ "$role" = "both" ]; then
        if [ -z "$master_ip" ] || [ "$master_ip" = "auto" ]; then
            _check_info "master.ip is unset/'auto' — relying on cluster discovery"
        elif _valid_ip_or_host "$master_ip"; then
            _check_pass "master.ip $master_ip is a valid address"
        else
            _check_fail "master.ip='$master_ip' is not a valid IP/hostname — re-run setup."
        fi
    fi

    # ── Local agent ───────────────────────────────────────────────────────────
    if curl -sf --connect-timeout 3 --max-time 5 "http://localhost:$agent_port/health" >/dev/null 2>&1; then
        _check_pass "local agent responding on :$agent_port"
    else
        _check_fail "local agent NOT responding on :$agent_port — check journalctl -xeu vllm-cluster-agent.service"
    fi

    # ── Child-side: master reachable + token works ───────────────────────────
    if [ "$role" = "child" ] && [ -n "$master_ip" ] && [ "$master_ip" != "auto" ]; then
        if curl -sf --connect-timeout 3 --max-time 5 "http://$master_ip:5000/health" >/dev/null 2>&1; then
            _check_pass "master agent reachable at $master_ip:5000"
        else
            _check_fail "master agent NOT reachable at $master_ip:5000 — confirm master is up and firewall permits the LAN."
        fi

        if [ -n "$cluster_token" ]; then
            local hs_status
            hs_status=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 3 --max-time 5 \
                -H "X-Cluster-Token: $cluster_token" \
                "http://$master_ip:5000/cluster/handshake" 2>/dev/null || echo "000")
            if [ "$hs_status" = "200" ]; then
                _check_pass "cluster token authenticates against master /cluster/handshake"
            elif [ "$hs_status" = "401" ]; then
                _check_fail "cluster token REJECTED by master (401) — token mismatch between this node and master."
            else
                _check_fail "cluster/handshake returned $hs_status — token check inconclusive."
            fi
        else
            _check_info "no cluster.token set — auto-discovery disabled (fine if master.ip is hardcoded)"
        fi
    fi

    # ── Master/both: LiteLLM proxy ────────────────────────────────────────────
    if [ "$role" = "master" ] || [ "$role" = "both" ]; then
        local local_proxy="http://localhost:$proxy_port"
        if curl -sf --connect-timeout 3 --max-time 5 -H "Authorization: Bearer none" \
            "$local_proxy/v1/models" >/dev/null 2>&1; then
            _check_pass "LiteLLM proxy responding on :$proxy_port"
            local routed
            routed=$(curl -sf --max-time 5 -H "Authorization: Bearer none" "$local_proxy/v1/models" \
                | python3 -c "import json,sys; print(' '.join(m['id'] for m in json.load(sys.stdin).get('data',[])))" 2>/dev/null || echo "")
            if [ -n "$routed" ]; then
                _check_info "routed models: $routed"
            else
                _check_info "proxy is up but no models registered yet (children may still be coming up)"
            fi
        else
            _check_fail "LiteLLM proxy NOT responding on :$proxy_port — check journalctl -xeu vllm-cluster-litellm.service"
        fi
    fi

    # ── Dashboard (master/both only) ──────────────────────────────────────────
    if [ "$role" = "master" ] || [ "$role" = "both" ]; then
        if curl -sf --connect-timeout 3 --max-time 5 "http://localhost:3005" >/dev/null 2>&1; then
            _check_pass "dashboard responding on :3005"
        else
            _check_fail "dashboard NOT responding on :3005 — check journalctl -xeu vllm-cluster-dashboard.service"
        fi
    fi

    # ── Summary ───────────────────────────────────────────────────────────────
    echo ""
    if [ "$failures" -eq 0 ]; then
        success "Self-check: $passes/$((passes + failures)) checks passed. Cluster role '$role' is wired up correctly."
        return 0
    else
        err "Self-check: $failures failure(s), $passes pass(es). Setup wrote config but the cluster is not yet healthy."
        info "Fix the failing checks above (and inspect journalctl as suggested), then re-run: ./node.sh check"
        return 1
    fi
}

do_remove_systemd() {
    if ! _systemd_available; then
        info "systemd not detected; nothing to remove."
        return 0
    fi

    header "Removing systemd units"
    local removed=0
    for unit in $SYSTEMD_UNIT_AGENT $SYSTEMD_UNIT_DASHBOARD $SYSTEMD_UNIT_LITELLM; do
        if [ -f "$SYSTEMD_DIR/$unit" ]; then
            sudo systemctl disable --now "$unit" 2>/dev/null || true
            sudo rm -f "$SYSTEMD_DIR/$unit"
            success "Removed $unit"
            removed=$((removed + 1))
        fi
    done
    if [ "$removed" -gt 0 ]; then
        sudo systemctl daemon-reload
        success "Services are stopped. Use './node.sh start' for manual management going forward."
    else
        info "No systemd units found to remove."
    fi
}

# ── Python config helpers (env-var based — no shell quoting issues) ───────────

cfg_get() {
    # cfg_get KEY DEFAULT
    python3 -c "
import json, sys
try:
    d = json.load(open('$CONFIG_FILE'))
    print(d$1)
except Exception:
    print(sys.argv[1] if len(sys.argv) > 1 else '')
" "${2:-}" 2>/dev/null || echo "${2:-}"
}

cfg_nodes() {
    python3 - "$CONFIG_FILE" <<'PY' 2>/dev/null
import json, sys
nodes = json.load(open(sys.argv[1])).get("nodes", [])
for n in nodes:
    print("{}|{}|{}".format(n["name"], n["ip"], n.get("agent_port", 5000)))
PY
}

write_config() {
    # All values passed as env vars — avoids quoting/injection issues.
    # cluster_proxy: where model registrations are POSTed. For master/both it's
    # this node's own :4000; for child it's master_ip:4000.
    # cluster.token + cluster.discovery_range + cluster.master_host: new schema
    # supporting auto-discovery and DNS-aware resolution. Backward compatible
    # with the legacy `master.ip` field.
    python3 - "$CONFIG_FILE" <<'PY'
import json, os, sys, ipaddress, secrets
role       = os.environ["CFG_ROLE"]
this_ip    = os.environ["CFG_THIS_IP"]
master_ip  = os.environ["CFG_MASTER_IP"]
proxy_ip   = this_ip if role in ("master", "both") else master_ip
proxy_port = int(os.environ.get("CFG_PROXY_PORT", "4000"))

# Cluster discovery fields. Token auto-generated for master; child MUST be
# given one (so it can authenticate to its master). Discovery range defaults
# to the /24 derived from this_ip if not explicitly set.
cluster_token = os.environ.get("CFG_CLUSTER_TOKEN", "").strip()
if not cluster_token:
    if role in ("master", "both"):
        cluster_token = secrets.token_hex(16)
    # child without explicit token → empty, agent will skip discovery and fall
    # back to the legacy master.ip path

discovery_range_env = os.environ.get("CFG_DISCOVERY_RANGE", "").strip()
if discovery_range_env:
    # comma-separated CIDR list
    discovery_range = [r.strip() for r in discovery_range_env.split(",") if r.strip()]
else:
    try:
        net = ipaddress.IPv4Network(f"{this_ip}/24", strict=False)
        discovery_range = [str(net)]
    except Exception:
        discovery_range = []

master_host = os.environ.get("CFG_MASTER_HOST", "").strip() or master_ip

cfg = {
    "role":    role,
    "this_ip": this_ip,
    "master": {
        "ip":             master_ip,
        "agent_port":     int(os.environ.get("CFG_MASTER_AGENT_PORT", "5000")),
    },
    "cluster": {
        "token":            cluster_token,
        "master_host":      master_host,
        "discovery_range":  discovery_range,
    },
    "cluster_proxy": {
        "ip":   proxy_ip,
        "port": proxy_port,
    },
    "agent_port": int(os.environ["CFG_AGENT_PORT"]),
    "nodes":      json.loads(os.environ.get("CFG_NODES", "[]")),
    "update": {
        "repo_url":           os.environ.get("CFG_REPO_URL", "https://github.com/Howie002/AI-Distributed-Inference-Cluster.git"),
        "branch":             os.environ.get("CFG_REPO_BRANCH", "main"),
        "auto_pull_on_start": os.environ.get("CFG_REPO_AUTO_PULL", "true").lower() == "true",
    },
}
json.dump(cfg, open(sys.argv[1], "w"), indent=2)
print(json.dumps(cfg, indent=2))
PY
}

append_node_to_config() {
    NODE_NAME="$1" NODE_IP="$2" NODE_PORT="$3" \
    python3 - "$CONFIG_FILE" <<'PY'
import json, os, sys
cfg  = json.load(open(sys.argv[1]))
name = os.environ["NODE_NAME"]
ip   = os.environ["NODE_IP"]
port = int(os.environ["NODE_PORT"])
nodes = [n for n in cfg.get("nodes", []) if n["ip"] != ip]
nodes.append({"name": name, "ip": ip, "agent_port": port})
cfg["nodes"] = nodes
json.dump(cfg, open(sys.argv[1], "w"), indent=2)
print("Saved.")
PY
}

# ── Detect LAN IP ─────────────────────────────────────────────────────────────
detect_ip() {
    python3 -c "
import socket
try:
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.connect(('8.8.8.8', 80))
    print(s.getsockname()[0])
    s.close()
except Exception:
    print('127.0.0.1')
"
}

# ── Install: Node.js + dashboard build ───────────────────────────────────────
install_master_deps() {
    header "Installing master dependencies"

    if ! command -v node &>/dev/null; then
        info "Node.js not found — installing v20 via NodeSource..."
        if ! command -v curl &>/dev/null; then
            sudo apt-get install -y curl || bail "Could not install curl. Install it manually and re-run."
        fi
        curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash - \
            || bail "NodeSource setup script failed. Install Node.js 20+ manually."
        sudo apt-get install -y nodejs \
            || bail "apt-get install nodejs failed."
    fi

    local ver
    ver=$(node -e "process.stdout.write(process.versions.node)" 2>/dev/null || echo "unknown")
    success "Node.js $ver"

    info "Installing npm packages..."
    cd "$SCRIPT_DIR/dashboard"
    npm install --loglevel=error \
        || bail "npm install failed. Check $LOG_FILE for details."

    info "Building dashboard..."
    npm run build \
        || bail "npm run build failed. Check $LOG_FILE for details."

    cd "$SCRIPT_DIR"
    success "Dashboard ready"
}

# ── Install: lightweight Python venv (no vLLM) for the control agent + proxy ─
# Master nodes need the agent (so children can POST /proxy/sync) and LiteLLM
# (the cluster's OpenAI-compatible entry point), but NOT vLLM itself — there's
# no GPU on a pure-master box. install_child_deps does the heavy vLLM install
# via setup.sh; this is the slimmer variant for master role.
install_agent_deps() {
    header "Installing control-plane Python deps (agent + LiteLLM, no vLLM)"

    if ! command -v python3 &>/dev/null; then
        bail "python3 not found — install Python 3.10+ first."
    fi
    if ! python3 -m venv --help &>/dev/null; then
        bail "python3-venv not found — run: sudo apt install python3-venv python3-full"
    fi

    if [ ! -d "$VENV_DIR" ]; then
        info "Creating venv at $VENV_DIR..."
        python3 -m venv "$VENV_DIR" || bail "venv creation failed."
    else
        info "Reusing existing venv at $VENV_DIR"
    fi

    info "Upgrading pip..."
    "$VENV_DIR/bin/pip" install --quiet --upgrade pip \
        || bail "pip upgrade failed."

    info "Installing LiteLLM proxy + agent runtime..."
    "$VENV_DIR/bin/pip" install --quiet \
        "litellm[proxy]>=1.83.0" \
        huggingface_hub \
        duckdb \
        psutil \
        "fastapi>=0.110" \
        "uvicorn>=0.27" \
        "pydantic>=2" \
        httpx \
        requests \
        || bail "pip install failed."

    [ -x "$VENV_DIR/bin/litellm" ] \
        || bail "litellm binary not found at $VENV_DIR/bin/litellm after install."

    success "Control-plane Python deps ready"
}

# ── Install: Python venv + vLLM + agent deps ─────────────────────────────────
install_child_deps() {
    header "Installing child (inference) dependencies"

    # CUDA toolkit
    if ! command -v nvcc &>/dev/null; then
        warn "nvcc not found — attempting to install cuda-toolkit-12-8..."
        if command -v apt-get &>/dev/null; then
            if ! apt-cache show cuda-toolkit-12-8 &>/dev/null 2>&1; then
                info "Adding NVIDIA package repository..."
                wget -q https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2404/x86_64/cuda-keyring_1.1-1_all.deb \
                    || bail "Could not download NVIDIA keyring. Check internet connection."
                sudo dpkg -i cuda-keyring_1.1-1_all.deb
                sudo apt-get update -qq
                rm -f cuda-keyring_1.1-1_all.deb
            fi
            sudo apt-get install -y cuda-toolkit-12-8 \
                || bail "cuda-toolkit-12-8 install failed. See: https://developer.nvidia.com/cuda-downloads"
        else
            warn "Cannot auto-install CUDA toolkit. Install cuda-toolkit-12-8 manually then re-run."
        fi
    else
        local cuda_ver
        cuda_ver=$(nvcc --version 2>/dev/null | grep -oP 'release \K[0-9.]+' || echo "found")
        success "CUDA toolkit $cuda_ver"
    fi

    # vLLM venv (setup.sh is idempotent)
    info "Running vLLM environment setup..."
    bash "$SCRIPT_DIR/setup.sh" \
        || bail "setup.sh failed — check $LOG_FILE"

    # Agent Python deps
    info "Installing agent Python deps (fastapi uvicorn psutil)..."
    "$VENV_DIR/bin/pip" install --quiet fastapi uvicorn psutil \
        || bail "pip install failed."

    success "Child dependencies ready"
}

# ── Setup (configure + install) ───────────────────────────────────────────────
do_setup() {
    # ── Non-interactive mode: all values from env vars ────────────────────────
    # Used by add-node SSH deployment. Set VLLM_NONINTERACTIVE=1 to enable.
    # Env vars: VLLM_ROLE, VLLM_THIS_IP, VLLM_MASTER_IP, VLLM_AGENT_PORT
    local _noninteractive="${VLLM_NONINTERACTIVE:-}"

    # Capture existing config so we can use its values as defaults when the
    # user is re-running setup. Without this, a reconfigure of a "child" node
    # silently defaults the role prompt to "both" — which has bitten us
    # (Death Star 2026-06-24).
    local existing_role=""
    if [ -f "$CONFIG_FILE" ]; then
        existing_role=$(cfg_get "['role']" "")
    fi

    if [ -z "$_noninteractive" ]; then
        echo -e "\n${BOLD}╔═══════════════════════════════════════╗${RESET}"
        echo -e "${BOLD}║   AI Distributed Inference Cluster     ║${RESET}"
        echo -e "${BOLD}╚═══════════════════════════════════════╝${RESET}\n"

        if [ -f "$CONFIG_FILE" ]; then
            warn "Existing config found (role: ${existing_role:-?})."
            read -rp "Overwrite and reconfigure? [y/N]: " yn
            [[ "${yn,,}" == "y" ]] || { info "Keeping existing config."; _CLEAN_EXIT=true; exit 0; }
        fi
    fi

    # ── This machine's IP ─────────────────────────────────────────────────────
    local detected_ip
    detected_ip=$(detect_ip)
    local this_ip
    if [ -n "$_noninteractive" ] && [ -n "${VLLM_THIS_IP:-}" ]; then
        this_ip="$VLLM_THIS_IP"
        info "This IP: $this_ip"
    else
        while true; do
            read -rp "This machine's IP [$detected_ip]: " this_ip
            this_ip="${this_ip:-$detected_ip}"
            if _valid_ip_or_host "$this_ip"; then
                break
            fi
            warn "  '$this_ip' is not a valid IP or hostname. Press Enter to accept '$detected_ip', or type an explicit value."
        done
    fi

    # ── Role ──────────────────────────────────────────────────────────────────
    # Default to the existing role when re-running setup on a configured node.
    # Falls back to "both" only on first-run / unrecognised existing role.
    local role role_default_num role_default_label
    case "$existing_role" in
        master) role_default_num=1; role_default_label="master (existing)" ;;
        child)  role_default_num=2; role_default_label="child (existing)"  ;;
        both)   role_default_num=3; role_default_label="both (existing)"   ;;
        *)      role_default_num=3; role_default_label="both"              ;;
    esac
    if [ -n "$_noninteractive" ] && [ -n "${VLLM_ROLE:-}" ]; then
        role="$VLLM_ROLE"
        info "Role: $role"
    else
        echo ""
        echo "  Select this node's role:"
        echo "    1) master  — dashboard only (no local GPU inference)"
        echo "    2) child   — GPU inference node (no dashboard)"
        echo "    3) both    — dashboard + GPU inference on this machine"
        read -rp "  Role [1/2/3, default $role_default_num — $role_default_label]: " role_num
        case "${role_num:-$role_default_num}" in
            1) role="master" ;;
            2) role="child"  ;;
            3) role="both"   ;;
            *) role="$existing_role" ;;
        esac
        [ -z "$role" ] && role="both"
    fi
    success "Role: $role"

    # ── Master IP / hostname ──────────────────────────────────────────────────
    # Now accepts hostnames as well as IPs. The agent re-resolves on each
    # connection, so DNS changes propagate without touching node configs.
    local master_ip master_host
    if [ -n "$_noninteractive" ] && [ -n "${VLLM_MASTER_IP:-}" ]; then
        master_ip="$VLLM_MASTER_IP"
        info "Master IP/host: $master_ip"
    elif [ "$role" = "child" ]; then
        echo ""
        info "Master can be specified by IP (e.g. 10.2.35.10) OR hostname (e.g. ai-master.foundation.local)."
        info "Tip: leave blank to use auto-discovery — agent will scan the discovery range for the master."
        local existing_master_ip
        existing_master_ip=$(cfg_get "['master']['ip']" "")
        local master_prompt_default="auto-discover"
        [ -n "$existing_master_ip" ] && [ "$existing_master_ip" != "auto" ] && master_prompt_default="$existing_master_ip"
        while true; do
            read -rp "Master node IP/host [$master_prompt_default]: " master_ip
            master_ip="${master_ip:-$master_prompt_default}"
            # "auto" / "auto-discover" are sentinel values, skip the validation.
            if [ "$master_ip" = "auto" ] || [ "$master_ip" = "auto-discover" ]; then
                master_ip="auto"
                break
            fi
            if _valid_ip_or_host "$master_ip"; then
                break
            fi
            warn "  '$master_ip' is not a valid IP or hostname. Try again, or type 'auto' for discovery."
        done
    else
        master_ip="$this_ip"
    fi
    master_host="$master_ip"

    # ── Ports ─────────────────────────────────────────────────────────────────
    local agent_port
    if [ -n "$_noninteractive" ] && [ -n "${VLLM_AGENT_PORT:-}" ]; then
        agent_port="$VLLM_AGENT_PORT"
    else
        while true; do
            read -rp "Agent port [5000]: " agent_port
            agent_port="${agent_port:-5000}"
            if _valid_port "$agent_port"; then
                break
            fi
            warn "  '$agent_port' is not a valid port (1-65535)."
        done
    fi

    # ── Cluster discovery (token + CIDR range) ────────────────────────────────
    # On master/both: token is auto-generated and displayed at end of setup so
    # the operator can share it with children. On child: token must be provided
    # (paste from master's setup output) or left blank to fall back to legacy
    # hardcoded-IP behaviour.
    local cluster_token discovery_range
    if [ -n "$_noninteractive" ] && [ -n "${VLLM_CLUSTER_TOKEN:-}" ]; then
        cluster_token="$VLLM_CLUSTER_TOKEN"
    elif [ "$role" = "child" ]; then
        echo ""
        info "Cluster token: shared secret that lets this node authenticate to the master."
        info "Get it from 'cluster.token' in the master's node_config.json (or master's setup output)."
        read -rp "Cluster token [skip — fall back to hardcoded master IP]: " cluster_token
        cluster_token="${cluster_token}"
    else
        cluster_token=""  # write_config will auto-generate one for master/both
    fi

    if [ -n "$_noninteractive" ] && [ -n "${VLLM_DISCOVERY_RANGE:-}" ]; then
        discovery_range="$VLLM_DISCOVERY_RANGE"
    else
        # Suggest /24 derived from this_ip as the default.
        local default_range
        default_range=$(python3 -c "
import ipaddress
try:
    print(str(ipaddress.IPv4Network('$this_ip/24', strict=False)))
except Exception:
    print('')
" 2>/dev/null)
        echo ""
        info "Discovery range: CIDR(s) to scan for cluster nodes. Comma-separated for multiple."
        while true; do
            read -rp "Discovery range [$default_range]: " discovery_range
            discovery_range="${discovery_range:-$default_range}"
            # Empty is OK — discovery is optional when master IP is hardcoded.
            [ -z "$discovery_range" ] && break
            if _valid_cidr_list "$discovery_range"; then
                break
            fi
            warn "  '$discovery_range' is not a valid CIDR. Use form like 10.2.35.0/24 (not 10.2.35)."
        done
    fi

    # ── Child nodes ───────────────────────────────────────────────────────────
    local nodes_json="[]"
    if [ "$role" != "child" ]; then
        echo ""
        info "Register child GPU nodes (press Enter with blank IP when done)."

        # Collect as parallel arrays — avoids JSON quoting inside bash
        local names=() ips=() ports=()

        if [ "$role" = "both" ]; then
            names+=("This Machine")
            ips+=("$this_ip")
            ports+=("$agent_port")
            success "  This machine added automatically."
        fi

        local i=1
        while true; do
            read -rp "  Child node $i IP (blank to finish): " child_ip
            [ -z "$child_ip" ] && break
            read -rp "    Name [GPU Server $i]: " child_name
            child_name="${child_name:-GPU Server $i}"
            read -rp "    Agent port [$agent_port]: " child_port
            child_port="${child_port:-$agent_port}"
            names+=("$child_name")
            ips+=("$child_ip")
            ports+=("$child_port")
            success "  Added: $child_name ($child_ip:$child_port)"
            i=$((i + 1))
        done

        # Build JSON array in Python — join with | (safe: IPs/ports/names won't contain it)
        if [ "${#names[@]}" -gt 0 ]; then
            local joined_names joined_ips joined_ports
            joined_names=$(IFS='|'; echo "${names[*]}")
            joined_ips=$(IFS='|'; echo "${ips[*]}")
            joined_ports=$(IFS='|'; echo "${ports[*]}")
            nodes_json=$(NODE_NAMES="$joined_names" NODE_IPS="$joined_ips" NODE_PORTS="$joined_ports" \
                python3 - "${#names[@]}" <<'PY'
import json, sys, os
count = int(sys.argv[1])
names = os.environ["NODE_NAMES"].split("|")[:count]
ips   = os.environ["NODE_IPS"].split("|")[:count]
ports = os.environ["NODE_PORTS"].split("|")[:count]
nodes = [{"name": names[i], "ip": ips[i], "agent_port": int(ports[i])} for i in range(count)]
print(json.dumps(nodes))
PY
) || nodes_json="[]"
        fi
    fi

    # ── Write config ──────────────────────────────────────────────────────────
    echo ""
    info "Writing $CONFIG_FILE..."
    CFG_ROLE="$role" \
    CFG_THIS_IP="$this_ip" \
    CFG_MASTER_IP="$master_ip" \
    CFG_MASTER_HOST="$master_host" \
    CFG_MASTER_AGENT_PORT="${VLLM_MASTER_AGENT_PORT:-5000}" \
    CFG_AGENT_PORT="$agent_port" \
    CFG_NODES="$nodes_json" \
    CFG_CLUSTER_TOKEN="$cluster_token" \
    CFG_DISCOVERY_RANGE="$discovery_range" \
    write_config || bail "Failed to write config file."
    success "Config saved."

    # ── Surface the cluster token for master/both so operator can share ───────
    if [ "$role" = "master" ] || [ "$role" = "both" ]; then
        local saved_token
        saved_token=$(cfg_get "['cluster']['token']" "")
        if [ -n "$saved_token" ]; then
            echo ""
            info "──────────────────────────────────────────────────────────────────"
            info "  CLUSTER TOKEN (share this with child nodes during their setup):"
            echo ""
            echo "    $saved_token"
            echo ""
            info "  Discovery range: $(cfg_get "['cluster']['discovery_range']" "[]")"
            info "  Children scanning that range will discover this master via"
            info "  GET /cluster/handshake (token-gated)."
            info "──────────────────────────────────────────────────────────────────"
        fi
    fi

    # ── Install ───────────────────────────────────────────────────────────────
    echo ""
    local do_install="Y"
    if [ -z "$_noninteractive" ]; then
        read -rp "Install dependencies now? [Y/n]: " do_install
    fi
    if [[ "${do_install:-Y}" =~ ^[Yy]$ ]] || [ -z "$do_install" ]; then
        case "$role" in
            master)
                install_master_deps   # Node.js + dashboard build
                install_agent_deps    # venv + LiteLLM + agent runtime (no vLLM)
                ;;
            child)
                install_child_deps    # CUDA + vLLM + agent deps (via setup.sh)
                install_master_deps   # child also runs the dashboard (to see the full cluster)
                ;;
            both)
                install_child_deps
                install_master_deps
                ;;
        esac
    fi

    echo ""
    success "Setup complete — restarting services to pick up the new code..."
    echo ""
    # Stop-first guards against "already running" failures on re-setup. Without
    # this, pulling new code and re-running setup would leave the old agent /
    # proxy / dashboard processes in place — pre-edit code still serving.
    _CLEAN_EXIT=true  # suppress the "Press Enter" prompts from do_stop/do_start chain
    bash "$SCRIPT_DIR/dashboard/stop_dashboard.sh" 2>/dev/null || true
    bash "$SCRIPT_DIR/litellm/stop_proxy.sh"       2>/dev/null || true
    bash "$SCRIPT_DIR/agent/stop_agent.sh"         2>/dev/null || true
    _CLEAN_EXIT=false

    # ── Auto-install systemd units (opt-out: VLLM_SKIP_SYSTEMD=1) ─────────────
    # Wires services to auto-restart on crash AND auto-start on host boot.
    # do_install_systemd ends with `systemctl enable --now <units>`, so this
    # also handles the post-setup "start everything" step on systemd hosts.
    # do_install_systemd BAILS now if any unit fails to come up — so reaching
    # the self-check below means systemd reports everything active.
    if [ -z "$VLLM_SKIP_SYSTEMD" ] && _systemd_available; then
        do_install_systemd
    else
        if [ -n "$VLLM_SKIP_SYSTEMD" ]; then
            warn "VLLM_SKIP_SYSTEMD set — skipping systemd auto-restart wiring (manual start only)."
        fi
        do_start
    fi

    # ── Self-check: prove the cluster is actually working before claiming OK ──
    # Setup is not "complete" if the agent/proxy/master-connection can't be
    # verified — silently leaving a broken config is the failure mode we just
    # bit ourselves on. If self-check fails, exit non-zero so callers (CI,
    # operator scripts) see the failure.
    echo ""
    sleep 3   # give services a beat to finish initial registration
    if ! do_self_check; then
        bail "Setup wrote config and installed services, but the self-check failed (see above). Address the failures and re-run './node.sh check' to retry."
    fi

    # Mark a clean exit so the global trap doesn't print "exited unexpectedly"
    # after a fully-successful setup + self-check.
    _CLEAN_EXIT=true
}

# ── Add node ──────────────────────────────────────────────────────────────────
do_add_node() {
    [ ! -f "$CONFIG_FILE" ] && bail "No config found. Run './node.sh setup' first."
    local role
    role=$(cfg_get "['role']" "?")
    [ "$role" = "child" ] && bail "This is a child node. Run add-node from the master."

    header "Add Child Node"

    read -rp "New node IP: " new_ip
    [ -z "$new_ip" ] && bail "IP cannot be blank."
    read -rp "Node name [GPU Server]: " new_name
    new_name="${new_name:-GPU Server}"
    local default_port master_ip this_ip
    default_port=$(cfg_get ".get('agent_port', 5000)" "5000")
    master_ip=$(cfg_get "['master']['ip']" "$(detect_ip)")
    this_ip=$(cfg_get ".get('this_ip', '$(detect_ip)')" "$(detect_ip)")
    read -rp "Agent port [$default_port]: " new_port
    new_port="${new_port:-$default_port}"

    # Register in master config
    append_node_to_config "$new_name" "$new_ip" "$new_port" \
        || bail "Failed to update config."
    success "Registered '$new_name' ($new_ip:$new_port) in master config."
    info "Dashboard will show this node once its agent is running."

    # ── Check if already reachable ────────────────────────────────────────────
    echo ""
    info "Checking if agent is already running on $new_ip:$new_port..."
    if curl -sf --connect-timeout 4 "http://$new_ip:$new_port/health" &>/dev/null; then
        success "Agent at $new_ip:$new_port is already up — nothing more to do."
        read -rp "Press Enter to close..." _
        _CLEAN_EXIT=true
        return
    fi
    warn "Agent not reachable yet. The child node needs to be set up."

    # ── Generate the one-liner for the child machine ──────────────────────────
    local repo_dir
    repo_dir="$(basename "$SCRIPT_DIR")"
    # Try to get git remote URL for clone instructions
    local git_remote=""
    git_remote=$(git -C "$SCRIPT_DIR" remote get-url origin 2>/dev/null || true)

    echo ""
    echo -e "${BOLD}  ── Option A: Run manually on the child machine ─────────────────${RESET}"
    echo ""
    if [ -n "$git_remote" ]; then
        echo "    git clone $git_remote"
        echo "    cd $repo_dir"
    else
        echo "    # Copy this repo to the child machine first, then:"
        echo "    cd <repo directory>"
    fi
    echo ""
    echo -e "    ${CYAN}VLLM_NONINTERACTIVE=1 \\"
    echo -e "    VLLM_ROLE=child \\"
    echo -e "    VLLM_THIS_IP=$new_ip \\"
    echo -e "    VLLM_MASTER_IP=$master_ip \\"
    echo -e "    VLLM_AGENT_PORT=$new_port \\"
    echo -e "    ./node.sh setup${RESET}"
    echo ""

    # ── Offer SSH deployment ──────────────────────────────────────────────────
    echo -e "${BOLD}  ── Option B: Deploy via SSH (requires SSH access) ──────────────${RESET}"
    echo ""
    read -rp "  Deploy to $new_ip via SSH now? [y/N]: " do_ssh
    if [[ "${do_ssh,,}" == "y" ]]; then
        read -rp "  SSH user [$(whoami)]: " ssh_user
        ssh_user="${ssh_user:-$(whoami)}"
        read -rp "  SSH port [22]: " ssh_port
        ssh_port="${ssh_port:-22}"

        # Verify SSH works
        info "Testing SSH connection to $ssh_user@$new_ip..."
        ssh -p "$ssh_port" -o ConnectTimeout=8 -o BatchMode=yes \
            "$ssh_user@$new_ip" "echo ok" &>/dev/null \
            || bail "SSH connection failed. Ensure key-based auth is set up for $ssh_user@$new_ip."
        success "SSH connection OK."

        # Copy repo via rsync (excluding build artifacts and model cache)
        info "Copying repo to $new_ip..."
        local remote_path="/home/$ssh_user/$repo_dir"
        rsync -az --progress \
            --exclude='.next' \
            --exclude='node_modules' \
            --exclude='logs' \
            --exclude='.stack_pids' \
            --exclude='node_config.json' \
            --exclude='__pycache__' \
            -e "ssh -p $ssh_port" \
            "$SCRIPT_DIR/" \
            "$ssh_user@$new_ip:$remote_path/" \
            || bail "rsync failed."
        success "Repo copied to $new_ip:$remote_path"

        # Run setup non-interactively on the remote
        info "Running setup on $new_ip (this will take a few minutes)..."
        ssh -p "$ssh_port" -t "$ssh_user@$new_ip" \
            "cd '$remote_path' && \
             VLLM_NONINTERACTIVE=1 \
             VLLM_ROLE=child \
             VLLM_THIS_IP=$new_ip \
             VLLM_MASTER_IP=$master_ip \
             VLLM_AGENT_PORT=$new_port \
             bash ./node.sh setup" \
            || bail "Remote setup failed. Check logs on $new_ip at $remote_path/logs/node.log"

        success "Child node $new_name set up and started."

        # Verify
        sleep 3
        if curl -sf --connect-timeout 8 "http://$new_ip:$new_port/health" &>/dev/null; then
            success "Agent at $new_ip:$new_port is live!"
        else
            warn "Agent not responding yet — it may still be starting. Check dashboard in a minute."
        fi
    fi

    echo ""
    read -rp "Press Enter to close..." _
    _CLEAN_EXIT=true
}

# Pre-start auto-update: fetch from configured git remote, fast-forward pull if
# behind & clean, rebuild dashboard if dashboard/ changed. Never fatal — any
# failure downgrades to a warning and services start with the current checkout.
try_auto_pull() {
    [ ! -d "$SCRIPT_DIR/.git" ] && return 0

    local auto branch
    auto=$(cfg_get "['update'].get('auto_pull_on_start', True)" "True")
    [ "$auto" != "True" ] && return 0
    branch=$(cfg_get "['update'].get('branch', 'main')" "main")

    # Dirty working tree → skip (a pull could clobber user edits)
    if ! git -C "$SCRIPT_DIR" diff --quiet 2>/dev/null || \
       ! git -C "$SCRIPT_DIR" diff --cached --quiet 2>/dev/null; then
        warn "Skipping auto-update: local uncommitted changes in working tree"
        return 0
    fi

    info "Checking for updates on origin/$branch..."
    if ! timeout 15 git -C "$SCRIPT_DIR" fetch --quiet origin "$branch" 2>/dev/null; then
        warn "Update check failed (network or auth) — continuing with current version"
        return 0
    fi

    local old_sha new_sha
    old_sha=$(git -C "$SCRIPT_DIR" rev-parse HEAD 2>/dev/null)
    local remote_sha
    remote_sha=$(git -C "$SCRIPT_DIR" rev-parse "origin/$branch" 2>/dev/null)
    if [ "$old_sha" = "$remote_sha" ]; then
        info "Already up to date (${old_sha:0:12})"
        return 0
    fi

    # Only fast-forward. If local has diverged, bail — user must resolve manually.
    if ! git -C "$SCRIPT_DIR" merge-base --is-ancestor HEAD "origin/$branch" 2>/dev/null; then
        warn "Cannot fast-forward: local has diverged from origin/$branch. Resolve manually."
        return 0
    fi

    if ! git -C "$SCRIPT_DIR" pull --ff-only --quiet origin "$branch" 2>/dev/null; then
        warn "git pull failed — continuing with current version"
        return 0
    fi

    new_sha=$(git -C "$SCRIPT_DIR" rev-parse HEAD 2>/dev/null)
    success "Updated ${old_sha:0:12} → ${new_sha:0:12}"

    # Rebuild dashboard if dashboard/ files changed — otherwise next.js serves stale JS
    if git -C "$SCRIPT_DIR" diff --name-only "$old_sha" "$new_sha" | grep -q '^dashboard/'; then
        info "Dashboard files changed — rebuilding..."
        (
            cd "$SCRIPT_DIR/dashboard" && \
            npm install --silent >/dev/null 2>&1 && \
            npm run build >/dev/null 2>&1
        ) && success "Dashboard rebuilt." \
          || warn "Dashboard rebuild failed — start will use previous build"
    fi
}

# ── Start ─────────────────────────────────────────────────────────────────────
do_start() {
    [ ! -f "$CONFIG_FILE" ] && bail "No config found. Run './node.sh setup' first."

    local role agent_port master_ip this_ip
    role=$(cfg_get "['role']" "both")
    agent_port=$(cfg_get ".get('agent_port', 5000)" "5000")
    master_ip=$(cfg_get "['master']['ip']" "localhost")
    this_ip=$(cfg_get ".get('this_ip', 'localhost')" "localhost")
    local dashboard_port="3005"

    # Auto-offer systemd wiring on nodes that were set up before the systemd
    # integration landed. setup() auto-installs on fresh setups; this catches
    # the upgrade path. Honours VLLM_SKIP_SYSTEMD=1 (opt-out) and
    # VLLM_NONINTERACTIVE=1 (skip prompt, manual start). do_install_systemd
    # is idempotent if the user picks "yes" but units already exist.
    _maybe_offer_systemd_install

    # Delegate to systemd if it's managing these services (installed by setup).
    if _systemd_is_managed; then
        header "Starting services (role: $role, systemd-managed)"
        local units
        units=$(_systemd_units_for_role "$role")
        # shellcheck disable=SC2086
        sudo systemctl start $units
        sudo systemctl --no-pager status $units 2>&1 | grep -E "Active:|Loaded:|Main PID:" | head -20
        echo ""
        success "Start sequence complete (via systemctl)."
        echo -e "  Dashboard  →  ${CYAN}http://$this_ip:$dashboard_port${RESET}"
        echo -e "  Agent      →  ${CYAN}http://$this_ip:$agent_port${RESET}"
        local proxy_ip proxy_port
        proxy_ip=$(cfg_get "['cluster_proxy']['ip']" "$master_ip")
        proxy_port=$(cfg_get "['cluster_proxy']['port']" "4000")
        echo -e "  LiteLLM    →  ${CYAN}http://$proxy_ip:$proxy_port/v1${RESET}  (cluster entry point)"
        echo ""
        info "Live logs:  sudo journalctl -u <unit-name> -f"
        read -rp "Press Enter to close..." _
        _CLEAN_EXIT=true
        return 0
    fi

    header "Starting services (role: $role)"

    try_auto_pull

    # Agent runs on every role. Master needs it so child nodes can POST
    # /proxy/sync (which triggers _proxy_write_and_restart to regenerate the
    # LiteLLM config from the current cluster-wide instance set). Without the
    # agent on master, the proxy is stuck with whatever config it had at
    # startup and the cluster can't add/remove models dynamically.
    info "Starting control agent (port $agent_port)..."
    AGENT_PORT="$agent_port" AGENT_BIND_IP="$this_ip" bash "$SCRIPT_DIR/agent/start_agent.sh" \
        || warn "Agent start reported errors — check agent/agent.log"

    # LiteLLM cluster proxy runs only on master/both — one per cluster, not per node.
    if [ "$role" = "master" ] || [ "$role" = "both" ]; then
        info "Starting LiteLLM cluster proxy (port 4000)..."
        PROXY_BIND_IP="$this_ip" bash "$SCRIPT_DIR/litellm/start_proxy.sh" \
            || warn "LiteLLM proxy start reported errors — check logs/litellm.log"
    fi

    info "Starting dashboard (port $dashboard_port)..."
    AGENT_URL="http://localhost:$agent_port" \
    DASHBOARD_PORT="$dashboard_port" \
    bash "$SCRIPT_DIR/dashboard/start_dashboard.sh" \
        || warn "Dashboard start reported errors — check dashboard/dashboard.log"

    echo ""
    success "Start sequence complete."
    echo -e "  Dashboard  →  ${CYAN}http://$this_ip:$dashboard_port${RESET}"
    echo -e "  Agent      →  ${CYAN}http://$this_ip:$agent_port${RESET}"
    local proxy_ip proxy_port
    proxy_ip=$(cfg_get "['cluster_proxy']['ip']" "$master_ip")
    proxy_port=$(cfg_get "['cluster_proxy']['port']" "4000")
    echo -e "  LiteLLM    →  ${CYAN}http://$proxy_ip:$proxy_port/v1${RESET}  (cluster entry point)"
    echo ""
    read -rp "Press Enter to close..." _
    _CLEAN_EXIT=true
}

# ── Stop ──────────────────────────────────────────────────────────────────────
do_stop() {
    # Delegate to systemd if it's managing these services.
    if _systemd_is_managed; then
        header "Stopping local services (systemd-managed)"
        local role units
        role=$(cfg_get "['role']" "both")
        units=$(_systemd_units_for_role "$role")
        # shellcheck disable=SC2086
        sudo systemctl stop $units
        # Also clean up any rogue vllm processes (the agent's watchdog won't
        # restart them once the agent is stopped — but a manual `vllm serve`
        # outside the agent path won't be tracked).
        [ -f "$SCRIPT_DIR/stop_inference_stack.sh" ] && bash "$SCRIPT_DIR/stop_inference_stack.sh" || true
        success "Done. (Services will NOT auto-restart until you 'start' or reboot.)"
        info "To disable auto-restart on boot permanently: ./node.sh remove-systemd"
        read -rp "Press Enter to close..." _
        _CLEAN_EXIT=true
        return 0
    fi

    header "Stopping local services"
    [ -f "$SCRIPT_DIR/dashboard/stop_dashboard.sh" ]    && bash "$SCRIPT_DIR/dashboard/stop_dashboard.sh"    || true
    [ -f "$SCRIPT_DIR/litellm/stop_proxy.sh" ]          && bash "$SCRIPT_DIR/litellm/stop_proxy.sh"          || true
    [ -f "$SCRIPT_DIR/agent/stop_agent.sh" ]            && bash "$SCRIPT_DIR/agent/stop_agent.sh"            || true
    [ -f "$SCRIPT_DIR/stop_inference_stack.sh" ]        && bash "$SCRIPT_DIR/stop_inference_stack.sh"        || true
    success "Done."
    read -rp "Press Enter to close..." _
    _CLEAN_EXIT=true
}

# ── Status ────────────────────────────────────────────────────────────────────
do_status() {
    [ ! -f "$CONFIG_FILE" ] && bail "No config found. Run './node.sh setup' first."

    local role agent_port
    role=$(cfg_get "['role']" "?")
    agent_port=$(cfg_get ".get('agent_port', 5000)" "5000")

    header "Local services (role: $role)"

    if [ "$role" != "master" ]; then
        if curl -sf --connect-timeout 3 "http://localhost:$agent_port/health" &>/dev/null; then
            success "Agent      :$agent_port  UP"
        else
            warn "Agent      :$agent_port  DOWN"
        fi
    fi

    if [ "$role" != "child" ]; then
        local dp
        local dp="3005"
        if curl -sf --connect-timeout 3 "http://localhost:$dp" &>/dev/null; then
            success "Dashboard  :$dp  UP"
        else
            warn "Dashboard  :$dp  DOWN"
        fi

        local pp
        pp=$(cfg_get "['cluster_proxy']['port']" "4000")
        if curl -sf --connect-timeout 3 --header 'Authorization: Bearer none' "http://localhost:$pp/v1/models" &>/dev/null; then
            success "LiteLLM    :$pp  UP"
        else
            warn "LiteLLM    :$pp  DOWN"
        fi
    fi

    if [ "$role" != "child" ]; then
        header "Child nodes"
        local any=false
        while IFS='|' read -r name ip port; do
            any=true
            if curl -sf --connect-timeout 3 "http://$ip:$port/health" &>/dev/null; then
                echo -e "  ${GREEN}✓${RESET}  $name  ($ip:$port)  UP"
            else
                echo -e "  ${RED}✗${RESET}  $name  ($ip:$port)  unreachable"
            fi
        done < <(cfg_nodes)
        [ "$any" = "false" ] && echo "  (no child nodes registered — run './node.sh add-node')"
    fi

    echo ""
    read -rp "Press Enter to close..." _
    _CLEAN_EXIT=true
}

# ── Logs ──────────────────────────────────────────────────────────────────────
do_logs() {
    echo ""
    echo -e "${BOLD}Log file:${RESET} $LOG_FILE"
    echo ""
    if [ ! -s "$LOG_FILE" ]; then
        echo "  (log is empty)"
    else
        # Show last 60 lines with line numbers
        tail -n 60 "$LOG_FILE" | nl -ba
        echo ""
        echo "  Full log: $LOG_FILE"
        echo "  Live tail: tail -f $LOG_FILE"
    fi
    echo ""
    read -rp "Press Enter to close..." _
    _CLEAN_EXIT=true
}

# ── Menu ──────────────────────────────────────────────────────────────────────
show_menu() {
    if [ ! -f "$CONFIG_FILE" ]; then
        info "No config found — starting first-time setup."
        sleep 1
        do_setup
        return
    fi

    local role
    role=$(cfg_get "['role']" "?")

    echo -e "\n${BOLD}  vLLM Node Manager${RESET}  (role: $role)\n"
    echo "    1)  start      start all local services"
    echo "    2)  stop       stop all local services"
    echo "    3)  status     check what's running"
    echo "    4)  add-node   register a new child node"
    echo "    5)  setup      reconfigure this node"
    echo "    6)  logs       view recent log output"
    echo "    q)  quit"
    echo ""
    read -rp "  Choice: " choice
    case "${choice,,}" in
        1|start)    do_start    ;;
        2|stop)     do_stop     ;;
        3|status)   do_status   ;;
        4|add-node) do_add_node ;;
        5|setup)    do_setup    ;;
        6|logs)     do_logs     ;;
        q|quit)     _CLEAN_EXIT=true; exit 0 ;;
        *)          show_menu   ;;
    esac
}

# ── Entry point ───────────────────────────────────────────────────────────────
CMD="${1:-menu}"
case "$CMD" in
    setup)            do_setup            ;;
    start)            do_start            ;;
    stop)             do_stop             ;;
    add-node)         do_add_node         ;;
    status)           do_status           ;;
    logs)             do_logs             ;;
    install-systemd)  do_install_systemd  ;;
    remove-systemd)   do_remove_systemd   ;;
    check|self-check) _CLEAN_EXIT=true; do_self_check ;;
    *)                show_menu           ;;
esac
