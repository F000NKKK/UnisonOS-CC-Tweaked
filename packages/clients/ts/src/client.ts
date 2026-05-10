import * as grpc from "@grpc/grpc-js";
import * as protoLoader from "@grpc/proto-loader";
import { PROTO_PATH } from "@unison/proto";

const def = protoLoader.loadSync(PROTO_PATH, {
  keepCase: false,
  longs: String,
  enums: String,
  defaults: true,
  oneofs: true,
});
const root = grpc.loadPackageDefinition(def) as any;
export const v1 = root.unison.v1;

export function connect(addr = process.env.UNISON_GRPC_ADDR ?? "localhost:9290") {
  const creds = grpc.credentials.createInsecure();
  return {
    devices: new v1.Devices(addr, creds),
    turtle:  new v1.Turtle(addr, creds),
    fs:      new v1.Fs(addr, creds),
    term:    new v1.Term(addr, creds),
    os:      new v1.Os(addr, creds),
    display: new v1.Display(addr, creds),
    events:  new v1.Events(addr, creds),
    lua:     new v1.LuaBridge(addr, creds),
    peripheral: new v1.Peripheral(addr, creds),
  };
}

export function unary<T>(client: any, method: string, req: any): Promise<T> {
  return new Promise((resolve, reject) => {
    client[method](req, (err: any, resp: T) => {
      if (err) reject(err); else resolve(resp);
    });
  });
}
