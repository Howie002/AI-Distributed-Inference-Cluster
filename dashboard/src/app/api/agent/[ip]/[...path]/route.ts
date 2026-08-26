import { NextRequest, NextResponse } from 'next/server';
import { checkLaunchAllowed, readRoster, type AgentUpdateStatus } from '@/lib/launchGuard';

export const runtime = 'nodejs';
export const dynamic = 'force-dynamic';

/**
 * Same-origin proxy to any node's control agent.
 *
 * Feedback #242 (Andrew): *"Do a second tab of this and have the actual vllm
 * dashboard appear instead as if its from the vm. Should be possible now."*
 *
 * **Why this route is what makes that possible.** Every one of this dashboard's
 * ~48 agent calls goes through `agentBase()` in src/lib/api.ts, which returned
 * `http://10.2.35.x:5000` — a direct browser call over the AI VLAN. That is the
 * single reason the dashboard cannot be served over HTTPS: an HTTPS page
 * mixed-content-blocks plain-HTTP calls, and a remote browser has no VLAN route
 * anyway. It is also why the Foundation dashboard had to reimplement a read-only
 * view server-side (foundation-ai-dashboard src/lib/cluster.ts) instead of just
 * linking here. Moving those calls through this route makes the browser talk
 * only to this origin, so the real dashboard works behind the Foundation
 * dashboard's proxy — "as if its from the vm".
 *
 * It replaces the old `/api/agent/:path*` rewrite in next.config.mjs, which
 * could only ever reach the MASTER agent (AGENT_URL), so remote nodes had no
 * same-origin path at all.
 *
 * **Two guards, because this route can start and stop production inference.**
 *
 * 1. *SSRF allow-list.* The target IP must appear in node_config.json. Without
 *    it, `/api/agent/<anything>/...` would proxy arbitrary hosts from a machine
 *    sitting on both the corporate and AI VLANs.
 * 2. *Launch guard.* `POST /instances/launch` is refused on any node whose agent
 *    cannot be PROVEN to carry the VRAM-reclaim fix — see src/lib/launchGuard.ts.
 *    As of 2026-08-26 that blocks Nano 1 (10.2.35.30), whose agent is 40 commits
 *    behind on the commit that introduced the bug while it serves live gemma on
 *    its only GPU.
 *
 * Authentication is deliberately NOT here: this dashboard has none of its own and
 * is reached through the Foundation dashboard's proxy route, which enforces
 * admin/grant access at the edge. Do not expose :3005 directly.
 */

// Long enough for a model launch or an HF download kickoff; short enough that a
// dead node does not hold a browser connection open.
const READ_TIMEOUT_MS = 15_000;
const WRITE_TIMEOUT_MS = 60_000;

function resolveTarget(ip: string): { base: string; name: string } | null {
  const node = readRoster().find((n) => n.ip === ip);
  return node ? { base: `http://${node.ip}:${node.agent_port}`, name: node.name } : null;
}

/** The agent's own view of its code version, for the launch guard. */
async function fetchUpdateStatus(base: string): Promise<AgentUpdateStatus | null> {
  try {
    const res = await fetch(`${base}/update/status`, {
      cache: 'no-store',
      signal: AbortSignal.timeout(6000),
    });
    return res.ok ? ((await res.json()) as AgentUpdateStatus) : null;
  } catch {
    return null;
  }
}

async function handle(req: NextRequest, ctx: { params: Promise<{ ip: string; path: string[] }> }) {
  const { ip, path } = await ctx.params;
  const target = resolveTarget(ip);
  if (!target) {
    return NextResponse.json(
      { detail: `${ip} is not a configured cluster node` },
      { status: 403 }
    );
  }

  // Take the tail VERBATIM from the pathname rather than re-encoding the parsed
  // segments. Several agent routes are FastAPI `{model_id:path}` params holding
  // ids like "nvidia/Gemma-4-26B-A4B-NVFP4", which callers pass pre-encoded;
  // decoding them into params and re-encoding risks changing what the agent
  // receives. Splitting the raw path keeps the bytes the caller sent.
  const marker = `/api/agent/${ip}/`;
  const at = req.nextUrl.pathname.indexOf(marker);
  const suffix =
    at >= 0
      ? req.nextUrl.pathname.slice(at + marker.length)
      : (path ?? []).map(encodeURIComponent).join('/');
  const search = req.nextUrl.search;
  const url = `${target.base}/${suffix}${search}`;
  const isWrite = req.method !== 'GET' && req.method !== 'HEAD';

  // The one action that can take down live inference.
  if (req.method === 'POST' && suffix === 'instances/launch') {
    const verdict = await checkLaunchAllowed(await fetchUpdateStatus(target.base));
    if (!verdict.allowed) {
      return NextResponse.json(
        {
          detail: `Launch blocked on ${target.name}: ${verdict.reason}`,
          launch_blocked: true,
          agent_sha: verdict.sha,
        },
        { status: 409 }
      );
    }
  }

  let body: string | undefined;
  if (isWrite) {
    const raw = await req.text();
    body = raw.length ? raw : undefined;
  }

  try {
    const res = await fetch(url, {
      method: req.method,
      headers: body ? { 'Content-Type': req.headers.get('content-type') ?? 'application/json' } : undefined,
      body,
      cache: 'no-store',
      signal: AbortSignal.timeout(isWrite ? WRITE_TIMEOUT_MS : READ_TIMEOUT_MS),
    });
    // Pass the agent's status and body through untouched: the dashboard's error
    // handling reads agent detail strings, and a 409 duplicate-port or a 422
    // validation error must stay distinguishable from a proxy failure.
    const text = await res.text();
    return new NextResponse(text, {
      status: res.status,
      headers: { 'Content-Type': res.headers.get('content-type') ?? 'application/json' },
    });
  } catch (e) {
    const msg = e instanceof Error ? e.message : String(e);
    const timedOut = /abort|timeout/i.test(msg);
    return NextResponse.json(
      { detail: timedOut ? `${target.name} agent timed out` : `${target.name} agent unreachable: ${msg}` },
      { status: 504 }
    );
  }
}

export const GET = handle;
export const POST = handle;
export const PUT = handle;
export const PATCH = handle;
export const DELETE = handle;
