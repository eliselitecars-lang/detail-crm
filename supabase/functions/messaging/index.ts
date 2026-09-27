/**
 * messaging — customer SMS/email (SPEC §4.7, §5). verify_jwt = false at the
 * gateway because cron and Twilio call it without a Supabase JWT; every
 * action authenticates itself:
 *
 *   send             POST JSON  staff JWT + role (technicians: templated
 *                               on-my-way / started / complete on assigned jobs;
 *                               quotes / invoices: owner/admin/manager)
 *   process_queue    POST JSON  x-cron-secret == CRON_SECRET (pg_cron, every minute)
 *   run_automations  POST JSON  x-cron-secret == CRON_SECRET (enqueue_due_automations)
 *   twilio_inbound   POST form  ?action=twilio_inbound&shop_id=…, X-Twilio-Signature
 *   twilio_status    POST form  ?action=twilio_status,  X-Twilio-Signature
 *   unsubscribe      POST/GET   ?action=unsubscribe&token=<unsubscribe token> (public
 *                               by the email's messages.unsubscribe_token, never its
 *                               message id; RFC 8058 one-click for marketing emails)
 *
 * See supabase/setup/cron.sql for the schedules and twilio_webhooks.ts for
 * the URLs to configure in Twilio.
 */
import { z } from "zod";
import { createActionRouter, jsonAction, rawAction } from "../_shared/actions.ts";
import { requireCronSecret } from "../_shared/auth.ts";
import { HttpError } from "../_shared/errors.ts";
import { createHandler } from "../_shared/http.ts";
import {
  DEFAULT_QUEUE_LIMIT,
  MAX_QUEUE_LIMIT,
  processQueue,
  type QueueRunSummary,
} from "./deliver.ts";
import { DbError, type Deps, services } from "./lib.ts";
import { send, sendInput } from "./send.ts";
import { twilioInbound, twilioStatus } from "./twilio_webhooks.ts";
import { unsubscribe } from "./unsubscribe.ts";

export type { Deps };

export const processQueueInput = z.object({
  /** Most messages to claim in this run (default 200). */
  limit: z.number().int().min(1).max(MAX_QUEUE_LIMIT).optional(),
}).strict();

export function makeHandler(deps: Deps = {}): (req: Request) => Promise<Response> {
  const router = createActionRouter({
    send: jsonAction(sendInput, (input, ctx) => send(services(deps, ctx), ctx.req, input)),

    process_queue: jsonAction(
      processQueueInput,
      async (input, ctx): Promise<QueueRunSummary> => {
        requireCronSecret(ctx.req, ctx.env.cronSecret());
        const svc = services(deps, ctx);
        const summary = await processQueue(svc, {
          limit: input.limit ?? DEFAULT_QUEUE_LIMIT,
          timeBudgetMs: deps.queueTimeBudgetMs,
          concurrency: deps.concurrency,
        });
        svc.log.info("queue_processed", { ...summary });
        return summary;
      },
    ),

    run_automations: jsonAction(
      z.object({}).strict(),
      async (_input, ctx): Promise<{ queued: number }> => {
        requireCronSecret(ctx.req, ctx.env.cronSecret());
        const svc = services(deps, ctx);
        const { data, error } = await svc.admin.rpc("enqueue_due_automations", {});
        if (error) throw new DbError("enqueue_due_automations", error);
        const queued = typeof data === "number" ? data : 0;
        svc.log.info("automations_enqueued", { queued });
        return { queued };
      },
    ),

    twilio_inbound: rawAction((req, ctx) => twilioInbound(services(deps, ctx), req)),
    twilio_status: rawAction((req, ctx) => twilioStatus(services(deps, ctx), req)),
    unsubscribe: rawAction((req, ctx) => unsubscribe(services(deps, ctx), req)),
  });

  return createHandler(
    { name: "messaging", env: deps.env, logger: deps.logger, methods: ["POST", "GET"] },
    (req, ctx) => {
      // GET exists only so an unsubscribe link opened in a browser works.
      if (req.method === "GET" && new URL(req.url).searchParams.get("action") !== "unsubscribe") {
        throw new HttpError("method_not_allowed", "Method not allowed.", {
          headers: { Allow: "POST, OPTIONS" },
        });
      }
      return router(req, ctx);
    },
  );
}

if (import.meta.main) Deno.serve(makeHandler());
