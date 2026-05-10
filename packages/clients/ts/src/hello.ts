import { connect, unary } from "./client.js";

const c = connect();
const target = {
  device_id: process.argv[2] ?? "1",
  world_id: process.env.UNISON_WORLD ?? "default",
};

const list = await unary<any>(c.devices, "List", { world_id: target.world_id });
console.log("attached devices:", list.devices.map((d: any) => `${d.device_id}/${d.role}`));

const fwd = await unary<any>(c.turtle, "Forward", { target });
console.log("turtle.forward →", fwd);

const id = await unary<any>(c.os, "GetComputerID", { target });
console.log("os.getComputerID →", id);

await unary<any>(c.display, "Bar", {
  target, monitor: "", x: 1, y: 1, width: 20,
  fraction: 0.42, fill_color: 0x2000, empty_color: 0x80, label: "fuel 42%",
});
