import * as grpc from "@grpc/grpc-js";
import * as protoLoader from "@grpc/proto-loader";
import { PROTO_PATH } from "@unison/proto";

export const pkgDef = protoLoader.loadSync(PROTO_PATH, {
  keepCase: false,
  longs: String,
  enums: String,
  defaults: true,
  oneofs: true,
});

export const proto = grpc.loadPackageDefinition(pkgDef) as any;
export const v1 = proto.unison.v1;
