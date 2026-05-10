import { WebSocketServer, WebSocket } from "ws";
import { EventEmitter } from "node:events";
import { config } from "./config.js";
import { log } from "./logger.js";
import type { LuaPlain } from "./lua.js";

// ---------------------------------------------------------------------------
// Wire format CC ↔ gateway (JSON-over-WS).
//
// Inbound (gateway → agent):
//   { id: string, type: "call",  path: "turtle.forward", args: [LuaPlain...] }
//   { id: string, type: "eval",  source: "...", env: {...} }
//   { id: string, type: "subscribe", events: ["key","monitor_touch"] }
//   { id: string, type: "unsubscribe" }
//   { id: string, type: "queue_event", event: "...", args: [...] }
//
// Outbound (agent → gateway):
//   { id, type: "result", values: [LuaPlain...] }   // pcall returned ok=true
//   { id, type: "error",  error: "..." }            // pcall ok=false
//   { type: "event", event: "key", args: [...], ts: 0 }   // unsolicited
//   { type: "auth",  id, world_id, role, label, version, capabilities, token? }
//   { type: "heartbeat", metrics: {...} }
// ---------------------------------------------------------------------------

export interface InboundCallMsg {
  id: string;
  type: "call";
  path: string;
  args: LuaPlain[];
}
export interface InboundEvalMsg {
  id: string;
  type: "eval";
  source: string;
  env: Record<string, LuaPlain>;
}
export interface InboundSubscribeMsg {
  id: string;
  type: "subscribe";
  events: string[];
}
export interface InboundUnsubscribeMsg { id: string; type: "unsubscribe" }
export interface InboundQueueEventMsg {
  id: string;
  type: "queue_event";
  event: string;
  args: LuaPlain[];
}

export type InboundMsg =
  | InboundCallMsg | InboundEvalMsg
  | InboundSubscribeMsg | InboundUnsubscribeMsg | InboundQueueEventMsg;

export interface DeviceInfo {
  device_id: string;
  world_id: string;
  role: string;
  label: string;
  version: string;
  capabilities: string[];
  last_seen_ms: number;
  online: boolean;
}

interface PendingCall {
  resolve: (values: LuaPlain[]) => void;
  reject: (err: Error) => void;
  timer: NodeJS.Timeout;
}

export class Device {
  readonly info: DeviceInfo;
  readonly ws: WebSocket;
  readonly pending = new Map<string, PendingCall>();
  private seq = 0;

  constructor(ws: WebSocket, info: DeviceInfo) {
    this.ws = ws;
    this.info = info;
  }

  newId(): string {
    this.seq = (this.seq + 1) >>> 0;
    return `${Date.now().toString(36)}-${this.seq.toString(36)}`;
  }

  send(msg: InboundMsg): void {
    if (this.ws.readyState !== WebSocket.OPEN) {
      throw new Error("device socket not open");
    }
    this.ws.send(JSON.stringify(msg));
  }

  call(path: string, args: LuaPlain[], timeoutMs: number): Promise<LuaPlain[]> {
    const id = this.newId();
    return new Promise<LuaPlain[]>((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(id);
        reject(new Error(`agent ${this.info.device_id} call '${path}' timed out after ${timeoutMs}ms`));
      }, timeoutMs);
      this.pending.set(id, { resolve, reject, timer });
      try {
        this.send({ id, type: "call", path, args });
      } catch (e) {
        this.pending.delete(id);
        clearTimeout(timer);
        reject(e as Error);
      }
    });
  }

  fail(err: Error): void {
    for (const p of this.pending.values()) {
      clearTimeout(p.timer);
      p.reject(err);
    }
    this.pending.clear();
  }
}

interface DeviceKey { world_id: string; device_id: string }
const keyOf = (k: DeviceKey) => `${k.world_id}::${k.device_id}`;

export class Bridge extends EventEmitter {
  private devices = new Map<string, Device>();
  private wss?: WebSocketServer;

