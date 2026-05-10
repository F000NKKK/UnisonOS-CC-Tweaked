import * as grpc from "@grpc/grpc-js";
import { v1 } from "./proto.js";
import { bridge, type DeviceInfo } from "./bridge.js";
import { config } from "./config.js";
import { log } from "./logger.js";
import { plainToLuaValue, luaValueToPlain, luaOk, luaErr, luaTuple, type LuaPlain } from "./lua.js";

// --- helpers ---------------------------------------------------------------

function targetFrom(call: grpc.ServerUnaryCall<any, any>) {
  const t = call.request?.target ?? call.request;
  return {
    device_id: String(t?.device_id ?? ""),
    world_id: String(t?.world_id ?? "default") || "default",
    timeout_ms: Number(t?.timeout_ms ?? 0) || config.defaultRpcTimeoutMs,
  };
}

async function route(
  call: grpc.ServerUnaryCall<any, any>,
  path: string,
  args: LuaPlain[],
): Promise<LuaPlain[]> {
  const t = targetFrom(call);
  const dev = bridge.require(t);
  return dev.call(path, args, t.timeout_ms);
}

// LuaResult с автоматической обработкой [false, "reason"]-конвенции CC.
async function singleResult(
  call: grpc.ServerUnaryCall<any, any>,
  path: string,
  args: LuaPlain[],
  cb: grpc.sendUnaryData<any>,
) {
  try {
    const values = await route(call, path, args);
    if (values.length >= 2 && values[0] === false) {
      cb(null, luaErr(String(values[1] ?? "operation failed")));
      return;
    }
    cb(null, luaOk(values[0] ?? null));
  } catch (e) {
    cb(null, luaErr((e as Error).message));
  }
}

async function tupleResult(
  call: grpc.ServerUnaryCall<any, any>,
  path: string,
  args: LuaPlain[],
  cb: grpc.sendUnaryData<any>,
) {
  try {
    const values = await route(call, path, args);
    cb(null, luaTuple(values));
  } catch (e) {
    cb(null, luaTuple([], (e as Error).message));
  }
}

const u = (n: any): LuaPlain => luaValueToPlain(n);

// --- Devices ---------------------------------------------------------------

const devicesImpl = {
  List: (call: grpc.ServerUnaryCall<any, any>, cb: grpc.sendUnaryData<any>) => {
    const wid = String(call.request?.world_id ?? "");
    cb(null, { devices: bridge.list(wid || undefined) });
  },
  Get: (call: grpc.ServerUnaryCall<any, any>, cb: grpc.sendUnaryData<any>) => {
    const t = targetFrom(call);
    const d = bridge.get(t);
    if (!d) return cb({ code: grpc.status.NOT_FOUND, message: "device not attached" } as any);
    cb(null, d.info);
  },
  Watch: (call: grpc.ServerWritableStream<any, any>) => {
    const wid = String(call.request?.world_id ?? "");
    for (const dev of bridge.list(wid || undefined)) {
      call.write({ kind: "ATTACHED", device: dev });
    }
    const onAttached = (d: DeviceInfo) => { if (!wid || d.world_id === wid) call.write({ kind: "ATTACHED", device: d }); };
    const onDetached = (d: DeviceInfo) => { if (!wid || d.world_id === wid) call.write({ kind: "DETACHED", device: d }); };
    const onUpdated  = (d: DeviceInfo) => { if (!wid || d.world_id === wid) call.write({ kind: "UPDATED",  device: d }); };
    bridge.on("attached", onAttached);
    bridge.on("detached", onDetached);
    bridge.on("updated",  onUpdated);
    call.on("cancelled", () => {
      bridge.off("attached", onAttached);
      bridge.off("detached", onDetached);
      bridge.off("updated",  onUpdated);
    });
  },
};

// --- LuaBridge -------------------------------------------------------------

