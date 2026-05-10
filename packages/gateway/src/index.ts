import * as grpc from "@grpc/grpc-js";
import { config } from "./config.js";
import { log } from "./logger.js";
import { bridge } from "./bridge.js";
import { registerAll } from "./services.js";

async function main() {
  bridge.start();

  const server = new grpc.Server({
    "grpc.max_receive_message_length": 16 * 1024 * 1024,
    "grpc.max_send_message_length":    16 * 1024 * 1024,
  });
  registerAll(server);

  await new Promise<void>((resolve, reject) => {
    server.bindAsync(config.grpcAddr, grpc.ServerCredentials.createInsecure(), (err) => {
      if (err) reject(err); else resolve();
    });
  });
  log.info({ addr: config.grpcAddr }, "gRPC listening");

  const shutdown = () => {
    log.info("shutting down");
    server.tryShutdown(() => process.exit(0));
    setTimeout(() => process.exit(1), 5000).unref();
  };
  process.on("SIGINT", shutdown);
  process.on("SIGTERM", shutdown);
}

main().catch((e) => { log.error({ err: e.message, stack: e.stack }, "fatal"); process.exit(1); });
