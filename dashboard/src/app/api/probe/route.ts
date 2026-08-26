import { NextRequest, NextResponse } from 'next/server';

export const runtime = 'nodejs';
export const dynamic = 'force-dynamic';

/**
 * Same-origin reachability probe for a node that is not in the roster yet.
 *
 * Feedback #242 support. Add Node and Edit Node let you test an agent before
 * saving it, which they did with a direct browser `fetch(http://<ip>:<port>/health)`.
 * Behind HTTPS that mixed-content-blocks, so the two flows would look broken in
 * the proxied dashboard. They cannot use /api/agent/<ip> either: that route
 * allow-lists against node_config.json, and the whole point here is an IP that
 * is not in it yet.
 *
 * **Kept narrow on purpose.** This is a server-side fetch on a host that sits on
 * both the corporate and AI VLANs, so an unrestricted version would be a useful
 * SSRF primitive. It therefore only ever hits /health, only on the AI VLAN's
 * /24, only on plausible agent ports, and returns nothing but reachability.
 */

/** The AI VLAN. Cluster nodes live here and nothing else needs probing. */
const ALLOWED_SUBNET = /^10\.2\.35\.(\d{1,3})$/;

export async function GET(req: NextRequest) {
  const ip = (req.nextUrl.searchParams.get('ip') ?? '').trim();
  const port = Number(req.nextUrl.searchParams.get('port') ?? 5000);

  const m = ALLOWED_SUBNET.exec(ip);
  const lastOctet = m ? Number(m[1]) : NaN;
  if (!m || lastOctet > 255) {
    return NextResponse.json(
      { reachable: false, detail: 'Only AI VLAN addresses (10.2.35.x) can be probed.' },
      { status: 400 }
    );
  }
  if (!Number.isInteger(port) || port < 1024 || port > 65535) {
    return NextResponse.json(
      { reachable: false, detail: 'Port must be between 1024 and 65535.' },
      { status: 400 }
    );
  }

  try {
    const res = await fetch(`http://${ip}:${port}/health`, {
      cache: 'no-store',
      signal: AbortSignal.timeout(5000),
    });
    if (!res.ok) {
      return NextResponse.json({ reachable: false, detail: `agent returned HTTP ${res.status}` });
    }
    // Pass the agent's own health payload through — Add Node shows the hostname
    // and role it reports so you can confirm you reached the box you meant.
    return NextResponse.json({ reachable: true, health: await res.json() });
  } catch (e) {
    const msg = e instanceof Error ? e.message : String(e);
    return NextResponse.json({
      reachable: false,
      detail: /abort|timeout/i.test(msg) ? 'timed out' : msg.slice(0, 160),
    });
  }
}