const luaBridgeImpl = {
  Call: async (call: grpc.ServerUnaryCall<any, any>, cb: grpc.sendUnaryData<any>) => {
    const path = String(call.request?.path ?? "");
    const args = (call.request?.args ?? []).map(u);
    return tupleResult(call, path, args, cb);
  },
  Eval: async (call: grpc.ServerUnaryCall<any, any>, cb: grpc.sendUnaryData<any>) => {
    try {
      const t = targetFrom(call);
      const dev = bridge.require(t);
      const id = dev.newId();
      const env: Record<string, LuaPlain> = {};
      for (const [k, v] of Object.entries(call.request?.env ?? {})) env[k] = u(v);
      const values = await new Promise<LuaPlain[]>((resolve, reject) => {
        const timer = setTimeout(() => reject(new Error("eval timed out")), t.timeout_ms);
        dev.pending.set(id, {
          resolve: (v) => { clearTimeout(timer); resolve(v); },
          reject:  (e) => { clearTimeout(timer); reject(e); },
          timer,
        });
        dev.send({ id, type: "eval", source: String(call.request?.source ?? ""), env });
      });
      cb(null, luaTuple(values));
    } catch (e) {
      cb(null, luaTuple([], (e as Error).message));
    }
  },
};

// --- Typed CC services ------------------------------------------------------
// Каждый handler — это `path` + сборка args. Большинство одноcтрочные.

const turtleImpl = {
  Forward:    (c: any, cb: any) => singleResult(c, "turtle.forward",    [], cb),
  Back:       (c: any, cb: any) => singleResult(c, "turtle.back",       [], cb),
  Up:         (c: any, cb: any) => singleResult(c, "turtle.up",         [], cb),
  Down:       (c: any, cb: any) => singleResult(c, "turtle.down",       [], cb),
  TurnLeft:   (c: any, cb: any) => singleResult(c, "turtle.turnLeft",   [], cb),
  TurnRight:  (c: any, cb: any) => singleResult(c, "turtle.turnRight",  [], cb),
  Dig:        (c: any, cb: any) => singleResult(c, "turtle.dig",        sideArgs(c), cb),
  DigUp:      (c: any, cb: any) => singleResult(c, "turtle.digUp",      sideArgs(c), cb),
  DigDown:    (c: any, cb: any) => singleResult(c, "turtle.digDown",    sideArgs(c), cb),
  Place:      (c: any, cb: any) => singleResult(c, "turtle.place",      textArg(c), cb),
  PlaceUp:    (c: any, cb: any) => singleResult(c, "turtle.placeUp",    textArg(c), cb),
  PlaceDown:  (c: any, cb: any) => singleResult(c, "turtle.placeDown",  textArg(c), cb),
  Drop:       (c: any, cb: any) => singleResult(c, "turtle.drop",       countArg(c), cb),
  DropUp:     (c: any, cb: any) => singleResult(c, "turtle.dropUp",     countArg(c), cb),
  DropDown:   (c: any, cb: any) => singleResult(c, "turtle.dropDown",   countArg(c), cb),
  Suck:       (c: any, cb: any) => singleResult(c, "turtle.suck",       countArg(c), cb),
  SuckUp:     (c: any, cb: any) => singleResult(c, "turtle.suckUp",     countArg(c), cb),
  SuckDown:   (c: any, cb: any) => singleResult(c, "turtle.suckDown",   countArg(c), cb),
  Refuel:     (c: any, cb: any) => singleResult(c, "turtle.refuel",     countArg(c), cb),
  GetFuelLevel:(c: any, cb: any) => singleResult(c, "turtle.getFuelLevel", [], cb),
  GetFuelLimit:(c: any, cb: any) => singleResult(c, "turtle.getFuelLimit", [], cb),
  Select:        (c: any, cb: any) => singleResult(c, "turtle.select", [Number(c.request.slot)], cb),
  GetSelectedSlot:(c: any, cb: any) => singleResult(c, "turtle.getSelectedSlot", [], cb),
  GetItemCount:  (c: any, cb: any) => singleResult(c, "turtle.getItemCount", slotArg(c), cb),
  GetItemSpace:  (c: any, cb: any) => singleResult(c, "turtle.getItemSpace", slotArg(c), cb),
  GetItemDetail: (c: any, cb: any) => singleResult(c, "turtle.getItemDetail",
                                       [c.request.slot ? Number(c.request.slot) : null,
                                        Boolean(c.request.detailed)], cb),
  TransferTo: (c: any, cb: any) => singleResult(c, "turtle.transferTo",
                                     [Number(c.request.to_slot),
                                      ...(c.request.count ? [Number(c.request.count)] : [])], cb),
  Compare:     (c: any, cb: any) => singleResult(c, "turtle.compare", [], cb),
  CompareUp:   (c: any, cb: any) => singleResult(c, "turtle.compareUp", [], cb),
  CompareDown: (c: any, cb: any) => singleResult(c, "turtle.compareDown", [], cb),
  CompareTo:   (c: any, cb: any) => singleResult(c, "turtle.compareTo", [Number(c.request.slot)], cb),
  Detect:      (c: any, cb: any) => singleResult(c, "turtle.detect", [], cb),
  DetectUp:    (c: any, cb: any) => singleResult(c, "turtle.detectUp", [], cb),
  DetectDown:  (c: any, cb: any) => singleResult(c, "turtle.detectDown", [], cb),
  Inspect:     (c: any, cb: any) => singleResult(c, "turtle.inspect", [], cb),
  InspectUp:   (c: any, cb: any) => singleResult(c, "turtle.inspectUp", [], cb),
  InspectDown: (c: any, cb: any) => singleResult(c, "turtle.inspectDown", [], cb),
  Attack:      (c: any, cb: any) => singleResult(c, "turtle.attack", sideArgs(c), cb),
  AttackUp:    (c: any, cb: any) => singleResult(c, "turtle.attackUp", sideArgs(c), cb),
  AttackDown:  (c: any, cb: any) => singleResult(c, "turtle.attackDown", sideArgs(c), cb),
  Equip:       (c: any, cb: any) => singleResult(
    c, c.request.right ? "turtle.equipRight" : "turtle.equipLeft", [], cb),
  Craft:       (c: any, cb: any) => singleResult(c, "turtle.craft", countArg(c), cb),
};

