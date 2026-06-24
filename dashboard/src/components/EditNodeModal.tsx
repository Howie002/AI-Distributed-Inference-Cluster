"use client";

import { useState } from "react";
import type { NodeConfig } from "@/lib/types";
import { editNode, removeNode } from "@/lib/api";

interface Props {
  node: NodeConfig;
  onClose: () => void;
  onSaved: () => void;
}

export function EditNodeModal({ node, onClose, onSaved }: Props) {
  const [name, setName]           = useState(node.name);
  const [ip, setIp]               = useState(node.ip);
  const [agentPort, setAgentPort] = useState(node.agent_port);
  const [saving, setSaving]       = useState(false);
  const [removing, setRemoving]   = useState(false);
  const [confirmRemove, setConfirmRemove] = useState(false);
  const [testing, setTesting]     = useState(false);
  const [testResult, setTestResult] = useState<"ok" | "fail" | null>(null);
  const [error, setError]         = useState<string | null>(null);

  const dirty =
    name.trim() !== node.name ||
    ip.trim()   !== node.ip   ||
    agentPort   !== node.agent_port;

  // The master is exposed via /nodes with `self: true`. Removing it from its
  // own config would orphan the host, so block the action at the UI level.
  const isSelf = node.self === true;

  async function handleRemove() {
    setRemoving(true);
    setError(null);
    try {
      await removeNode(node.ip, node.agent_port);
      onSaved();
      onClose();
    } catch (e) {
      setError(String(e));
    } finally {
      setRemoving(false);
    }
  }

  async function testConnection() {
    setTesting(true);
    setTestResult(null);
    try {
      const res = await fetch(`http://${ip.trim()}:${agentPort}/health`, {
        signal: AbortSignal.timeout(4000),
      });
      setTestResult(res.ok ? "ok" : "fail");
    } catch {
      setTestResult("fail");
    } finally {
      setTesting(false);
    }
  }

  async function handleSave(e: React.FormEvent) {
    e.preventDefault();
    if (!name.trim() || !ip.trim()) {
      setError("Name and IP are required.");
      return;
    }
    if (!dirty) { onClose(); return; }
    setSaving(true);
    setError(null);
    try {
      await editNode({
        ip: node.ip,
        agent_port: node.agent_port,
        name: name.trim(),
        new_ip: ip.trim(),
        new_agent_port: agentPort,
      });
      onSaved();
      onClose();
    } catch (e) {
      setError(String(e));
    } finally {
      setSaving(false);
    }
  }

  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/60 backdrop-blur-sm">
      <div className="bg-card border border-border rounded-2xl w-full max-w-md mx-4 shadow-2xl">

        <div className="px-6 py-4 border-b border-border flex items-center justify-between">
          <h2 className="text-white font-semibold">Edit node</h2>
          <button onClick={onClose} className="text-slate-500 hover:text-white text-lg leading-none">✕</button>
        </div>

        <form onSubmit={handleSave} className="px-6 py-5 space-y-4">
          <p className="text-xs text-slate-400 leading-relaxed">
            Updates the master&apos;s registered address for this node. Use this when a
            node is renumbered or moved to a different agent port. The OS-level
            IP on the box itself must already be set to the new value.
          </p>

          <div>
            <label className="text-xs text-slate-400 font-medium uppercase tracking-wider mb-1 block">Node name</label>
            <input
              type="text"
              value={name}
              onChange={e => setName(e.target.value)}
              className="w-full bg-slate-800 border border-border rounded-lg px-3 py-2 text-sm text-white focus:outline-none focus:border-blue-500"
            />
          </div>

          <div className="grid grid-cols-3 gap-3">
            <div className="col-span-2">
              <label className="text-xs text-slate-400 font-medium uppercase tracking-wider mb-1 block">IP address</label>
              <input
                type="text"
                value={ip}
                onChange={e => { setIp(e.target.value); setTestResult(null); }}
                className="w-full bg-slate-800 border border-border rounded-lg px-3 py-2 text-sm text-white font-mono focus:outline-none focus:border-blue-500"
              />
            </div>
            <div>
              <label className="text-xs text-slate-400 font-medium uppercase tracking-wider mb-1 block">Agent port</label>
              <input
                type="number"
                value={agentPort}
                onChange={e => { setAgentPort(Number(e.target.value)); setTestResult(null); }}
                className="w-full bg-slate-800 border border-border rounded-lg px-3 py-2 text-sm text-white font-mono focus:outline-none focus:border-blue-500"
              />
            </div>
          </div>

          {(ip.trim() !== node.ip || agentPort !== node.agent_port) && (
            <div className="flex items-center gap-3">
              <button
                type="button"
                onClick={testConnection}
                disabled={testing || !ip.trim()}
                className="text-xs px-3 py-1.5 rounded border border-border text-slate-400 hover:text-white hover:border-slate-500 disabled:opacity-50 transition-colors"
              >
                {testing ? "Testing…" : "Test connection"}
              </button>
              {testResult === "ok"   && <span className="text-xs text-emerald-400">Agent online at the new address.</span>}
              {testResult === "fail" && <span className="text-xs text-amber-400">Not reachable at {ip}:{agentPort}.</span>}
            </div>
          )}

          {error && (
            <p className="text-xs text-red-400 bg-red-900/20 border border-red-800 rounded-lg px-3 py-2">{error}</p>
          )}

          <div className="flex items-center justify-between pt-1">
            <div>
              {!isSelf && !confirmRemove && (
                <button
                  type="button"
                  onClick={() => setConfirmRemove(true)}
                  className="px-3 py-2 text-xs rounded-lg border border-red-900 text-red-300 hover:text-white hover:bg-red-900/40 transition-colors"
                >
                  Remove from cluster…
                </button>
              )}
              {!isSelf && confirmRemove && (
                <div className="flex items-center gap-2">
                  <span className="text-xs text-red-300">Remove {node.name}?</span>
                  <button
                    type="button"
                    onClick={handleRemove}
                    disabled={removing}
                    className="px-3 py-1.5 text-xs rounded-lg bg-red-700 hover:bg-red-600 text-white disabled:opacity-50 transition-colors"
                  >
                    {removing ? "Removing…" : "Yes, remove"}
                  </button>
                  <button
                    type="button"
                    onClick={() => setConfirmRemove(false)}
                    disabled={removing}
                    className="text-xs text-slate-400 hover:text-white"
                  >
                    Cancel
                  </button>
                </div>
              )}
            </div>
            <div className="flex gap-3">
              <button type="button" onClick={onClose} className="px-4 py-2 text-sm text-slate-300 hover:text-white transition-colors">
                Close
              </button>
              <button
                type="submit"
                disabled={saving || !dirty}
                className="px-4 py-2 text-sm rounded-lg bg-blue-600 hover:bg-blue-500 text-white disabled:opacity-50 transition-colors"
              >
                {saving ? "Saving…" : "Save changes"}
              </button>
            </div>
          </div>
        </form>
      </div>
    </div>
  );
}
