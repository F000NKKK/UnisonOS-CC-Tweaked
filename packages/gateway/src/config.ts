import fs from "node:fs";

const num = (k: string, d: number) => {
  const v = process.env[k];
  if (!v) return d;
  const n = parseInt(v, 10);
  return Number.isFinite(n) ? n : d;
};

export const config = {
  grpcAddr: process.env.UNISON_GRPC_ADDR ?? "0.0.0.0:9290",
  wsHost:   process.env.UNISON_WS_HOST   ?? "0.0.0.0",
  wsPort:   num("UNISON_WS_PORT", 9275),

  // Bearer token shared between agent ↔ gateway. Left null = unauthenticated
  // (only acceptable for dev). For prod set UNISON_AGENT_TOKEN_FILE or env.
  agentToken: (() => {
    if (process.env.UNISON_AGENT_TOKEN) return process.env.UNISON_AGENT_TOKEN;
    const f = process.env.UNISON_AGENT_TOKEN_FILE;
    if (!f) return null;
    try { return fs.readFileSync(f, "utf8").trim() || null; } catch { return null; }
  })(),

  // Default per-RPC timeout if DeviceTarget.timeout_ms == 0.
  defaultRpcTimeoutMs: num("UNISON_RPC_TIMEOUT_MS", 10_000),
};

export type Config = typeof config;