function sideArgs(c: any): LuaPlain[] {
  const s = c.request.side ?? "";
  return s ? [s] : [];
}
function textArg(c: any): LuaPlain[] {
  const t = c.request.text ?? "";
  return t ? [t] : [];
}
function countArg(c: any): LuaPlain[] {
  const n = Number(c.request.count ?? 0);
  return n > 0 ? [n] : [];
}
function slotArg(c: any): LuaPlain[] {
  const n = Number(c.request.slot ?? 0);
  return n > 0 ? [n] : [];
}

// --- Peripheral ------------------------------------------------------------

const peripheralImpl = {
  IsPresent:  (c: any, cb: any) => singleResult(c, "peripheral.isPresent",  [c.request.name], cb),
  GetType:    (c: any, cb: any) => singleResult(c, "peripheral.getType",    [c.request.name], cb),
  HasType:    (c: any, cb: any) => singleResult(c, "peripheral.hasType",    [c.request.name, c.request.type], cb),
  GetMethods: (c: any, cb: any) => singleResult(c, "peripheral.getMethods", [c.request.name], cb),
  GetNames:   (c: any, cb: any) => singleResult(c, "peripheral.getNames",   [], cb),
  Find:       (c: any, cb: any) => singleResult(c, "peripheral.find",       [c.request.type], cb),
  Call:       (c: any, cb: any) => tupleResult(c, "peripheral.call",
    [c.request.name, c.request.method, ...(c.request.args ?? []).map(u)], cb),
};

// --- Fs --------------------------------------------------------------------

const fsImpl = {
  List:        (c: any, cb: any) => singleResult(c, "fs.list",        [c.request.path], cb),
  Exists:      (c: any, cb: any) => singleResult(c, "fs.exists",      [c.request.path], cb),
  IsDir:       (c: any, cb: any) => singleResult(c, "fs.isDir",       [c.request.path], cb),
  IsReadOnly:  (c: any, cb: any) => singleResult(c, "fs.isReadOnly",  [c.request.path], cb),
  GetSize:     (c: any, cb: any) => singleResult(c, "fs.getSize",     [c.request.path], cb),
  GetFreeSpace:(c: any, cb: any) => singleResult(c, "fs.getFreeSpace",[c.request.path], cb),
  MakeDir:     (c: any, cb: any) => singleResult(c, "fs.makeDir",     [c.request.path], cb),
  Move:        (c: any, cb: any) => singleResult(c, "fs.move",        [c.request.from, c.request.to], cb),
  Copy:        (c: any, cb: any) => singleResult(c, "fs.copy",        [c.request.from, c.request.to], cb),
  Delete:      (c: any, cb: any) => singleResult(c, "fs.delete",      [c.request.path], cb),
  Find:        (c: any, cb: any) => singleResult(c, "fs.find",        [c.request.pattern], cb),
  Attributes:  (c: any, cb: any) => singleResult(c, "fs.attributes",  [c.request.path], cb),
  ReadFile: async (c: any, cb: any) => {
    try {
      const values = await route(c, "__readFile", [c.request.path]);
      const data = values[0];
      if (typeof data !== "string") {
        cb(null, { ok: false, data: Buffer.alloc(0), error: "file not found or not readable" });
        return;
      }
      cb(null, { ok: true, data: Buffer.from(data, "utf8"), error: "" });
    } catch (e) {
      cb(null, { ok: false, data: Buffer.alloc(0), error: (e as Error).message });
    }
  },
  WriteFile: async (c: any, cb: any) => {
    const data: Buffer = c.request.data ?? Buffer.alloc(0);
    return singleResult(c, "__writeFile", [c.request.path, data.toString("utf8")], cb);
  },
  AppendFile: async (c: any, cb: any) => {
    const data: Buffer = c.request.data ?? Buffer.alloc(0);
    return singleResult(c, "__appendFile", [c.request.path, data.toString("utf8")], cb);
  },
};

