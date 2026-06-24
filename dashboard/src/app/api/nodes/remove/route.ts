import { NextResponse } from "next/server";
import { readFileSync, writeFileSync, renameSync } from "fs";
import { join } from "path";

// Write JSON atomically: tmp file in the same directory, then rename. Prevents
// a crashed/interrupted handler from leaving node_config.json half-written.
function writeJsonAtomic(path: string, data: unknown): void {
  const tmp = `${path}.tmp`;
  writeFileSync(tmp, JSON.stringify(data, null, 2));
  renameSync(tmp, path);
}

export const dynamic = "force-dynamic";

interface NodeEntry {
  name: string;
  ip: string;
  agent_port: number;
  setup_cmd?: string;
}

interface RemoveBody {
  ip: string;
  agent_port: number;
}

// Remove flow — same topology as /api/nodes/rename and /api/nodes/edit:
//   * master/both dashboards own the canonical nodes[] list → write locally.
//   * child dashboards have an empty local nodes[]; proxy the DELETE to master's
//     agent so the master config is the one that changes.
export async function POST(req: Request) {
  try {
    const body: RemoveBody = await req.json();
    const { ip, agent_port } = body;

    if (!ip || !agent_port) {
      return NextResponse.json({ error: "ip and agent_port are required" }, { status: 400 });
    }

    const configPath = join(process.cwd(), "..", "node_config.json");
    let config: Record<string, unknown> = {};
    try {
      config = JSON.parse(readFileSync(configPath, "utf-8"));
    } catch {
      return NextResponse.json({ error: "node_config.json not readable" }, { status: 500 });
    }

    const role = config.role as string | undefined;
    const thisIp = (config.this_ip as string | undefined) ?? "";
    const selfPort = (config.agent_port as number | undefined) ?? 5000;

    // Refuse to remove the host this dashboard is running on — the dashboard
    // reads its own node_config.json, so dropping self from itself would leave
    // the box orphaned. The agent's synthetic master "self" entry surfaces
    // with `self: true` to keep the UI from offering this in the first place;
    // this is a server-side belt-and-braces check.
    if (role !== "child" && ip === thisIp && agent_port === selfPort) {
      return NextResponse.json(
        { error: "Cannot remove this node from itself. Edit role/config on the host directly." },
        { status: 400 },
      );
    }

    const localNodes: NodeEntry[] = (config.nodes as NodeEntry[]) ?? [];
    const localMatch = localNodes.find(n => n.ip === ip && n.agent_port === agent_port);

    if (role !== "child" && localMatch) {
      const kept = localNodes.filter(n => !(n.ip === ip && n.agent_port === agent_port));
      config.nodes = kept;
      writeJsonAtomic(configPath, config);
      return NextResponse.json({ removed: ip, remaining: kept.length });
    }

    // Child dashboard, or master doesn't have this node: forward to master's agent.
    const masterIp = (config.master as { ip?: string } | undefined)?.ip;
    const masterAgentPort = (config.master as { agent_port?: number } | undefined)?.agent_port ?? 5000;
    if (!masterIp) {
      return NextResponse.json({ error: "No master IP configured — cannot proxy remove" }, { status: 500 });
    }

    let res: Response;
    try {
      res = await fetch(
        `http://${masterIp}:${masterAgentPort}/nodes/${encodeURIComponent(ip)}?agent_port=${agent_port}`,
        {
          method: "DELETE",
          signal: AbortSignal.timeout(8000),
        },
      );
    } catch (e) {
      return NextResponse.json(
        { error: `Could not reach master agent at ${masterIp}:${masterAgentPort} — ${String(e)}` },
        { status: 504 },
      );
    }
    if (!res.ok) {
      const detail = await res.text();
      return NextResponse.json({ error: detail || `master agent → ${res.status}` }, { status: res.status });
    }
    return NextResponse.json(await res.json());
  } catch (e) {
    return NextResponse.json({ error: String(e) }, { status: 500 });
  }
}
