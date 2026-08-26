import { NextResponse } from 'next/server';
import { checkLaunchAllowed, readRoster, type AgentUpdateStatus } from '@/lib/launchGuard';

export const runtime = 'nodejs';
export const dynamic = 'force-dynamic';

/**
 * Per-node launch safety, for display.
 *
 * Feedback #242. The proxy route refuses a launch on a node whose agent predates
 * the VRAM-reclaim fix, but a refusal arriving only after the operator clicks
 * Launch is a bad way to learn it — and an unexplained 409 reads as a broken
 * button (the lesson already recorded against #256). This reports the same
 * verdict up front, so the UI can badge a node as launch-blocked and say why
 * before anyone tries.
 *
 * It is also how the guard gets tested without POSTing a real launch at a
 * production cluster: same code path, same live /update/status data, no writes.
 */
export async function GET() {
  const nodes = await Promise.all(
    readRoster()
      // localhost duplicates the master, and the master is CPU-only anyway.
      .filter((n) => n.ip !== 'localhost')
      .map(async (n) => {
        let status: AgentUpdateStatus | null = null;
        try {
          const res = await fetch(`http://${n.ip}:${n.agent_port}/update/status`, {
            cache: 'no-store',
            signal: AbortSignal.timeout(6000),
          });
          if (res.ok) status = (await res.json()) as AgentUpdateStatus;
        } catch {
          status = null;
        }
        const verdict = await checkLaunchAllowed(status);
        return {
          name: n.name,
          ip: n.ip,
          launchAllowed: verdict.allowed,
          reason: verdict.reason,
          agentSha: verdict.sha,
          branch: status?.branch ?? null,
          behind: status?.behind ?? null,
          dirty: verdict.dirty,
        };
      })
  );
  return NextResponse.json({ checkedAt: new Date().toISOString(), nodes });
}
