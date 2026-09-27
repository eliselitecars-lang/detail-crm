/** Logger that captures records in memory (keeps test output clean). */
import { createLogger, type Logger, type LogRecord } from "../log.ts";

export interface MemoryLogger {
  logger: Logger;
  records: LogRecord[];
  /** Records for one event name. */
  events(event: string): LogRecord[];
}

export function memoryLogger(): MemoryLogger {
  const records: LogRecord[] = [];
  return {
    logger: createLogger({}, (record) => records.push(record)),
    records,
    events: (event) => records.filter((record) => record.event === event),
  };
}
