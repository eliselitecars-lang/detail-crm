/**
 * Structured JSON-line logging for edge functions. Supabase's log explorer
 * indexes each line; fields whose key looks secret are redacted so tokens,
 * keys and signatures never reach the logs.
 */

export type LogLevel = "debug" | "info" | "warn" | "error";

export type LogFields = Record<string, unknown>;

export interface LogRecord {
  level: LogLevel;
  event: string;
  time: string;
  [field: string]: unknown;
}

export type LogSink = (record: LogRecord) => void;

export interface Logger {
  debug(event: string, fields?: LogFields): void;
  info(event: string, fields?: LogFields): void;
  warn(event: string, fields?: LogFields): void;
  error(event: string, fields?: LogFields): void;
  child(fields: LogFields): Logger;
}

const SECRET_KEY =
  /(authorization|cookie|secret|password|passwd|token|api[_-]?key|apikey|signature|card[_-]?number|cvc|cvv)/i;
const MAX_DEPTH = 5;

export const REDACTED = "[redacted]";

/** Deep-copies `value` into something JSON-safe with secret-looking keys redacted. */
export function redact(value: unknown, depth = 0): unknown {
  if (value === null || value === undefined) return value ?? null;
  if (value instanceof Error) {
    const out: Record<string, unknown> = { name: value.name, message: value.message };
    if (value.stack) out.stack = value.stack;
    const extra = value as unknown as Record<string, unknown>;
    for (const key of ["code", "status", "provider", "providerCode", "httpStatus", "variable"]) {
      if (key in extra && extra[key] !== undefined) out[key] = redact(extra[key], depth + 1);
    }
    if (value.cause !== undefined && depth < MAX_DEPTH) out.cause = redact(value.cause, depth + 1);
    return out;
  }
  if (typeof value === "bigint") return value.toString();
  if (typeof value !== "object") return value;
  if (depth >= MAX_DEPTH) return "[truncated]";
  if (Array.isArray(value)) return value.map((item) => redact(item, depth + 1));
  const out: Record<string, unknown> = {};
  for (const [key, item] of Object.entries(value as Record<string, unknown>)) {
    out[key] = SECRET_KEY.test(key) ? REDACTED : redact(item, depth + 1);
  }
  return out;
}

export const consoleSink: LogSink = (record: LogRecord): void => {
  const line = JSON.stringify(record);
  // deno-lint-ignore no-console
  if (record.level === "error") console.error(line);
  // deno-lint-ignore no-console
  else if (record.level === "warn") console.warn(line);
  // deno-lint-ignore no-console
  else console.log(line);
};

export function createLogger(base: LogFields = {}, sink: LogSink = consoleSink): Logger {
  const write = (level: LogLevel, event: string, fields?: LogFields) => {
    const merged = redact({ ...base, ...fields }) as Record<string, unknown>;
    sink({ ...merged, level, event, time: new Date().toISOString() });
  };
  return {
    debug: (event, fields) => write("debug", event, fields),
    info: (event, fields) => write("info", event, fields),
    warn: (event, fields) => write("warn", event, fields),
    error: (event, fields) => write("error", event, fields),
    child: (fields) => createLogger({ ...base, ...fields }, sink),
  };
}

export const logger: Logger = createLogger();
