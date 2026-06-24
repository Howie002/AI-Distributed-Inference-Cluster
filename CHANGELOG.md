# Changelog

Notable changes to the vLLM Stack. Newest first. Format loosely follows
[Keep a Changelog](https://keepachangelog.com/) — Added / Changed / Fixed.

---

## 2026-05-06 — Tool calling support for vLLM-served models

### Added
- **`enable_auto_tool_choice` and `tool_call_parser` flags** in `agent/model_library.json`'s per-model `flags` block. When set, the cluster agent passes `--enable-auto-tool-choice` and `--tool-call-parser <name>` to `vllm serve` at launch.
- Both Nemotron models and both base Llama 3.x models now ship with these flags pre-configured (parser: `llama3_json`).

### Changed
- `agent/agent.py` `launch_instance()` — `vllm serve` command builder now reads the two new flag keys and appends the corresponding CLI args. Backward compatible: models without these keys launch exactly as before.

### Fixed
- **Agentic clients (CrewAI, LangChain agents, the Deep Research Agent in Fundable Ideas) could not use any vLLM-served model.** vLLM rejected `tool_choice="auto"` requests with HTTP 400:

  ```
  litellm.BadRequestError: "auto" tool choice requires
    --enable-auto-tool-choice and --tool-call-parser to be set
  ```

  This silently broke every research job dispatched against the cluster proxy. Without these flags, vLLM serves chat completions but blocks function-calling — which agentic frameworks rely on for tool-using agents (web search, page fetch, note-taking, etc.).

### Operational note — applying the fix to a running model

These changes only take effect at vLLM **launch time**. Models already running before the fix landed must be restarted to pick up the new flags. Two paths:

**Via the cluster agent's API** (clean — proxy config refreshes automatically):
```bash
# Stop the instance
curl -X POST http://10.2.30.28:5000/instances/<port>/stop

# Relaunch — agent now reads the new flags from model_library.json
curl -X POST http://10.2.30.28:5000/instances/launch -d '{...}'
```

**Manual** (if you know the original `vllm serve` command):
```bash
pkill -f "vllm serve nvidia/Llama-3.1-Nemotron-Nano-8B-v1"
# Re-run the original command + add:
#   --enable-auto-tool-choice --tool-call-parser llama3_json
```

vLLM takes ~1–2 minutes to reload the model. Anything pointing at the cluster proxy gets `Connection refused` during that window.

### Per-model parser reference

| Model family | Parser to use | Notes |
|---|---|---|
| Llama 3.1 / 3.2 / 3.3 (incl. Nemotron Nano/Super) | `llama3_json` | Tested working with Nemotron-Nano-8B |
| Qwen 2.5 / Qwen 3 | `hermes` | Not yet enabled in model_library.json |
| Mistral 7B / Nemo 12B | `mistral` | Not yet enabled in model_library.json |
| Phi-4 | `phi4_mini_json` | Requires recent vLLM version |
| Gemma 3 / 4 | (no native support) | Use a different model for tool-calling workloads |
| DeepSeek R1 distills | `deepseek_v3` | Reasoning models — varies |

To enable for additional models, add the two flags to the model's `flags` block in `agent/model_library.json` and relaunch. Test with a real `tool_choice="auto"` request after each enable — parser names occasionally change between vLLM releases.

---
