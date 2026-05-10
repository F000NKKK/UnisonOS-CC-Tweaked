import { connect } from "./client.js";

const c = connect();
const target = {
  device_id: process.argv[2] ?? "1",
  world_id: process.env.UNISON_WORLD ?? "default",
};

const stream = c.events.Subscribe({
  target,
  event_types: ["key", "char", "monitor_touch", "redstone", "modem_message"],
});

stream.on("data", (ev: any) => console.log(new Date(Number(ev.ts_ms)).toISOString(), ev.event, ev.args));
stream.on("error", (e: any) => console.error("stream err:", e.message));
stream.on("end", () => console.log("stream ended"));
