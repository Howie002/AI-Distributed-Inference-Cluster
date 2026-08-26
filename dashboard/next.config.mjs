/** @type {import('next').NextConfig} */

/**
 * Feedback #242 (Andrew): *"Do a second tab of this and have the actual vllm
 * dashboard appear instead as if its from the vm."*
 *
 * Two changes make that possible:
 *
 * 1. **basePath.** The app now serves under /InferenceCluster so it can sit
 *    behind the Foundation dashboard's proxy plane with strip_prefix=0, the same
 *    shape every other proxied tool uses. Next rewrites <Link> and asset URLs
 *    for this automatically; plain fetch() calls it does NOT, which is why
 *    src/lib/api.ts has an apiUrl() helper and NEXT_PUBLIC_BASE_PATH is set to
 *    match. Overridable so a bare :3005 still works for local use.
 *
 * 2. **The /api/agent rewrite is gone**, replaced by a real route handler at
 *    src/app/api/agent/[ip]/[...path]/route.ts. The rewrite could only ever
 *    reach the MASTER agent (one AGENT_URL), so remote nodes had no same-origin
 *    path and the browser called them directly over the AI VLAN — the reason
 *    this dashboard could not be served over HTTPS. The route handler proxies
 *    any configured node, allow-lists the IP, and refuses model launches on
 *    agents that predate the VRAM-reclaim fix.
 */
const basePath = process.env.DASHBOARD_BASE_PATH ?? '/InferenceCluster';

const nextConfig = {
  basePath,
  env: {
    // Read by apiUrl() in src/lib/api.ts. Must equal basePath, or same-origin
    // fetches 404 in production while working in dev.
    NEXT_PUBLIC_BASE_PATH: basePath,
  },
};

export default nextConfig;
