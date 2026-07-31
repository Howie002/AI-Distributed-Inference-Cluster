#!/usr/bin/env bash
# boot.sh — headless bring-up for this node's cluster control plane.
#
# Standardized name across the Foundation AI fleet so the Phase 9.3 boot
# orchestrator (foundation-ai-dashboard/ops/rolling-start.py) and the fleet
# watchdog (ops/watchdog.py) can start/recover this the same way as every tool.
#
# What it brings up, role-aware (role read from node_config.json):
#   every role      — the control agent (:5000 by default)
#   master / both   — plus the cluster LiteLLM proxy (:4000), via the agent's
#                     /proxy/sync, which regenerates litellm/cluster_config.yaml
#                     from the instances actually running across the cluster.
#
# It deliberately does NOT start the proxy by hand. The repo-root
# litellm_config.yaml is a DEPRECATED legacy single-box artifact; the live
# config is litellm/cluster_config.yaml and only the agent may write it.
#
# Idempotent and non-interactive: safe to run when things are already up (the
# watchdog relaunches this on health failure), and never prompts. Waits are
# bounded so the whole script finishes inside the orchestrator's health window.
#
# NOTE: this is boot bring-up only. `./node.sh install-systemd` additionally
# installs vllm-cluster-{agent,dashboard,litellm}.service for crash-restart at
# the OS level; that needs sudo. The two are complementary, not exclusive: with
# the systemd units installed, this script's work is a fast no-op.

set -uo pipefail   # NOT -e: health probes are expected to fail while starting.

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$REPO_DIR"

CONFIG_FILE="$REPO_DIR/node_config.json"

# ── Read role / ports out of node_config.json (with safe fallbacks) ──────────
read_cfg() {
  python3 - "$CONFIG_FILE" <<'PY' 2>/dev/null
import json, sys
try:
    c = json.load(open(sys.argv[1]))
except Exception:
    c = {}
role  = c.get("role", "both")
agent = c.get("agent_port") or (c.get("master") or {}).get("agent_port") or 5000
proxy = (c.get("cluster_proxy") or {}).get("port") or 4000
print(f"{role} {agent} {proxy}")
PY
}

read -r ROLE AGENT_PORT PROXY_PORT <<<"$(read_cfg)"
ROLE="${ROLE:-both}"; AGENT_PORT="${AGENT_PORT:-5000}"; PROXY_PORT="${PROXY_PORT:-4000}"

log() { echo "[boot $(date +%H:%M:%S)] $*"; }

# HTTP status for a URL, or 000 if unreachable. Note: curl already prints 000
# on a connection failure AND exits non-zero, so a `|| echo 000` fallback would
# emit "000000" — which compares unequal to "000" and reads as success. Capture
# the body and normalise only the empty case instead.
code_for() {
  local c
  c="$(curl -s -o /dev/null -m 4 -w '%{http_code}' "$1" 2>/dev/null)"
  echo "${c:-000}"
}

# Poll until a URL answers with any HTTP status (server up), bounded.
wait_http() {
  local url="$1" limit="$2" waited=0 code
  while [ "$waited" -lt "$limit" ]; do
    code="$(code_for "$url")"
    [ "$code" != "000" ] && { echo "$code"; return 0; }
    sleep 2; waited=$((waited + 2))
  done
  echo 000; return 1
}

log "role=$ROLE agent_port=$AGENT_PORT proxy_port=$PROXY_PORT"

# ── 1. Control agent ────────────────────────────────────────────────────────
AGENT_HEALTH="http://localhost:${AGENT_PORT}/health"
if [ "$(code_for "$AGENT_HEALTH")" = "200" ]; then
  log "agent already healthy on :${AGENT_PORT}"
else
  log "starting control agent on :${AGENT_PORT} ..."
  # start_agent.sh backgrounds the agent and exits; it clears its own stale PID
  # file, and exits non-zero if a LIVE agent is already running (harmless here).
  AGENT_PORT="$AGENT_PORT" setsid bash "$REPO_DIR/agent/start_agent.sh" </dev/null >/dev/null 2>&1 || true
  if [ "$(wait_http "$AGENT_HEALTH" 12)" = "000" ]; then
    log "ERROR: agent did not come up on :${AGENT_PORT} — see agent/agent.log"
    exit 1
  fi
  log "agent up on :${AGENT_PORT}"
fi

# ── 2. Cluster LiteLLM proxy (master/both only) ─────────────────────────────
if [ "$ROLE" != "master" ] && [ "$ROLE" != "both" ]; then
  log "role=$ROLE hosts no proxy — control plane ready"
  exit 0
fi

PROXY_HEALTH="http://localhost:${PROXY_PORT}/v1/models"

# Always sync: the agent rebuilds the config from live cluster instances, and
# the call is a deliberate no-op when the config is unchanged AND the proxy is
# already alive — so this both starts a missing proxy and corrects a config
# left stale by nodes that changed while this box was down.
log "requesting proxy sync ..."
curl -s -m 15 -X POST "http://localhost:${AGENT_PORT}/proxy/sync" \
  -H 'Content-Type: application/json' -d '{}' >/dev/null 2>&1 || \
  log "WARN: /proxy/sync call failed; relying on the agent's periodic reconcile"

PROXY_CODE="$(wait_http "$PROXY_HEALTH" 16)"
if [ "$PROXY_CODE" = "000" ]; then
  # Not fatal: the agent reconciles the proxy every 60s, so this self-heals
  # shortly after boot even if the models were slow to register.
  log "WARN: proxy not serving on :${PROXY_PORT} yet — agent will reconcile within 60s"
  exit 1
fi

MODELS="$(curl -s -m 8 -H 'Authorization: Bearer none' "$PROXY_HEALTH" 2>/dev/null \
  | python3 -c 'import json,sys; print(",".join(m["id"] for m in json.load(sys.stdin).get("data",[])) or "NONE")' 2>/dev/null)"
log "proxy up on :${PROXY_PORT} (http $PROXY_CODE) models=${MODELS:-unknown}"

# ── 3. Cluster web dashboard (master/both only) ─────────────────────────────
# Added 2026-07-31: the dashboard (:3005) was in NEITHER systemd NOR this boot
# path — same failure class as foundation-after-hours on 07-29 — so the 07-27
# patch reboot left it down and no sweep counted it (its last log entry was
# 07-01; found only when a user asked). Folding it in here means the boot
# orchestrator AND any watchdog recovery of this entry bring it back. Residual
# gap on the record: the watchdog health-checks only :${PROXY_PORT}, so a solo
# :3005 death still goes unnoticed until the next boot.sh run.
DASH_PORT="${DASHBOARD_PORT:-3005}"
DASH_URL="http://localhost:${DASH_PORT}/"
if [ "$(code_for "$DASH_URL")" != "000" ]; then
  log "dashboard already serving on :${DASH_PORT}"
else
  log "starting cluster dashboard on :${DASH_PORT} ..."
  # start_dashboard.sh backgrounds `next start`, writes its own PID file, and
  # clears a stale one; it exits non-zero only if a LIVE instance already runs.
  setsid bash "$REPO_DIR/dashboard/start_dashboard.sh" </dev/null >/dev/null 2>&1 || true
  if [ "$(wait_http "$DASH_URL" 20)" = "000" ]; then
    # Not fatal for the control plane — inference is unaffected by the web UI.
    log "WARN: dashboard did not come up on :${DASH_PORT} — see dashboard/dashboard.log"
  else
    log "dashboard up on :${DASH_PORT}"
  fi
fi
