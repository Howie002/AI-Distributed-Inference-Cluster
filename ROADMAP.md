# AI Distributed Inference Cluster — Roadmap

**Repo:** [github.com/Howie002/AI-Distributed-Inference-Cluster](https://github.com/Howie002/AI-Distributed-Inference-Cluster) (private, active on `dev`)
**Last Synced:** 2026-06-24
**Current Phase:** v2 Cluster — operational hardening + analytics follow-on
**Target Production:** Ongoing operational service

Living document. Software feature work in "In Progress" and phased sections below. Deployment/ops-level tasks in the first section. Nothing is scheduled — items get picked up as capacity allows.

---

## Carry-overs from 2026-06-24

- [ ] **Master pull one-time intervention** — master is N commits behind with persistent runtime writeback. The `force=true` option on `/update/pull` lives in the unpulled commits, so unblocking it needs one SSH session: `git stash push --include-untracked && git pull && curl -X POST http://localhost:5000/agent/restart`. After that, future updates run via `curl -X POST http://10.2.35.10:5000/update/pull?force=true` with no SSH required.
- [ ] **Diagnose Deat Star vLLM zombie accumulation** — discovered 30+ stale `vllm serve` processes from past 4-7 days holding ~40 GB combined RSS, not tracked by the agent's `/instances` list. Watchdog should have caught these but didn't. Open question: under what conditions does a vLLM launch leak its PID past `_reclaim_vram_before_launch`'s scope? Pattern matters because it cost ~5x memory pressure today and broke 31B's reload.
- [ ] **31B failing silent-exit during APIServer init on Deat Star** — after the zombie sweep, `google/gemma-4-31B` won't relaunch on GPU 3 (also tried GPU 0 by request). vLLM exits cleanly before spawning EngineCore subprocess, no error in log, just `resource_tracker: leaked semaphore` warnings. Earlier today's successful run was on the same hardware before the bulk SIGKILL. Theory: multiprocessing semaphore namespace disturbed by the kill sweep. Removed 31B from `intended_instances.json` so watchdog stops cycling. Investigation: try a Deat Star reboot to reset the multiprocessing namespace, OR add `--disable-frontend-multiprocessing` to the launch, OR investigate `/dev/shm` cleanup.
- [ ] **Verify the new chat_template flag end-to-end** — agent now accepts `chat_template`, `enable_auto_tool_choice`, `tool_call_parser` in `extra_flags`. Canonical Gemma template lives at `agent/chat_templates/gemma.jinja`. Code change is correct (visible in argv) but couldn't verify a successful chat completion against 31B today because of the load failure above. Worth a quick test on a smaller base model.
- [ ] **Default the dashboard testing tab to `gemma-4-26b-a4b-nvfp4` for chat** — it's chat-tuned and works natively. The testing tab errored when pointed at gemma-4-31b today (base model + no chat template). UI fix: detect base models in the model list and either disable chat-completions mode or auto-route to `/v1/completions`.
- [ ] **LiteLLM `encoding_format` quirk on `/v1/embeddings`** — the proxy injects `encoding_format=None`, vLLM 400s. Today's workaround: consumers send `encoding_format: "float"` explicitly. Fix path: either set `drop_params: true` on the embedding model in `cluster_config.yaml`, or add a request transform. Land this so the README doesn't have to teach the quirk to every consumer.
- [ ] **Document the proxy quirks in a single source consumers can find** — gemma-4-31b is a base model (use `/v1/completions` with Gemma turn markers), nomic-embed-text-v1-5 needs `encoding_format: "float"`, gemma-4-31b's max context is 32K and 26B's is 100K, embedding model max context is 2048 (not 8192 as commonly assumed). Right now this lives only in `docs/Notes.md` 2026-06-24 entry. Add a `docs/UsingTheProxy.md` to the repo so the next developer doesn't have to spelunk.
- [ ] **Dashboard `dev` branch on GitHub is ahead of local** — someone (CI? webhook? earlier session?) pushed to `origin/dev` independently. Local push to `dev` rejected. Fetch + reconcile before next dev-branch work.

---

## Active Deployment Tasks

Operational tasks layered on top of the running cluster. Not code features — hardware, DNS, security.

### Needs DNS / Network Access
- [ ] Configure `aidev.txamfoundation.com` — point DNS to cluster master
- [ ] Set up proxy host in Nginx Proxy Manager (:81) → dashboard with SSL / Let's Encrypt
- [ ] Lock down port exposure via firewall — dashboard, proxy, agent ports should not be publicly routable

### Production Hardening
- [ ] Schedule regular VM / node snapshots for disaster recovery
- [ ] GPU monitoring — connect analytics JSONL to a persistent dashboard (Grafana or similar)
- [ ] Migrate SQLite → PostgreSQL when user volume grows (if applicable to dashboard state)

### Z Workstation Pilot (Parallel Project)
*See separate `HP Z Workstation Pilot` project — infrastructure listed here for cross-reference.*
- [ ] Confirm pilot loaner delivery date and specs with HP
- [ ] Onboard hardware — OS, NVIDIA drivers, CUDA, vLLM agent
- [ ] Benchmark vs. DGX Sparks using the dashboard
- [ ] Connect to Foundation Snowflake AI app as inference target
- [ ] Purchase decision: 2× workstations, 2 cards each if validated

---

## Active Issues / UX Gaps

### 🟢 *(Shipped 2026-06-17)* Auto-discovery of cluster nodes + DNS-aware resolution

**Status:** Resolved (agent + node.sh layers). Webapp wizard for setup/settings: agent endpoints shipped, dashboard UI deferred to next sprint.

**Problem solved**
- Every re-IP (DHCP renewal, subnet change like the recent Death Star `10.2.30.28` → `10.2.30.30` → `10.2.35.20` thrash) used to require manual edits to every node's `node_config.json`. Hardcoded master IPs made the cluster brittle.
- No human-friendly node naming — the dashboard showed `10.2.35.28` instead of `Death Star`.

**What landed**
- **Cluster token + discovery range schema** in `node_config.json` under a new `cluster` key. Backward-compat: legacy `master.ip`-only configs still work; the new fields are optional.
- **`GET /cluster/handshake`** endpoint — token-gated. Children call this against every IP in their discovery range; matching responses identify masters.
- **`POST /cluster/register`** endpoint — token-gated. Children post their address to the master after discovery.
- **`GET /cluster/nodes`** endpoint — read-only view of currently-registered children (hostname + IP + port + role + last-seen timestamp).
- **Discovery thread** (`_discovery_loop`) on child/both roles. Scans up to 1024 IPs per pass with a 32-way thread pool. Fast path: re-verifies known master every 60 s; slow path: full scan when verify fails. Self-heals on re-IP.
- **DNS-aware resolution** — `_resolve_to_ip()` / `_resolve_to_hostname()` helpers with 60 s TTL cache. `master.ip` field now accepts hostnames; agent re-resolves on each connection so DNS changes take effect without config edits. Hostnames surface in `/cluster/nodes` for the dashboard.
- **`node.sh setup` prompts** added for cluster token (auto-generated on master, paste from master on child) and discovery range (defaults to /24 derived from `this_ip`). Token displayed at end of master setup so operator can share with children.
- **Webapp setup wizard — agent side complete**: `GET /setup/state`, `POST /setup/complete`, `GET /settings`, `PUT /settings`. Dashboard UI (the actual wizard pages in Next.js) is the remaining work — these endpoints are ready to drive it.

**Acceptance demonstrated**
- New `cluster_token` auto-generates on master setup (16 random hex bytes via `secrets.token_hex(16)`).
- Discovery range auto-derives from `this_ip` when operator presses Enter.
- Existing nodes without cluster fields keep working via the legacy `master.ip` path (the discovery thread cleanly skips if no token is configured).
- `_check_cluster_token` uses `secrets.compare_digest` so timing attacks aren't a concern.

**Carry-over follow-ups**
- **Dashboard UI for setup wizard + settings panel** — agent has the endpoints; just needs a Next.js page that hits them. Multi-step form, validation, hostname picker for master, copyable token output. Track as its own sprint.
- **Master role: surface `/cluster/nodes` in the dashboard's main view** — replace any remaining hardcoded node-table data with a live read of registered children.
- **Cluster-token rotation** — once a token is set, there's no rotation primitive yet. Add `POST /cluster/rotate-token` (master-only, requires current token) that returns the new value and invalidates old children.

---

### 🟢 *(Shipped 2026-06-10)* systemd auto-restart + boot-time bring-up

**Status:** Resolved. `node.sh setup` now wires the cluster into systemd by default. Reboot → cluster comes back. Agent/dashboard/proxy crash → systemd restarts within 10 s.

**What landed**
- Three role-aware systemd units written by `node.sh setup`:
  - `vllm-cluster-agent.service` (every role)
  - `vllm-cluster-dashboard.service` (every role)
  - `vllm-cluster-litellm.service` (master + both only)
- `Type=forking`, `Restart=on-failure`, `RestartSec=10`, `StartLimitBurst=3` over 120 s — protects against crash-loop thrashing
- `After=network-online.target` so DNS / agent-to-master discovery is ready before bring-up
- `WantedBy=multi-user.target` so services come back on boot
- `node.sh start/stop` detect systemd-managed mode and delegate to `systemctl` — no more dual-startup races
- Opt-out via `VLLM_SKIP_SYSTEMD=1 ./node.sh setup` for containers / dev machines without systemd
- New subcommands: `./node.sh install-systemd` (retrofit existing install), `./node.sh remove-systemd` (uninstall cleanly)

**Operational impact**
- Brand-new Death Star: `git clone … && ./node.sh setup` → answer role questions → one sudo prompt → cluster fully operational AND survives reboots / crashes. No second command.
- Existing nodes: re-run `./node.sh setup` (idempotent) or `./node.sh install-systemd` to opt in.

**Carry-over follow-ups** (not blocking, captured for future)
- Move the auto-update `git pull` step (currently in `try_auto_pull` inside `do_start`) into a separate timer-driven systemd unit so the agent doesn't have to restart to pick up upstream changes
- Surface systemd status in the dashboard (currently invisible — operators have to `systemctl status` from a shell)
- `node.sh status` could also surface systemd state alongside the existing per-service curl checks

---

### 🔴 vLLM restart loop on Blackwell — CUDA 12.8 too old for SM 12.0 + watchdog masks the failure

**Priority:** Critical — cluster cannot serve any NVFP4 model on RTX PRO 6000 Blackwell hardware
**Reported:** 2026-06-05
**Hardware:** Death Star (`10.2.35.20`) — 4× NVIDIA RTX PRO 6000 Blackwell Max-Q Workstation Edition (SM 12.0)
**Software:** `node.sh setup` auto-installs `cuda-toolkit-12-8`; driver-side CUDA is 13.0

**Symptom**
Master sends `POST /instances/launch` to the child agent. vLLM serve process spawns, loads weights successfully (~17.5 GiB shards in ~8 s), enters NVFP4 MoE backend setup, then **dies silently** with no error written to its dynamic log. Watchdog from `5716ba1` detects the dead process and spawns a fresh one. New process truncates the log, repeats. **Four full generations of vLLM PIDs observed in ~15 minutes** with zero serving and no diagnostic trace preserved.

**Why this is two bugs at once**
1. **CUDA toolkit version mismatch (root cause)** — vLLM logs `Failed to get device capability: SM 12.x requires CUDA >= 12.9` twice during init, then falls back from `FLASHINFER_*` NVFP4 backends to `VLLM_CUTLASS`. The fallback kernels apparently crash silently when they hit the loaded weights or during cudagraph capture. The `node.sh setup` script's auto-install of `cuda-toolkit-12-8` is **wrong for any SM 12.x hardware**.
2. **Watchdog hides the crash (secondary)** — the `2b7897b` "Launch failure surfacing" path catches launch-time failures via the `EARLY_FAIL_WAIT_S` babysitter, but doesn't catch a process that dies *after* the agent has reported launch success. The new watchdog (`5716ba1`) immediately respawns the dead process, which truncates the dynamic log — destroying the only forensic evidence of why it died.

**What's missing**
- `node.sh setup` does not detect GPU compute capability before picking the CUDA toolkit version
- Watchdog has no rate-limiting / backoff on restart attempts (instant respawn = continuous log churn)
- Dynamic logs are overwritten on each launch rather than rotated (`dynamic_<port>.log.1`, `.2`, etc.)
- No "crash mode" — after N consecutive crash-loop iterations, watchdog should stop respawning and surface the failure to the master rather than thrash

**Acceptance criteria**
- [ ] `node.sh setup` reads the highest GPU compute capability from `nvidia-smi --query-gpu=compute_cap` and picks toolkit accordingly:
  - SM ≤ 9.0 → `cuda-toolkit-12-8`
  - SM 10.x → `cuda-toolkit-12-9`
  - **SM 12.x (Blackwell) → `cuda-toolkit-13-0` or `cuda-toolkit-12-9` minimum**
- [ ] Setup also re-checks an existing install; if installed toolkit is older than what the hardware requires, warn and offer to upgrade in place (not just skip)
- [ ] Dynamic logs rotate, not truncate: keep last N attempts as `dynamic_<port>.log.<N>` for postmortem
- [ ] Watchdog adds exponential backoff: 5 s → 30 s → 2 min → 5 min between restart attempts
- [ ] Watchdog enters "crash-loop detected" state after 3 consecutive failures within 5 min — stops respawning, marks the instance failed at the master via `POST /instances/{port}/failed` (new endpoint), and includes the preserved log tail
- [ ] `/diagnose` (from `ce12428`) surfaces "this model crashed-looped N times today" so operators can see the pattern in one place

**Workaround until fix lands (Blackwell-specific)**
- Manually upgrade toolkit: `sudo apt install cuda-toolkit-13-0` (matches the 13.0 driver)
- If crash persists after upgrade: launch with `--enforce-eager` to skip cudagraph capture (slower but lets the model serve while the real fix is being investigated)
- Until either workaround is verified, do NOT auto-launch NVFP4 models from the master on Blackwell nodes — manual launches only with full log capture (`./vllm serve ... 2>&1 | tee /tmp/vllm-manual.log`)

**Cross-references**
- Origin context: Death Star re-IP from `10.2.30.28` → `10.2.35.20` (2026-06-05); fresh `node.sh setup` ran the (wrong) `cuda-toolkit-12-8` install
- Related: Phase 6 *Device-profile setup presets* — this is the same problem space, but for a CRITICAL bug rather than ergonomics. Solving the auto-detect for the toolkit version is a subset of the device-profile preset work.

---

### 🔴 Model launch feedback is opaque — "Launching…" with no progress or failure signal

**Priority:** High — blocks confident operation of the cluster
**Reported:** 2026-04-20
**Repro:** Launch `llama-3-3-nemotron-super-49b` (fp8, 50 GB weights) on The Deathstar GPU 2 via the Deploy modal (80% memory, 32768 max context, 256 parallel slots). Modal sits on "Launching…" for a long time with no indication of what is happening. In at least one case the load silently failed and the user had no idea whether the model was still loading, stuck, or dead.

**What's missing**
- No visible stages during model load (spawning → loading weights → warming up → ready)
- No live log tail from the vLLM subprocess in the launch modal
- No progress indicator tied to load phase (weights into VRAM, KV cache init, server ready)
- Silent failures — if vLLM crashes during startup, the dashboard does not surface the error or stderr
- No timeout / "still working…" indicator when a launch is taking longer than expected
- No cancel button once a launch has started

**Acceptance criteria**
- [ ] Launch modal shows live status: `Spawning process` → `Loading config` → `Allocating GPU memory` → `Loading weights (X%)` → `Warming up` → `Ready`
- [x] Live tail of vLLM stdout/stderr (last ~20 lines) in the launch modal while launching — `LaunchLogModal` ships in [387086b](387086b)
- [x] Failure state surfaces the error with a stderr snippet and a "View full log" link — agent's `/instances/launch` now babysits the spawned process for `EARLY_FAIL_WAIT_S` seconds, returns HTTP 422 with structured `{message, exit_code, log_tail, log_path}` on startup crash; `DeployModal` renders the panel inline. *(2026-05-13)*
- [ ] Cancel button available throughout launch; kills the spawned process and cleans up GPU allocation
- [ ] If no stdout is observed for >30 s, UI shows `No activity for 30s — last stage: X` so user knows it is not frozen
- [x] After launch completes, modal auto-dismisses on success and persists on failure — failure path keeps the modal open with the error/log; the success path closes as before. *(2026-05-13)*

**Side-effect of the failure-surfacing work — auto-retry for chunked-MM models**
When vLLM fails with the specific `Chunked MM input disabled but max_tokens_per_mm_item (N) is larger than max_num_batched_tokens (M)` error (e.g. Gemma-4 multimodal), the agent now parses N out of the log, retries the launch once with `--max-num-batched-tokens=max(N, 4096)`, and surfaces the auto-retry result in the response. Prevents the same silent crash that motivated the failure-surfacing fix from happening on the very next try. *(2026-05-13)*

---

### 🟡 No way to forensically diagnose orphaned vLLM workers or RAM leaks during a spike

**Priority:** Medium — needed whenever the agent reports `instances: []` but system RAM or VRAM is still pinned
**Reported:** 2026-05-13 (post-restart incident on a child node: system RAM spiked to 100% while the agent reported no running instances)
**Context:** On DGX Spark (GB10) unified-memory hardware GPU and system RAM share the same physical pool, so an allocation the agent has lost track of looks like a system-wide RAM leak. Three known mechanisms can leave allocations un-owned:
1. **Reparented vLLM workers** — tensor-parallel children reparented to PID 1 when the parent process is `SIGKILL`ed (OOM killer, hard restart). `./node.sh stop` does not kill them because the agent never tracked their PIDs.
2. **PID-file desync** — vLLM spawned and allocated memory but the agent's tracking file was never written, or was deleted by a concurrent `stop`.
3. **`/dev/shm` and SysV shm leaks** — KV-cache and IPC shared-memory segments not cleaned up after a crash. On unified memory these directly count as system RAM.

Today the only path is to SSH into the node and run `nvidia-smi --query-compute-apps`, `ps --ppid 1`, `ls /dev/shm/`, and `ipcs -m` by hand and cross-reference against the agent's `instances` list.

**Acceptance criteria**
- [x] New `/diagnose` route on the agent returns JSON with: GPU compute apps from `nvidia-smi --query-compute-apps=pid,process_name,used_memory`, reparented Python/vLLM processes (`PPID == 1`), `/dev/shm` segments (path, size, mtime), SysV shared-memory segments from `ipcs -m`, and a side-by-side comparison of what the agent's `instances` list owns vs. what's actually allocated — `agent.py @app.get("/diagnose")`. *(2026-05-13)*
- [x] Dashboard surfaces a "Diagnose" action on each node card that calls this route and renders the result, highlighting anything unowned — `DiagnoseModal` reachable from `NodeCard` header. *(2026-05-13)*
- [ ] Follow-on: "Reap orphan" action that kills reparented workers and clears unowned shm segments after a confirm dialog (gated behind a setting, since false positives could kill a legitimate process the agent is mid-launching)

---

### 🟠 Dashboard UI performance & stability hardening

**Priority:** Next up — these are the highest-leverage UI perf and resilience fixes surfaced by a code review on 2026-05-07. Each item is independently shippable.

**Critical**
- [x] **Stop tearing down ModelLibrary poll intervals on every parent render** — [`dashboard/src/components/ModelLibrary.tsx`](dashboard/src/components/ModelLibrary.tsx). Memoized `onlineNodes` against a stable string signature of online node keys; `useCallback`/`useEffect` deps no longer invalidate every render, so cache (15 s) and download (2 s) intervals stay alive across status ticks. *(2026-05-07)*

**High**
- [x] **Status poll: skip-if-busy + latest-only guard** — [`dashboard/src/app/page.tsx`](dashboard/src/app/page.tsx). Added `inFlightRef` to drop overlapping ticks and a monotonic `requestIdRef` so a slow tick that lands after a newer one can't overwrite state. *(2026-05-07)*
- [x] **Fetch timeout on `/api/nodes/edit` and `/api/nodes/rename` proxy paths** — [`edit/route.ts`](dashboard/src/app/api/nodes/edit/route.ts), [`rename/route.ts`](dashboard/src/app/api/nodes/rename/route.ts). Wrapped the child→master PATCH in `AbortSignal.timeout(8000)` and return `504` with a clear message on unreachable master. (`add/route.ts` has no proxy fetch.) *(2026-05-07)*
- [x] **"Restart dashboard" polls for health instead of sleeping 60 s** — [`dashboard/src/components/NodeCard.tsx`](dashboard/src/components/NodeCard.tsx). Polls a relative `/api/nodes` (when on this node's dashboard) or the agent's `/status` (cross-node), waits for down→back transition, max 3 minutes, surfaces failure instead of force-reloading a broken page. *(2026-05-07)*

**Medium**
- [x] **Atomic config writes** — `edit/`, `add/`, `rename/` route handlers now go through a `writeJsonAtomic(path, data)` helper that writes to `node_config.json.tmp` and `renameSync`s into place. Crash mid-write no longer corrupts the canonical config. *(2026-05-07)*
- [x] **Removed dead `useEffect`** — [`dashboard/src/components/SettingsView.tsx`](dashboard/src/components/SettingsView.tsx) and its now-unused `useEffect` import. *(2026-05-07)*

**Low (deferred — pick up if larger clusters expose jank)**
- `React.memo` wrappers for `ClusterServiceList`, `NodeCard`, `ClusterGPUView` so the 15 s status tick doesn't re-render every row.
- AnalyticsView: split the four chart memos so changing one input doesn't recompute all four.
- AddNodeModal "Copied!" `setTimeout` cleanup — minor unmounted-setState warning.
- SettingsView `pullNode`: useRef-backed in-flight set keyed by node, to harden against the small double-click race window the disabled state already mostly covers.

---

## Recently Completed

- **Model Library v2 — per-node download & disk management** — every library row now shows per-node cache status with on-disk size, Download/Delete buttons, and live pre-pull progress bars polled from `/models/hf/downloads`. Top strip shows per-node disk headroom with a warning above 85% usage
- **HuggingFace token management** — per-node token set/clear from the dashboard; tokens are written to `~/.cache/huggingface/token` on the actual node and masked in the UI
- **HF link-based importer** — paste a HuggingFace URL or `org/repo`; agent's `/models/hf/lookup` hits the HF API and prefills params, VRAM estimate, quant guess, context length, type, and license; user reviews before saving to the library
- **Kill silent HF gating** — `/models/hf/preflight` + `auth_check` integration in `/instances/launch` now blocks gated-and-unauthorized deploys with a readable 403 error instead of letting vLLM fail silently in its own log
- **Analytics tab** — per-node 1-minute sampler writes append-only JSONL; DuckDB aggregates to any resolution at query time; 30-day retention with daily file rotation; dashboard charts GPU utilization, requests/bucket (stacked by model), prompt+generation tokens, TTFT p95, plus cluster totals and queue-depth peak
- **Cluster-wide LiteLLM proxy** — single proxy on master serves every node's vLLM instances under one URL; agents register models dynamically using their real node IP; per-node proxy config retired; node.sh lifecycle starts/stops the proxy on master/both roles
- **Cluster-unified GPU view** — all GPUs from all nodes in one flat grid; node badge per card; click to expand for temperature, power, clock, fan
- **Cluster-unified service list** — all vLLM instances across nodes in one table; expandable rows with context length, quant, tensor parallel, direct endpoint
- **Cross-cluster deployment** — Deploy modal picks GPUs from any node; `targetNode` derived from the selected GPU
- **Child node cluster view** — child dashboards fetch the full node list from the master and show the whole cluster, not just their own GPUs
- **Unified memory GPU support** — DGX Spark GB10 / GB200 unified memory detected automatically; falls back to `torch.cuda.mem_get_info()` / psutil for VRAM reporting; `unified` badge in dashboard
- **Dashboard self-rebuild** — "Restart dashboard" button runs `npm run build` on the agent machine and restarts the server; kills by port as fallback when no PID file
- **Smart allocate (repack)** — bin-packing algorithm reassigns models across GPUs to maximise fit; shows what won't fit; direct button on each stack config row
- **Create stack from scratch** — form-based stack config creation with model picker, GPU assignment, utilisation slider
- **Snapshot running state** — capture currently running instances as a saved stack config
- **Offline node setup command** — when a node is unreachable, the dashboard shows the exact `node.sh setup` command to bring it back online
- **Per-GPU temperature, fan, power, clock** — expanded GPU card shows full telemetry panel

---

## In Progress

### Analytics — follow-on work
The v1 analytics tab ships with per-node 1-minute sampling, DuckDB aggregation, and a fixed set of charts. Remaining items to close out the full feature:

- [ ] CSV/JSON export from the Analytics tab (download current window)
- [ ] Co-residency timeline band — render the `coresident_pct` metric as a colored strip under each GPU's utilization line so "when did two models share this GPU?" is instantly visible
- [ ] Error rate panel — parse LiteLLM `/metrics` for 4xx/5xx per model; show only when non-zero
- [ ] Per-model zoom: click a model in the legend → drill-down view with requests, tokens, TTFT, queue depth aligned
- [ ] Backfill tolerance — gracefully handle clock skew across nodes when combining buckets (currently assumes nodes agree on minute boundaries)

---

## Phase 2 — Automation

**Auto-scaling overflow instances**
When a model's queue depth or GPU utilisation crosses a threshold, automatically spin up a second instance on the next free GPU and register it with LiteLLM. Tear it down when load drops.

**Time-based model scheduling**
Define a schedule (e.g. "load the 70B model 08:00–18:00 weekdays, swap to 8B overnight") that the agent enforces automatically at startup and via cron.

**Preload on boot**
Config-driven list of models that should be running at all times. Agent ensures they are present on startup and restarts them if they die.

**Queue depth alerting**
Webhook or email notification when `requests_waiting` is non-zero for more than N seconds — first signal that capacity needs to increase.

---

## Phase 3 — Multi-Node Operations

**Unified request analytics across nodes**
The usage chart currently shows one node at a time. Aggregate across all registered nodes so total cluster load is visible in one view.

**Cross-node model migration**
Move a running model from one GPU/node to another via the dashboard — drain connections, launch on target, deregister source.

**Dynamic cluster partitioning (dual-master sandbox)**
Split the node pool into two (or more) independent clusters from the same physical hardware — a production partition and a staging/testing/batch partition. Each partition has its own master (dashboard + LiteLLM proxy), its own model library authority, its own analytics JSONL, and its own set of assigned nodes; traffic and deploys are isolated between them. Mechanism: add a `partition` field to `node_config.json` and to each node entry in `nodes[]`; the master that serves a partition only shows/manages nodes whose partition matches. A "Fork partition" action in the dashboard picks which of the current nodes come along to the new partition, promotes one as its master, re-registers its agents to point at the new master's proxy, and leaves the production master untouched. Nodes can move between partitions via the dashboard without a service restart — just a config push + proxy re-registration.

Two driving use cases:
1. **Testing** — try new vLLM versions, new model combos, or a risky node.sh change on a subset of hardware without taking the production cluster offline.
2. **Heavy batch isolation** — when a batch workload (eval sweeps, embedding a large corpus, fine-tuning feedback loops) would otherwise hammer interactive production traffic, peel off a few nodes into a batch partition so the network, GPU queues, and VRAM pressure stay contained. When the batch finishes, merge the nodes back.

**Multi-GPU model sharding — run models larger than a single GPU**
Two tiers of GPU combining, at different stages of readiness:
- *Single-node tensor parallelism (supported today)* — launch with `--tensor-parallel-size N` in the Deploy modal; vLLM splits the model's weight matrices across N GPUs on the same machine via NVLink/PCIe. The Deathstar's 4-GPU configuration can hold up to ~384 GB of model weight today.
- *Cross-node pipeline parallelism (future)* — vLLM supports Ray-backed distributed serving across separate machines. This would allow combining GPUs on Deathstar + Nano 0 for a model that requires more VRAM than any single node holds. Requires standing up a Ray cluster across nodes, wiring the agent's launch flow to pass `--pipeline-parallel-size` and the Ray head address, and coordinating model-weight distribution across the WAN link. High network bandwidth between nodes is critical — NVLink is not available cross-node so tensor parallelism is impractical; pipeline parallelism (each node handles different layers) is the correct topology.

**Zero-downtime rolling restart**
One-click "restart everything cleanly" — bring the cluster back to a known-good state without dropping in-flight inference. Agent/dashboard/proxy restarts individually today already lose any model registrations that weren't persisted, and a full `node.sh stop && start` kills every vLLM worker. Mechanism: for each node in sequence, drain its LiteLLM traffic (set weight → 0), wait for in-flight requests, restart the agent and dashboard, replay registered models from a saved manifest (`.cluster_state.json`), verify health, then restore traffic weight. Proxy restarts go last and use a pre-warmed config so there's no registration gap. End state is a fully-refreshed stack with no observable downtime to clients. Builds on cross-node migration + request analytics (to know when "drained" is actually drained).

---

## Model Library — follow-on work

v1 (per-node download / delete / token / importer / gating precheck) shipped above. Remaining items in this area:

**Library propagation across nodes**
Today, a model added via "+ Import from HF" writes to `model_library.json` on the node whose agent the modal talked to. The dashboard pulls from a single node so it *looks* right, but the entry isn't replicated to other nodes. Either (a) each add writes to every online node's library, or (b) promote the master's library as the authoritative copy and have other nodes read through it. (b) is cleaner but requires new API surface.

**Shared HF cache (NFS/SMB)**
Scalable fix for per-node duplication. Instead of `~/.cache/huggingface/hub/` living on each node's local disk, mount a shared volume. One 50 GB download serves the whole cluster. Requires: an install-time option to configure the cache path, plus some care with concurrent-write locking (`huggingface_hub` already handles this via `.lock` files so may Just Work). Low urgency until the cluster grows past 2-3 nodes or disk cost becomes a concern.

**Resume / parallelize downloads**
Downloads currently run one-at-a-time per model, serially per node. huggingface_hub already does parallel-file fetch internally; what's missing is: visible per-file progress within a download, ability to kick off downloads on every node at once with one click ("pre-warm cluster"), and a visible queue when multiple downloads are requested.

**Download priority / throttling**
A single 50 GB model download can saturate network and disk on a smaller node. Add a bandwidth/concurrency limit per node, configurable in `node_config.json`.

---

## Phase 4 — Management & Security

**Dashboard authentication**
Currently the dashboard is open to anyone on the network. Add optional basic-auth or token-based login, configurable in `node_config.json`.

**API key management**
Issue per-application keys through LiteLLM. Track usage per key so you know which app is generating load.

**Per-app usage quotas**
Rate-limit or cap token usage per API key — useful when multiple teams share the cluster.

**Audit log**
Persistent log of who launched/stopped which model, when, from which IP. Written by the agent on every mutating action.

---

## Phase 5 — Developer Experience

**Request playground in dashboard**
Send a test chat or embedding request directly from the dashboard UI, see the response and latency inline. Removes the need to open a separate tool to verify a newly deployed model is working.

**OpenAPI explorer**
Embed Swagger UI in the dashboard pointing at the LiteLLM proxy, so API consumers can explore available models and endpoints without leaving the browser.

**Model benchmarking**
One-click throughput test: send N concurrent requests to a model, report tokens/second, time-to-first-token, and latency p50/p95. Helps compare quantization options before committing a GPU slot.

**Webhook notifications**
Push events (model healthy, model crashed, GPU OOM, scale-up triggered) to a configurable URL — Slack, Teams, or any webhook receiver.

---

## Phase 6 — Infrastructure

**DNS-based node discovery for faster onboarding** *(from 2026-04-29 conversation with Cody)*
Today onboarding a master or child node requires the operator to know and type the target IP, which slows things down and creates room for typos. Replace (or augment) the IP-entry step with a DNS-driven discovery flow:
- **DNS lookup mode** — operator types a hostname; setup resolves it via DNS and uses the resulting IP. Removes the "what IP did Cody assign that box again?" friction.
- **Range-scan mode** — setup scans a configured network range (e.g. `10.2.30.0/24` for the AI subnet), reverse-resolves each responding host, and produces a picklist of DNS names. Operator chooses from the list instead of remembering hostnames.
- The picklist also surfaces nodes that are reachable but not yet registered with this cluster — useful for catching forgotten boxes or planning expansion.
- Pairs naturally with the device-profile presets below: pick the host from the DNS list, pick the device profile, setup proceeds.
- Configurable: `node.sh` setup gains `DNS_SEARCH_DOMAIN` and `NODE_DISCOVERY_RANGE` env vars or `node_config.json` fields; falls back to manual IP entry if discovery is disabled.

**Device-profile setup presets**
Today `node.sh setup` asks generic questions (role, IP, port) and a single aarch64-vs-x86_64 switch picks wheels. Real deployments tend to be a handful of well-known platforms — DGX Spark (GB10), HP Z8 Linux + RTX PRO 6000 Blackwell, Jetson, generic x86_64 + consumer RTX, etc. Add a device-type picker to the setup flow that expands into a preset: correct wheel index (cu130 nightly vs cu128 stable), torch pin, vLLM channel (pre vs stable), default GPU layout in `stack_configs.json`, expected SM/compute-cap warnings, and any platform-specific quirks (unified memory, NVLink topology, MIG). A profile registry (`setup_profiles/*.yaml` or similar) keeps the logic out of the shell script and makes new hardware trivial to onboard — add a profile, pick it at setup.

**Docker Compose deployment**
Alternative to the current bare-metal install: a `docker-compose.yml` that containerises the agent, dashboard, and LiteLLM proxy. vLLM itself still runs on the host for GPU passthrough.

**Windows native agent**
Remove the WSL dependency for the agent. The dashboard already runs natively on Windows via Node.js; the Python agent could too with minor changes.

**Automatic model updates**
Check HuggingFace for new revisions of cached models on a schedule. Show "update available" in the model library and allow one-click re-pull.

**Config backup and restore**
Snapshot the full stack state (running models, GPU assignments, flags) to a JSON file. Restore it on a new machine or after a wipe.

---

## Ideas Backlog

Small or uncertain items that may not be worth building but are worth remembering.

- LM Studio process auto-detection — show actual model name in the GPU process list rather than the raw process label
- Embedding model benchmarking (MTEB subset) — quick retrieval benchmark against a deployed embedding model
- Dark/light theme toggle in dashboard
- Pin a node card to the top of the dashboard
- Export utilization data to Grafana via a Prometheus scrape endpoint on the agent
- Per-node resource reservations — prevent the stack from filling a GPU that's allocated to LM Studio or another tool
- Model family grouping in the deploy modal — show all quantization variants of a base model together

---

## Cross-cutting: In-tool Feedback Widget

- [ ] When the Foundation AI Dashboard ships its in-tool feedback widget, drop the shared component into this tool's UI (vLLM Dashboard surface — for IT operators to give feedback on cluster management UX). Per-tool work = thin embed; the shared widget, API, GitHub Issue routing, and central aggregation view are built once in the Foundation AI Dashboard. **Canonical source of truth (design / architecture / acceptance criteria):** [Foundation AI Dashboard → Phase 7](../Foundation%20AI%20Dashboard/Roadmap.md).

---

**Last Updated:** 2026-05-13