  start(): void {
    this.wss = new WebSocketServer({ host: config.wsHost, port: config.wsPort });
    this.wss.on("connection", (ws) => this.handleConn(ws));
    log.info({ host: config.wsHost, port: config.wsPort }, "agent WS listening");
  }

  list(world_id?: string): DeviceInfo[] {
    const out: DeviceInfo[] = [];
    for (const d of this.devices.values()) {
      if (!world_id || d.info.world_id === world_id) out.push({ ...d.info });
    }
    return out;
  }

  get(target: { device_id: string; world_id?: string }): Device | undefined {
    const wid = target.world_id?.trim() || "default";
    return this.devices.get(keyOf({ world_id: wid, device_id: target.device_id }));
  }

  require(target: { device_id: string; world_id?: string }): Device {
    const d = this.get(target);
    if (!d) throw new Error(`no agent attached for device '${target.device_id}'`);
    return d;
  }

  private handleConn(ws: WebSocket): void {
    let device: Device | null = null;

    const authTimer = setTimeout(() => {
      if (!device) {
        try { ws.close(4001, "auth timeout"); } catch { /* noop */ }
      }
    }, 10_000);

    ws.on("message", (raw) => {
      let msg: any;
      try { msg = JSON.parse(raw.toString("utf8")); } catch {
        log.warn("agent sent malformed JSON; closing");
        ws.close(4002, "bad json");
        return;
      }

      if (!device) {
        if (msg?.type !== "auth") { ws.close(4003, "auth required"); return; }
        if (config.agentToken && msg.token !== config.agentToken) {
          ws.close(4004, "unauthorized"); return;
        }
        const info: DeviceInfo = {
          device_id: String(msg.id ?? ""),
          world_id: String(msg.world_id ?? "default") || "default",
          role: String(msg.role ?? "computer"),
          label: String(msg.label ?? ""),
          version: String(msg.version ?? ""),
          capabilities: Array.isArray(msg.capabilities) ? msg.capabilities.map(String) : [],
          last_seen_ms: Date.now(),
          online: true,
        };
        if (!info.device_id) { ws.close(4005, "id required"); return; }
        device = new Device(ws, info);
        this.devices.set(keyOf(info), device);
        clearTimeout(authTimer);
        ws.send(JSON.stringify({ type: "ready" }));
        this.emit("attached", { ...device.info });
        log.info({ device: info.device_id, world: info.world_id, role: info.role }, "agent attached");
        return;
      }

      device.info.last_seen_ms = Date.now();

      switch (msg.type) {
        case "result": {
          const p = device.pending.get(msg.id);
          if (!p) return;
          device.pending.delete(msg.id);
          clearTimeout(p.timer);
          p.resolve(Array.isArray(msg.values) ? msg.values : []);
          return;
        }
        case "error": {
          const p = device.pending.get(msg.id);
          if (!p) return;
          device.pending.delete(msg.id);
          clearTimeout(p.timer);
          p.reject(new Error(String(msg.error ?? "agent error")));
          return;
        }
        case "event": {
          this.emit("event", {
            device_id: device.info.device_id,
            world_id: device.info.world_id,
            ts_ms: Number(msg.ts ?? Date.now()),
            event: String(msg.event ?? ""),
            args: Array.isArray(msg.args) ? msg.args : [],
          });
          return;
        }
        case "heartbeat": {
          this.emit("updated", { ...device.info });
          return;
        }
        default:
          log.debug({ type: msg.type }, "agent sent unknown message");
      }
    });

    const onClose = () => {
      clearTimeout(authTimer);
      if (device) {
        device.info.online = false;
        device.fail(new Error("agent disconnected"));
        this.devices.delete(keyOf(device.info));
        this.emit("detached", { ...device.info });
        log.info({ device: device.info.device_id }, "agent detached");
      }
    };
    ws.on("close", onClose);
    ws.on("error", (e) => log.warn({ err: e.message }, "agent ws error"));
  }
}

export const bridge = new Bridge();
