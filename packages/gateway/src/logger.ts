import pino from "pino";

export const log = pino({
  transport: { target: "pino-pretty", options: { colorize: true, translateTime: "SYS:HH:MM:ss" } },
  level: process.env.UNISON_LOG_LEVEL ?? "info",
});