// --- Redstone --------------------------------------------------------------

const redstoneImpl = {
  GetSides:        (c: any, cb: any) => singleResult(c, "redstone.getSides", [], cb),
  SetOutput:       (c: any, cb: any) => singleResult(c, "redstone.setOutput", [c.request.side, c.request.on], cb),
  GetOutput:       (c: any, cb: any) => singleResult(c, "redstone.getOutput", [c.request.side], cb),
  GetInput:        (c: any, cb: any) => singleResult(c, "redstone.getInput",  [c.request.side], cb),
  SetAnalogOutput: (c: any, cb: any) => singleResult(c, "redstone.setAnalogOutput", [c.request.side, Number(c.request.value)], cb),
  GetAnalogOutput: (c: any, cb: any) => singleResult(c, "redstone.getAnalogOutput", [c.request.side], cb),
  GetAnalogInput:  (c: any, cb: any) => singleResult(c, "redstone.getAnalogInput",  [c.request.side], cb),
  SetBundledOutput:(c: any, cb: any) => singleResult(c, "redstone.setBundledOutput",[c.request.side, Number(c.request.colors)], cb),
  GetBundledOutput:(c: any, cb: any) => singleResult(c, "redstone.getBundledOutput",[c.request.side], cb),
  GetBundledInput: (c: any, cb: any) => singleResult(c, "redstone.getBundledInput", [c.request.side], cb),
  TestBundledInput:(c: any, cb: any) => singleResult(c, "redstone.testBundledInput",[c.request.side, Number(c.request.color)], cb),
};

// --- Term ------------------------------------------------------------------

const termImpl = {
  Write:           (c: any, cb: any) => singleResult(c, "term.write", [c.request.text], cb),
  Blit:            (c: any, cb: any) => singleResult(c, "term.blit", [c.request.text, c.request.text_color, c.request.bg_color], cb),
  Clear:           (c: any, cb: any) => singleResult(c, "term.clear", [], cb),
  ClearLine:       (c: any, cb: any) => singleResult(c, "term.clearLine", [], cb),
  GetCursorPos:    (c: any, cb: any) => singleResult(c, "term.getCursorPos", [], cb),
  SetCursorPos:    (c: any, cb: any) => singleResult(c, "term.setCursorPos", [Number(c.request.x), Number(c.request.y)], cb),
  GetCursorBlink:  (c: any, cb: any) => singleResult(c, "term.getCursorBlink", [], cb),
  SetCursorBlink:  (c: any, cb: any) => singleResult(c, "term.setCursorBlink", [Boolean(c.request.value)], cb),
  IsColor:         (c: any, cb: any) => singleResult(c, "term.isColor", [], cb),
  GetSize:         (c: any, cb: any) => singleResult(c, "term.getSize", [], cb),
  Scroll:          (c: any, cb: any) => singleResult(c, "term.scroll", [Number(c.request.lines)], cb),
  SetTextColor:    (c: any, cb: any) => singleResult(c, "term.setTextColor", [Number(c.request.color)], cb),
  SetBackgroundColor:(c: any, cb: any) => singleResult(c, "term.setBackgroundColor", [Number(c.request.color)], cb),
  SetPaletteColor: (c: any, cb: any) => singleResult(c, "term.setPaletteColor", [Number(c.request.color), c.request.r, c.request.g, c.request.b], cb),
  GetPaletteColor: (c: any, cb: any) => singleResult(c, "term.getPaletteColor", [Number(c.request.color)], cb),
};

// --- Gps -------------------------------------------------------------------

