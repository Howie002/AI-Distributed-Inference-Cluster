# AI Distributed Inference Cluster - Roadmap

> *Reconciled 2026-07-29 (SB↔repo): the vault copy is canonical. Where both sides had drifted in the same section, the older repo wording was superseded — it remains intact in the repo's git history at the pre-reconciliation commit.*

**Repo:** [github.com/Howie002/AI-Distributed-Inference-Cluster](https://github.com/Howie002/AI-Distributed-Inference-Cluster) (private, active on `dev`)
**Last Synced:** 2026-08-11 *(reclaim kill-bug fix; third replica scripted, parked on Nano hands)*
**Current Phase:** v2 Cluster - operational hardening + analytics follow-on
**Target Production:** Ongoing operational service

Living document. Software feature work in "In Progress" and phased sections below. Deployment/ops-level tasks in the first section. Nothing is scheduled - items get picked up as capacity allows.

---

## New from 2026-08-11 - launch-path kill bug fixed; third replica scripted but parked

- [x] **Pre-launch VRAM reclaim killed live models' EngineCore children** - any launch onto an occupied GPU SIGKILLed the resident model's engine (tracked-PID protection covered only the APIServer parent). On the Nano's single GPU this made the third-replica launch itself an outage, with a watchdog-driven mutual-kill loop behind it. Fixed on **both** branches (`682e953` main, `7082f9a` dev cherry-pick); deployed + verified on `.20` (instances survived the agent update). Detail in Notes 08-11.
- [ ] **PARKED (needs Andrew): third nomic replica on the Nano.** Fully scripted in Notes 08-11 - blocked only on a 30-second hands-on `git pull` on the Nano, whose agent (`5716ba1`, 29 commits behind, dirty tree, pre-`force` `/update/pull`, no SSH from aivm) cannot be updated remotely. **Do NOT launch anything on the Nano until its code is updated** - through the old agent the launch kills the live gemma.
- [ ] **Branch split-brain (Andrew):** `.20` tracks `dev` (8 commits main lacks), master + `.30` track `main` (18 commits dev lacks). Fixes must currently ship twice; reconcile or standardize.
- [ ] **Mid-load reclaim window (post-fix residual):** a model whose APIServer isn't listening yet is invisible to the tracked-PID scan, so concurrent launches onto one GPU can still kill a loader. Sequence launches; a durable fix needs a launch-in-progress registry.

## New from 2026-08-10 - embedding redundancy and the 2048-token ceiling

- [x] **nomic-embed had no redundancy at all** (gemma had two nodes, embeddings had one). Second instance launched on the Death Star's idle GPU 1 at `:8024`; failover verified by killing `:8022` and confirming embeddings continued, then restoring it. Both registered.
- [ ] **Embeddings still have no BOX-level redundancy** - both instances are on `10.2.35.20`. The Nano path is now de-risked and scripted (08-11 above) but parked on hands; or bring Death Star 2 back (see below). This is the same shape as the Voicebox failover gap logged 08-04, and now applies to Living Catalog's semantic search, a Sept 14 flagship surface.
- [ ] **Death Star 2 (`10.2.35.21`) is fully dark, not just "agent down"** *(corrected 08-11: no ICMP, all ports closed, ARP FAILED)*. Likely benign - the DS1→DS2 transfer is in flight (08-04 item below) and the box may be powered down for it - but confirm with Andrew. Until it answers it cannot host the embedding replica that would give box-level redundancy.
- [ ] **`register_with_proxy: true` on `/instances/launch` did not re-register a relaunched instance**; an explicit `POST /proxy/sync` was needed. Either fix the launch path or document that sync always follows a launch.
- [x] **Confirmed `/proxy/sync` cannot be emptied by the master's blank `/instances`** - it fans out to every node in `node_config.json`, and only writes an empty model list if all nodes fail. Closes the hazard flagged earlier.

## New from 2026-08-04 - Voicebox failover/redundancy gap

**Andrew (2026-08-04):** noticed while thinking about the Foundation AI Dashboard's view of the AI stack - there is no failover/redundancy for Voicebox. It runs as a single Docker instance on the Death Star (`10.2.35.20`), GPU 0. If that node goes down (hardware failure, or mid-migration since the Death Star 1 → Death Star 2 transfer is already in flight), Foundation Coach and HyperFrames - the two current TTS consumers - lose voice capability entirely with no fallback.

- [ ] **Decide the redundancy shape** - hot standby on a second node (Death Star 2 is a natural candidate once onboarded), active-active with routing, or an accepted-risk single point of failure with fast manual recovery
- [ ] **Define failure detection** - how the VM/webapp layer (Foundation Coach, HyperFrames) notices Voicebox is unreachable and what it does instead of silently failing
- [ ] **Reconcile with the existing multi-instance discussion** (2026-07-16, above) - that thread is about latency/parallel-use contention, not failover, but a second instance placement decision could serve both goals if planned together
- [ ] Surface Voicebox health/redundancy state on the Foundation AI Dashboard, not just the vLLM cluster state

---

## New from 2026-07-30 - Death Star 2 onboarding

- [x] ~~**Get DHCP reservation for `10.2.35.21`** from Cody~~ — **Done 2026-07-31.** Physical-terminal verification: `ens255` up, MAC `b4:e2:5b:cd:6b:3e`, DHCP lease `10.2.35.21/24`; no static address set.
- [ ] **Register Death Star 2 with the cluster** - `node_config.json` / control agent, role=`child`.
- [ ] **Confirm Death Star 2's actual GPU spec** - assumed similar to Death Star 1 (4× RTX Pro 6000 Blackwell) but not yet physically confirmed.
- [ ] **Resolve whether Death Star 2 is the same unit as the HP Z Workstation pilot** (identical GPU spec, never conclusively distinguished) or genuinely separate new hardware.
- [ ] Decide model/workload placement once Death Star 2 is live (mirror Death Star 1, or split by workload type).
- [ ] **Execute and verify the Death Star 1 → Death Star 2 transfer** using [[DS2-Migration-Instructions-2026-07-31]] — includes cluster services, model endpoints, irreplaceable Voicebox volumes/profiles, direct-IP consumer updates, and pre-decommission load-balancing checks. **Status 2026-08-05 (Andrew): ongoing, expected to close this week (S10W7).**

---

## Carry-overs from 2026-07-08

- [x] ~~**⭐ Voicebox headless TTS on the Death Star**~~ — **✅ DONE 2026-07-08 (PM), and better than planned: running on the GPU, not CPU.** Deployed via Docker on **GPU 0**; the sm120 blocker that killed Higgs is gone (container torch 2.13+cu130 ships `sm_120` kernels). LAN-reachable at `http://10.2.35.20:17600/speak`, reboot-persistent (`restart: unless-stopped` + docker enabled), ops via `~/voicebox/{start,stop}_voicebox.sh`. Real 24 kHz WAV verified end-to-end (Kokoro `am_michael` preset). Entrypoint self-heals volume ownership on boot. See Notes.md 2026-07-08 (PM).
- [~] **Wire VM webapp(s) to Voicebox** (follow-on) — point the app(s) at `http://10.2.35.20:17600/speak`, create/select a voice profile per voice, handle the async `generating → output/<id>.wav` flow. Optional: evaluate heavier engines (Qwen3-TTS quality, Chatterbox cloning) now that GPU is proven. **2026-07-14: VM→Voicebox reachability confirmed; voice testing tomorrow, then HyperFrames integration.**
- [ ] **New (2026-07-14): Voicebox management interface on the VM** — a lightweight app that proxies to the Voicebox endpoint so Foundation Coach and HyperFrames (the two current TTS consumers) can customize voices/profiles without needing Death Star SSH access each time. Not started - captured as an idea, not yet scoped. **2026-07-16: largely superseded by the dashboard `/admin/voicebox` panel** (models, profiles, clone-with-mic, hide/delete, test speech - see Dashboard Notes 07-16).
- [ ] **New (2026-07-16, discussion point): multiple instances of the same voice model to cut parallel-use latency.** Measured on chatterbox_turbo (the Coach/narration engine): solo ≈ 2.0s to audio, 2 concurrent ≈ 3s each, 3 concurrent ≈ 6s+ each - one GPU time-slices all simultaneous generations, and Coach live sessions, HyperFrames render narration, and panel tests all share it. Options to discuss: (a) a second Voicebox worker/instance pinned to another GPU (Death Star has capacity?), (b) load the 0.6B Chatterbox variant as a second, cheaper instance for live Coach traffic while renders keep the 1.7B, (c) a small routing shim that sends Coach vs batch traffic to different instances. Decision needed only when simultaneous cloned-voice demand becomes real (2 concurrent sessions are already fine); measurements + contention notes in Cluster Notes 2026-07-16 and Foundation Coach Notes 2026-07-16.
- [x] ~~**Higgs Audio V3 deploy**~~ — **ABANDONED 2026-07-08 (dead end).** sm120 driver/fault-buffer saga + zero-shot-only voices; pivoted to Voicebox. Install artifacts (`/home/admin/higgs-audio`, 19 GB) to be removed.
- [ ] **Deploy `dev` → live + merge `dev`→`main`** — **NON-CRITICAL (per Andrew 2026-07-08).** 5 commits pending (GPU labels, enriched cards, embedding-mode fix, watchdog disable). Death Star runs `dev`; Master VM + Nano need pull + agent restart, master dashboard rebuild. Pick up when convenient.

## Backlog additions (Quick Notes filing, 2026-07-06)
- **Voicebox on the Death Star** (Andrew, 07-01): point the VM at Voicebox for all audio requests; keep it a SIBLING service to the inference proxy, do not merge (STT/TTS vs. TTT). Relates to the Higgs Audio TTS thread.
- **Model-load visibility feature + open issues**: spec and commit log in [Cluster-Fixes-and-Model-Load-Visibility-2026-07-01.md](Cluster-Fixes-and-Model-Load-Visibility-2026-07-01.md) (moved whole from Quick Notes).

## Carry-overs from 2026-07-01

- [ ] **Fix + re-enable the auto-restart watchdog** — **DEFERRED (per Andrew 2026-07-08, "leave the watchdog for now").** Disabled 2026-07-01 (`dev` `9963401`). It was relaunching *healthy* instances (flaky `net_connections` scan → thinks they're missing) and the launch VRAM-reclaim then killed them → crash-loop (gemma `:8020`, `:8021`). **Re-enable only after:** (a) instance scan is robust / not solely `psutil.net_connections`-dependent; (b) **reclaim never kills a healthy co-located/same instance** (the core fix — also unblocks the keep-retrying watchdog `e30544a` and the 196K `:8021`); (c) health check uses `127.0.0.1` not `localhost` (IPv6 `::1` vs IPv4 bind). Then uncomment the two lines in `_on_startup`.
- [ ] ⭐ **Model-load visibility** — surface load/failure state in the agent + dashboard. Today a loading/crash-looping model shows as `absent` in `/instances` (only bound ports listed) — indistinguishable from "never existed"; confirming gemma `:8020` was stuck needed a manual `nvidia-smi` poll loop. Build: lifecycle state (`starting → loading_weights → allocating_kv → warming_up → healthy`, plus `crash_looping (N attempts)` / `abandoned`) parsed from the vLLM launch log markers; dashboard status pill + a per-card GPU-mem sparkline (a crash-loop is an obvious sawtooth). See SB quick note `2026-07-01-inference-cluster-fixes-and-model-load-visibility-roadmap`.
- [ ] **Deploy `dev` → live** — 5 commits pending (GPU model labels `ed040f6`, enriched cards `99ff87e`, embedding `mode` fix `adc50f4`, watchdog keep-retry `e30544a` [now moot — superseded by the disable], watchdog disable `9963401`). Death Star already runs `dev`; Master VM + Nano need pull + agent restart, master needs dashboard rebuild. Then merge `dev`→`main`.

## Carry-overs from 2026-06-29

- [ ] **Higgs Audio V3 deploy on Death Star** — `dev` branch ready (`e03ce50`). Pending on other machine: run `scripts/install_higgs_audio.sh`, create `litellm/.env` with `HIGGS_AUDIO_HOST`, restart proxy. Then verify API format, benchmark latency vs. Kokoro, get voice IDs. See Notes.md for full checklist.
- [ ] **Pull `dev` to Master VM + Death Star** — both repos have `dev` commits to pull before any deployment work.

## Carry-overs from 2026-06-24

- [ ] **Master pull one-time intervention** — master is N commits behind with persistent runtime writeback. The `force=true` option on `/update/pull` lives in the unpulled commits, so unblocking it needs one SSH session: `git stash push --include-untracked && git pull && curl -X POST http://localhost:5000/agent/restart`. After that, future updates run via `curl -X POST http://10.2.35.10:5000/update/pull?force=true` with no SSH required.
- [x] ~~**Diagnose Deat Star vLLM zombie accumulation**~~ — **RESOLVED 2026-06-30.** Discovered 30+ stale `vllm serve` processes from past 4-7 days holding ~40 GB combined RSS, not tracked by the agent's `/instances` list; watchdog/reclaim gap closed.
- [x] ~~**31B failing silent-exit during APIServer init on Deat Star**~~ — **Retired from active fleet 2026-06-24.** After repeated launch failures + the underlying base-model awkwardness (no chat template, slow load, fragile under memory pressure), decided `gemma-4-31b` is not the right production model. `gemma-4-26b-a4b-nvfp4` (chat-tuned, on GPU Server 1) is the new default. HyperFrames pipeline + cluster docs updated. If 31b ever needs to come back for a specific experiment, `chat_template` support is shipped in the agent and `agent/chat_templates/gemma.jinja` is ready.
- [x] ~~**Install systemd units on Death Star**~~ — **Confirmed working 2026-06-29** (Andrew verified). Auto-start on reboot is livex] ~~**Install systemd units on Death Star**~~ — **Confirmed working 2026-06-29** (Andrew verified). Auto-start on reboot is live.
- [ ] **Node rename `Deat Star` → `Death Star`** ✅ shipped 2026-06-24 via `PATCH /nodes/10.2.35.20` (cosmetic spelling fix; master's `node_config.json` updated).
- [ ] **Verify the new chat_template flag end-to-end** — agent now accepts `chat_template`, `enable_auto_tool_choice`, `tool_call_parser` in `extra_flags`. Canonical Gemma template lives at `agent/chat_templates/gemma.jinja`. Code change is correct (visible in argv) but couldn't verify a successful chat completion against 31B today because of the load failure above. Worth a quick test on a smaller base model.
- [x] ~~**Default the dashboard testing tab to `gemma-4-26b-a4b-nvfp4` for chat**~~ — **RESOLVED 2026-06-30.** It's chat-tuned and works natively; the testing tab previously errored when pointed at gemma-4-31b (base model + no chat template).
- [x] ~~**LiteLLM `encoding_format` quirk on `/v1/embeddings`**~~ — **RESOLVED 2026-06-30** (commit `1efb987`). The documented `drop_params: true` guess did **NOT** work — verified against a shadow litellm on `:4001` with the exact live config, which still 400'd (so a proxy restart/update alone was not the fix). Real fix: pin `encoding_format: float` per embedding model in the config **generator** (`agent/agent.py` `_proxy_write_and_restart`, detected via `if "embed" in served_name.lower()`), since `cluster_config.yaml` is auto-generated and can't be hand-edited. Bare `/v1/embeddings` calls now return a 768-dim vector with no caller workaround; R&FI's ChromaDB RAG unblocked. See Notes.md 2026-06-30.
- [x] ~~**Document the proxy quirks in a single source consumers can find**~~ — **DONE 2026-06-30.** Created `docs/UsingTheProxy.md` in the repo (consumer-facing reference for the `:4000` proxy: base URL, model names + backends, embeddings-now-work-bare, embedding max context 2048, gemma 100K context, auto-generated config / don't-hand-edit).
- [ ] **Dashboard `dev` branch on GitHub is ahead of local** — someone (CI? webhook? earlier session?) pushed to `origin/dev` independently. Local push to `dev` rejected. Fetch + reconcile before next dev-branch work.

---

> - [ ] **Master pull one-time intervention** — master is N commits behind with persistent runtime writeback. The `force=true` option on `/update/pull` lives in the unpulled commits, so unblocking it needs one SSH session: `git stash push --include-untracked && git pull && curl -X POST http://localhost:5000/agent/restart`. After that, future updates run via `curl -X POST http://10.2.35.10:5000/update/pull?force=true` with no SSH required.
> - [ ] **Diagnose Deat Star vLLM zombie accumulation** — discovered 30+ stale `vllm serve` processes from past 4-7 days holding ~40 GB combined RSS, not tracked by the agent's `/instances` list. Watchdog should have caught these but didn't. Open question: under what conditions does a vLLM launch leak its PID past `_reclaim_vram_before_launch`'s scope? Pattern matters because it cost ~5x memory pressure today and broke 31B's reload.
> - [x] ~~**31B failing silent-exit during APIServer init on Deat Star**~~ — **Retired from active fleet 2026-06-24.** After repeated launch failures + the underlying base-model awkwardness (no chat template, slow load, fragile under memory pressure), decided `gemma-4-31b` is not the right production model. `gemma-4-26b-a4b-nvfp4` (chat-tuned, on GPU Server 1) is the new default. HyperFrames pipeline + cluster docs updated. If 31b ever needs to come back for a specific experiment, `chat_template` support is shipped in the agent and `agent/chat_templates/gemma.jinja` is ready.
> - [ ] **Install systemd units on Death Star** for boot-time auto-start of agent + watchdog. The code is in `node.sh install-systemd` but requires sudo on the host. Without it, the cluster does not bounce back automatically on machine reboot — only on `bash ./agent/start_agent.sh` after manual login. Run once from a real TTY: `sudo bash node.sh install-systemd`.
> - [ ] **Node rename `Deat Star` → `Death Star`** ✅ shipped 2026-06-24 via `PATCH /nodes/10.2.35.20` (cosmetic spelling fix; master's `node_config.json` updated).
> - [ ] **Verify the new chat_template flag end-to-end** — agent now accepts `chat_template`, `enable_auto_tool_choice`, `tool_call_parser` in `extra_flags`. Canonical Gemma template lives at `agent/chat_templates/gemma.jinja`. Code change is correct (visible in argv) but couldn't verify a successful chat completion against 31B today because of the load failure above. Worth a quick test on a smaller base model.
> - [ ] **Default the dashboard testing tab to `gemma-4-26b-a4b-nvfp4` for chat** — it's chat-tuned and works natively. The testing tab errored when pointed at gemma-4-31b today (base model + no chat template). UI fix: detect base models in the model list and either disable chat-completions mode or auto-route to `/v1/completions`.
> - [x] ~~**LiteLLM `encoding_format` quirk on `/v1/embeddings`**~~ — **RESOLVED 2026-06-30** (commit `1efb987`). The documented `drop_params: true` guess did **NOT** work — verified against a shadow litellm on `:4001` with the exact live config, which still 400'd (so a proxy restart/update alone was not the fix). Real fix: pin `encoding_format: float` per embedding model in the config **generator** (`agent/agent.py` `_proxy_write_and_restart`, detected via `if "embed" in served_name.lower()`), since `cluster_config.yaml` is auto-generated and can't be hand-edited. Bare `/v1/embeddings` calls now return a 768-dim vector with no caller workaround; R&FI's ChromaDB RAG unblocked.
> - [x] ~~**Document the proxy quirks in a single source consumers can find**~~ — **DONE 2026-06-30.** Created `docs/UsingTheProxy.md` (consumer-facing reference for the `:4000` proxy: base URL, model names + backends, embeddings-now-work-bare, embedding max context 2048, gemma 100K context, auto-generated config / don't-hand-edit).
> - [ ] **Dashboard `dev` branch on GitHub is ahead of local** — someone (CI? webhook? earlier session?) pushed to `origin/dev` independently. Local push to `dev` rejected. Fetch + reconcile before next dev-branch work.
> ---

## Self-Healing Follow-ons *(from 2026-05-14 deploy of commit `5716ba1`)*

- [ ] **`/diagnose` surfaces intended-vs-actual mismatches** - today it only shows orphan VRAM forensics. Extend it to flag instances in `intended_instances.json` that are not running, with last-restart-attempt timestamp and current backoff state.
- [ ] **Dashboard surfaces "instance abandoned" state** - when the watchdog gives up after exhausting backoff, the dashboard should make that visible with a one-click "restart" / "remove from intent" action. Currently abandoned state is silent until an operator inspects the agent.
- [ ] **Escalation rung when reclaim doesn't free enough VRAM** - after N failed launches in a row, surface "manual reboot required" (or `nvidia-smi --gpu-reset` recipe) in the dashboard rather than silently retrying forever.

---

## Active Deployment Tasks

Operational tasks layered on top of the running cluster. Not code features - hardware, DNS, security.

### Needs DNS / Network Access
- [ ] Configure `aidev.txamfoundation.com` - point DNS to cluster master
- [ ] Set up proxy host in Nginx Proxy Manager (:81) → dashboard with SSL / Let's Encrypt
- [ ] Lock down port exposure via firewall - dashboard, proxy, agent ports should not be publicly routable

### Production Hardening
- [ ] Schedule regular VM / node snapshots for disaster recovery
- [ ] GPU monitoring - connect analytics JSONL to a persistent dashboard (Grafana or similar)
- [ ] Migrate SQLite → PostgreSQL when user volume grows (if applicable to dashboard state)

### Z Workstation Pilot (Parallel Project)
*See separate `HP Z Workstation Pilot` project - infrastructure listed here for cross-reference.*
- [ ] Confirm pilot loaner delivery date and specs with HP
- [ ] Onboard hardware - OS, NVIDIA drivers, CUDA, vLLM agent
- [ ] Benchmark vs. DGX Sparks using the dashboard
- [ ] Connect to Foundation Snowflake AI app as inference target
- [ ] Purchase decision: 2× workstations, 2 cards each if validated

---

## Active Issues / UX Gaps

### 🔴 Model launch feedback is opaque - "Launching…" with no progress or failure signal

**Priority:** High - blocks confident operation of the cluster
**Reported:** 2026-04-20
**Repro:** Launch `llama-3-3-nemotron-super-49b` (fp8, 50 GB weights) on The Deathstar GPU 2 via the Deploy modal (80% memory, 32768 max context, 256 parallel slots). Modal sits on "Launching…" for a long time with no indication of what is happening. In at least one case the load silently failed and the user had no idea whether the model was still loading, stuck, or dead.

**What's missing**
- No visible stages during model load (spawning → loading weights → warming up → ready)
- No live log tail from the vLLM subprocess in the launch modal
- No progress indicator tied to load phase (weights into VRAM, KV cache init, server ready)
- Silent failures - if vLLM crashes during startup, the dashboard does not surface the error or stderr
- No timeout / "still working…" indicator when a launch is taking longer than expected
- No cancel button once a launch has started

**Acceptance criteria**
- [ ] Launch modal shows live status: `Spawning process` → `Loading config` → `Allocating GPU memory` → `Loading weights (X%)` → `Warming up` → `Ready`
- [ ] Live tail of vLLM stdout/stderr (last ~20 lines) in the launch modal while launching
- [ ] Failure state surfaces the error with a stderr snippet and a "View full log" link
- [ ] Cancel button available throughout launch; kills the spawned process and cleans up GPU allocation
- [ ] If no stdout is observed for >30 s, UI shows `No activity for 30s - last stage: X` so user knows it is not frozen
- [ ] After launch completes, modal auto-dismisses on success and persists on failure

---

### 🟡 Show context window per model in the dashboard

**Priority:** Medium - informational, but it's the missing piece for "is this model right for what I'm about to do."
**Reported:** 2026-05-06

**Ask:** Surface each running model's **context window size** (max prompt + generation tokens) so it's visible at a glance. Today the dashboard shows model name, GPU assignment, port, and tensor parallel - but not the context window. Have to dig into launch flags or model config to know.

**Why it matters:** When picking which model to point a tool at (Foundation Secure Chat, K-1, Deep Research Tool, etc.), context window is one of the top decision factors:
- Long-document workflows (gift agreement extraction, IC notes, full board packets) need a 100k+ window - a nano-class 8B with 8k won't work
- Short Q&A workflows (Foundation Agent intent routing, brief K-1 fields) are fine on small windows
- Cost / VRAM tradeoff - bigger context costs more VRAM; knowing what's deployed lets the operator right-size

**Where it should appear**
1. **Cluster Service List row (Overview tab)** - already shown on expand; promote to always-visible columns
2. **Endpoints tab** - alongside each direct vLLM endpoint so tool integrators know what to pass for `max_model_len`
3. **Model Library** - for cached models, show advertised max (from HF config `max_position_embeddings`) vs. currently deployed max (from launch flag). Lets the operator see "this model could go up to 1M but I deployed it at 32k" - useful when revisiting capacity decisions

**Sources of the value**
- Launch-time flag: `--max-model-len <N>` in spawn command. `_scan_vllm_instances` in `agent/agent.py` already parses cmdline flags - just needs to capture this field and surface in `/instances` + `/status` payloads
- Model's advertised max: in HF model config (`config.json` → `max_position_embeddings`). HF importer already pulls model metadata for the library - same path can store advertised max alongside
- vLLM `/metrics` doesn't expose this directly, so launch flags + HF config are the sources of truth

**Acceptance criteria**
- [ ] `/status` payload includes `max_model_len` per running instance (parsed from cmdline)
- [ ] Cluster Service List shows context window as a top-level column (not just on expand)
- [ ] Endpoints tab shows context window per direct vLLM endpoint
- [ ] Model Library row shows both advertised and deployed context window
- [ ] Empty / unknown values render gracefully ("-") instead of "0" or "null"

**Pairs naturally with:** VRAM-vs-context decision support - once context window is visible, a follow-on could surface "VRAM headroom remaining" so the operator can see how much further `max-model-len` could be pushed before OOM. (Future enhancement, not part of this item.)

---

> ### 🟢 *(Shipped 2026-06-17)* Auto-discovery of cluster nodes + DNS-aware resolution
> **Status:** Resolved (agent + node.sh layers). Webapp wizard for setup/settings: agent endpoints shipped, dashboard UI deferred to next sprint.
> **Problem solved**
> - Every re-IP (DHCP renewal, subnet change like the recent Death Star `10.2.30.28` → `10.2.30.30` → `10.2.35.20` thrash) used to require manual edits to every node's `node_config.json`. Hardcoded master IPs made the cluster brittle.
> - No human-friendly node naming — the dashboard showed `10.2.35.28` instead of `Death Star`.
> **What landed**
> - **Cluster token + discovery range schema** in `node_config.json` under a new `cluster` key. Backward-compat: legacy `master.ip`-only configs still work; the new fields are optional.
> - **`GET /cluster/handshake`** endpoint — token-gated. Children call this against every IP in their discovery range; matching responses identify masters.
> - **`POST /cluster/register`** endpoint — token-gated. Children post their address to the master after discovery.
> - **`GET /cluster/nodes`** endpoint — read-only view of currently-registered children (hostname + IP + port + role + last-seen timestamp).
> - **Discovery thread** (`_discovery_loop`) on child/both roles. Scans up to 1024 IPs per pass with a 32-way thread pool. Fast path: re-verifies known master every 60 s; slow path: full scan when verify fails. Self-heals on re-IP.
> - **DNS-aware resolution** — `_resolve_to_ip()` / `_resolve_to_hostname()` helpers with 60 s TTL cache. `master.ip` field now accepts hostnames; agent re-resolves on each connection so DNS changes take effect without config edits. Hostnames surface in `/cluster/nodes` for the dashboard.
> - **`node.sh setup` prompts** added for cluster token (auto-generated on master, paste from master on child) and discovery range (defaults to /24 derived from `this_ip`). Token displayed at end of master setup so operator can share with children.
> - **Webapp setup wizard — agent side complete**: `GET /setup/state`, `POST /setup/complete`, `GET /settings`, `PUT /settings`. Dashboard UI (the actual wizard pages in Next.js) is the remaining work — these endpoints are ready to drive it.
> **Acceptance demonstrated**
> - New `cluster_token` auto-generates on master setup (16 random hex bytes via `secrets.token_hex(16)`).
> - Discovery range auto-derives from `this_ip` when operator presses Enter.
> - Existing nodes without cluster fields keep working via the legacy `master.ip` path (the discovery thread cleanly skips if no token is configured).
> - `_check_cluster_token` uses `secrets.compare_digest` so timing attacks aren't a concern.
> **Carry-over follow-ups**
> - **Dashboard UI for setup wizard + settings panel** — agent has the endpoints; just needs a Next.js page that hits them. Multi-step form, validation, hostname picker for master, copyable token output. Track as its own sprint.
> - **Master role: surface `/cluster/nodes` in the dashboard's main view** — replace any remaining hardcoded node-table data with a live read of registered children.
> - **Cluster-token rotation** — once a token is set, there's no rotation primitive yet. Add `POST /cluster/rotate-token` (master-only, requires current token) that returns the new value and invalidates old children.
> ---
> ### 🟢 *(Shipped 2026-06-10)* systemd auto-restart + boot-time bring-up
> **Status:** Resolved. `node.sh setup` now wires the cluster into systemd by default. Reboot → cluster comes back. Agent/dashboard/proxy crash → systemd restarts within 10 s.
> **What landed**
> - Three role-aware systemd units written by `node.sh setup`:
>   - `vllm-cluster-agent.service` (every role)
>   - `vllm-cluster-dashboard.service` (every role)
>   - `vllm-cluster-litellm.service` (master + both only)
> - `Type=forking`, `Restart=on-failure`, `RestartSec=10`, `StartLimitBurst=3` over 120 s — protects against crash-loop thrashing
> - `After=network-online.target` so DNS / agent-to-master discovery is ready before bring-up
> - `WantedBy=multi-user.target` so services come back on boot
> - `node.sh start/stop` detect systemd-managed mode and delegate to `systemctl` — no more dual-startup races
> - Opt-out via `VLLM_SKIP_SYSTEMD=1 ./node.sh setup` for containers / dev machines without systemd
> - New subcommands: `./node.sh install-systemd` (retrofit existing install), `./node.sh remove-systemd` (uninstall cleanly)
> **Operational impact**
> - Brand-new Death Star: `git clone … && ./node.sh setup` → answer role questions → one sudo prompt → cluster fully operational AND survives reboots / crashes. No second command.
> - Existing nodes: re-run `./node.sh setup` (idempotent) or `./node.sh install-systemd` to opt in.
> **Carry-over follow-ups** (not blocking, captured for future)
> - Move the auto-update `git pull` step (currently in `try_auto_pull` inside `do_start`) into a separate timer-driven systemd unit so the agent doesn't have to restart to pick up upstream changes
> - Surface systemd status in the dashboard (currently invisible — operators have to `systemctl status` from a shell)
> - `node.sh status` could also surface systemd state alongside the existing per-service curl checks
> ---
> ### ✅ vLLM restart loop on Blackwell — CUDA 12.8 too old for SM 12.0 + watchdog masks the failure — RESOLVED 2026-07-02
> **Resolved 2026-07-02:** CUDA/sm120 blocker cleared; Death Star (10.2.35.20) serves nvfp4 gemma on :8021/:8023 + nomic-embed-text-v1-5 on :8022 in production (verified; Deep Research Heavy-depth confirmed 07-07).
> **Priority:** Critical — cluster cannot serve any NVFP4 model on RTX PRO 6000 Blackwell hardware
> **Reported:** 2026-06-05
> **Hardware:** Death Star (`10.2.35.20`) — 4× NVIDIA RTX PRO 6000 Blackwell Max-Q Workstation Edition (SM 12.0)
> **Software:** `node.sh setup` auto-installs `cuda-toolkit-12-8`; driver-side CUDA is 13.0
> **Symptom**
> Master sends `POST /instances/launch` to the child agent. vLLM serve process spawns, loads weights successfully (~17.5 GiB shards in ~8 s), enters NVFP4 MoE backend setup, then **dies silently** with no error written to its dynamic log. Watchdog from `5716ba1` detects the dead process and spawns a fresh one. New process truncates the log, repeats. **Four full generations of vLLM PIDs observed in ~15 minutes** with zero serving and no diagnostic trace preserved.
> **Why this is two bugs at once**
> 1. **CUDA toolkit version mismatch (root cause)** — vLLM logs `Failed to get device capability: SM 12.x requires CUDA >= 12.9` twice during init, then falls back from `FLASHINFER_*` NVFP4 backends to `VLLM_CUTLASS`. The fallback kernels apparently crash silently when they hit the loaded weights or during cudagraph capture. The `node.sh setup` script's auto-install of `cuda-toolkit-12-8` is **wrong for any SM 12.x hardware**.
> 2. **Watchdog hides the crash (secondary)** — the `2b7897b` "Launch failure surfacing" path catches launch-time failures via the `EARLY_FAIL_WAIT_S` babysitter, but doesn't catch a process that dies *after* the agent has reported launch success. The new watchdog (`5716ba1`) immediately respawns the dead process, which truncates the dynamic log — destroying the only forensic evidence of why it died.
> **What's missing**
> - `node.sh setup` does not detect GPU compute capability before picking the CUDA toolkit version
> - Watchdog has no rate-limiting / backoff on restart attempts (instant respawn = continuous log churn)
> - Dynamic logs are overwritten on each launch rather than rotated (`dynamic_<port>.log.1`, `.2`, etc.)
> - No "crash mode" — after N consecutive crash-loop iterations, watchdog should stop respawning and surface the failure to the master rather than thrash
> **Acceptance criteria**
> - [ ] `node.sh setup` reads the highest GPU compute capability from `nvidia-smi --query-gpu=compute_cap` and picks toolkit accordingly:
>   - SM ≤ 9.0 → `cuda-toolkit-12-8`
>   - SM 10.x → `cuda-toolkit-12-9`
>   - **SM 12.x (Blackwell) → `cuda-toolkit-13-0` or `cuda-toolkit-12-9` minimum**
> - [ ] Setup also re-checks an existing install; if installed toolkit is older than what the hardware requires, warn and offer to upgrade in place (not just skip)
> - [ ] Dynamic logs rotate, not truncate: keep last N attempts as `dynamic_<port>.log.<N>` for postmortem
> - [x] Watchdog adds exponential backoff: 5 s → 30 s → 2 min → 5 min between restart attempts (implemented as 30 s → 2 min → 10 min then abandon, `agent/agent.py` `_RESTART_BACKOFF_S`; note the auto-restart watchdog itself was subsequently disabled entirely in `9963401`, which also ends the respawn/log-truncate churn)
> - [ ] Watchdog enters "crash-loop detected" state after 3 consecutive failures within 5 min — stops respawning, marks the instance failed at the master via `POST /instances/{port}/failed` (new endpoint), and includes the preserved log tail
> - [ ] `/diagnose` (from `ce12428`) surfaces "this model crashed-looped N times today" so operators can see the pattern in one place
> **Workaround until fix lands (Blackwell-specific)**
> - Manually upgrade toolkit: `sudo apt install cuda-toolkit-13-0` (matches the 13.0 driver)
> - If crash persists after upgrade: launch with `--enforce-eager` to skip cudagraph capture (slower but lets the model serve while the real fix is being investigated)
> - Until either workaround is verified, do NOT auto-launch NVFP4 models from the master on Blackwell nodes — manual launches only with full log capture (`./vllm serve ... 2>&1 | tee /tmp/vllm-manual.log`) *(pre-07-02 guidance; superseded by the resolution above)*
> **Cross-references**
> - Origin context: Death Star re-IP from `10.2.30.28` → `10.2.35.20` (2026-06-05); fresh `node.sh setup` ran the (wrong) `cuda-toolkit-12-8` install
> - Related: Phase 6 *Device-profile setup presets* — this is the same problem space, but for a CRITICAL bug rather than ergonomics. Solving the auto-detect for the toolkit version is a subset of the device-profile preset work.
> ---
> ### 🔴 Model launch feedback is opaque — "Launching…" with no progress or failure signal
> **Priority:** High — blocks confident operation of the cluster
> **Reported:** 2026-04-20
> **Repro:** Launch `llama-3-3-nemotron-super-49b` (fp8, 50 GB weights) on The Deathstar GPU 2 via the Deploy modal (80% memory, 32768 max context, 256 parallel slots). Modal sits on "Launching…" for a long time with no indication of what is happening. In at least one case the load silently failed and the user had no idea whether the model was still loading, stuck, or dead.
> **What's missing**
> - No visible stages during model load (spawning → loading weights → warming up → ready)
> - No live log tail from the vLLM subprocess in the launch modal
> - No progress indicator tied to load phase (weights into VRAM, KV cache init, server ready)
> - Silent failures — if vLLM crashes during startup, the dashboard does not surface the error or stderr
> - No timeout / "still working…" indicator when a launch is taking longer than expected
> - No cancel button once a launch has started
> **Acceptance criteria**
> - [ ] Launch modal shows live status: `Spawning process` → `Loading config` → `Allocating GPU memory` → `Loading weights (X%)` → `Warming up` → `Ready`
> - [x] Live tail of vLLM stdout/stderr (last ~20 lines) in the launch modal while launching — `LaunchLogModal` ships in [387086b](387086b)
> - [x] Failure state surfaces the error with a stderr snippet and a "View full log" link — agent's `/instances/launch` now babysits the spawned process for `EARLY_FAIL_WAIT_S` seconds, returns HTTP 422 with structured `{message, exit_code, log_tail, log_path}` on startup crash; `DeployModal` renders the panel inline. *(2026-05-13)*
> - [ ] Cancel button available throughout launch; kills the spawned process and cleans up GPU allocation
> - [ ] If no stdout is observed for >30 s, UI shows `No activity for 30s — last stage: X` so user knows it is not frozen
> - [x] After launch completes, modal auto-dismisses on success and persists on failure — failure path keeps the modal open with the error/log; the success path closes as before. *(2026-05-13)*
> **Side-effect of the failure-surfacing work — auto-retry for chunked-MM models**
> When vLLM fails with the specific `Chunked MM input disabled but max_tokens_per_mm_item (N) is larger than max_num_batched_tokens (M)` error (e.g. Gemma-4 multimodal), the agent now parses N out of the log, retries the launch once with `--max-num-batched-tokens=max(N, 4096)`, and surfaces the auto-retry result in the response. Prevents the same silent crash that motivated the failure-surfacing fix from happening on the very next try. *(2026-05-13)*
> ---
> ### 🟡 No way to forensically diagnose orphaned vLLM workers or RAM leaks during a spike
> **Priority:** Medium — needed whenever the agent reports `instances: []` but system RAM or VRAM is still pinned
> **Reported:** 2026-05-13 (post-restart incident on a child node: system RAM spiked to 100% while the agent reported no running instances)
> **Context:** On DGX Spark (GB10) unified-memory hardware GPU and system RAM share the same physical pool, so an allocation the agent has lost track of looks like a system-wide RAM leak. Three known mechanisms can leave allocations un-owned:
> 1. **Reparented vLLM workers** — tensor-parallel children reparented to PID 1 when the parent process is `SIGKILL`ed (OOM killer, hard restart). `./node.sh stop` does not kill them because the agent never tracked their PIDs.
> 2. **PID-file desync** — vLLM spawned and allocated memory but the agent's tracking file was never written, or was deleted by a concurrent `stop`.
> 3. **`/dev/shm` and SysV shm leaks** — KV-cache and IPC shared-memory segments not cleaned up after a crash. On unified memory these directly count as system RAM.
> Today the only path is to SSH into the node and run `nvidia-smi --query-compute-apps`, `ps --ppid 1`, `ls /dev/shm/`, and `ipcs -m` by hand and cross-reference against the agent's `instances` list.
> **Acceptance criteria**
> - [x] New `/diagnose` route on the agent returns JSON with: GPU compute apps from `nvidia-smi --query-compute-apps=pid,process_name,used_memory`, reparented Python/vLLM processes (`PPID == 1`), `/dev/shm` segments (path, size, mtime), SysV shared-memory segments from `ipcs -m`, and a side-by-side comparison of what the agent's `instances` list owns vs. what's actually allocated — `agent.py @app.get("/diagnose")`. *(2026-05-13)*
> - [x] Dashboard surfaces a "Diagnose" action on each node card that calls this route and renders the result, highlighting anything unowned — `DiagnoseModal` reachable from `NodeCard` header. *(2026-05-13)*
> - [ ] Follow-on: "Reap orphan" action that kills reparented workers and clears unowned shm segments after a confirm dialog (gated behind a setting, since false positives could kill a legitimate process the agent is mid-launching)
> ---
> ### 🟠 Dashboard UI performance & stability hardening
> **Priority:** Next up — these are the highest-leverage UI perf and resilience fixes surfaced by a code review on 2026-05-07. Each item is independently shippable.
> **Critical**
> - [x] **Stop tearing down ModelLibrary poll intervals on every parent render** — [`dashboard/src/components/ModelLibrary.tsx`](dashboard/src/components/ModelLibrary.tsx). Memoized `onlineNodes` against a stable string signature of online node keys; `useCallback`/`useEffect` deps no longer invalidate every render, so cache (15 s) and download (2 s) intervals stay alive across status ticks. *(2026-05-07)*
> **High**
> - [x] **Status poll: skip-if-busy + latest-only guard** — [`dashboard/src/app/page.tsx`](dashboard/src/app/page.tsx). Added `inFlightRef` to drop overlapping ticks and a monotonic `requestIdRef` so a slow tick that lands after a newer one can't overwrite state. *(2026-05-07)*
> - [x] **Fetch timeout on `/api/nodes/edit` and `/api/nodes/rename` proxy paths** — [`edit/route.ts`](dashboard/src/app/api/nodes/edit/route.ts), [`rename/route.ts`](dashboard/src/app/api/nodes/rename/route.ts). Wrapped the child→master PATCH in `AbortSignal.timeout(8000)` and return `504` with a clear message on unreachable master. (`add/route.ts` has no proxy fetch.) *(2026-05-07)*
> - [x] **"Restart dashboard" polls for health instead of sleeping 60 s** — [`dashboard/src/components/NodeCard.tsx`](dashboard/src/components/NodeCard.tsx). Polls a relative `/api/nodes` (when on this node's dashboard) or the agent's `/status` (cross-node), waits for down→back transition, max 3 minutes, surfaces failure instead of force-reloading a broken page. *(2026-05-07)*
> **Medium**
> - [x] **Atomic config writes** — `edit/`, `add/`, `rename/` route handlers now go through a `writeJsonAtomic(path, data)` helper that writes to `node_config.json.tmp` and `renameSync`s into place. Crash mid-write no longer corrupts the canonical config. *(2026-05-07)*
> - [x] **Removed dead `useEffect`** — [`dashboard/src/components/SettingsView.tsx`](dashboard/src/components/SettingsView.tsx) and its now-unused `useEffect` import. *(2026-05-07)*
> **Low (deferred — pick up if larger clusters expose jank)**
> - `React.memo` wrappers for `ClusterServiceList`, `NodeCard`, `ClusterGPUView` so the 15 s status tick doesn't re-render every row.
> - AnalyticsView: split the four chart memos so changing one input doesn't recompute all four.
> - AddNodeModal "Copied!" `setTimeout` cleanup — minor unmounted-setState warning.
> - SettingsView `pullNode`: useRef-backed in-flight set keyed by node, to harden against the small double-click race window the disabled state already mostly covers.
> ---

## Recently Completed

- **Model Library v2 - per-node download & disk management** - every library row now shows per-node cache status with on-disk size, Download/Delete buttons, and live pre-pull progress bars polled from `/models/hf/downloads`. Top strip shows per-node disk headroom with a warning above 85% usage
- **HuggingFace token management** - per-node token set/clear from the dashboard; tokens are written to `~/.cache/huggingface/token` on the actual node and masked in the UI
- **HF link-based importer** - paste a HuggingFace URL or `org/repo`; agent's `/models/hf/lookup` hits the HF API and prefills params, VRAM estimate, quant guess, context length, type, and license; user reviews before saving to the library
- **Kill silent HF gating** - `/models/hf/preflight` + `auth_check` integration in `/instances/launch` now blocks gated-and-unauthorized deploys with a readable 403 error instead of letting vLLM fail silently in its own log
- **Analytics tab** - per-node 1-minute sampler writes append-only JSONL; DuckDB aggregates to any resolution at query time; 30-day retention with daily file rotation; dashboard charts GPU utilization, requests/bucket (stacked by model), prompt+generation tokens, TTFT p95, plus cluster totals and queue-depth peak
- **Cluster-wide LiteLLM proxy** - single proxy on master serves every node's vLLM instances under one URL; agents register models dynamically using their real node IP; per-node proxy config retired; node.sh lifecycle starts/stops the proxy on master/both roles
- **Cluster-unified GPU view** - all GPUs from all nodes in one flat grid; node badge per card; click to expand for temperature, power, clock, fan
- **Cluster-unified service list** - all vLLM instances across nodes in one table; expandable rows with context length, quant, tensor parallel, direct endpoint
- **Cross-cluster deployment** - Deploy modal picks GPUs from any node; `targetNode` derived from the selected GPU
- **Child node cluster view** - child dashboards fetch the full node list from the master and show the whole cluster, not just their own GPUs
- **Unified memory GPU support** - DGX Spark GB10 / GB200 unified memory detected automatically; falls back to `torch.cuda.mem_get_info()` / psutil for VRAM reporting; `unified` badge in dashboard
- **Dashboard self-rebuild** - "Restart dashboard" button runs `npm run build` on the agent machine and restarts the server; kills by port as fallback when no PID file
- **Smart allocate (repack)** - bin-packing algorithm reassigns models across GPUs to maximise fit; shows what won't fit; direct button on each stack config row
- **Create stack from scratch** - form-based stack config creation with model picker, GPU assignment, utilisation slider
- **Snapshot running state** - capture currently running instances as a saved stack config
- **Offline node setup command** - when a node is unreachable, the dashboard shows the exact `node.sh setup` command to bring it back online
- **Per-GPU temperature, fan, power, clock** - expanded GPU card shows full telemetry panel

---

## In Progress

### Analytics - follow-on work
The v1 analytics tab ships with per-node 1-minute sampling, DuckDB aggregation, and a fixed set of charts. Remaining items to close out the full feature:

- [ ] CSV/JSON export from the Analytics tab (download current window)
- [ ] Co-residency timeline band - render the `coresident_pct` metric as a colored strip under each GPU's utilization line so "when did two models share this GPU?" is instantly visible
- [ ] Error rate panel - parse LiteLLM `/metrics` for 4xx/5xx per model; show only when non-zero
- [ ] Per-model zoom: click a model in the legend → drill-down view with requests, tokens, TTFT, queue depth aligned
- [ ] Backfill tolerance - gracefully handle clock skew across nodes when combining buckets (currently assumes nodes agree on minute boundaries)

---

## Phase 2 - Automation

**Auto-scaling overflow instances**
When a model's queue depth or GPU utilisation crosses a threshold, automatically spin up a second instance on the next free GPU and register it with LiteLLM. Tear it down when load drops.

**Time-based model scheduling**
Define a schedule (e.g. "load the 70B model 08:00–18:00 weekdays, swap to 8B overnight") that the agent enforces automatically at startup and via cron.

**Preload on boot**
Config-driven list of models that should be running at all times. Agent ensures they are present on startup and restarts them if they die.

**Queue depth alerting**
Webhook or email notification when `requests_waiting` is non-zero for more than N seconds - first signal that capacity needs to increase.

---

## Phase 3 - Multi-Node Operations

**Unified request analytics across nodes**
The usage chart currently shows one node at a time. Aggregate across all registered nodes so total cluster load is visible in one view.

**Auto-discovery of nodes (master ↔ child)**
Today, every new node that joins the cluster requires its master IP to be hardcoded into config (and the master needs to know about each child). This breaks down fast - IPs change after DHCP renewals, DGX Sparks come and go from the rack, network re-IPs (like the recent re-IP that blocked node↔VM traffic) leave the cluster in a broken state until configs are manually patched. Replace this with **subnet-scan auto-discovery** so nodes find each other over the network. Mechanism: configure each node with its **role** (master / child) plus a **discovery range** (e.g., `10.2.30.0/24` or a YAML list of candidate ranges) instead of an explicit master IP. On startup, child nodes broadcast / scan the configured range for a master agent's known port + handshake response; master nodes accept registrations from children that present a valid cluster token. Discovery uses a lightweight HTTP probe + cluster-token auth (no mDNS/Bonjour dependency - works on the Foundation's flat L2). On IP change, the rediscovery loop re-pairs the node automatically; no manual reconfig needed.
- Acceptance: kill a child node's IP, give it a new one in the same subnet, watch it auto-rejoin the cluster within ≤30 seconds.
- Acceptance: bring up a fresh node with only `role=child` + `discovery_range=10.2.30.0/24` + `cluster_token=...` in config - it finds the master and registers without any master-side intervention.
- Foundation for **Cross-node model migration** and **Dynamic cluster partitioning** below - those features assume nodes can find their master without a human in the loop.

**DNS-aware discovery - resolve device names alongside IPs**
Builds on auto-discovery above. As the master scans the discovery range and finds candidate nodes, it should also perform **reverse DNS lookups** for each responding IP and surface the resolved hostnames (e.g., `deathstar.foundation.local`, `nano-0.foundation.local`) in the dashboard's node-management view. IPs are fragile - they change with DHCP renewals and re-IPs - but DNS names are stable, human-readable, and what staff actually remember when troubleshooting ("is Death Star up?" not "is 10.2.30.28 up?"). Capability:
- Forward + reverse DNS resolution as part of the scan: for each candidate IP that responds to the discovery probe, resolve `PTR` to get the hostname; if hostname-based config is preferred, resolve forward (`A`/`AAAA`) on a configured DNS suffix.
- **Search-by-DNS-name** in the dashboard: type "deathstar" and the dashboard finds the node regardless of its current IP.
- **Assign nodes by DNS name, not IP**: in the agent / proxy / partition config, allow `master: deathstar.foundation.local` instead of `master: 10.2.30.28`. The agent re-resolves on each connection attempt - IP changes are transparent.
- Surface both name + IP in the UI: e.g., `Death Star (deathstar.foundation.local · 10.2.30.28)` so the operator sees the human name first and the current IP for reference.
- **Range-scan picklist**: when scanning a configured range, reverse-resolve every responding host and present the result as a picklist of DNS names - also surface nodes that are reachable but **not yet registered** with this cluster (useful for catching forgotten boxes or planning expansion).
- Pairs with device-profile presets in Phase 6 - pick the host from the DNS list, pick the device profile, setup proceeds.
- Graceful fallback when DNS is misconfigured or unavailable: fall back to IP-only display + assignment, but log the missing resolution so it can be fixed.
- Acceptance: rename a node in DNS without touching cluster configs - the dashboard reflects the new name on next refresh.
- Acceptance: re-IP a node - the dashboard continues to show the same DNS name and the cluster keeps working without manual reconfiguration.

*Origin:* Cody's input - moving the cluster off hardcoded IPs is what makes the rest of the network operations sustainable. DNS is the layer that makes auto-discovery results human-friendly.

**Cross-node model migration**
Move a running model from one GPU/node to another via the dashboard - drain connections, launch on target, deregister source.

**Dynamic cluster partitioning (dual-master sandbox)**
Split the node pool into two (or more) independent clusters from the same physical hardware - a production partition and a staging/testing/batch partition. Each partition has its own master (dashboard + LiteLLM proxy), its own model library authority, its own analytics JSONL, and its own set of assigned nodes; traffic and deploys are isolated between them. Mechanism: add a `partition` field to `node_config.json` and to each node entry in `nodes[]`; the master that serves a partition only shows/manages nodes whose partition matches. A "Fork partition" action in the dashboard picks which of the current nodes come along to the new partition, promotes one as its master, re-registers its agents to point at the new master's proxy, and leaves the production master untouched. Nodes can move between partitions via the dashboard without a service restart - just a config push + proxy re-registration.

Two driving use cases:
1. **Testing** - try new vLLM versions, new model combos, or a risky node.sh change on a subset of hardware without taking the production cluster offline.
2. **Heavy batch isolation** - when a batch workload (eval sweeps, embedding a large corpus, fine-tuning feedback loops) would otherwise hammer interactive production traffic, peel off a few nodes into a batch partition so the network, GPU queues, and VRAM pressure stay contained. When the batch finishes, merge the nodes back.

**Multi-GPU model sharding - run models larger than a single GPU**
Two tiers of GPU combining, at different stages of readiness:
- *Single-node tensor parallelism (supported today)* - launch with `--tensor-parallel-size N` in the Deploy modal; vLLM splits the model's weight matrices across N GPUs on the same machine via NVLink/PCIe. The Deathstar's 4-GPU configuration can hold up to ~384 GB of model weight today.
- *Cross-node pipeline parallelism (future)* - vLLM supports Ray-backed distributed serving across separate machines. This would allow combining GPUs on Deathstar + Nano 0 for a model that requires more VRAM than any single node holds. Requires standing up a Ray cluster across nodes, wiring the agent's launch flow to pass `--pipeline-parallel-size` and the Ray head address, and coordinating model-weight distribution across the WAN link. High network bandwidth between nodes is critical - NVLink is not available cross-node so tensor parallelism is impractical; pipeline parallelism (each node handles different layers) is the correct topology.

**Zero-downtime rolling restart**
One-click "restart everything cleanly" - bring the cluster back to a known-good state without dropping in-flight inference. Agent/dashboard/proxy restarts individually today already lose any model registrations that weren't persisted, and a full `node.sh stop && start` kills every vLLM worker. Mechanism: for each node in sequence, drain its LiteLLM traffic (set weight → 0), wait for in-flight requests, restart the agent and dashboard, replay registered models from a saved manifest (`.cluster_state.json`), verify health, then restore traffic weight. Proxy restarts go last and use a pre-warmed config so there's no registration gap. End state is a fully-refreshed stack with no observable downtime to clients. Builds on cross-node migration + request analytics (to know when "drained" is actually drained).

---

## Model Library - follow-on work

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

## Phase 4 - Management & Security

**Dashboard authentication**
Currently the dashboard is open to anyone on the network. Add optional basic-auth or token-based login, configurable in `node_config.json`.

**API key management**
Issue per-application keys through LiteLLM. Track usage per key so you know which app is generating load.

**Per-app usage quotas**
Rate-limit or cap token usage per API key - useful when multiple teams share the cluster.

**Audit log**
Persistent log of who launched/stopped which model, when, from which IP. Written by the agent on every mutating action.

---

## Phase 5 - Developer Experience

**Bake the terminal startup menu into the webapp (setup wizard + Settings panel)**
Today the node manager presents an interactive menu in the terminal at startup - setup, configure role/IP/port, pick a device profile, edit `node_config.json`, etc. Anyone bringing up a new node has to SSH into it and drive that menu by hand. Move the entire menu into the dashboard so setup is point-and-click, not CLI:
- **First-run setup wizard** - when a fresh node starts up and has no valid config, the agent puts the dashboard in a "setup" state. Operator opens the dashboard URL, walks through the same questions the terminal menu asks (role, IP/DNS name, port, discovery range, cluster token, device profile, GPU layout) - but in a real form, with validation, sensible defaults, and inline help text per field. Saves the result to `node_config.json` and starts the agent normally.
- **Settings panel - same menu, but accessible later** - every option from the startup menu also lives in a `Settings` view in the dashboard, so configuration changes (e.g., change role from child to master, swap discovery range, rotate cluster token, switch device profile) don't require dropping back to the terminal. Edits write through to the same config files; agent reloads or restarts as needed with a clear "this requires a restart" prompt where applicable.
- **Per-node and cluster-wide views** - Settings should distinguish node-local config (this node's role, IP, GPU layout) from cluster-wide config (cluster token, discovery range, partition assignment). Operator picks which they're editing.
- **Audit / change history** - every config change made through the UI gets logged (who, when, what changed, before → after) - pairs well with the audit log item in Phase 4.
- **Terminal menu stays as a fallback** - for headless setup, recovery scenarios, or scripted bring-up, the CLI menu doesn't go away. The webapp is the new default; the terminal is the safety net.
- **Pairs with Phase 6 device-profile presets** - once profiles exist as `setup_profiles/*.yaml`, the wizard's "Device type" question becomes a dropdown that pulls from the profile registry. New hardware = add a profile = it shows up in the wizard.
- Acceptance: bring up a brand-new node, never SSH into it, complete setup entirely from the dashboard, and have it join the cluster.
- Acceptance: change a node's role from child → master in the Settings panel; agent reconfigures and the change is reflected across the cluster within a refresh cycle.

**Request playground in dashboard**
Send a test chat or embedding request directly from the dashboard UI, see the response and latency inline. Removes the need to open a separate tool to verify a newly deployed model is working.

**OpenAPI explorer**
Embed Swagger UI in the dashboard pointing at the LiteLLM proxy, so API consumers can explore available models and endpoints without leaving the browser.

**Model benchmarking**
One-click throughput test: send N concurrent requests to a model, report tokens/second, time-to-first-token, and latency p50/p95. Helps compare quantization options before committing a GPU slot.

**Webhook notifications**
Push events (model healthy, model crashed, GPU OOM, scale-up triggered) to a configurable URL - Slack, Teams, or any webhook receiver.

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
*Precursor step now documented, 2026-08-04:* the human/tooling bring-up sequence that happens before `node.sh setup` even runs - install Claude CLI, then VS Code, then Obsidian, prepare SSH, then hand Claude the Second Brain's own instructions to finish the rest. See [[Node-Bring-Up-Checklist-2026-08-04]], captured from onboarding Death Star 2. This is now the standard starting point for bringing up any new node, ahead of the automated preset work below.

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

- LM Studio process auto-detection - show actual model name in the GPU process list rather than the raw process label
- Embedding model benchmarking (MTEB subset) - quick retrieval benchmark against a deployed embedding model
- Dark/light theme toggle in dashboard
- Pin a node card to the top of the dashboard
- Export utilization data to Grafana via a Prometheus scrape endpoint on the agent
- Per-node resource reservations - prevent the stack from filling a GPU that's allocated to LM Studio or another tool
- Model family grouping in the deploy modal - show all quantization variants of a base model together

---

## Cross-cutting: In-tool Feedback Widget

- [ ] When the Foundation AI Dashboard ships its in-tool feedback widget, drop the shared component into this tool's UI (vLLM Dashboard surface — for IT operators to give feedback on cluster management UX). Per-tool work = thin embed; the shared widget, API, GitHub Issue routing, and central aggregation view are built once in the Foundation AI Dashboard. **Canonical source of truth (design / architecture / acceptance criteria):** [Foundation AI Dashboard → Phase 7](../Foundation%20AI%20Dashboard/Roadmap.md).

---

**Last Updated:** 2026-07-17 (CUDA blocker marked resolved; Death Star backends documented)
