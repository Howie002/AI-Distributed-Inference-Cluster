# AI Distributed Inference Cluster - Notes

## 2026-08-19 - DS1 fully removed from the cluster (never coming back)

Dominic: DS1 (`10.2.35.20`, "Z8 Workstation / Death Star") is returned to HP and will never be plugged
in again, so it should not be part of the cluster dashboard anymore. Removed it everywhere it was still
listed:

- **Node registry:** `DELETE http://10.2.35.10:5000/nodes/10.2.35.20` → node_config.json now holds only
  Nano + DS2, and the in-memory `_REGISTERED_CHILDREN` entry is cleared so it can't be rebuilt by a
  stray re-register (moot anyway — it's gone). `node_config.json` is gitignored (per-node runtime), so
  there's nothing to commit there; the master's live copy is the source of truth and the dashboard
  reads `/nodes` live, so DS1 disappeared immediately with no rebuild. Ran `POST /proxy/sync` after
  (litellm `cluster_config.yaml` already had no `.20` — the agent re-pooled when DS1 went dark 08-18).
- **Voicebox failover proxy:** dropped the DS1 upstream from `config.json` entirely (it was already
  `enabled:false`). Hot-reloaded; status now shows only DS2 (active) + the Nano placeholder.
- **Docs:** Overview hardware table row → REMOVED; the TTS section (which still named DS1 as the live
  Voicebox host) updated to DS2 + the failover proxy.

## 2026-08-19 - Dashboard: average GPU utilization (trailing 24h) stat

Dominic asked for an average-GPU-utilization-over-24-hours statistic, on the Analytics tab too. The
metrics to do it already existed - the Analytics "GPU Utilization (%)" chart reads bucketed
`util_pct_avg` from each node's `GET /metrics/query` - so this is a headline number over that same data,
not new instrumentation.

- New `dashboard/src/lib/useAvgGpuUtil.ts` → `useAvgGpuUtil24h(nodes)`: fetches `metrics("24h","1h")`
  per node and averages every non-null `util_pct_avg` across all nodes/GPUs into one fleet-wide percent.
  **Always 24h, independent of the Analytics range picker**, so it reads the same on both surfaces.
  Polls every 60s; a node that's down or has no samples simply doesn't contribute.
- **GPU view** (overview tab): "avg 24h util NN%" in the GPU Cluster header, beside nodes/GPUs/VRAM.
- **Analytics tab**: an "Avg GPU util" tile in the totals strip ("trailing 24h · N GPUs").

Verified against live agents: DS2 returns 100 GPU buckets (4 GPUs × 25h), Nano 25, master 0 (no GPU) -
the cluster is mostly idle so the number sits low (~1%), which is accurate. Shipped `c65ef41`; cluster
dashboard rebuilt + restarted on :3005 (had to reap an orphaned 2-day-old `next-server` still holding
the port - the stop script's tracked PID had left its child behind).

## 2026-08-19 - Fleet TTS is back, and the proxy now checks capability, not just liveness

The 08-18 blocker is closed. DS2's Voicebox triton "no C compiler" failure was
fixed **on the box overnight** (Andrew's domain - he owns the DS1 wipe/DS2
transfer), and I verified it end-to-end this morning rather than trusting
`/health`:

- George default `501cf0ee` generated real PCM: mean −20 dB / peak −6 dB (not
  silence), and duration scaled with text (1.74s for a 5-word line, 6.98s for a
  long one, so it is not a canned clip).
- Voicebox's own Whisper STT transcribed both clips back **verbatim**.
- The same worked **through the proxy** at `10.2.35.10:17600`, not just direct to
  `.21`.

### The real fix on our side: a capability deep check in the proxy

08-18's lesson was that `/health == 200` told us nothing about whether the node
could actually generate. The proxy now runs a second, independent probe
(`deep_check_*` in `config.json`, hot-reloaded, default every 120s): it actually
`POST /generate`s a tiny clip on each **live** node, polls it to completion, and
confirms real audio bytes come back (`>= deep_check_min_bytes`). A live-but-
incapable node is demoted below any capable node, logged loudly, and dropped from
`active` (which goes `null` as a visible alarm) - but still receives traffic as a
**last resort**, so the deep check can never hard-block routing. `status` now
exposes `active` / `serving` / `degraded` plus per-node `capable` /
`deep_fail_count` / `deep_last`.

Tested against real DS2 before deploying: forced the failure path (impossible
min-bytes floor) and confirmed demotion → `active:null`, `degraded:true`, traffic
still forwarding; then confirmed auto-recovery when the floor was restored.

**What's still thin:** nothing yet scrapes `/__failover/status` to page a human -
the deep check makes the outage *visible*, but a person still has to look. Wiring
`degraded:true` / `active:null` into the dashboard telemetry (or a cron alert) is
the natural next step. And there is still **no real failover target**: DS1 is now
`enabled:false` in the config (box returning to HP), and the Nano entry is a
placeholder with no Voicebox installed - so DS2 is a singleton. Standing up
Voicebox on the Nano is the redundancy fix.

Also done today: the proxy finally has a git repo -
`github.com/Howie002/voicebox-failover-proxy` (private, `main`), with a README
documenting the two-layer health model.

## 2026-08-18 (later 2) - Lone Starr (DGX Spark 1) bring-up started

The fleet's second DGX Spark node - listed in Overview.md as "DGX Spark 1, Setup Pending" - is now up and named **Lone Starr** (hostname `zgx-0f1e`). SSH access from Andrew's work laptop confirmed working at `10.2.35.31` (DHCP - can drift; see [[../../../1. Quick Notes/SSH Setup - Work Laptop to This Machine|SSH Setup - Work Laptop to This Machine]] for the laptop-side setup). Currently sitting at Andrew's desk; plan is to complete the [[Node-Bring-Up-Checklist-2026-08-04|standard bring-up checklist]] (Claude CLI, VS Code, Obsidian, then cluster agent/`node.sh setup`) before moving it to the server room. Claude CLI install command given (native installer, `curl -fsSL https://claude.ai/install.sh | bash`); remaining checklist steps not yet done.

## 2026-08-18 (later) - Death Star 2 unresponsive after BIOS (black screen): NVIDIA driver/kernel mismatch from unattended-upgrades

DS2 (`10.2.35.21`) rebooted to BIOS-then-black-screen with no video output, right after Andrew was doing vLLM proxy work - timing was coincidental, not causal. Diagnosis (all done live over SSH, not physically at the box):

- SSH (`22`) was reachable throughout, proving the OS booted fine - this was a display/GPU-driver problem, not a boot hang.
- `nvidia-smi` couldn't talk to the driver; `lsmod`/journalctl showed no NVRM/Xid activity at all, meaning the module never loaded this boot.
- Root cause, found in `/var/log/unattended-upgrades/unattended-upgrades.log`: an overnight auto-update (07:02-07:14) bumped the kernel to `6.17.0-1032-oem` and auto-removed the old kernel packages, but **held back every `nvidia-*-580` package** (driver, kernel module, xorg driver) instead of upgrading them in the same run. No driver built for the new kernel → no GPU framebuffer → black screen at the exact point BIOS hands off to the OS display driver.
- **Mid-fix near-miss:** with no graphical session ever succeeding at the console, GDM's idle-suspend policy almost put the box to sleep during the SSH session, which would have required physical hands to wake it. Masked permanently: `sudo systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target`.
- **Fix:** targeted `sudo apt install` of the matching `linux-modules-nvidia-580-open-oem-24.04c` (and the rest of the 580 driver stack) rather than a full `apt full-upgrade` of all 223 pending packages - kept the blast radius to just the NVIDIA stack. Confirmed live via `sudo modprobe nvidia && nvidia-smi` (all 4 RTX PRO 6000 Blackwell GPUs back, driver `580.173.02`, CUDA 13.0) before rebooting to validate the actual boot path.
- **Not yet confirmed:** whether the reboot brought the physical display back, whether `vllm-cluster-agent`/`vllm-cluster-dashboard` came up healthy after, and whether DS2's vLLM model instances (gemma `:8023`, nomic-embed `:8022`) need relaunching - none were running when last checked.
- **Fleet-wide follow-up worth deciding:** unattended-upgrades can repeat this on any GPU node with the same auto-update policy (partial kernel bump without the matching driver). Options: hold `nvidia-*`/`linux-modules-nvidia-*` from unattended-upgrades, or add a post-update health check.

## 2026-08-18 - DS1 went dark and the fleet did not notice: a Voicebox failover proxy, and a cluster that re-pooled itself

Death Star 1 (`10.2.35.20`) is being returned to HP. Today it stopped answering - no ICMP, agent
`:5000` dead - and the two things that depended on it behaved very differently. Verified after the
fact, with DS1 already unreachable, which is the test the 08-17 closeout said was still outstanding.

### vLLM: nothing to do, because the control plane regenerates its own pool

`litellm/cluster_config.yaml` is generated by the control agent, not hand-maintained. With DS1 gone
the agent rewrote it and restarted `:4000` on its own; the live file now carries only DS2
(`10.2.35.21:8023` gemma, `:8022` + `:8024` nomic) and the Nano (`10.2.35.30:8020` gemma). Verified
through the proxy rather than by reading config:

- `POST /v1/chat/completions` on `gemma-4-26b-a4b-nvfp4` returned the exact requested string.
- `POST /v1/embeddings` on `nomic-embed-text-v1-5` returned a 768-dim vector.

Both embedding replicas now sit on DS2, so [[reference_embedding_2048_ceiling]]'s "instance-level,
not box-level" caveat still stands - it just moved boxes. The third replica on the Nano
([[project_cluster_third_replica_parked]]) is the fix and is still parked on Nano hands.

### Voicebox: a reverse proxy, NOT the client-side endpoint list the roadmap specified

Andrew's 08-18 direction was "dynamic failover across IPs", written up in the Roadmap as
`VOICEBOX_BASE_URLS` - a comma-separated list each consumer tries in order. **Built the other shape:
one reverse proxy on aivm (`10.2.35.10:17600`), consumers keep a single `VOICEBOX_BASE_URL`.**

The roadmap itself argued for this without naming it: *"every consumer needs the same failover
behaviour, which argues for one shared client rather than three copies."* Three consumers here are
two languages (Python and TypeScript), so "one shared client" cannot actually be one artifact - it
would have been three implementations of the same retry logic, drifting independently. The
deciding constraint is that **Voicebox is stateful across calls**: `POST /generate` returns an id
you then poll at `/history/{id}` and fetch from `/audio/{id}` **on the same node**. A client-side
list that re-picks per request can submit to one node and fetch from another and get a 404 - and
only under failover, which is exactly when nobody is watching. One proxy holding one active
upstream makes that unrepresentable.

Cost of the choice, recorded honestly: aivm is now in the Voicebox path, so the proxy is itself a
SPOF for TTS. It is a small stateless forwarder next to the tools it serves, so it fails with them
rather than independently, but it is a new dependency and should not be forgotten.

**Shape:** active/passive over an ordered list, `DS2 -> Nano -> DS1`, priority order = failover
order. Health is `GET /health` == 200, probed every 5s. It deliberately ignores the body's
`model_loaded` flag, which only reflects the qwen slot and is a red herring. `config.json`
hot-reloads on mtime, so adding the Nano later is an edit, not a restart. Admin surface is
namespaced under `/__failover/` and never forwarded upstream: `status`, plus `disable/{name}` and
`enable/{name}` for drills and drains. Failover was exercised at build time, both directions
(`manual DISABLE DS2 -> active now DS1`, then back).

**Consumers repointed to the proxy** and confirmed by reading each running process, not the file:
HyperFrames (:3013), SOP Builder (:3012), Foundation Coach frontend (:3001) and backend (:7860) all
restarted at 16:16 carrying `VOICEBOX_BASE_URL=http://10.2.35.10:17600`.

**Boot persistence:** aivm has no passwordless sudo, so this is a user crontab (`@reboot` plus a
`*/2` idempotent watchdog calling `start_proxy.sh`) rather than a systemd unit. It also carries a
`boot.meta.json`, and a live `rolling-start.py` run confirms the orchestrator discovers it at boot
position 2, ahead of the tools - so it is not another [[feedback_migration_sweep_unmanaged_services]]
gap. Give it a real unit when someone can sudo.

### ⚠️ Open, and it is the important one: DS2's Voicebox cannot generate audio

The proxy is healthy and routing correctly, but the node behind it is not producing speech. Every
one of the 10 profiles on DS2 fails the same way:

```
Failed to find C compiler. Please specify via CC environment variable
or set triton.knobs.build.impl.
```

Confirmed **not** a proxy fault - the identical call sent straight to `10.2.35.21:17600` fails the
same way. Triton needs a C compiler present inside the Voicebox container to JIT its kernels, and
DS2's image does not have one. `/health` returns 200 throughout, so **no health check catches
this** - the proxy will happily keep routing to a node that fails every job.

Consequence: **fleet TTS is down right now** - HyperFrames narration, Coach voice, SOP narration.
The profile data survived the migration (all 10 present, including the shared George default
`501cf0ee`), so this is the container's build environment, not the irreplaceable `voicebox-data`
volume. Not chased further today at Dominic's direction.

This also converts a roadmap assumption into a finding: the roadmap called voice-profile parity
"the hard part, not the routing." Parity was fine. **The engine was the hard part**, and neither
`/health` nor profile presence would have told anyone.

## 2026-08-11 - The third embedding replica is blocked twice over: a launch-path kill bug (fixed), and a Nano agent nobody can update remotely (parked)

Set out to close yesterday's box-level embedding SPOF by placing a third `nomic-embed` replica on the Nano. The replica is NOT deployed. What happened instead: the launch itself would have been an outage, the fix for that is shipped to both branches and deployed to the Death Star, and the Nano turned out to be unreachable for code updates without hands on the box. Dominic parked it pending Andrew. Nothing about the fleet was changed except the Death Star's agent (updated + verified, instances untouched).

### Death Star 2 is not "agent down" - the whole box is dark
Correcting yesterday's framing: `10.2.35.21` gives no ICMP echo, SSH and every probed port closed, ARP resolution FAILED - while `.20`/`.30` answer in under a millisecond on the same segment. On 08-08 it had a healthy agent and 4 idle Blackwells. **Likely benign cause: the DS1→DS2 transfer is in flight** (Roadmap 08-04 item, Andrew expected it to close S10W7) - the box may be powered down or reimaging as part of that. Question for Andrew, not an alarm; but until it answers, DS2 cannot host the embedding replica, and the Roadmap's "agent not answering" wording undersold the state.

### The launch path would have killed the Nano's gemma: pre-launch VRAM reclaim SIGKILLs live models' EngineCore children
Read before launching, because the Nano's single GPU hosts a live gemma. `_reclaim_vram_before_launch()` protects tracked instances by PID - but the tracked PID is the **APIServer** (it owns the listening port), while the process nvidia-smi actually reports on the GPU is its **EngineCore child**: untracked, name-matched by `_VLLM_PROCESS_FRAGMENTS`, and SIGKILLed by any launch targeting the GPU it lives on. Never bitten in practice only because every launch so far went to an empty GPU (yesterday's `:8024` went to the Death Star's idle GPU 1, and the `target_uuids` filter shielded the rest). On the Nano it fires 100%: launching nomic next to gemma kills gemma's engine.

Worse, it doesn't stop there. Both models would carry relaunch intents in `intended_instances.json`, and each watchdog relaunch runs the same reclaim against the same shared GPU - **the two instances SIGKILL each other's engines in an alternating loop**, including through the mid-load window where the incoming APIServer isn't listening yet and so is invisible to the tracked-PID scan. On an agent with this bug, two models can never stably coexist on one GPU.

**Fix:** children of tracked PIDs are now tracked too (recursive), so a resident model's EngineCore is off-limits. Shipped to **both** branches: `682e953` (main), `7082f9a` (dev cherry-pick). Residual known limit, on the record: the mid-load window above is still theoretically exposed even with the fix (a not-yet-listening APIServer has no tracked parent) - concurrent launches onto one GPU remain a footgun; sequence them.

### Discovered while shipping: the repo is split-brained across branches, and node agents are pinned to different ones
- **`.20` (Death Star) tracks `dev`** - was at `9963401`; dev carries 8 commits main lacks (watchdog disable, `mode=embedding` proxy flag, Higgs TTS support, dashboard work).
- **Master (aivm) + `.30` (Nano) track `main`** - which carries 18 commits dev lacks.
- Consequence already felt today: a production-hazard fix had to be shipped twice, and any fix landed on one branch silently misses nodes pinned to the other. Reconciliation is Andrew's call (dev has his active work); flagged.
- Also stale on main: `stack_configs.json` still describes the retired nemotron/gte-Qwen2 single-box stacks.

### Death Star deployed + verified; Nano is the blocker
- **`.20`:** `POST /update/pull?force=true` pulled `9963401 → 7082f9a`, agent self-restarted (execv; instances survive by design, `start_new_session`). Verified by output: all three instance PIDs unchanged (`8022:3273700, 8023:23379, 8024:3272908`), all healthy, 768-dim embeddings still flowing through `:4000`.
- **`.30`:** agent is `5716ba1` (2026-05-14 - ironically the commit that *introduced* the reclaim), 29 commits behind, **dirty working tree**, and its `/update/pull` predates the `force` stash (06-24) - hard 409, no bypass. No startup auto-pull in that version either, so `/agent/restart` alone reloads the same old code. No SSH from aivm (aivmadmin/admin/dominic all refused; the 08-04 bring-up checklist's "prepare SSH" step was never completed for the GPU nodes). **Do NOT launch anything on the Nano until its code is updated** - any launch through the old agent is the guaranteed gemma-kill + watchdog loop above.

### Runbook to finish (30 seconds of hands + the rest is remote)
1. Terminal on the Nano (gnome-remote-desktop is running on it): `cd <cluster repo>` (find via `ps -ef | grep agent.py`), then
   `git pull --ff-only origin main || { git stash push --include-untracked -m pre-update-0811; git pull --ff-only origin main; }`
2. From aivm: `POST http://10.2.35.30:5000/agent/restart` (execv reloads the pulled code; the live gemma survives).
3. From aivm: `POST /instances/launch` on `.30` - `nomic-ai/nomic-embed-text-v1.5`, GPU 0, port `8025`, served name `nomic-embed-text-v1-5`, `extra_flags {runner: pooling, trust_remote_code: true, gpu_memory_utilization: 0.03}`. Footprint is ~1.3 GB into 4.2 GB free (unified memory; the 0.15 util on `.20` is a cap, not a reservation - actual use is 1.3 GB there too). vLLM model download ~550 MB on first launch.
4. `POST /proxy/sync` on the master afterwards (auto-register on launch is not reliable - 08-10 rough edge), then verify: three nomic entries in `litellm/cluster_config.yaml`, cross-box vector consistency (same input on `.20:8022` vs `.30:8025`, cosine ≈ 1), and gemma on `.30` still answering.

### SPOF state at close
Unchanged from yesterday: instance-level redundancy only, both replicas on `10.2.35.20`. The path to box-level redundancy is fully de-risked and scripted above; it needs either the Nano hands-on step or DS2 back from migration.

## 2026-08-10 - nomic-embed was a single point of failure, and was also rejecting long inputs

The new Foundation AI Dashboard cluster panel (`/admin/cluster`, feedback #125) surfaced it on its first run: **`gemma-4-26b-a4b-nvfp4` ran on two nodes, `nomic-embed-text-v1-5` on one.** Losing `10.2.35.20` would have taken every embedding in the fleet with it - Living Catalog semantic search over ideas, researchers and foundations, and the Chat KB grounding - while chat kept working, so the failure would have looked like "Living Catalog is broken" rather than "a node is down". Same class of gap Andrew logged for Voicebox on 08-04.

**Redundancy added.** Launched a second instance on the Death Star's **idle GPU 1** at `:8024` (`runner=pooling`, `trust_remote_code`, `gpu_memory_utilization=0.15`) via the agent's `/instances/launch`. GPUs 0 and 1 were sitting at 6.1 GB and 0.0 GB of 95.6 GB, so there was room to spare.

**Failover verified, not assumed.** Killed the original `:8022` outright and embeddings kept serving 768-dim vectors from `:8024` alone (first call 14.7s while the proxy settled, then 0.02s); gemma was unaffected. Then relaunched `:8022` on its original GPU 2. Both are registered now.

**Honest limit: this is instance-level redundancy, not box-level.** Both instances live on `10.2.35.20`, so losing that node still takes embeddings down. Real redundancy needs either the Nano (only ~4 GB VRAM free - adding a model there risks the gemma instance it already serves) or **Death Star 2, whose agent is not answering on `:5000`**. Recorded in the Roadmap.

### `/proxy/sync` is safe to call, and here is why that was worth checking

I had earlier flagged the master's empty `/instances` as a hazard - if sync regenerated the model list from it, the config would empty and inference would stop fleet-wide. Reading `_sync_proxy()` settles it: it aggregates **local scan plus a parallel fan-out to every node in `node_config.json`**, so with `.20` and `.30` answering it produces a complete config. It only writes `model_list: []` when *every* node fails to report. The master's own `/instances` returning `[]` is correct - aivm is CPU-only and that endpoint is local-only. What is genuinely empty is `/cluster/nodes` (dynamic child registration), which sync does not depend on.

One rough edge: relaunching `:8022` with `register_with_proxy: true` did **not** re-add it to the config; an explicit `POST /proxy/sync` afterwards did. Worth knowing that the auto-register on launch is not reliable enough to skip the sync.

### The integration failure underneath the SPOF

The embedder's log was carrying real errors: `This model's maximum context length is 2048 tokens... your prompt contains at least 2049 input tokens`. **26 embedding calls failed** that way (against 5,058 successes), all during the 07-23 foundations import. And the model cannot simply be given more room - launching it at `max_model_len 8192` is refused, because this checkpoint's `config.json` sets `max_position_embeddings=2048`. Fixed on the client side in Living Catalog (`lms.embed_text` now chunks and mean-pools); see that project's Notes for 2026-08-10.

## 2026-08-04 - Lessons learned onboarding Death Star 2: standard node bring-up sequence

Andrew captured the bring-up sequence that worked for Death Star 2, generalized as the standard for any future node: **(1)** install Claude CLI first - it bootstraps everything else, **(2)** install VS Code for a real repo-working UI, **(3)** install Obsidian to open the Second Brain vault on the machine for full context, **(4)** prepare SSH for remote access going forward, **(5)** point Claude at the Second Brain's existing instructions (Agent Instructions.md, this project's docs) to complete whatever machine-specific setup remains. Full checklist: [[Node-Bring-Up-Checklist-2026-08-04]].

## 2026-08-03 - HP case-study exploratory call confirmed for Wednesday, August 5, 1:00 PM CST

Objective per the HP email thread: an exploratory call to discuss developing and publishing a joint HP-Texas A&M Foundation customer success story case study. Andrew's framing going in: a working session on how Foundation is using HP's systems (Death Star 1/2 hardware) to do "amazing things" - useful context for what to bring to the call.

HP (Erik Hawkins) offered to push the meeting to the week of August 17 since he's traveling the week of August 10; Steve Catlin declined and kept the original slot - **1:00 PM Central (2:00 PM Eastern), Wednesday, August 5, via Microsoft Teams.**

**HP contacts (fills the "HP Representative - TBD" gap in Overview.md):** Erik Hawkins (erik-michael.hawkins@hp.com), Jesse Otts (jesse.otts@hp.com). Foundation side: Steve Catlin, Andrew Howerton.

## 2026-07-31 - Death Star 2 network reservation resolved; migration checklist prepared

Andrew focused on the critical VM/cluster work while Dominic was gone, then shifted to preparing the Death Star 1 → Death Star 2 transfer.

**Network state verified at the physical DS2 terminal:**
- Interface `ens255` is `state UP`.
- MAC address: `b4:e2:5b:cd:6b:3e`.
- DS2 holds `10.2.35.21/24` by DHCP; Cody's reservation has landed.
- No static IP was set, preserving the AI-VLAN DHCP-reservation convention.

**Migration preparation:** Created [[DS2-Migration-Instructions-2026-07-31|Death Star 1 → Death Star 2 Migration Instructions]], covering cluster-agent/dashboard replication, model-serving setup, Voicebox state transfer, direct-IP consumer risk, and an explicit verification checklist.

**Local-stack / Salesforce architecture discussion captured:**
- Salesforce-side access should be read-only; “Joes” is expected to create a read-only access path. The identity/name is preserved verbatim because the quick capture does not establish whether it is a person, team, or system.
- Proposed flow: user question in Salesforce → authenticated request to the local AI VM (`.35` network) → interpretation/query work against Snowflake → response returned to Salesforce.
- Security candidates named in the discussion: Salesforce REST API, OAuth, and a Salesforce Named Credential; Cody is expected to create the Named Credential.
- Network/hosting question remains open: expose a public-facing route to the AI VM with Cody/Steve, or use an Azure/web-proxy route such as `APIAI.txamfoundation.com`. No route, credential, or firewall change is claimed complete.

**Still open and not claimed complete:** cluster registration, DS2 GPU-spec confirmation, model launch/load-balancing verification, Voicebox volume migration, Foundation Coach/HyperFrames endpoint decision, and confirmation that DS2 is distinct from the earlier HP Z Workstation pilot. Andrew's reflection says he “focused on the Deathstar transfer,” which supports preparation/progress, not completion of those technical gates.

## 2026-07-31 (later) - Death Star 2 registered with the cluster; onboarding was further along than the 07-30 note knew

Dominic (on the freshly-revived :3005 dashboard): "why does it not see the Death Star 2?" Answer: **the dashboard only lists nodes registered in the master's `node_config.json`, and DS2 was never added.** But probing `10.2.35.21` showed onboarding had quietly progressed past yesterday's checklist: the box is UP on its assigned IP (so the DHCP-reservation ask to Cody is evidently satisfied) and **already runs a healthy cluster agent** (`:5000/health` 200) reporting **4x RTX Pro 6000 Blackwell Max-Q (97,887 MB each)**, GPUs idle, zero instances.

- **Identity checked before registering:** `.20` (Death Star 1) and `.21` answered SIMULTANEOUSLY with identical 4x-Blackwell inventories - two distinct physical boxes, settling half of the 07-30 doubt (whether the HP Z pilot unit is DS2 *reclassified* remains open; what is now certain is that two 4x-Blackwell machines are live at once).
- **Registered as "Death Star 2"** via the dashboard's own add-node flow (`POST :3005/api/nodes/add`, atomic write to `node_config.json`); master agent `/nodes` now returns Nano + Death Star + Death Star 2. `node_config.json` is gitignored runtime config - nothing to commit for the registration itself.
- **Remaining from the 07-30 checklist:** decide model/workload placement across DS1 vs DS2 (nothing deployed on DS2 yet); confirm the chassis model for the Overview table; pilot-unit disambiguation above.

## 2026-07-31 - Cluster web dashboard was down ~a month unnoticed; now in the boot path (boot.sh step 3)

Dominic asked why the "vllm cluster webpage" was unreachable. Ground truth: **nothing was listening on :3005** - the dashboard's own log shows its last start on **2026-07-01**; the 07-27 patch reboot is the latest it could have died, and no sweep ever counted it because it was in NEITHER systemd NOR the fleet boot path (this repo's `boot.meta.json` boots only the control plane). Same failure class as foundation-after-hours on 07-29, third instance overall (llm-proxy 07-28, after-hours 07-29, this).

- **Immediate:** started it via `dashboard/start_dashboard.sh` - :3005 answers 200.
- **Durable:** `boot.sh` gained **step 3** (master/both roles): if :3005 is dead, start the dashboard; idempotent when alive. `boot.meta.json` `extra_ports` now lists 3005. **Kill-tested:** killed the :3005 listener, ran `boot.sh` - agent/proxy fast-pathed as already-healthy, dashboard back in 2s.
- **Residual gaps, on the record:** (1) the fleet watchdog health-checks only :4000 for this entry, so a SOLO :3005 death goes unnoticed until the next boot.sh run (reboot, patch night, or watchdog recovery of the control plane); (2) the dashboard tile + admin page link to `https://aisandbox.txamfoundation.com/InferenceCluster`, but **no proxy route or basePath exists for that path - it 404s for a signed-in user** and likely always has. Proxying it properly is not just a route row: the app's browser code calls node agents DIRECTLY over the AI VLAN (`http://10.2.35.x:5000`), which an HTTPS page would mixed-content-block - so remote access needs an agent-proxying refactor first. Access today is direct: `http://localhost:3005` on the box (or the box IPs where the client network can reach them).

## 2026-07-30 - Death Star 2 has arrived - IP assigned, onboarding not yet started

**Death Star 2 arrived today.** Assigned IP: **`10.2.35.21`** - the second slot in the big-compute band (`.20-.29`), immediately next to Death Star 1 at `.20`, per the documented function-based IP-banding convention (Foundation Infrastructure `Operations-Runbook.md`, "IP Allocation Convention").

**This is a DHCP reservation, not a static config** - per the same convention, Cody (Foundation IT) needs to add a MAC-keyed reservation for `.21` before the box will actually come up on that address. Not yet done as of this entry.

**Not yet done (real onboarding work, not just a documentation note):**
- Get the DHCP reservation for `.21` from Cody, keyed to Death Star 2's MAC address
- Register the node with the cluster's control agent / `node_config.json` (role=`child`, big-compute)
- Confirm GPU count/model on Death Star 2 (assumed similar to Death Star 1's 4× RTX Pro 6000 Blackwell, but not yet confirmed physically)
- Add Death Star 2 to the Hardware Fleet table in Overview.md once specs are confirmed (placeholder row added below, marked pending)
- Decide model/workload placement across Death Star 1 vs. 2 once the second node is live

**Also worth resolving separately:** the vault's HP Z Workstation pilot (identical 4× RTX Pro 6000 Blackwell spec) was never confirmed as a distinct physical unit from Death Star 1 - worth confirming Death Star 2 isn't actually that same pilot unit being reclassified, versus genuinely new hardware.

## 2026-07-22 - Proposal to expose the proxy externally to Salesforce IP ranges

Andrew proposed (email to Cody Nerren + Steve Catlin, cc Drew East) securely exposing this cluster's LiteLLM proxy (`10.2.35.10:4000/v1`) to Salesforce's common IP ranges, so Cortex workflows can offload expensive inference to local compute. New project: [[../../0. Active Priority/Local Stack Access (AI Endpoint)/Notes|Local Stack Access (AI Endpoint)]]. No changes made to this cluster yet - proposal stage only, awaiting IT/security discussion.

## 2026-07-17 - Moved to Maintain

Project moved from Active Priority to Maintain as part of a broader portfolio reorganization pass - cluster is operational and serving the fleet; additional capability gets added as needed rather than under active build. No technical work done on this project today.

## 2026-07-16 — Voicebox: durability flag PASSED; Chatterbox Turbo + Whisper Turbo added; GPU concurrency profiled

- **Yesterday's durability flag: PASSED for normal operation.** Voicebox came up healthy this morning (~18h after the fixes) with both Qwen models loaded and profiles intact — the container fixes survived. The bake-into-image ask stands only for the full-rebuild/reboot case (unchanged from yesterday's wording).
- **Two models added from the aivm via the API** (disk fine post-cleanup): `chatterbox-turbo` (3.8 GB — zero-shot cloning engine, now the workhorse: ~3× faster than base qwen per generation, ~1.5–2s/sentence; rejects reference clips ≤5s) and `whisper-turbo` (STT for the capture API — powers the dashboard clone card's mic auto-transcription). Note: non-Qwen engines lazy-load on first generation; `/models/load` is Qwen-only.
- **GPU concurrency profiled** (chatterbox_turbo, same sentence, through the Coach service path): solo ≈ 2.0s; 2 concurrent ≈ 2.7–3.1s each (GPU overlaps two well); 3 concurrent ≈ 6.1–6.4s each, all finishing together (time-slicing, not FIFO — unlike the async `/generate` queue for qwen, which is serial FIFO). `/generate/stream` returns the complete WAV at generation end, not progressively.
- **Consumers now: HyperFrames narration + Foundation Coach live voice + dashboard panel tests** — all sharing the one GPU. Contention is real (an HF render's TTS phase slows a live Coach session); if simultaneous demand grows, the options are a second GPU worker or the 0.6B Chatterbox model.
- **API quirks catalogued today** (also in the dashboard/HF notes): `GET /profiles/{id}` always reports `sample_count: 0` (LIST + `/samples` are truthful); a `/generate` request that omits `engine` does NOT fall back to the profile's default engine — the API default (base qwen) silently wins, so every consumer must pass engine explicitly.

## 2026-07-15 — Voicebox Qwen TTS unblocked (disk, torchaudio, Triton) and live

Voicebox (Death Star `10.2.35.20:17600`) went from "loads nothing usable" to serving Qwen TTS end-to-end today. Three stacked, distinct blockers, each diagnosed from the aivm (which has NO SSH to the Death Star - key rejected, password auth for `admin`/`aivmadmin` also rejected) and fixed by Andrew on the box after a handoff recipe:

1. **Disk full.** `GET /health/filesystem` reported ~36 MB free of 952 GB (`healthy:false`); nothing could download. Andrew freed it to ~292 GB.
2. **torch/torchaudio CUDA mismatch.** Qwen model downloads errored: "PyTorch has CUDA version 13.0 whereas TorchAudio has CUDA version 12.8." Qwen imports torchaudio; Kokoro does not (why Kokoro alone had worked). Fixed so both Qwen models now download + load (`qwen-tts-1.7B`, `qwen-custom-voice-1.7B`).
3. **Triton "Failed to find C compiler."** After the models loaded, generation still failed: Qwen JIT-compiles Triton kernels on first inference and the container had no `gcc`. Reproduced via both HyperFrames `tts.py` and a direct `/generate`. Andrew installed a compiler in the container; Qwen generation now returns audio.

Cleanup done from the aivm side via the Voicebox API: dismissed the two errored Qwen download tasks (`/models/download/cancel`) so `/tasks/active` was clean before the retries.

**Live now (HTTP-verified):** `qwen-tts-1.7B` + `qwen-custom-voice-1.7B` both loaded; a real HyperFrames narration preview produced valid 24 kHz audio through the deployed proxy. Voice model in use for narration is `qwen_custom_voice` (Ryan preset). Managed from the new dashboard `/admin/voicebox` panel; consumed by HyperFrames narration (see [[../HyperFrames Education Generator/Notes]] 07-15, [[project_hyperframes_voicebox_narration]]).

**DURABILITY FLAG (Cody / Andrew):** if the three container fixes (disk cleanup aside) - the torchaudio-matching-torch install and the `gcc`/`build-essential` install - were applied to the running container rather than baked into the `~/voicebox` Dockerfile (its `cuda` build branch), a container rebuild or restart could regress them and silently break Qwen TTS. Confirm they persist across a Voicebox restart; fold `build-essential` + a cu130-matching torchaudio into the image if not.

## 2026-07-14 — VM confirmed reachable to Voicebox; management-interface idea; dev branch reconciled

**Voicebox reachability confirmed:** Dominic verified the VM (10.2.35.10) can reach the Death Star's Voicebox endpoint (`10.2.35.20:17600/health` → healthy, RTX PRO 6000 Blackwell GPU visible, no model loaded yet). Voice testing planned for tomorrow (2026-07-15), then integration into HyperFrames.

**New idea (Andrew):** the Foundation's current text-to-speech consumers are Foundation Coach and HyperFrames. Rather than requiring Death Star SSH access every time a voice/profile needs customizing, build a lightweight management interface on the VM that proxies to the Voicebox endpoint - giving both consuming apps (and future ones) a way to configure voices/profiles without touching the Death Star directly. Not started; captured as a real idea worth roadmapping.

**`dev` branch reconciled:** config snapshot committed+pushed to `main` (`cbffaf3`; Death Star `:8021` gemma confirmed out of pool/connection-refused, `:8023` + `10.2.35.30:8020` still serving); local `dev` fast-forwarded 18 commits to `origin/dev`. Closes the long-carried "GitHub ahead of local" Master To Do item.

---

## 2026-07-14 (Tuesday) — `dev` branch reconciled; Death Star `:8021` gemma instance confirmed down

**Config snapshot committed** (`cbffaf3` on `main`): the control agent's generated `litellm/cluster_config.yaml` had an uncommitted local diff dropping the Death Star `:8021` gemma instance — confirmed genuinely down (connection refused) before committing, not just diffing. `:8023` and `10.2.35.30:8020` remain in the chat pool, so the cluster is running two gemma endpoints instead of three; worth knowing if latency creeps up under load.

**`dev` branch reconciliation:** local `dev` was 18 commits behind `origin/dev` with no local divergence — fast-forwarded clean (`f22011c` now the tip). Closes the Master To Do item that had been carried since 07-13.

**Also:** renamed a doc-comment referencing "Tetrix" (timeout-rationale note in `agent/agent.py`) to "Providence" following that repo's rename today — cosmetic, no behavior change. Commit `f22011c`.

**Voicebox check (Investments/adjacent to this repo, not this repo itself):** `10.2.35.20:17600/health` reachable and healthy, CUDA GPU visible, `model_loaded: false` — production voice/engine selection still pending, not this repo's decision to make.

---

## 2026-07-08 (PM) — ✅ Voicebox LIVE on Death Star GPU (sm120 solved), LAN-reachable

**Status: WORKING end-to-end.** Voicebox is deployed headless on the Death Star, running on the Blackwell GPU, reachable from the LAN, and reboot-persistent. Real 24 kHz WAV synthesized via `/speak`. This is the win the Higgs saga never reached.

**The sm120 problem that killed Higgs is solved by the toolchain, not a patch.** Inside the container: `torch 2.13.0+cu130` (resolved to CUDA 13, newer than the cu128 I targeted), `cuda.is_available()=True`, device = RTX PRO 6000 Blackwell, capability `(12,0)`, and **`sm_120` is in `torch.cuda.get_arch_list()`**. Higgs died precisely because its torch had no sm120 kernels; this build ships them. `/health` reports `backend_variant: cuda`, `gpu_compatibility_warning: null` (the backend's `check_cuda_compatibility()` gives it a clean bill — no CPU fallback).

**How it's wired:**
- Image built from `~/voicebox` with a **`cuda` build branch added to the Dockerfile** (installs torch/torchaudio from the cu128 wheel index; pip resolved cu130) — mirrors the stock ROCm branch. NVIDIA overlay `docker-compose.nvidia.yml` pins **physical GPU 0** (`device_ids:["0"]`, gemma is on GPU 3) with a 24 G mem limit.
- Host prereqs done: `nvidia-container-toolkit` installed + `nvidia-ctk runtime configure` + `systemctl restart docker` → `nvidia` runtime registered.
- Port published **`0.0.0.0:17600:17493`** → VM webapps hit **`http://10.2.35.20:17600/speak`** directly (custom API, NOT OpenAI `/v1/audio/speech`, so it does NOT route through the LiteLLM proxy — by design).
- **Ownership fix baked into the entrypoint** (`scripts/rocm-entrypoint.sh`): Docker creates the HF-cache volume + `output/` bind-mount root-owned, but the app runs as `voicebox` (uid 999) → model download hit `EACCES`. Entrypoint now chowns `/home/voicebox/.cache` + `/app/data(/generations)` and pre-creates the torch JIT-kernel cache dir on every boot (idempotent, self-healing). Verified cold-start works with no manual chown.

**Boot persistence:** container `restart: unless-stopped` + `docker.service` enabled → survives crash and host reboot with no human in the loop.

**Ops (dir `~/voicebox`):** `bash start_voicebox.sh` (up + polls `/health`, prints LAN URL) / `bash stop_voicebox.sh` (down, keeps data volumes). Model cache + profiles/DB persist in named volumes across restarts/rebuilds.

**Engines/voices:** 7 engines available (qwen, qwen_custom_voice, luxtts, chatterbox, chatterbox_turbo, tada, kokoro). A `/speak` call needs a **voice profile** first — created a Kokoro preset profile `Coach-Michael` (`am_michael`, id `80ad109b-497e-45d0-b5a3-56cece634e90`) via `POST /profiles` `{voice_type:"preset", preset_engine:"kokoro", preset_voice_id:"am_michael"}`. `/speak` is **async**: returns `status:"generating"`, writes the `.wav` to `output/<gen-id>.wav` a few seconds later. Kokoro presets list at `GET /profiles/presets/kokoro`.

**Next:** point the VM webapp(s) at `http://10.2.35.20:17600/speak` (create/choose a profile per voice); optionally evaluate the heavier engines (Qwen3-TTS quality, Chatterbox cloning) now that the GPU path is proven.

---

## 2026-07-08 — Higgs Audio ABANDONED (dead end); pivot to Voicebox headless TTS

**Decision (Andrew):** Stop pursuing Higgs Audio V3 — it was a dead end (the sm120 driver/fault-buffer saga + zero-shot-only voices never justified the effort). **Pivoting to [Voicebox](https://voicebox.sh)** — an open-source, local-first, API-first voice studio (7 TTS engines incl. Kokoro/Qwen3-TTS/LuxTTS, plus Whisper STT + voice cloning; REST `/speak` + `/transcribe` and a built-in MCP server).

**Target architecture (same pattern as before):** install Voicebox **headless on the Death Star** (`10.2.35.20`) via its **Docker image** (`uvicorn backend.main:app --host 0.0.0.0 --port 17493`, health `/health`) → expose on the LAN → VM webapps call `http://10.2.35.20:<port>/speak`. NOT the Tauri desktop build (that needs a display + webkit deps — wrong for a headless server). Note: `/speak` is a **custom** API, not OpenAI `/v1/audio/speech`, so it does NOT route through the LiteLLM proxy — webapps hit it directly.

**Feasibility notes captured today:**
- Disk was the blocker (13 GB free, `/` 99%). Reclaiming the **19 GB dead-end Higgs install** (`/home/admin/higgs-audio`) frees enough for the build.
- Docker present, but **no nvidia-container-toolkit** and Voicebox ships only CPU + ROCm compose (no NVIDIA overlay). **POC plan: CPU-only** (Kokoro 82M / LuxTTS "150x realtime on CPU") — sidesteps the sm120 CUDA compatibility risk that sank Higgs. GPU accel is a later, optional step.
- Compose default binds `127.0.0.1:17600:17493` — must change to `0.0.0.0` (or the LAN IP) so the VM can reach it.

**Other status per Andrew:** watchdog stays **disabled** for now (no re-enable work). The pending `dev`→live vLLM deploy is **demoted to non-critical** (roadmap, not urgent).

---

## 2026-07-06 - Filed: 07-01 dev-branch fixes + model-load visibility note
The 2026-07-01 Quick Note (dev-branch commit log, operational gotchas, open issues, model-load visibility feature spec) moved whole into this project: [Cluster-Fixes-and-Model-Load-Visibility-2026-07-01.md](Cluster-Fixes-and-Model-Load-Visibility-2026-07-01.md). Roadmap backlog updated to point at it.

## 2026-07-02 — Router timeout 30s→150s + Death Star back in the pool

**Router timeout raised** (`agent/agent.py` `router_settings.timeout`, commit `1056f98`; config snapshot `1c3f664`). The 30s router timeout 408'd legitimate long non-streaming generations — Tetrix document extraction runs 25-45s, HR synthesis 80-120s — and `num_retries: 3` × 30s wedged callers for minutes (surfaced as three Tetrix docs stuck 'processing'; diagnosis trail in the Tetrix ROADMAP 07-02 entry). Now 150s, keeping the defensive-timeout cascade ordered: **NGINX 180 > tool clients ~170 > router 150 > vLLM**. Streaming paths (Coach voice, Chat) unaffected in feel — total-request cap, not time-to-first-token. Deployed via the standard procedure: commit → restart master agent (:5000) → `POST /proxy/sync`; chat + embeddings verified immediately after.

**Death Star is back.** Verified live: nvfp4 gemma serving on `10.2.35.20:8021` AND `:8023` (both in the proxy's least-busy gemma pool alongside `10.2.35.30:8020`), nomic embeddings on `:8022` — no crash-loop, so the CUDA blocker is resolved (Cody's upgrade evidently landed). Embedder health verified with a sustained loop (20/20 single embeds @ ~30ms avg + batch-array). **Downstream unblocks:** Deep Research live runs (first live run still needs a verification pass) and the R&FI 3,600-researcher briefing batch (awaiting Andrew's go — it occupies the LLM for hours).

## 2026-07-01 — Auto-restart watchdog DISABLED (was causing self-inflicted crash-loops)

**Action:** Turned off the per-node instance watchdog. Committed on `dev` (`9963401`) — the thread-start in `_on_startup` is commented out; `_instance_watchdog_loop`/`_instance_watchdog_tick` are preserved for future work. Applied live on the Death Star via `POST /agent/restart` (no sudo); confirmed the thrash stopped (GPU 1 held steady, no relaunch over 80s).

**Why:** The watchdog was doing more harm than good on this cluster. Root cause of the crash-looping:
- `_scan_vllm_instances()` depends on `psutil.net_connections()`, which **intermittently returns empty** on this box (same flakiness that made `/instances` blank and broke the first GPU-label attempt).
- When a scan tick flakes, the watchdog thinks healthy instances are "missing" → relaunches them → `launch_instance`'s **VRAM reclaim kills the healthy copy** → self-inflicted crash-loop. Made permanent by the earlier keep-retrying change (`e30544a`).
- Observed thrashing **gemma `:8020`** (local copy) and the 196K **`:8021`** indefinitely. Also the `localhost`/IPv6 health-check failure compounds it (vLLM binds IPv4; `localhost` → `::1`).

**Consequence:** Instances no longer auto-relaunch if they die — a manual relaunch (or agent restart with the watchdog re-enabled) is needed until the root cause is fixed. Acceptable for now; the false-relaunch thrash was worse than no auto-restart.

**Re-enable criteria (see Roadmap):** (a) make the instance scan robust / not solely `net_connections`-dependent; (b) reclaim must never kill a healthy co-located/same instance; (c) fix the `localhost` health check to use `127.0.0.1`. Then uncomment the two lines in `_on_startup`.

**Cluster state after:** agent + dashboard up (systemd), nomic `:8022` healthy and serving (768-dim, direct + via proxy), gemma served cluster-wide via the Nano's copy through the proxy. The Death Star's local gemma `:8020` is intentionally down (redundant; was the thrash victim).

---

## 2026-06-30 — Infrastructure Stability: Both Nodes UPS Protected, Cold-Reboot Verified

Both the Master VM (10.2.35.10) and Death Star (10.2.35.20) are now on UPS power. Both nodes verified to come back up cleanly after a reboot and restore proxy inference without manual intervention. This closes the cold-reboot verification concern that had been open since June 24.

The NVRM shadow fault buffer issue that blocked Higgs Audio V3 first inference was tied to 5-day uptime under memory pressure. With UPS in place, controlled reboots can be done on demand without power-loss risk, removing the primary source of driver state accumulation.

---

## 2026-06-30 — VM Inference Proxy Update: bare `/v1/embeddings` fixed (encoding_format pinned in the generator)

Resolved Andrew's Planner card **"VM Inference Proxy Update"** — cluster embeddings weren't working through the LiteLLM proxy. Bare `POST /v1/embeddings` to `:4000` returned **HTTP 400** because LiteLLM (v1.83.14) injects `encoding_format=None`, which vLLM rejects (`Input should be 'float','base64','bytes' or 'bytes_only'`, input=`None`).

**The initial "proxy is just a couple updates behind" assumption was wrong.** The global `litellm_settings: drop_params: true` is already in the live config and does **not** fix this. Verified by standing up a fresh shadow litellm on `:4001` with the exact live config — it still 400'd. So a process restart/update alone was a no-op for embeddings.

**Root cause / topology confirmed:**
- aivm (`10.2.35.10`) is the cluster **master** node (role in `node_config.json`; control agent on `:5000`).
- The live `litellm/cluster_config.yaml` is **auto-generated by the control agent** (`agent/agent.py`) and is marked "do not edit by hand."
- The aivm repo was already current on `main` (0 behind). The running agent process was stale (started Jun 05) but the current code generated a **byte-identical** config — so restarting the agent alone changed nothing for embeddings.
- Proxy routes: chat `gemma-4-26b-a4b-nvfp4` → `10.2.35.30:8020`; embeddings `nomic-embed-text-v1-5` → Death Star `10.2.35.20:8022`. Embedding model max context = **2048**.

**The fix (commit `1efb987` on `main`, pushed):** patched the generator `agent/agent.py` (~line 466, in `_proxy_write_and_restart`) to append `encoding_format: float` to the `litellm_params` of embedding models — detected via `if "embed" in served_name.lower()`. This pins the value so bare calls carry it.

**Deploy steps:**
1. Commit + push the `agent.py` change.
2. Restart the master control agent: `agent/stop_agent.sh` then `agent/start_agent.sh` (loads the new generator code; agent on `:5000`).
3. `POST http://127.0.0.1:5000/proxy/sync` → regenerates `cluster_config.yaml` (now with `encoding_format: float` on the embed model) and bounces the `:4000` proxy (a few-second chat blip; the old orphaned proxy pid was replaced cleanly).

**Verification:**
- Bare `/v1/embeddings` on `:4000` now returns a **768-dim vector** — no caller workaround needed.
- gemma chat on `:4000` still healthy.
- Downstream consumer **R&FI's ChromaDB RAG** (the main embeddings consumer) is now unblocked.

**Docs:** added `docs/UsingTheProxy.md` to the repo as the single consumer-facing reference for the `:4000` proxy.

**Operational note worth recording:** the aivm cluster agent runs as a plain background process (`.agent_pid`), **NOT under systemd** — it will not auto-restart on reboot.

---

> **Variant preserved from the repo mirror at reconciliation (2026-07-29)** — same-titled section drifted on both sides; the mirror's wording carried detail the vault copy lacked:

> Resolved Andrew's Planner card **"VM Inference Proxy Update"** — cluster embeddings weren't working through the LiteLLM proxy. Bare `POST /v1/embeddings` to `:4000` returned **HTTP 400** because LiteLLM (v1.83.14) injects `encoding_format=None`, which vLLM rejects (`Input should be 'float','base64','bytes' or 'bytes_only'`, input=`None`).
> **The initial "proxy is just a couple updates behind" assumption was wrong.** The global `litellm_settings: drop_params: true` is already in the live config and does **not** fix this. Verified by standing up a fresh shadow litellm on `:4001` with the exact live config — it still 400'd. So a process restart/update alone was a no-op for embeddings.
> **Root cause / topology confirmed:**
> - aivm (`10.2.35.10`) is the cluster **master** node (role in `node_config.json`; control agent on `:5000`).
> - The live `litellm/cluster_config.yaml` is **auto-generated by the control agent** (`agent/agent.py`) and is marked "do not edit by hand."
> - The aivm repo was already current on `main` (0 behind). The running agent process was stale (started Jun 05) but the current code generated a **byte-identical** config — so restarting the agent alone changed nothing for embeddings.
> - Proxy routes: chat `gemma-4-26b-a4b-nvfp4` → `10.2.35.30:8020`; embeddings `nomic-embed-text-v1-5` → Death Star `10.2.35.20:8022`. Embedding model max context = **2048**.
> **The fix (commit `1efb987` on `main`, pushed):** patched the generator `agent/agent.py` (~line 466, in `_proxy_write_and_restart`) to append `encoding_format: float` to the `litellm_params` of embedding models — detected via `if "embed" in served_name.lower()`. This pins the value so bare calls carry it.
> **Deploy steps:**
> 1. Commit + push the `agent.py` change.
> 2. Restart the master control agent: `agent/stop_agent.sh` then `agent/start_agent.sh` (loads the new generator code; agent on `:5000`).
> 3. `POST http://127.0.0.1:5000/proxy/sync` → regenerates `cluster_config.yaml` (now with `encoding_format: float` on the embed model) and bounces the `:4000` proxy (a few-second chat blip; the old orphaned proxy pid was replaced cleanly).
> **Verification:**
> - Bare `/v1/embeddings` on `:4000` now returns a **768-dim vector** — no caller workaround needed.
> - gemma chat on `:4000` still healthy.
> - Downstream consumer **R&FI's ChromaDB RAG** (the main embeddings consumer) is now unblocked.
> **Docs:** added `docs/UsingTheProxy.md` as the single consumer-facing reference for the `:4000` proxy.
> **Operational note worth recording:** the aivm cluster agent runs as a plain background process (`.agent_pid`), **NOT under systemd** — it will not auto-restart on reboot.
> ---

## 2026-06-29 (PM) — Higgs Audio V3 Deploy on Death Star: Full Stack Working, Blocked on Driver Fault-Buffer

**Status:** Software stack 100% configured and verified. Blocked on a driver-level GPU memory allocation failure. Rebooting the box to retry on clean driver state (in progress at end of session).

**Goal of the session:** Actually deploy Higgs Audio TTS V3 on the Death Star (`10.2.35.20`, GPU 1 — GPU 0 reserved for training) and produce a first `.wav` (proof of concept). The model is **`bosonai/higgs-tts-3-4b`** (4B Qwen3 backbone + audio codec), served via **SGLang-Omni** (the official Boson AI self-host path; the old `boson-ai/higgs-audio` repo is V2 only).

### What got built / installed (all on the Death Star)
- **SGLang-Omni** installed manually into `/home/admin/higgs-audio/venv` (uv venv, py3.12). Docs recommend Docker but disk was too tight; manual install works.
- **Model** downloaded to `/home/admin/higgs-audio/model` (9.3 GB, public, no HF auth needed).
- **`/home/admin/higgs-audio/start_higgs.sh`** — complete launcher with all required env (see below).
- **`/home/admin/higgs-audio/higgs_poc.yaml`** — pipeline config with the tts_engine server_args_overrides that are required on sm120.
- API is **OpenAI-compatible** (`POST /v1/audio/speech`) — confirmed. So once serving, it's a drop-in for the proxy + Coach (no custom Pipecat wrapper needed). **Note: V3 is zero-shot — no preset named voices like Kokoro; voice cloning is via reference audio clip.** This changes the Coach voice-picker design (decide later: hide picker, or use reference-clip "characters").

### The sm120 (RTX PRO 6000 Blackwell) gauntlet — all REAL, all required
Took a long debugging chain. The opaque `-9 SIGKILL` crashes (no traceback) masked a series of plain toolchain errors. **`CUDA_LAUNCH_BLOCKING=1` is the key** — it converts the async crash into a readable Python error. Root causes, in order found:
1. **CUDA 12.8 can't target sm120** — needs ≥ 12.9. Installed `cuda-nvcc-13-0` + `cuda-libraries-dev-13-0` (the latter for `cublasLt.h` and other math-lib dev headers). `/usr/local/cuda-13.0`.
2. **FlashInfer's `is_cuda_version_at_least("12.9")` is buggy for CUDA 13.0** → workaround `FLASHINFER_CUDA_ARCH_LIST="12.0f"`.
3. **No prebuilt sm120 cubins** → FlashInfer JIT-compiles kernels on first request via **ninja** (must be on PATH — prepend `venv/bin`) + nvcc-13.
4. **Acoustic-encoder `torch.compile` + warmup crash on sm120** → patched `sglang_omni/models/higgs_tts/stages.py` to skip both, gated by `HIGGS_DISABLE_ACOUSTIC_COMPILE=1`.
5. Pipeline config needs: `disable_cuda_graph: true`, `disable_flashinfer_autotune: true`, `attention_backend: triton`, `sampling_backend: pytorch`, `mem_fraction_static: 0.50`.

**After all fixes: server starts clean, all 4 stages load, kernels compile.** Verified the model loads (7.6 GB), KV cache allocates, Uvicorn serves on `:8881`.

### The remaining blocker (THE thing to solve next)
First inference dies with NVRM **`NV_ERR_NO_MEMORY` allocating system memory for the GPU shadow fault buffer** (`_kgmmuClientShadowFaultBufferPagesAllocate`). Confirmed via `sudo dmesg`. **Not a code, config, RAM, or sm120-compute problem** — it failed even with 21 GB free RAM, drained swap, and an empty GPU. vLLM/gemma run fine on the same box (they use plain `cudaMalloc`; sglang-omni uses a GPU-fault-based memory path that needs the shadow fault buffer, which the driver refuses to allocate). Box had 5-day uptime under heavy memory pressure. **Hypothesis: stale driver memory state → reboot should clear it.** Bringing Higgs up FIRST on a fresh boot (before cluster/training reclaim resources) is the test.

### The verified launch command (post-reboot)
```bash
bash /home/admin/higgs-audio/start_higgs.sh
# env baked in: MAX_JOBS=1, PATH=venv/bin:cuda-13.0/bin, CUDA_VISIBLE_DEVICES=1,
# HIGGS_DISABLE_ACOUSTIC_COMPILE=1, FLASHINFER_CUDA_ARCH_LIST=12.0f, CUDA_HOME=/usr/local/cuda-13.0
```
First request JIT-compiles (~1-3 min, cached after). `file ~/higgs_test.wav` → `WAVE audio` = POC achieved.

**Full reproduction + gotchas saved to auto-memory `higgs-audio-sm120-serving`.** If clean-boot retry still hits the fault-buffer error, it's a genuine driver/Blackwell bug → defer to the real Death Star hardware (~2 weeks); the proxy + Coach integration is already staged on the `dev` branches (see entry below).

---

## 2026-06-29 — Model Evaluation: Minimax 2.7 on Dual RTX Pro 6000 Blackwell

**Test:** Minimax 2.7 running across two RTX Pro 6000 Blackwell GPUs on the Death Star
**Tool:** Continue extension (VS Code) as the AI agent coding interface

### Results

**Throughput:** ~80 tokens/second across both GPUs. Strong decode performance for a model of this size.

**Code quality:** Very good. Comparable to Claude Code for agentic coding tasks. Genuinely competitive for most coding workflows when used with the Continue extension.

**Limitations:**
- Slow prompt processing (prefill / time-to-first-token is sluggish; noticeable on long inputs)
- Context window under 200K tokens; cramped during longer Second Brain sessions and extended coding tasks where full context is needed

### Verdict

Minimax 2.7 is a credible local alternative to Claude Code for standard coding tasks. The throughput is good enough for interactive use. However, the slow prompt processing and sub-200K context window make it a poor fit for the Second Brain management workflows and for long-running coding sessions where full context matters. Better suited to contained, shorter coding tasks where the context limit is not a binding constraint.

**Follow-on:** The two DGX Spark nodes (GB10, 128GB each) are already on the network and pending naming. Revisit Minimax 2.7 or a larger context window variant once they are fully integrated into the cluster routing — more combined VRAM may resolve the prompt processing bottleneck. Continue extension integration is confirmed working as the agent coding interface.

---

## 2026-06-29 — Higgs Audio TTS V3: Modular Proxy Architecture (Dev Branches Shipped)

**Status:** Dev branches ready. Deployment pending on Death Star + Master VM (other computer).
**Repos:** `AI-Distributed-Inference-Cluster` @ `dev` commit `e03ce50`, `Foundation-Coach` @ `dev` commit `bfb7253`

### What shipped on `dev` today

**Cluster repo — modular static model overlay:**
- `litellm/static_models.yaml` (new) — non-vLLM model declarations that survive every agent-generated rewrite of `cluster_config.yaml`. Higgs Audio entry uses `$HIGGS_AUDIO_HOST` env var.
- `agent/agent.py` — `_proxy_write_and_restart` now reads `static_models.yaml` and merges entries after building the vLLM list. Env vars expanded at write time; unexpanded entries skipped silently.
- `litellm/start_proxy.sh` — sources `litellm/.env` before starting so `HIGGS_AUDIO_HOST` is available.
- `litellm/.env.example` — documents audio host vars; copy to `litellm/.env`.
- `scripts/install_higgs_audio.sh` — idempotent install script: clones repo, builds venv, generates `start_server.sh`/`stop_server.sh`, prints systemd template + the `litellm/.env` line.

**Foundation Coach repo — provider-aware TTS:**
- `TTS_PROVIDER` env var (`kokoro`|`higgs-audio`), dynamic VALID_VOICES, `TTS_BASE_URL` default → proxy (`:4000`), voice picker switches per provider, `HIGGS_AUDIO_VOICES` placeholder array.

### Hardware swap path (when Death Star demo is replaced — ~2 weeks)
```
1. New node:   bash scripts/install_higgs_audio.sh
2. Master VM:  edit litellm/.env → HIGGS_AUDIO_HOST=http://<new-ip>:8881
3.             bash litellm/stop_proxy.sh && bash litellm/start_proxy.sh
Foundation Coach: zero changes — calls the proxy, not the node directly.
```

### Still pending (Death Star access needed)
- [ ] Pull `dev` to Master VM + Death Star
- [ ] Run `scripts/install_higgs_audio.sh` on Death Star — confirm `HIGGS_AUDIO_REPO` URL + `START_CMD` entrypoint in generated `start_server.sh`
- [ ] Create `litellm/.env` on Master VM: `HIGGS_AUDIO_HOST=http://10.2.35.20:8881`
- [ ] Restart proxy → verify `higgs-audio-tts` in `GET /v1/models`
- [ ] **Verify API format:** OpenAI-compatible `/v1/audio/speech`? If custom, write thin Pipecat wrapper
- [ ] **Benchmark latency:** first-chunk vs. Kokoro — must be ≤ for real-time voice
- [ ] **Get voice IDs** → fill `HIGGS_AUDIO_VOICES` in `prospect.ts` + `TTS_VOICES` in `backend/.env`
- [ ] **Speed param:** confirm `speed` support; if not, set `NEXT_PUBLIC_TTS_SPEED_SUPPORTED=false`
- [ ] Live voice test end-to-end via `bash boot.sh`

**Filed from:** Quick Note `2026-06-26-higgs-audio-tts-v3-integration`

---

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

## 2026-05-18 - Nano 0 child-node bugfix; cluster inference back to known-good

Squashed bugs and updated the child node on Nano 0. Server inference is working correctly end-to-end again:

- LiteLLM router on the VM (`localhost:4000` / `10.2.35.10:4000`) probes healthy with one loaded model (`gemma-4-26b-a4b-nvfp4`) - confirmed via the Scholarships Tools `/api/inference/discover` probe today as a side-effect of getting the Settings tab working there.
- Cluster proxy responds to chat completions cleanly (1 model returned, status 200) - verified by direct curl to `/v1/models` and indirectly by the Living Catalog backend (Information Requests endpoint queues items with the model selected).

**Stale defaults cleaned up:** The Scholarships Tools `inference.py` had `10.2.30.28:4000` (legacy Death Star) in the auto-discovery list - dead since the subnet migration. Replaced with `localhost:4000` first, then `10.2.35.10:4000`. Kept the legacy entry as a no-op probe so machines on the old subnet still resolve.

**Open thread:** Death Star migration to `.35.2x` is still TBD with Cody. Today's work doesn't depend on it because the VM is now the cluster master and runs LiteLLM locally.

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