const gpsImpl = {
  Locate: (c: any, cb: any) => singleResult(
    c, "gps.locate",
    [(c.request.timeout_ms ?? 0) / 1000 || 2, Boolean(c.request.debug)], cb),
};

// --- Http (CC native) ------------------------------------------------------

const httpImpl = {
  Get:  async (c: any, cb: any) => httpRequest(c, c.request.url, "GET",  null, c.request.headers, cb),
  Post: async (c: any, cb: any) => httpRequest(c, c.request.url, "POST", c.request.body, c.request.headers, cb),
  Request: async (c: any, cb: any) => httpRequest(c, c.request.url, c.request.method || "GET", c.request.body, c.request.headers, cb),
  CheckUrl:    (c: any, cb: any) => singleResult(c, "http.checkURL", [c.request.url], cb),
  WebsocketSend: (c: any, cb: any) => singleResult(c, "__wsSend", [c.request.handle, c.request.data, Boolean(c.request.binary)], cb),
};

async function httpRequest(c: any, url: string, method: string, body: Buffer | null, headers: Record<string, string>, cb: any) {
  try {
    const args: LuaPlain[] = [{
      url,
      method,
      body: body && body.length > 0 ? body.toString("utf8") : null,
      headers: headers ?? {},
      binary: false,
    }];
    const values = await route(c, "__httpFetch", args);
    const r = values[0] as any;
    if (!r || typeof r !== "object") {
      cb(null, { ok: false, code: 0, body: Buffer.alloc(0), headers: {}, error: "no response" });
      return;
    }
    cb(null, {
      ok: !!r.ok,
      code: Number(r.code ?? 0),
      body: Buffer.from(String(r.body ?? ""), "utf8"),
      headers: r.headers ?? {},
      error: r.error ?? "",
    });
  } catch (e) {
    cb(null, { ok: false, code: 0, body: Buffer.alloc(0), headers: {}, error: (e as Error).message });
  }
}

// --- Rednet ----------------------------------------------------------------

const rednetImpl = {
  Open:      (c: any, cb: any) => singleResult(c, "rednet.open",     [c.request.side], cb),
  Close:     (c: any, cb: any) => singleResult(c, "rednet.close",    [c.request.side], cb),
  IsOpen:    (c: any, cb: any) => singleResult(c, "rednet.isOpen",   [c.request.side], cb),
  Send:      (c: any, cb: any) => singleResult(c, "rednet.send",     [Number(c.request.recipient), u(c.request.message), c.request.protocol || null], cb),
  Broadcast: (c: any, cb: any) => singleResult(c, "rednet.broadcast",[u(c.request.message), c.request.protocol || null], cb),
  Host:      (c: any, cb: any) => singleResult(c, "rednet.host",     [c.request.protocol, c.request.hostname], cb),
  Unhost:    (c: any, cb: any) => singleResult(c, "rednet.unhost",   [c.request.protocol], cb),
  Lookup:    (c: any, cb: any) => singleResult(c, "rednet.lookup",   [c.request.protocol, c.request.hostname || null], cb),
};

// --- Os --------------------------------------------------------------------

const osImpl = {
  GetComputerID:    (c: any, cb: any) => singleResult(c, "os.getComputerID", [], cb),
  GetComputerLabel: (c: any, cb: any) => singleResult(c, "os.getComputerLabel", [], cb),
  SetComputerLabel: (c: any, cb: any) => singleResult(c, "os.setComputerLabel", [c.request.label], cb),
  Time:             (c: any, cb: any) => singleResult(c, "os.time",  c.request.locale ? [c.request.locale] : [], cb),
  Day:              (c: any, cb: any) => singleResult(c, "os.day",   c.request.locale ? [c.request.locale] : [], cb),
  Epoch:            (c: any, cb: any) => singleResult(c, "os.epoch", c.request.locale ? [c.request.locale] : [], cb),
  Clock:            (c: any, cb: any) => singleResult(c, "os.clock", [], cb),
  Reboot:           (c: any, cb: any) => singleResult(c, "os.reboot", [], cb),
  Shutdown:         (c: any, cb: any) => singleResult(c, "os.shutdown", [], cb),
  Version:          (c: any, cb: any) => singleResult(c, "os.version", [], cb),
};

// --- Commands --------------------------------------------------------------

