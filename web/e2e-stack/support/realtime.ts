import { expect, type Page } from '@playwright/test';

/**
 * Records the page's Supabase Realtime traffic so a test can wait until the
 * app's `postgres_changes` subscription for a table is really live before it
 * triggers a change (an event that races the subscribe is missed by design).
 *
 * Why not just wait for any "Subscribed to PostgreSQL" frame: every staff
 * page also subscribes to other tables (NotificationsBell → notifications, the
 * dashboard → jobs/payments/messages/time_entries), frames of earlier pages
 * are still in the log after a navigation, and React StrictMode (dev server)
 * joins, leaves and re-joins each channel. So we wait for the LATEST
 * `phx_join` of `rt:<table>:…` (web/src/lib/useRealtime.ts channel names)
 * sent after `mark()` to be acknowledged with "Subscribed to PostgreSQL".
 *
 * Handles both realtime-js wire formats: vsn 1.0.0 objects
 * `{topic, event, payload, ref}` and vsn 2.0.0 arrays
 * `[join_ref, ref, topic, event, payload]`.
 */
interface RealtimeMessage {
  topic?: string;
  event?: string;
  payload?: { status?: string; message?: string } | null;
}

function parse(raw: string | Buffer): RealtimeMessage | null {
  if (typeof raw !== 'string') return null;
  try {
    const m = JSON.parse(raw) as unknown;
    if (Array.isArray(m)) {
      return {
        topic: m[2] as string,
        event: m[3] as string,
        payload: m[4] as RealtimeMessage['payload'],
      };
    }
    return m as RealtimeMessage;
  } catch {
    return null;
  }
}

export interface RealtimeRecorder {
  /** Every text frame the browser received (raw). */
  frames: string[];
  /** Position to wait from (call right before the navigation that subscribes). */
  mark(): number;
  /** Waits until the latest channel on `table` joined after `since` is subscribed. */
  waitForSubscription(table: string, since: number, timeout?: number): Promise<void>;
}

export function recordRealtime(page: Page): RealtimeRecorder {
  const frames: string[] = [];
  const joins: string[] = [];
  const subscribed = new Set<string>();
  page.on('websocket', (ws) => {
    if (!ws.url().includes('/realtime/v1/')) return;
    ws.on('framesent', (frame) => {
      const m = parse(frame.payload);
      if (m?.event === 'phx_join' && m.topic) joins.push(m.topic);
    });
    ws.on('framereceived', (frame) => {
      if (typeof frame.payload === 'string') frames.push(frame.payload);
      const m = parse(frame.payload);
      if (
        m?.event === 'system' &&
        m.topic &&
        m.payload?.status === 'ok' &&
        /Subscribed to PostgreSQL/.test(m.payload.message ?? '')
      ) {
        subscribed.add(m.topic);
      }
    });
  });
  return {
    frames,
    mark: () => joins.length,
    async waitForSubscription(table, since, timeout = 20_000) {
      const prefix = `realtime:rt:${table}:`;
      await expect
        .poll(
          () => {
            const latest = joins
              .slice(since)
              .filter((t) => t.startsWith(prefix))
              .at(-1);
            return latest !== undefined && subscribed.has(latest);
          },
          { message: `realtime postgres_changes subscription on ${table} is live`, timeout },
        )
        .toBe(true);
    },
  };
}
