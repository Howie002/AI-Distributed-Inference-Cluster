# AI Distributed Inference Cluster

> *Reconciled 2026-07-29 (SB↔repo): the vault copy is canonical. Where both sides had drifted in the same section, the older repo wording was superseded — it remains intact in the repo's git history at the pre-reconciliation commit.*
*(Renamed 2026-04-29 from "Foundation AI Infrastructure" / repo `vllm-start-point`. Scope unchanged.)*

## Repository
- **GitHub:** [Howie002/AI-Distributed-Inference-Cluster](https://github.com/Howie002/AI-Distributed-Inference-Cluster) (private)
- **GitLab:** [tamfassoc_gitlab/ai/AI-Distributed-Inference-Cluster](https://gitlab.com/tamfassoc_gitlab/ai/AI-Distributed-Inference-Cluster) (private) - *⚠️ corrected 2026-07-29: the aivm clone has NO GitLab push remote (GitHub-only), like every fleet repo. Dual-remote directive reconciliation flagged to Andrew.*
- **Branches:** `main` stable, `dev` active (currently equal)
- **Docs synced to:** `repo/docs/`
- **Roadmap:** `repo/docs/Roadmap.md` (mirrors `Roadmap.md` in the vault folder)
- **Scope:** dashboard + control agent + vLLM workers + LiteLLM router - the control plane for the multi-node GPU cluster

## Purpose
Enduring project tracking the build-out, migration, maintenance, and evolution of Foundation's on-premises AI inference cluster. Covers hardware fleet management, v2 architecture migration, dashboard & agent development, future scaling decisions, and ongoing operational health.

## Status
**Current Phase:** Maintain - cluster operational, serving the fleet; additional capability added as needed rather than under active build
**Moved to Maintain:** 2026-07-17
**Started:** 2025
**Last Updated:** 2026-07-08

> **Current Phase:** v2 Cluster - Operational Hardening + Analytics Follow-on
> **Started:** 2025
> **Last Updated:** 2026-07-17

## Current Architecture (v2)

Multi-node GPU cluster managed via the cluster dashboard (`AI-Distributed-Inference-Cluster` repo). Cluster includes master + child nodes, unified GPU view, LiteLLM proxy for model serving, and per-node analytics. DGX Spark unified memory (GB10) fully supported; cross-node deployment works via dashboard. Previous architecture used Docker Compose on a single VM with Nginx-round-robin to Ollama nodes - that pattern has been superseded by the dashboard-managed cluster.

**Reference:** See [Foundation AI Strategic Roadmap.md](../../Foundation AI Strategic Roadmap.md) for full architecture diagram, network topology, and port map.

## Services on the Cluster

### TTS / Voice — Voicebox (live 2026-07-08; moved to DS2 + failover proxy 2026-08-18)
Text-to-speech + STT + voice cloning is served by **[Voicebox](https://voicebox.sh)** (open-source, local-first voice studio), running **headless in Docker on Death Star 2 (`10.2.35.21`)**. It originally ran on DS1 (`10.2.35.20`); that box was decommissioned and returned to HP (2026-08-19), and Voicebox moved to DS2. This replaced the abandoned Higgs Audio V3 effort (Higgs hit an unrecoverable sm120 driver/kernel wall; see Notes.md).

- **Endpoint:** consumers use the **failover proxy at `http://10.2.35.10:17600`** (aivm), NOT a node directly — `/generate` (TTS, async), `/captures` (STT), `/profiles`. It is a **custom API, not OpenAI `/v1/audio/speech`**, so it deliberately does **not** route through the LiteLLM proxy. The proxy is active/passive over **DS2 → Lone Starr → Nano** and includes a capability deep-check; Lone Starr became the first real failover target on 2026-08-25 (capability-verified). See `voicebox-failover-proxy` and Notes.md 2026-08-18/08-19.
- **GPU:** runs on a Blackwell card. The sm120 kernel gap that killed Higgs is resolved by the container's torch (ships `sm_120` kernels). `/health` reports `backend_variant: cuda`.
- **Engines:** clone-only voices via `chatterbox`/`chatterbox_turbo` (qwen/kokoro paths retired 2026-08-10). Each `/generate` needs a **voice profile** (`POST /profiles`); `/generate` is **async** (returns `generating`, then poll `/history/{id}`, fetch `/audio/{id}` on the same node).
- **Ops:** on DS2, `~/voicebox/{start,stop}_voicebox.sh` (reboot-persistent). The failover proxy on aivm is a user-crontab (`@reboot` + `*/2` watchdog); give it a systemd unit when someone can sudo.

## Hardware Fleet

> ⚠️ This table is known stale in places (e.g., "VM Host: TBD" - the VM has been live at `10.2.35.10` since May) and hasn't had a full reconciliation pass. The **Death Star** rows are current as of 2026-08-19 and **Lone Starr** as of 2026-08-20; treat the rest with caution until reconciled against Notes.md's dated entries.

| Device | Model | GPU | IP | Role | Status |
|--------|-------|-----|-----|------|--------|
| Master VM | - | N/A | `10.2.35.10` | Orchestrator (proxy, control agent, dashboard) | Live |
| ~~Death Star (DS1)~~ | HP Z8 Fury | 4× RTX Pro 6000 Blackwell (~382 GB total) | `10.2.35.20` | Big compute | **REMOVED 2026-08-19** — returned to HP, will not be plugged in again; deregistered from the node registry + failover proxy. |
| **Death Star 2 (DS2)** | **HP Z8 Fury G5 Workstation** (SKU `4Z3K7AV`, Xeon w5-3433 32c, 62 GiB RAM; chassis confirmed via DMI 2026-08-18) | 4× RTX Pro 6000 Blackwell Max-Q (~382 GB total, confirmed via agent) | **`10.2.35.21`** | Big compute | **Live — the permanent big-compute unit** (hosts gemma + both nomic replicas + Voicebox); all three vLLM instances serving + load-balancing verified 2026-08-18. |
| **Nano 0** / DGX Spark (**Dark Helmet**) | HP ZGX Nano G1n (`zgx-0d80`) | NVIDIA GB10, 128GB | `10.2.35.30` | Small compute | Live |
| **Lone Starr** / DGX Spark 1 | HP ZGX Nano G1n (`zgx-0f1e`) | NVIDIA GB10, 128GB | `10.2.35.31` | Small compute | **Setup In Progress** (2026-08-18) - up, SSH access confirmed, currently at Andrew's desk; bring-up checklist underway before move to the server room. Registered in the cluster node registry (observed via `GET /nodes` 2026-08-20). |
| AMD Box | HP AI Box | AMD 395+, 128GB | TBD | Testing / Staging | Available |
| Z Workstation (pilot) | HP Z Workstation | 4× RTX Pro 6000 Blackwell | — | Pilot - Snowflake AI | **RESOLVED / MOOT 2026-08-18 (Andrew):** purchase decision changed. **Death Star 2 is the final unit and is being kept; Death Star 1 goes back.** The earlier "is DS2 the same unit as the pilot?" question no longer gates anything - DS2 is permanent either way. |

## Infrastructure Phases

### Phase 1 - v2 Migration (Active)
Complete the migration from AMD Box single-node to VM + dual DGX Spark architecture. Establish snapshot/DR capability, round-robin inference, and staging pipeline.

### Phase 2 - Z Workstation Pilot (Parallel)
Evaluate HP Z Workstation (4x RTX Pro 6000 Blackwell) for high-capacity inference. Purchase decision: 2x workstations with 2 cards each if validated. See HP Z Workstation Pilot project.

### Phase 3 - Capacity Expansion (Future)
Scale inference capacity based on usage patterns from pilots. Options:
- Add DGX Spark nodes to Nginx upstream
- Purchase Z Workstations (2x with 2 cards each)
- ZGX Furry evaluation (750GB+ unified memory, 1T+ parameter models)

### Phase 4 - Monitoring & Operations (Ongoing)
GPU load dashboards, uptime monitoring, cost tracking, snapshot cadence, model management across nodes.

## Key Contacts
- **Andrew Howerton** - Infrastructure Lead
- HP Representative (hardware/pilot coordination) - Erik Hawkins (erik-michael.hawkins@hp.com), Jesse Otts (jesse.otts@hp.com)
- Foundation IT/IS - Jose and team (network, security, VM provisioning)

## Related Projects
- [Foundation Snowflake AI](../Foundation Snowflake AI/Overview.md) - first major workload targeting Z Workstation
- [Foundation Secure Chat](../Foundation Secure Chat/Overview.md) - primary app service running on infrastructure
- *Foundation Way Coach - archived 2026-04-20*
- *HP Z Workstation Pilot - merged into this project's Hardware section (2026-04-27); standalone folder removed*

---

## HP Z Workstation Pilot Detail
*(Merged from the standalone "HP Z Workstation Pilot" project on 2026-04-27. The pilot is part of Foundation AI Infrastructure's hardware fleet evaluation, not a separate project.)*

### Pilot Hardware
| Component | Detail |
|-----------|--------|
| **Device** | HP Z Workstation (model TBD) |
| **GPUs** | 4× NVIDIA RTX Pro 6000 Blackwell |
| **GPU Memory** | TBD (specs pending hardware arrival) |
| **System RAM** | TBD |
| **Storage** | TBD |
| **Status** | TENTATIVE - Pilot Loaner |

> Update specs once hardware arrives.

### Purchase Plan (If Validated) — ⚠️ SUPERSEDED 2026-08-18

> **Do not plan from the table below.** Andrew changed the purchase decision: **Death Star 2 (4× RTX Pro 6000 Blackwell Max-Q) is the final kept unit and Death Star 1 is being returned** - DS2 is near spec-for-spec identical to DS1. The "2 units × 2 GPUs each" shape below never happened; anything reasoning from it (e.g. inferring unit identity from GPU count) will reach the wrong conclusion.
- **Units:** 2× HP Z Workstations
- **GPUs per unit:** 2× NVIDIA RTX Pro 6000 Blackwell
- **Rationale:** Distributed across two machines for redundancy; expandable to 4 cards per machine if needed
- **Role:** Replace or supplement DGX Sparks for high-demand inference workloads

### Why This Hardware Matters
RTX Pro 6000 Blackwell cards provide substantially more GPU memory than the DGX Spark GB10 nodes, enabling:
- Larger models (higher parameter counts) without quantization tradeoffs
- Batch processing workloads (e.g., AI extraction across entire Snowflake tables)
- Multi-GPU inference for very large models (if NVLink supported)
- Potential for fine-tuning smaller models on Foundation data

### Pilot Role in v2 Cluster
**Current pilot role:** standalone inference node for Snowflake AI app testing. Connects directly to the Streamlit app during testing - not yet registered with the vLLM dashboard / LiteLLM proxy.

**Future role (if purchased):** two workstations join the cluster via the vLLM dashboard, alongside or replacing DGX Sparks based on benchmark results.

### Pilot Contacts
- **Andrew Howerton** - Project Lead
- HP representative (pilot coordination) - Erik Hawkins (erik-michael.hawkins@hp.com), Jesse Otts (jesse.otts@hp.com)

## Future Considerations
- **ZGX Furry** - 750GB+ unified memory, 1T parameter models, training/fine-tuning capability
- **GPU monitoring dashboard** - inference load tracking across DGX Sparks and future nodes
- **Foundation Way Coach S2S** - Whisper STT + Kokoro TTS now both provided by the Voicebox service (see Services section); remaining need is the S2S orchestration/pipeline
- **Nginx upstream expansion** - adding nodes is a one-line config change

---

**Filed Under:** Work Projects > 3. Maintain
**Created:** 2026-03-05
**Last Updated:** 2026-07-08

> - **ZGX Furry** - 750GB+ unified memory, 1T parameter models, training/fine-tuning capability
> - **GPU monitoring dashboard** - inference load tracking across DGX Sparks and future nodes
> - **Foundation Way Coach S2S** - will require additional containers (Whisper, S2S pipeline, Kokoro)
> - **Nginx upstream expansion** - adding nodes is a one-line config change
> ---
> **Filed Under:** Work Projects > Active Priority
> **Created:** 2026-03-05
> **Last Updated:** 2026-07-17

