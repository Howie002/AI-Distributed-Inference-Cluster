# AI Distributed Inference Cluster - Notes

## 2026-06-24 (late) — Turning away from `gemma-4-31b`; node rename to Death Star

**Decision: `gemma-4-31b` is not a production model on this cluster.** After today's repeated silent-exit failures during APIServer init (post the zombie sweep that freed ~40 GB of leaked RAM), we're stepping away from it as the default. **`gemma-4-26b-a4b-nvfp4`** is the canonical chat/completions model going forward — it's instruction-tuned, runs reliably on GPU Server 1, supports `/v1/chat/completions` natively, and produces equivalent-or-better structured output for the HyperFrames pipeline at lower latency.

**Why retire 31b:**
- Operationally fragile: required `--enforce-eager` (Blackwell SM 12.x CUDA gap), occasionally dropped off the cluster mid-session, took 2+ minutes to load 58 GB BF16 weights, and after today's zombie cleanup wouldn't relaunch at all (silent exit before EngineCore spawn, no traceback).
- Base model — needed an explicit chat template Jinja just to be usable from `/v1/chat/completions`, and the responses are still less polished than the instruction-tuned 26B.
- HyperFrames pipeline used 31b via `/v1/completions` with Gemma turn markers, but the 26B understands the same turn markers AND is chat-native. Net win: simpler, more reliable, faster.

**What this changes:**
- `HyperFrames Education Generator/pipeline/llm.py` and `start.sh` now default to `gemma-4-26b-a4b-nvfp4` (was `gemma-4-31b`). Override via `PIPELINE_LLM_MODEL` env var if you need to test something else.
- Cluster recommendation: point dashboard testing tab + consumer code at the 26B by default.
- `chat_template` flag support in the agent stays useful for future base models (any non-instruction-tuned model coming in via the model library), but is not in active use right now.

**Node rename: `Deat Star` → `Death Star`.** Cosmetic spelling fix. Done via `PATCH /nodes/10.2.35.20` on master with `{"name":"Death Star","agent_port":5000}`. Master's `node_config.json` updated; dashboard now shows the correct name. No service interruption.

**Restart-resilience on Death Star.** Confirmed the watchdog recovers cleanly:
- Local agent was down at start of this turn (orphan from earlier zombie cleanup). Restarted via `bash ./agent/start_agent.sh`.
- Within 45s the watchdog re-launched `nomic-embed-text-v1-5` from `intended_instances.json` (port 8022, GPU 2, healthy).
- The 26B-A4B local copy is also intended but takes longer to relaunch (separate from the routed copy on GPU Server 1 — the local one has `register_with_proxy: false`).
- **systemd auto-start NOT installed** on Death Star yet — needs `sudo bash node.sh install-systemd` from a terminal with a real TTY. Without it, the cluster does not auto-bring-up on machine reboot. Adding to the carry-over list.

---

## 2026-06-24 — Master role correction, Death Star decommission, 31B + nomic-embed back on Deat Star

Big day for cluster hygiene. Net effect: the proxy at `10.2.35.10:4000` now routes three models cleanly across the live nodes, the master role is no longer pretending to be compute-eligible, and the agent has the endpoints needed to manage cluster topology from the dashboard going forward.

### Topology + role clarification (now canonical)

- **Master `10.2.35.10` is a VM, role=`master`, orchestrator-only. No GPU, no NVIDIA drivers, never will.** Hosts LiteLLM proxy (`:4000`), control agent (`:5000`), dashboard (`:3005`), plus the other Foundation backends (Portfolio-Strategy-Tools, Scholarships-Tools, Research-Fundable-Ideas-Marketplace, etc.). Moving the master is not on the table — co-tenancy with those services is intentional.
- `nvidia-smi: No such file or directory` from master's `/gpus` is **expected and correct**, not a bug to chase. Agent now resolves nvidia-smi via `shutil.which()` + 4 fallback paths, so when drivers DO exist on a node but PATH is stripped (systemd, minimal nohup), the agent finds them.
- **Death Star `10.2.30.20` decommissioned.** Node no longer exists. Dropped from the master's `node_config.json` via the new `DELETE /nodes/{ip}` endpoint. The other `10.2.30.x` references in older notes are obsolete.

**Current node fleet:**

| Node | IP | Role | Hardware | Purpose |
|---|---|---|---|---|
| Master VM | `10.2.35.10` | `master` | CPU-only VM | Proxy + agent + dashboard + Foundation backends |
| GPU Server 1 | `10.2.35.30` | `child` | 1× NVIDIA GB10 (DGX Spark, 122 GB unified) | Compute |
| Deat Star | `10.2.35.20` | `child` | 4× NVIDIA RTX PRO 6000 Blackwell Max-Q (~95.6 GB each, ~382 GB total) | Compute |

### Models currently routed via the proxy

| Served name | Hosted on | GPU | VRAM | Notes |
|---|---|---|---|---|
| `gemma-4-26b-a4b-nvfp4` | GPU Server 1 | 0 | ~102 GB at 0.85 util | NVFP4 quant, 100K context |
| `gemma-4-31b` | Deat Star | 3 | ~93 GB at 0.95 util | BF16 dense, 32K context, base model (not instruction-tuned) |
| `nomic-embed-text-v1-5` | Deat Star | 2 | ~1.3 GB at 0.15 util | 768-dim embeddings, **2048-token max context** (not 8192) |

