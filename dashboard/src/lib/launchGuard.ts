import 'server-only';
import { execFile } from 'child_process';
import { readFileSync } from 'fs';
import { join } from 'path';
import { promisify } from 'util';

const exec = promisify(execFile);

/**
 * Refuse a model launch on a node whose agent still has the VRAM-reclaim kill bug.
 *
 * Feedback #242/#212 (Andrew): the dashboard's second tab lets him load models
 * onto the cluster from the Foundation dashboard. That makes a latent hazard
 * reachable by a button.
 *
 * **The bug.** Before `5716ba1`'s fix, `_reclaim_vram_before_launch` SIGKILLs
 * the resident model's EngineCore children — tracked-PID protection only covered
 * the APIServer parent. So launching anything on a node with a live model on the
 * same GPU kills that model, and the restart watchdog turns it into a mutual
 * kill loop. Fixed twice, once per branch, because the repo is split-brained:
 * `682e953` on main and `7082f9a` on dev.
 *
 * **Why the check is ancestry rather than a version string.** The agent exposes
 * no version or capability flag, and adding one would need new agent code
 * deployed to the very nodes this is protecting — including the Nano, which has
 * no working remote update path. What every agent DOES report, at
 * `/update/status`, is `local_sha`, `branch`, `remote_sha` and `behind`. The
 * provable claim from those: the node contains everything up to
 * `remote_sha~behind`. If a fix commit is an ancestor of that point, the node
 * has it. Anything we cannot prove is treated as unsafe.
 *
 * **Why `remote_sha` and not a local branch.** Checked 2026-08-26: local `dev`
 * (`9963401`) has DIVERGED from `origin/dev` (`7082f9a`), so resolving against
 * the local branch would have reported Death Star 2 as unfixed when it is fine.
 * The node's own reported `remote_sha` is the honest base — it is what that node
 * actually pulls from.
 *
 * State as of 2026-08-26: Nano 1 `.30` BLOCKED (`5716ba1`, 40 behind — the very
 * commit that introduced the reclaim path, and it is serving live gemma on its
 * single GPU); Death Star 2 `.21` and DGX Spark 1 `.31` allowed.
 */

/** The reclaim fix, once per branch — the repo is split-brained. */
const FIX_COMMITS = ['682e953', '7082f9a'];

/** Agent /update/status, as much of it as this check needs. */
export interface AgentUpdateStatus {
  local_sha?: string;
  remote_sha?: string;
  branch?: string;
  behind?: number;
  dirty?: boolean;
}

export interface LaunchVerdict {
  allowed: boolean;
  /** One line, shown to the operator. Always populated. */
  reason: string;
  sha: string | null;
  dirty: boolean;
}

/** The cluster repo checkout this dashboard is served from. */
function repoRoot(): string {
  return join(process.cwd(), '..');
}

async function isAncestor(commit: string, of: string): Promise<boolean> {
  try {
    await exec('git', ['merge-base', '--is-ancestor', commit, of], {
      cwd: repoRoot(),
      timeout: 5000,
    });
    return true;
  } catch {
    // Non-zero exit means "not an ancestor"; a missing object or a git failure
    // also lands here. Both are "cannot prove", which is a block.
    return false;
  }
}

/**
 * Does this agent provably carry the reclaim fix?
 *
 * Fails closed on every uncertainty: no status, no remote_sha, git unavailable,
 * an unknown commit. A false "unfixed" costs a blocked launch and a visible
 * reason; a false "fixed" costs production gemma.
 */
export async function checkLaunchAllowed(
  status: AgentUpdateStatus | null
): Promise<LaunchVerdict> {
  const sha = status?.local_sha ? status.local_sha.slice(0, 12) : null;
  const dirty = status?.dirty === true;

  if (!status) {
    return {
      allowed: false,
      reason:
        'Cannot read this node\'s agent version (/update/status did not answer), ' +
        'so the VRAM-reclaim kill bug cannot be ruled out.',
      sha,
      dirty,
    };
  }

  const remote = status.remote_sha;
  const behind = Number.isFinite(status.behind) ? Number(status.behind) : null;
  if (!remote || behind === null || behind < 0) {
    return {
      allowed: false,
      reason:
        'This node\'s agent did not report a comparable version ' +
        '(remote_sha/behind missing), so the reclaim fix cannot be proven.',
      sha,
      dirty,
    };
  }

  // What the node provably contains: everything up to remote_sha~behind. Its
  // "ahead" commits are local and unknowable from here, so they are ignored
  // rather than credited.
  const base = behind > 0 ? `${remote}~${behind}` : remote;

  for (const fix of FIX_COMMITS) {
    if (await isAncestor(fix, base)) {
      return {
        allowed: true,
        reason: dirty
          ? `Agent carries the reclaim fix (${fix} is in ${base}), but its tree is ` +
            'dirty — local edits are not visible from here.'
          : `Agent carries the reclaim fix (${fix} is in ${base}).`,
        sha,
        dirty,
      };
    }
  }

  return {
    allowed: false,
    reason:
      `This node's agent (${sha ?? 'unknown'}${
        behind ? `, ${behind} commits behind ${status.branch ?? 'its branch'}` : ''
      }) predates the VRAM-reclaim fix. Launching here would SIGKILL the ` +
      'EngineCore of any model already resident on the target GPU. Update the ' +
      'agent first, then launch.',
    sha,
    dirty,
  };
}

/** The node roster this proxy is allowed to reach. Also the SSRF allow-list. */
export interface RosterNode {
  name: string;
  ip: string;
  agent_port: number;
}

export function readRoster(): RosterNode[] {
  const config = JSON.parse(
    readFileSync(join(repoRoot(), 'node_config.json'), 'utf-8')
  );
  const out: RosterNode[] = (config.nodes ?? []).map(
    (n: { name?: string; ip?: string; agent_port?: number }) => ({
      name: String(n.name ?? n.ip ?? ''),
      ip: String(n.ip ?? ''),
      agent_port: Number(n.agent_port ?? config.agent_port ?? 5000),
    })
  );
  // The master's own agent is a legitimate target (proxy status, node roster)
  // and is not always in the nodes array.
  const masterIp = config.master?.ip ?? config.this_ip;
  if (masterIp && !out.some((n) => n.ip === masterIp)) {
    out.push({
      name: 'Master',
      ip: String(masterIp),
      agent_port: Number(config.master?.agent_port ?? config.agent_port ?? 5000),
    });
  }
  // localhost is how the master dashboard addresses its own agent.
  if (!out.some((n) => n.ip === 'localhost')) {
    out.push({
      name: 'Local',
      ip: 'localhost',
      agent_port: Number(config.agent_port ?? 5000),
    });
  }
  return out.filter((n) => n.ip);
}
