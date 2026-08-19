"use client";

import { useState, useEffect, useCallback } from "react";
import type { NodeConfig } from "@/lib/types";
import { createNodeApi } from "@/lib/api";

const POLL_MS = 60_000;

export interface AvgGpuUtil {
  /** Fleet-wide average GPU utilization over the trailing 24h, as a percent
   *  (mean of the hourly per-GPU averages across every node/GPU). null until
   *  there is at least one sample. */
  avgPct: number | null;
  /** Number of (node, GPU) series that contributed. */
  gpuCount: number;
  /** Number of hourly buckets averaged (across all GPUs). */
  sampleCount: number;
  loading: boolean;
}

/**
 * Average GPU utilization over the last 24 hours (feedback: a headline stat for
 * both the GPU view and the Analytics tab). Reads the same bucketed metrics the
 * Analytics charts use — `metrics("24h", "1h")` per node — and averages every
 * non-null `util_pct_avg`. It ALWAYS reports 24h, independent of the Analytics
 * range picker, so the number means the same thing wherever it is shown.
 */
export function useAvgGpuUtil24h(nodes: NodeConfig[]): AvgGpuUtil {
  const [state, setState] = useState<AvgGpuUtil>({
    avgPct: null, gpuCount: 0, sampleCount: 0, loading: true,
  });

  // Depend on the set of node IPs rather than the array identity, so a new
  // status poll that rebuilds an equivalent nodes array doesn't refetch.
  const nodeKey = nodes.map(n => n.ip).sort().join(",");

  const fetchAvg = useCallback(async () => {
    if (nodes.length === 0) {
      setState({ avgPct: null, gpuCount: 0, sampleCount: 0, loading: false });
      return;
    }
    let sum = 0;
    let sampleCount = 0;
    const gpuSeries = new Set<string>();
    await Promise.all(
      nodes.map(async (node) => {
        try {
          const data = await createNodeApi(node).metrics("24h", "1h");
          for (const g of data.gpus) {
            if ("_error" in (g as object)) continue;
            if (g.util_pct_avg == null) continue;
            sum += g.util_pct_avg;
            sampleCount += 1;
            gpuSeries.add(`${node.name}:${g.gpu_idx}`);
          }
        } catch {
          // A node that is down or has no samples just doesn't contribute.
        }
      })
    );
    setState({
      avgPct: sampleCount > 0 ? sum / sampleCount : null,
      gpuCount: gpuSeries.size,
      sampleCount,
      loading: false,
    });
  }, [nodeKey]); // eslint-disable-line react-hooks/exhaustive-deps

  useEffect(() => {
    fetchAvg();
    const id = setInterval(fetchAvg, POLL_MS);
    return () => clearInterval(id);
  }, [fetchAvg]);

  return state;
}