**Deat Star orphan VRAM right now:** GPU 0 has 88.7 GB held by a dead vLLM process (a first launch attempt during today's testing); GPU 1 has 20.3 GB leaked from a pre-existing dead process. Both are reclaimable by the agent's `_reclaim_vram_before_launch` on next launch on those GPUs — non-blocking, but worth cleaning up if we need the headroom.

### Two operational gotchas every consumer must know

**1. `gemma-4-31b` is a base model, not chat-tuned.** Calls to `/v1/chat/completions` will fail with a malformed response. Use `/v1/completions` with manual Gemma turn markers:

```
prompt = "<start_of_turn>user\n{message}<end_of_turn>\n<start_of_turn>model\n"
stop = ["<end_of_turn>"]
```

The 26B-A4B (`gemma-4-26b-a4b-nvfp4`) IS instruction-tuned and works fine with `/v1/chat/completions` — choose model intentionally.

**2. LiteLLM injects `encoding_format=None` on `/v1/embeddings`, which vLLM rejects with HTTP 400.** Every consumer hitting the proxy for embeddings **must pass `encoding_format: "float"` explicitly**:

```json
POST http://10.2.35.10:4000/v1/embeddings
{"model": "nomic-embed-text-v1-5", "input": "...", "encoding_format": "float"}
```

Direct calls to the vLLM port (`:8022` on Deat Star) don't have this issue — only via the proxy. Worth fixing at the LiteLLM config level (drop_params or a per-model override) so consumers don't have to remember; logged as follow-up.

### Agent / dashboard capability adds (shipped today)

Commits `e09bc19 → a7cec43` on `Howie002/AI-Distributed-Inference-Cluster` main. Brings ~1000 lines of previously-uncommitted cluster work to ground truth, plus today's additions.

- **`DELETE /nodes/{ip}?agent_port=N`** — drop a registered child from the master's `node_config.json`. Mirrors the existing PATCH (rename) handler. Master-only. Also clears the `_REGISTERED_CHILDREN` registry so a re-registered child can't ghost back via stale discovery state.
- **`POST /role`** — flip role between `master`/`child`/`both`. Updates config + triggers `os.execv` restart so the new role takes effect immediately.
- **`GET /nodes` auto-includes self when role=`both`** (not master) — orchestrator-only nodes shouldn't show as deploy targets in the dashboard; nodes that ARE compute-eligible (role=both) do.
- **`POST /update/pull?force=true`** — git-stashes local writeback before pulling. Solves the "master accumulated runtime writeback that blocks ff-only pull" chicken-and-egg. Default behaviour (no force) is unchanged: still refuses on dirty state.
- **nvidia-smi PATH resolver** — `shutil.which()` first, then `/usr/bin`, `/usr/local/bin`, `/usr/local/nvidia/bin`, `/opt/nvidia/bin`. Bare fallback if none exist (correct for genuine no-GPU nodes like the master).
- **Dashboard:** "Remove from cluster…" button on the EditNodeModal with two-step confirmation. Hidden on the master's synthetic self-entry.
- **systemd integration in `node.sh`** (`install-systemd` / `remove-systemd`) — three role-aware units for auto-restart on crash + boot-time bring-up.

### Open follow-ups

- **Master is one commit behind** (`82a851a` → newer). Master accumulated runtime writeback (`litellm/cluster_config.yaml`, `boot.meta.json`) and `/update/pull` refused. The `force=true` option ships in the new commits, so the chicken-and-egg needs **one** hand-clearing — SSH to master, run `git stash push --include-untracked && git pull && curl -X POST http://localhost:5000/agent/restart`. After that, future deploys can use `curl -X POST http://10.2.35.10:5000/update/pull?force=true` remotely.
- **Surface the LiteLLM embedding `encoding_format` quirk** in the cluster README / docs so consumers don't trip on it.
- **Dashboard `dev` branch on GitHub is ahead of local** — someone (CI? webhook? earlier session?) pushed to `dev` independently. Need to fetch + reconcile before next dev work.

### Late-afternoon addendum: chat_template flag, zombie sweep, 31B load failure

- **Dashboard testing tab failed against `gemma-4-31b`** with `transformers v4.44: default chat template is no longer allowed`. gemma-4-31B is a base model (no tokenizer chat_template). Fix landed in agent: added `chat_template`, `enable_auto_tool_choice`, `tool_call_parser` flag passthrough in `_build_vllm_cmd`, plus a canonical Gemma Jinja template at `agent/chat_templates/gemma.jinja`.
- **Recommendation: use `gemma-4-26b-a4b-nvfp4` for chat completions.** It's instruction-tuned, already routed, and works natively via `/v1/chat/completions` (verified end-to-end via proxy). Point the dashboard testing tab default at this model.
- **Zombie sweep on Deat Star.** Discovered 30+ leaked vLLM processes from past 4-7 days holding ~40 GB of RSS each (~1.4 GB × 30). System was at 1.5 GB free / 31 GB swap exhausted. Killed all stale `vllm serve` PIDs except the two healthy actives. Memory recovered to 22 GB free, swap mostly clear. **Root cause unknown** — watchdog should be cleaning up failed launches but evidently doesn't catch every case. Worth investigating: how do we end up with dozens of stale vllm PIDs running for days without the agent tracking them?
- **`gemma-4-31b` won't relaunch right now.** Silent exit during APIServer init (right after `nixl_utils.py` log line), before EngineCore subprocess spawn. No traceback, no OOM kill in dmesg, just clean exit + resource_tracker semaphore-leak warnings. Multiple retries on GPU 3 (post-cleanup), with and without chat_template, all the same. Earlier today's successful run was on the SAME machine in a DIFFERENT state (before the zombie sweep). Theory: multiprocessing semaphore namespace got disturbed by the bulk SIGKILL, vLLM's spawn() is failing silently. Removed `gemma-4-31b` from `intended_instances.json` to stop the watchdog cycling. **Holding for fresh investigation next session** — might need a Deat Star reboot to reset the multiprocessing namespace.
- **Final cluster state at end of session:**
  - `gemma-4-26b-a4b-nvfp4` on GPU Server 1 (chat + completions) — healthy
  - `nomic-embed-text-v1-5` on Deat Star GPU 2 (embeddings) — healthy
  - `gemma-4-31b` not running — pending diagnosis
  - Master VM proxy at `10.2.35.10:4000` routes the two healthy models

---

## 2026-06-16 — Single-user latency vs. throughput: Blackwell concurrency benchmark (diagnosis only, no code change)

Andrew/Dominic noted Foundation Chat "feels slow" given the Blackwell 6000s in the cluster, and asked (a) is it only using the Nano, and (b) would reducing parallelism increase throughput.

**Findings (benchmarked one Blackwell, `10.2.35.20:8020`):**
- **Not Nano-only** — `:4000` load-balances `least-busy` across all 3 gemma backends.
- Single-stream decode is the floor: **~22 tok/s per request**, with the GPU only ~44% utilized / 160 W of a 300 W cap / 46 °C under one request → **decode-bound, not throttling**.
- Concurrency sweep proves parallelism *creates* throughput and barely touches single-user speed until saturation:

| Concurrent reqs | Aggregate tok/s | Per-request tok/s |
|---|---|---|
| 1 | 22.0 | 22.0 |
| 4 | 93.5 | 23.4 |
| 8 | 175.5 | 21.9 |
| 16 | 254.1 | 15.9 |

**Answers.** (a) No, not Nano-only. (b) **No — reducing parallelism would *lower* the aggregate ceiling** (the 22→254 tok/s gain from N=1→16) without improving single-user latency. `max_num_seqs: 256` isn't engaged at batch-1; `tensor_parallel_size` is already null (optimal for single-stream). The ~44% utilization is *because* parallelism is low (one user = batch of 1), not because of parallelism overhead.

**The only lever for one user feeling faster is speculative decoding** (small draft model → realistic ~35–45 tok/s single-stream) — a cluster vLLM relaunch flag, i.e. **Cody/Andrew infra territory**. Offered to write the exact `vllm serve --speculative-config …` spec + a before/after benchmark harness so it's a one-shot, measurable change. (N=16 GPU-util=0% sample was a timing artifact between scheduling batches.) Separate from the `[[reference_deathstar_cuda_blocker]]` (Deathstar still on CUDA 12.8).

---

## 2026-06-05 - Cluster dashboard up on :3005; Death Star gemma blocked on CUDA 12.8

**Dashboard live on `:3005`.** Brought up the `vllm-dashboard` (production build via `dashboard/start_dashboard.sh`) on **`:3005`** + the control agent (`agent/start_agent.sh`) on **`:5000`** on the master (aivm). Verified: dashboard HTTP 200, agent `/health` 200, dashboard→agent rewrite (`/api/agent/*`) 200, LiteLLM proxy `:4000` alive. Reachable on both legs (`localhost:3005`, `10.2.35.10:3005`, `10.2.30.29:3005`); external `aisandbox/...` would need an Entra App Proxy publish (Cody), not a box change.

**🛑 Death Star can't serve the nvfp4 gemma yet — CUDA version gap.** Tried to add Death Star (`10.2.35.20`, 4× RTX PRO 6000 Blackwell ≈ 392 GB VRAM) to inference so Deep Research could load-balance onto it. The model (`nvidia/Gemma-4-26B-A4B-NVFP4`) **was already cached** there, and the launch path worked (agent `POST /instances/launch` → spawns vLLM → child delegates to master `/proxy/sync` → regenerates `cluster_config.yaml` + restarts `:4000`; same `served_name` on Nano+DeathStar = `least-busy` load-balancing, **zero DR changes**). But the instance **crash-looped**: vLLM log `Failed to get device capability: SM 12.x requires CUDA >= 12.9`, and the agent's CUDA path is `cuda-12.8`. **Death Star is on CUDA 12.8; Blackwell SM 12.x + ModelOpt nvfp4 kernels need ≥ 12.9.** The Nano (GB10 Blackwell) serves the same model fine on a newer CUDA. **Stopped cleanly** (`DELETE /instances/8020`, watchdog intent cleared, GPUs idle); proxy was **never modified** (sync was deliberately deferred until health) so DR/R&FI were unaffected throughout. **Fix = upgrade Death Star CUDA toolkit/driver to ≥ 12.9 + matching vLLM build (Cody/owner task)**, then one-shot relaunch. Detail in memory `reference_deathstar_cuda_blocker`. ⚠️ Supersedes the old "Death Star not migrated" caveat — it IS on the VLAN now; the remaining gap is purely CUDA.

---

## 2026-06-04 - Death Star migrated to AI VLAN (10.2.35.20) - migration complete

Death Star moved from `10.2.30.28` (interim subnet) to **`10.2.35.20`** (AI VLAN, big-compute band `.20-.29`) on 2026-06-04. All three AI devices are now on the `.35` VLAN:
- VM: `10.2.35.10` (management band) - done
- Nano 0 (`zgx-0d80`): `10.2.35.30` (small-compute band) - done
- Death Star: `10.2.35.20` (big-compute band) - **done 2026-06-04**

Death Star moved from `10.2.30.28` (interim subnet) to **`10.2.35.20`** (AI VLAN, big-compute band `.20-.29`) on 2026-06-04.

**Open follow-up for 2026-06-05:**
- Confirm MAC address with Cody and document in the IP inventory
- Verify Death Star is reachable from the VM at `10.2.35.20`
- Update any configs still referencing `10.2.30.28`
- Confirm cluster dashboard and LiteLLM proxy still route correctly to Death Star

---

## 2026-06-04 - LiteLLM proxy down after the aivm reboot; restored (model backend never went down)

The 6/3 23:05 aivm maintenance reboot took down the **master's LiteLLM proxy** (`10.2.35.10:4000`) — it's not a systemd service. This broke every consumer (HR "LLM insights", Deep Research) with "Cluster unreachable / fetch failed". Key diagnosis: the **model backend was fine the whole time** — the Nano node (`10.2.35.30`) was reachable, its agent (`:5000`) up, and the **gemma vLLM (`:8020`) still serving `gemma-4-26b-a4b-nvfp4`** (102 GB on the GB10, confirmed via the agent `/status`). Only the master `:4000` proxy needed restarting.

**Fix:** `cd AI-Distributed-Inference-Cluster && PROXY_BIND_IP=10.2.35.10 bash litellm/start_proxy.sh` → proxy up on `:4000` using `litellm/cluster_config.yaml` (gemma → Nano `:8020`). Verified end-to-end (completion returned). HR insights confirmed working.

**Notes for next time:**
- aivm = master (CPU-only): runs the LiteLLM proxy + control agent, **no models**. The Nano = GPU node: runs vLLM. After an aivm reboot, normally **only the proxy** needs restarting; check the Nano first (`curl http://10.2.35.30:8020/v1/models`).
- The master **agent** (`:5000`) — which auto-restarts the proxy + syncs `cluster_config.yaml` — wasn't restarted (proxy started directly via `start_proxy.sh`). Start it for self-heal.
- Beware the orphaned `litellm` **Docker** container (old Foundation-Chat compose, config in Trash) — it is NOT the cluster proxy; ignore it.
- Don't start `stack_configs.json` "Default Stack" (Nemotron on GPUs 1/2/3) — targets Deathstar, not migrated.
- Full recovery runbook: [Foundation Infrastructure/Reboot-Recovery-Runbook.md](../Foundation%20Infrastructure/Reboot-Recovery-Runbook.md). Durable copy in memory `reference-aivm-dual-homed-routing`.

---

## 2026-05-14 - `node.sh` master-role fixes (commit `2bf4714`)

The user had run setup on the VM but the master agent wouldn't come up cleanly. Two real bugs in the master role's lifecycle:

- **`do_setup` for `role=master` only ran `install_master_deps`** (Node.js + dashboard build). Never created the Python venv or installed LiteLLM / FastAPI / uvicorn / psutil - those were only reached via the GPU-heavy `install_child_deps` → `setup.sh` path. Master couldn't run its agent because the dependencies weren't installed.
- **`do_start` started the agent only for `role=child`/`both`.** Master needs the agent too - that's how it writes the LiteLLM config from registered children.

**Fix shipped in `2bf4714`:**
- New `install_agent_deps()` - slim Python venv install (litellm[proxy], huggingface_hub, duckdb, psutil, fastapi, uvicorn, pydantic, httpx, requests). No vLLM.
- `do_setup` master case now calls both `install_master_deps` and `install_agent_deps`.
- `do_start` always starts the agent regardless of role.
- `start.bat` / `stop.bat` rewritten to drive `node.sh` instead of the legacy `start_inference_stack.sh`.

This is the second time a master-role lifecycle gap has bitten - worth a unit-test pass on `node.sh` setup/start across all role combinations (master / child / both) the next time the script gets touched.

---

## 2026-05-14 - Path-based routing pivot - `/k1` supersedes `k1.txamfoundation.com`

Direction pivot during the migration: instead of per-tool subdomains (`k1.txamfoundation.com`, `chat.txamfoundation.com`, etc.) the new architecture is a **single hostname with path-based routing**:

```
https://aisandbox.txamfoundation.com/         → Foundation AI Dashboard (172.17.0.1:3010)
https://aisandbox.txamfoundation.com/k1[/...] → K-1 Tracker (10.2.35.10:3003)
https://aisandbox.txamfoundation.com/<tool>   → future tools follow the same pattern
```

NPM has one proxy host for `aisandbox.txamfoundation.com` with a `location /<tool>` block per tool, each forwarding to that tool's upstream. The tool's framework handles the path-prefixing on the app side (Next.js `basePath` in K-1's `next.config.ts`; the Scholarships pattern documented separately).

**Why the pivot:**
- One wildcard cert covers the whole surface; no per-subdomain DNS request to Cody per new tool
- Foundation AI Dashboard becomes the natural front door - the URL bar matches the navigation model
- Cross-tool auth, cookies, and CORS get easier (same origin)
- The Operations Runbook's "subdomain-per-tool" recipe is now superseded by the path-based recipe

**NPM gotcha that bit twice today:** NPM's admin UI writes new conf to disk but doesn't reliably trigger nginx reload. Edits stick after `docker restart nginx-proxy-manager`. Saw 504s from a stale upstream (`.30.29:3003`) after the config had already been updated to `.35.10:3003` - until the container was bounced.

The `k1.txamfoundation.com` subdomain pattern that was the runbook's canonical example is **superseded.** Both Foundation Infrastructure's `Operations-Runbook.md` and the Foundation AI Dashboard tile env vars (`NEXT_PUBLIC_K1_HREF`) need an update pass to reflect the new URL shape.

---

## 2026-05-14 - Self-healing instances shipped (commit `5716ba1`)

Failure that drove this: Gemma-4 vLLM crashed on Nano 0, cluster proxy correctly went empty, but nothing brought the model back. Manual relaunch failed because ~70 GB of VRAM was orphaned.

Commit `5716ba1` adds:
- **Pre-launch VRAM reclaim** - every `/instances/launch` runs `_reclaim_vram_before_launch` first (kills straggler PIDs on the GPU, clears `/dev/shm/sem.mp-*`)
- **Per-node restart watchdog** - re-launches dead-but-intended instances with backoff (30s → 2min → 10min → abandoned)
- **Intent persistence** - `data/intended_instances.json` records what *should* be running so the watchdog has something to compare against
- **Config knobs** - `pre_launch_vram_cleanup` and `auto_restart_failed_instances` in `node_config.json` (both default true; can disable per node)

**Deploy steps that ran (Master VM + Nano 0):**
- `git pull --ff-only` on each node's clone
- `POST /agent/restart` (or via dashboard node card → "Restart agent") to load the new binary into memory
- Re-launch Gemma-4 via `POST /instances/launch` so it gets recorded in `intended_instances.json` and falls under watchdog protection (models launched before the new code aren't auto-protected)

**Verification path:** controlled crash via `sudo kill -9` on the vLLM PID → within ~30s watchdog detects mismatch → within ~60s model is back and `/v1/models` shows it on master proxy. If reclaim can't free enough VRAM (true leak), watchdog backs off and marks abandoned; operator gets visibility via dashboard.

**Temporary Gemma-4 footprint while Nano 0 orphan VRAM persists:** `gpu_memory_utilization=0.40`, `max_model_len=65536`, `max_num_batched_tokens=4096`. Restore to design `0.85` / `196608` after a reboot or `nvidia-smi --gpu-reset` clears the orphans.

---

## 2026-05-18 - Nano 0 child-node bugfix; cluster inference back to known-good

Squashed bugs and updated the child node on Nano 0. Server inference is working correctly end-to-end again:

- LiteLLM router on the VM (`localhost:4000` / `10.2.35.10:4000`) probes healthy with one loaded model (`gemma-4-26b-a4b-nvfp4`) - confirmed via the Scholarships Tools `/api/inference/discover` probe today as a side-effect of getting the Settings tab working there.
- Cluster proxy responds to chat completions cleanly (1 model returned, status 200) - verified by direct curl to `/v1/models` and indirectly by the Living Catalog backend (Information Requests endpoint queues items with the model selected).

**Stale defaults cleaned up:** The Scholarships Tools `inference.py` had `10.2.30.28:4000` (legacy Death Star) in the auto-discovery list - dead since the subnet migration. Replaced with `localhost:4000` first, then `10.2.35.10:4000`. Kept the legacy entry as a no-op probe so machines on the old subnet still resolve.

**Open thread:** Death Star migration to `.35.2x` is still TBD with Cody. Today's work doesn't depend on it because the VM is now the cluster master and runs LiteLLM locally.

## 2026-05-11 - `.30` → `.35` AI VLAN migration begins; Nano 0 first

**Context corrected:** What I previously thought was *the* AI subnet (`10.2.30.0/24`) is actually the **interim** home. The real AI VLAN is `10.2.35.0/24` and the entire AI stack needs to migrate onto it. Nano 0 is the first device to make the move; if it works cleanly, Death Star and the VM follow.

**IP allocation convention** (applies to both subnets; banding doesn't change with the subnet):
- `.1–.9` infra · `.10–.19` management/service · `.20–.29` big compute · `.30–.49` small compute · `.50–.99` storage/aux · `.100+` DHCP dynamic pool
- Implemented as **DHCP reservations** at the Foundation IT layer (Cody), keyed by MAC - one source of truth, no per-device static configs

**Migration sequence:**
1. **Nano 0 / `zgx-0d80` → `10.2.35.3x`** *(in progress 2026-05-11 - today's THE ONE THING)*
2. **Death Star → `10.2.35.2x`** *(after Nano 0 proves the path; cluster-master IP change, do during planned window, update `node_config.json` master IP via Edit Node UI)*
3. **AI Sandbox VM → `10.2.35.1x`** *(most disruptive - NPM proxy hosts, every tool `AUTH_URL` / `allowedDevOrigins`, every DNS `A` record under `*.txamfoundation.com`, SSL wildcard cert. Paired move into management band so it lands clean in one cutover.)*
4. **Retire `.30` AI presence** *(confirm nothing else still reaches into `.30`)*

**Hostname recorded:** Nano 0 device name is `zgx-0d80` (inference proxy role).

**Why the migration is the strongest argument for accelerating DNS-name-first config (Phase 3 Cody-input):** if every config references DNS names instead of raw IPs, the entire `.30 → .35` migration becomes a no-op at the application layer - only DHCP reservations and `A` records change.

**Canonical source of truth:** [Foundation AI Operations Runbook](../../../../1.%20Quick%20Notes/Foundation%20AI%20Operations%20Runbook.md) → section **IP Allocation Convention** - includes the two-subnet table, banding, current-state-vs-target, migration sequence, ops surface, and the MAC ↔ Hostname ↔ Band ↔ Subnet running inventory.

**Open follow-ups:**
- [ ] **Today:** Confirm Nano 0 DHCP reservation on `.35`, validate inference access end-to-end
- [ ] Collect MAC addresses for Death Star, VM, Nano 0 (and any future devices) → populate inventory in the runbook
- [ ] Confirm with Cody where the Foundation IT DHCP reservation table lives (per-subnet, possibly two tables) → document in the runbook
- [ ] Schedule Death Star migration window (cluster-impacting)
- [ ] Schedule VM migration window (paired with management-band move - biggest cutover)

---

## 2026-04-29 - ✅ Resolved: nodes were reachable; dashboard had stale IP

**Resolution:** Not a network issue - the dashboard's `node_config.json` had the wrong IP for Death Star (was `10.2.30.34`, actual address is `10.2.30.28`). Once the IP was corrected via the new Edit Node UI, the agent came online from the VM. Nano 0 likewise corrected.

**Cody email:** not sent - no longer needed. Draft retained at `1. Quick Notes/Email - Cody - Inference Cluster Network Issue.md` as a template for any future cross-team network ask.

**What this surfaced (worth keeping):**
- The dashboard had no UI to edit a registered node's IP - required hand-editing `node_config.json`. Shipped as part of this session: `EditNodeModal` + `POST /api/nodes/edit` + extended `PATCH /nodes/{ip}` agent endpoint (`new_ip` / `new_agent_port` support, regenerates `setup_cmd`, rejects collisions with HTTP 409).
- Firefox tab-freeze when nodes were "unreachable" was a real bug (no fetch timeout on the `get` helper → polling pile-up). Fixed: 6s/30s/30s defaults on `get`/`post`/`del`, plus 5s cap on the server-side master proxy in `/api/nodes`.

**Unblocks:** the carried-over Foundation E2E Test (S9W3 → W4 → W5) can now proceed from the VM.

---

## 2026-04-29 - Project + Repo Renamed

Project renamed from "Foundation AI Infrastructure" to "AI Distributed Inference Cluster"; repo renamed from `vllm-start-point` to `AI-Distributed-Inference-Cluster`. Scope and ownership unchanged. Cross-references in the Foundation Tool Registry, Foundation AI Dashboard, and connected SB project docs updated.

---

## 2026-04-27 - Merged HP Z Workstation Pilot into this project

The standalone "HP Z Workstation Pilot" project was redundant - the Z Workstation work is part of this project's hardware fleet evaluation, not a separate project. Merged the pilot's content into this project's Overview.md as a new "HP Z Workstation Pilot Detail" section, preserving all the original spec / purchase plan / role information.

**Changes:**
- Folder `0. Active Priority/HP Z Workstation Pilot/` deleted (content fully migrated)
- New section in this project's Overview.md captures pilot hardware specs, purchase plan, why this hardware matters, role in v2 cluster, contacts
- "Related Projects" link to the standalone HP Z Workstation Pilot folder removed (folder no longer exists)

Pilot status unchanged: TENTATIVE - awaiting hardware arrival. RTX Pro 6000 Blackwell cards are the candidate. If validated, plan is 2× workstations with 2 cards each.

---

## 2026-04-20 - Model Launch UX Bug Logged

**Issue:** Launching a model from the Deploy modal shows "Launching…" with no feedback for a long time. Observed with `llama-3-3-nemotron-super-49b` (fp8, 50 GB) on Deathstar GPU 2. In one case the model failed silently - user had no way to tell if it was loading, stuck, or dead.

**Logged under:** Roadmap → "Active Issues / UX Gaps" → 🔴 Model launch feedback is opaque

**Why this matters:** Most model launches are multi-minute operations (loading 50GB+ weights into VRAM, initializing KV cache, vLLM warmup). Without stage-level feedback, users cannot distinguish "still working" from "hung" from "failed." This erodes confidence in the cluster.

**Next steps:** Add live log tail + load-stage indicator + explicit failure surface to the Deploy modal. Full acceptance criteria captured in Roadmap.md.

---

## 2026-04-20 - Repo Linked + v2 Cluster Status Catch-up

**Context:** Linked Foundation AI Infrastructure project to the `vllm-start-point` repo. First sync under the new Second Brain ↔ Repo protocol. Previously flagged as "no repo" - corrected.

**Since Last SB Update (2026-03-05 → 2026-04-20) - major commits in repo:**
- `3e188e6` Initial commit: full vLLM dashboard with agent control system
- `2946e34` Child node dashboard, create stack UI, smart allocation improvements
- `4907d3c` Cluster GPU view, DGX Spark unified memory fix, smart dashboard restart
- `ec5e06c` Fix aarch64/child-node setup, CUDA detection, and agent IP reporting
- `f00ca8b` Cluster proxy, analytics, model library v2, endpoints tab, rename
- `a8c332c` Fix agent port scan perf, proxy registration, and node setup
- `c9936fd` Fix proxy sync to include child node instances
- `fe13b3b` Self-update system, Settings tab, multi-model testing, dashboard port 3005

**Key Architectural Shift:**
- Original plan: Docker Compose on VM + Nginx round-robin to Ollama on two DGX Sparks
- Current reality: **vLLM Dashboard-managed cluster** with LiteLLM proxy, multi-node agent system, unified GPU view, cross-node deployment
- DGX Spark unified memory (GB10) detection working; aarch64 child nodes supported
- Per-node analytics sampler + DuckDB aggregation shipped

**Sync Changes:**
- SB `Overview.md` - added Repository section; Status updated from "v2 Migration" → "v2 Cluster - Operational Hardening"; architecture rewritten to reflect dashboard-managed cluster
- SB `Project-Instructions.md` - session protocol references updated `To-Do.md` → `Roadmap.md`
- SB `To-Do.md` - deleted (the v2 migration tasks are largely shipped via the dashboard); remaining deployment-level items (DNS, SSL, firewall, snapshots) moved into `Roadmap.md` under "Active Deployment Tasks"
- SB `Roadmap.md` - new file, mirror of `repo/ROADMAP.md` (software roadmap for vLLM dashboard features + deployment tasks)
- Repo `ROADMAP.md` - prepended standardized header (Repo, Last Synced, Current Phase) + new "Active Deployment Tasks" section at top

**Open Deployment Items (carried from old SB To-Do):**
- DNS: `aidev.txamfoundation.com` → cluster master
- SSL via Nginx Proxy Manager / Let's Encrypt
- Firewall lockdown (dashboard / proxy / agent ports)
- VM / node snapshots for DR

---

## VM Setup Status (2026-03-05)

Full status report received. VM is live and healthy.

### Infrastructure - Confirmed Running

| Component | Version | Status |
|-----------|---------|--------|
| VM (App Server) | - | Running |
| Git | v2.43.0 | Installed |
| GitHub CLI (gh) | - | Installed + Authenticated as Howie002 |
| Docker | v29.3.0 | Installed |
| Docker Compose | v5.1.0 | Installed |
| Foundation-Chat Repo | - | Cloned at `/home/aivmadmin/Foundation AI Projects/Foundation Secure Chat` |

### Containers - Confirmed Running

| Container | Port | Status | Notes |
|-----------|------|--------|-------|
| open-webui | :3000 | Healthy | Foundation Secure Chat UI |
| kokoro-tts | :8880 | Running | Text-to-speech, CPU mode |
| searxng | :8888 | Running | Web search |
| redis | :6379 | Running | Session cache |
| nginx-proxy-manager | :80/:81/:443 | Running | SSL + reverse proxy |
| portainer | :9000 | Running | Docker management UI |
| nginx-ollama | :11434 | **Paused** | Waiting on DGX Spark IPs |

### Key Paths
- **Repo location on VM:** `/home/aivmadmin/Foundation AI Projects/Foundation Secure Chat`
- **Nginx Proxy Manager UI:** http://\<vm-ip\>:81
- **Portainer UI:** http://\<vm-ip\>:9000
- **OpenWebUI:** http://\<vm-ip\>:3000
- **Config file to update:** `.env` → `DGX_SPARK_0_IP` and `DGX_SPARK_1_IP`
- **Nginx template:** `configs/nginx-ollama.conf.template` → uncomment DGX Spark 1 entry

### Critical First Actions
1. **Portainer:** Must create admin account within 5 minutes of container start or it locks permanently
2. **OpenWebUI:** First user to register becomes admin - do this before sharing access
3. **Docker permissions:** `sudo usermod -aG docker $USER` has been run - takes effect after full logout/reboot

### What's Working Right Now
OpenWebUI is live and usable immediately upon admin account creation. No AI models connected until DGX Sparks are online. Can temporarily connect to external APIs (OpenAI, Anthropic) via OpenWebUI settings as a bridge if needed.

---

## v2 Architecture Decisions

### Why VM + Dual DGX Spark vs. single node
- Separation of concerns: apps and inference scale independently
- VM snapshots = disaster recovery in minutes
- Round-robin across 2x GB10 nodes = 2x throughput, automatic failover
- AMD Box freed up as dedicated staging/testing environment

### DNS Plan
- **Production:** ai.txamfoundation.com → VM IP (when v2 migration complete)
- **Dev/Staging:** aidev.txamfoundation.com → VM IP (for testing before DNS cutover)
- Nginx Proxy Manager handles SSL termination via Let's Encrypt

### Docker Compose Profile Strategy
- Default profile: all app containers (OpenWebUI, Kokoro, SearXNG, Redis, Nginx PM, Portainer)
- `dgx` profile: nginx-ollama load balancer - only starts when DGX Sparks are online

### Port Security (Action Required)
The following ports should NOT be exposed publicly - firewall rules needed:
- `:8880` - Kokoro TTS
- `:8888` - SearXNG
- `:6379` - Redis
- `:9000` - Portainer

Only `:80` and `:443` (Nginx Proxy Manager) should be public-facing.

---

## Snowflake AI App - Infrastructure Notes

When the Snowflake AI app (Streamlit) is ready to deploy:
- Add as new Docker container on VM alongside existing services
- Assign port (e.g., `:8501`)
- Add proxy host in Nginx Proxy Manager routing to `:8501`
- Connect to Ollama via `nginx-ollama` upstream (:11434) - same as OpenWebUI

---

## DGX Spark 0 (ZGX Nano) - Setup Complete (2026-03-17)

### What Was Built
**`zgx-nano.sh`** - single self-contained management script. Drop on the desktop of any ZGX Nano; a tech can set it up or manage it without knowing the underlying system.

### Setup Completed
| Step | Result |
|------|--------|
| GPU detected | ✅ NVIDIA GB10 |
| Ollama version | ✅ 0.18.1 (already installed) |
| Systemd override | ✅ Ollama listens on `0.0.0.0` (network-accessible) |
| Service enabled | ✅ Starts on boot |
| Default models pulled | ✅ See below |
| API validated | ✅ Responding at `http://10.2.30.32:11434` |

### Models Loaded (~40 GB total, all fit in 128 GB unified memory)
| Model | Size | Purpose |
|-------|------|---------|
| llama3.2:latest | ~2 GB | General chat |
| nemotron-3-nano:30b | 24 GB | NVIDIA agentic model |
| gpt-oss:20b | 14 GB | OpenAI open-weight model |
| nomic-embed-text:latest | ~274 MB | RAG embeddings |

### Script Menu Capabilities
- **Option 1/2** - Start / Restart Ollama service
- **Option 3** - Pull a model (accepts raw name or `ollama pull/run` prefix - strips automatically)
- **Option 4** - Update Ollama binary in place (does not touch models)
- **Option 5** - Status: GPU temp/util, IP, service state, API health, model list
- **Option 6** - Full setup (new node)
- **CLI:** `./zgx-nano.sh pull <modelname>` works without menu

### Current Network Endpoint
```
http://10.2.30.32:11434   ← DHCP - pending static IP from Jose
```

### What's Still Pending
- [ ] **Static IP from Jose's team** - both ZGX Nano IPs currently DHCP; once assigned, set on NIC and update `DGX_SPARK_0_IP=10.2.30.32` in VM `.env`
- [ ] **VM side** - uncomment ZGX Nano entry in `nginx-ollama.conf.template` and restart `nginx-ollama` container
- [ ] **`nginx-ollama.conf.template`** - file does not exist in the repo yet; must be written before VM can route traffic to ZGX Nano
- [ ] **DGX Spark 1** - same process once second unit is ready

## OpenAI-Compatible API Layer - Feature Request (2026-03-17)

**Source:** Ryan Gardner conversation (Investments)
**Request:** Expose Foundation Secure Chat's Ollama endpoint with an OpenAI-compatible API so tools like Claude Code and Codex can point to it via env var overrides:
```
export ANTHROPIC_BASE_URL="http://<foundation-ai-ip>/v1"
export ANTHROPIC_AUTH_TOKEN="foundation"
```

**Use Case:** Investment team members run Claude Code locally and route LLM calls to Foundation's inference nodes instead of paying frontier API costs. Enables multi-agent/subagent workflows on large document sets (data rooms, 100+ docs).

**Ollama already supports this** - Ollama exposes an OpenAI-compatible REST API at `/v1` natively. The work is exposing it safely through the Nginx layer and managing auth tokens per user.

**Blocker:** AI infrastructure is network-segmented from the rest of Foundation. Investment team members on the main network can't reach the AI nodes without a controlled bridge. Need to design a secure path - options:
- VPN tunnel to AI segment for approved users
- Nginx reverse proxy on the main network DMZ forwarding to AI segment
- Per-user token auth on the Ollama/Nginx layer

**Action:** Add to Phase 4 roadmap - design the access architecture before building.

---

### Context Packet for AI Code Editor (send first thing 3/18)

Paste the following into the AI code editor on the project machine to build the `nginx-ollama.conf.template`:

---

**Task:** Write `nginx-ollama.conf.template` for the Foundation Secure Chat repo.

**What it does:** This file is the Nginx upstream config that load-balances LLM inference requests across the DGX Spark nodes. It is templated so environment variables can be substituted at container startup.

**Architecture:**
- The VM runs a Docker container called `nginx-ollama` that proxies all Ollama API traffic on port `:11434`
- Upstream nodes are DGX Spark units running Ollama, each listening on port `11434`
- Round-robin load balancing across available nodes
- Only DGX Spark 0 is active now; DGX Spark 1 entry should be present but commented out until ready

**Environment variables to template:**
- `DGX_SPARK_0_IP` - IP of DGX Spark 0 (currently `10.2.30.32`, pending static assignment)
- `DGX_SPARK_1_IP` - IP of DGX Spark 1 (not yet assigned)

**Where the file lives:** `configs/nginx-ollama.conf.template` in the Foundation Secure Chat repo

**Docker Compose context:** The `nginx-ollama` service uses this template to generate the live Nginx config at container startup. The `dgx` Docker Compose profile controls whether this container runs - it only starts when DGX Sparks are online.

**What to produce:**
1. `configs/nginx-ollama.conf.template` - the Nginx config with `${DGX_SPARK_0_IP}` and `${DGX_SPARK_1_IP}` placeholders
2. Any startup script or Docker entrypoint logic needed to substitute the env vars and launch Nginx (if not already handled in the repo)

**Repo location on VM:** `/home/aivmadmin/Foundation AI Projects/Foundation Secure Chat`

---

## 2026-04-14 - Background Research: Four-Card Workstation AI Setup (NOT the chosen architecture)

> **Status:** Background research only. This was an earlier exploration of a single-machine four-GPU stack. The final Foundation direction is the VM + dual DGX Spark + ZGX Nano topology documented above. Retained here for reference on vLLM/LiteLLM patterns, FP8 deployment, and co-located model tricks that may inform future decisions.

### Summary

Self-hosted AI inference stack across **4× NVIDIA RTX PRO 6000 Blackwell GPUs** (96 GB VRAM each, 384 GB total) serving models via an OpenAI-compatible API through a **LiteLLM proxy** on port 4000. Ubuntu 24.04, NVIDIA driver 580.126.09, CUDA toolkit 12.8, Python 3.12, vLLM 0.19.0, PyTorch 2.10.0+cu128.

### GPU Allocation

| GPU | Role |
|---|---|
| 0 | Dynamic / reserved - LM Studio, overflow, ad-hoc vLLM, model eval |
| 1 | Static co-located: Nemotron Nano FP8 (:8001) + GTE-Qwen2-7B embedding (:8011) |
| 2 | Nemotron Super 49B FP8 Instance A (:8003) |
| 3 | Nemotron Super 49B FP8 Instance B (:8004) - data-parallel pair with GPU 2 |

### Models

- **Nemotron Nano** - `nvidia/Llama-3.1-Nemotron-Nano-8B-v1`, FP8 runtime quant, 32k ctx, fast general reasoning
- **Nemotron Super** - `nvidia/Llama-3_3-Nemotron-Super-49B-v1-FP8` (underscore in ID, not `3.1`), ~50GB weights, FP8 pre-quantized, LiteLLM `least-busy` balances the two GPU instances
- **GTE-Qwen2-7B** - `Alibaba-NLP/gte-Qwen2-7B-instruct`, MTEB 70.24, co-located on GPU 1, used via `--runner pooling`

### Traffic Flow

Single LiteLLM proxy at `:4000/v1` routes OpenAI-style calls by `model` name → appropriate vLLM backend. Direct endpoints also exposed per instance. Health checks at `/health` on each port.

### Bring-up Gotchas Worth Remembering

- **CUDA toolkit 12.8 required at runtime** - vLLM calls `nvcc` during GPU memory profiling and flashinfer FP8 JIT; driver alone is insufficient
- **vLLM 0.19.0 flag changes:** `--disable-log-requests` → `--disable-uvicorn-access-log`; `--task embedding` → `--runner pooling`
- **Venv must live in a space-free path** (e.g., `~/.vllm-venv`) - flashinfer JIT passes include paths to nvcc unquoted, spaces break the compile
- **NV-Embed-v2 unsupported in vLLM 0.19.0** (NVEmbedModel arch missing) - GTE-Qwen2-7B is a better-scoring drop-in
- **`--trust-remote-code`** required for both GTE-Qwen2-7B and Nemotron Super
- **GTE-Qwen2-7B** needs `--hf-overrides '{"is_causal": false}'` to enable bidirectional attention for embeddings
- Overflow Nano can be registered with LiteLLM live via `POST /model/new` - no proxy restart

### Startup

Windows `start.bat` opens `nvidia-smi` monitor + WSL → `setup.sh` (idempotent) → launches 4 vLLM instances → polls health → starts LiteLLM once all healthy. Cold start 5–10 min (first-run downloads ~70 GB), warm start 2–4 min. Logs per service in `./logs/`.

### Why Not Chosen for Foundation

[Fill in when you have a moment - likely: single-machine failure domain, rack/power/cooling footprint, doesn't match the VM + DGX Spark horizontal-scale strategy, ZGX Nano handles the edge/inference role more cleanly]

---

**Last Updated:** 2026-04-14
