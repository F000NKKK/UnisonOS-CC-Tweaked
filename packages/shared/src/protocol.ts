import { z } from "zod";

export const RegisterReq = z.object({
  id: z.union([z.string(), z.number()]).optional(),
  device_id: z.union([z.string(), z.number()]).optional(),
  role: z.string().optional(),
  name: z.string().optional(),
  version: z.string().optional(),
  registered_at: z.number().optional(),
});

export const HeartbeatReq = z.object({
  id: z.union([z.string(), z.number()]).optional(),
  device_id: z.union([z.string(), z.number()]).optional(),
  metrics: z.record(z.unknown()).optional(),
  version: z.string().optional(),
});

export const MessageBody = z.record(z.unknown());

export const Envelope = z.object({
  id: z.string(),
  ts: z.number(),
  to: z.string(),
  world_id: z.string(),
  msg: z.record(z.unknown()),
});
export type Envelope = z.infer<typeof Envelope>;

export const Device = z.object({
  id: z.string(),
  role: z.string().optional(),
  name: z.string().optional(),
  version: z.string().optional(),
  world_id: z.string(),
  last_seen: z.number(),
  transport: z.string().optional(),
  metrics: z.record(z.unknown()).optional(),
  registered_at: z.number().optional(),
});
export type Device = z.infer<typeof Device>;

export const AtlasBlock = z.object({
  x: z.number().int(),
  y: z.number().int(),
  z: z.number().int(),
  name: z.string(),
  by: z.string().nullable().optional(),
  ts: z.number().optional(),
});
export type AtlasBlock = z.infer<typeof AtlasBlock>;

export const AtlasBlocksReq = z.object({
  blocks: z.array(AtlasBlock).default([]),
  by: z.string().optional(),
});

export const Landmark = z.object({
  name: z.string(),
  x: z.number().int(),
  y: z.number().int(),
  z: z.number().int(),
  tags: z.array(z.string()).optional(),
  by: z.string().optional(),
  ts: z.number().optional(),
});
export type Landmark = z.infer<typeof Landmark>;

export const LandmarkReq = z.object({
  name: z.string(),
  x: z.number().int(),
  y: z.number().int(),
  z: z.number().int(),
  tags: z.array(z.string()).optional(),
  by: z.string().optional(),
});

export const StorageReplaceReq = z.object({
  by: z.string().optional(),
  device: z.string().optional(),
  items: z.array(z.object({ name: z.string(), count: z.number().int() })).default([]),
});

export const AtlasEvent = z.record(z.unknown());
export const AtlasEventsReq = z.object({
  events: z.array(AtlasEvent).default([]),
  by: z.string().optional(),
});

// WS handshake / messages
export const WsAuth = z.object({
  type: z.literal("auth"),
  id: z.union([z.string(), z.number()]),
  token: z.string().optional(),
  role: z.string().optional(),
  name: z.string().optional(),
  version: z.string().optional(),
  world_id: z.string().optional(),
});

export const WsClientMsg = z.discriminatedUnion("type", [
  z.object({ type: z.literal("ping") }),
  z.object({ type: z.literal("heartbeat"), metrics: z.record(z.unknown()).optional() }),
  z.object({
    type: z.literal("send"),
    to: z.union([z.string(), z.number()]),
    msg: z.record(z.unknown()),
  }),
]);

// Stable envelope id (UUID v4 — uses crypto.randomUUID at runtime).
export function makeEnvelopeId(): string {
  // globalThis.crypto.randomUUID is available in Node 20+
  return globalThis.crypto.randomUUID();
}

export function nowMs(): number {
  return Date.now();
}