const commandsImpl = {
  Exec: async (c: any, cb: any) => {
    try {
      const values = await route(c, "commands.exec", [c.request.command]);
      const ok = !!values[0];
      const out = (values[1] as string[]) ?? [];
      cb(null, { ok, output: ok ? out : [], error: ok ? "" : String(out?.[0] ?? "command failed") });
    } catch (e) {
      cb(null, { ok: false, output: [], error: (e as Error).message });
    }
  },
  List:             (c: any, cb: any) => singleResult(c, "commands.list", [], cb),
  GetBlockPosition: (c: any, cb: any) => singleResult(c, "commands.getBlockPosition", [], cb),
};

// --- Display (high-level) --------------------------------------------------

const displayImpl = {
  Clear: (c: any, cb: any) => singleResult(c, "__display.clear",
    [c.request.monitor || null, Number(c.request.bg) || null], cb),
  Text:  (c: any, cb: any) => singleResult(c, "__display.text",
    [c.request.monitor || null, Number(c.request.x), Number(c.request.y),
     c.request.text, Number(c.request.fg) || null, Number(c.request.bg) || null,
     c.request.scale || 0], cb),
  Bar:   (c: any, cb: any) => singleResult(c, "__display.bar",
    [c.request.monitor || null, Number(c.request.x), Number(c.request.y),
     Number(c.request.width), Number(c.request.fraction),
     Number(c.request.fill_color) || null, Number(c.request.empty_color) || null,
     c.request.label || ""], cb),
  Chart: (c: any, cb: any) => singleResult(c, "__display.chart",
    [c.request.monitor || null, Number(c.request.x), Number(c.request.y),
     Number(c.request.width), Number(c.request.height),
     (c.request.values ?? []).map(Number),
     Number(c.request.line_color) || null, Number(c.request.bg) || null,
     Number(c.request.min) || 0, Number(c.request.max) || 0], cb),
};

// --- Events ----------------------------------------------------------------

const eventsImpl = {
  Subscribe: (call: grpc.ServerWritableStream<any, any>) => {
    const t = {
      device_id: String(call.request?.target?.device_id ?? ""),
      world_id:  String(call.request?.target?.world_id  ?? "default") || "default",
    };
    const filter: Set<string> = new Set((call.request?.event_types ?? []).map(String));
    const dev = bridge.get(t);
    if (!dev) {
      call.emit("error", { code: grpc.status.NOT_FOUND, message: "device not attached" });
      return;
    }
    // Tell agent which events to forward.
    try {
      dev.send({ id: dev.newId(), type: "subscribe", events: Array.from(filter) });
    } catch (e) {
      call.emit("error", { code: grpc.status.UNAVAILABLE, message: (e as Error).message });
      return;
    }
    const onEvent = (ev: any) => {
      if (ev.device_id !== t.device_id || ev.world_id !== t.world_id) return;
      if (filter.size > 0 && !filter.has(ev.event)) return;
      call.write({
        device_id: ev.device_id,
        world_id: ev.world_id,
        ts_ms: ev.ts_ms,
        event: ev.event,
        args: (ev.args as LuaPlain[]).map(plainToLuaValue),
      });
    };
    bridge.on("event", onEvent);
    call.on("cancelled", () => {
      bridge.off("event", onEvent);
      try { dev.send({ id: dev.newId(), type: "unsubscribe" }); } catch { /* gone */ }
    });
  },
  Queue: (c: any, cb: any) => singleResult(c, "os.queueEvent",
    [c.request.event, ...((c.request.args ?? []).map(u))], cb),
};

// --- Registration ----------------------------------------------------------

export function registerAll(server: grpc.Server) {
  server.addService(v1.Devices.service,    devicesImpl);
  server.addService(v1.LuaBridge.service,  luaBridgeImpl);
  server.addService(v1.Turtle.service,     turtleImpl);
  server.addService(v1.Peripheral.service, peripheralImpl);
  server.addService(v1.Fs.service,         fsImpl);
  server.addService(v1.Redstone.service,   redstoneImpl);
  server.addService(v1.Term.service,       termImpl);
  server.addService(v1.Gps.service,        gpsImpl);
  server.addService(v1.Http.service,       httpImpl);
  server.addService(v1.Rednet.service,     rednetImpl);
  server.addService(v1.Os.service,         osImpl);
  server.addService(v1.Commands.service,   commandsImpl);
  server.addService(v1.Display.service,    displayImpl);
  server.addService(v1.Events.service,     eventsImpl);
  log.info("gRPC services registered");
}
