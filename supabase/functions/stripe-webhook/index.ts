/**
 * stripe-webhook — the Stripe Connect webhook (SPEC section 5). verify_jwt is
 * false: Stripe authenticates with the Stripe-Signature header, which is
 * verified over the RAW body before anything is parsed.
 *
 *   POST /functions/v1/stripe-webhook
 *     200 { received: true, handled, duplicate, result }  processed / replay / unhandled type
 *     400 invalid_signature                               missing or bad signature
 *     409 conflict                                        another delivery is processing it
 *     500 internal_error                                  processing failed; Stripe retries
 *
 * Idempotency: `processStripeEventOnce` records the event in `stripe_events`;
 * a replay of a processed event is acknowledged without running again, while
 * a redelivery of an event whose earlier attempt failed is processed again.
 * The event handlers (handlers.ts) are themselves safe to re-run and to
 * receive events out of order.
 */
import type { Env } from "../_shared/env.ts";
import { HttpError } from "../_shared/errors.ts";
import { createHandler, readText } from "../_shared/http.ts";
import type { Logger } from "../_shared/log.ts";
import { processStripeEventOnce } from "../_shared/stripe_events.ts";
import { eventAccount, stripeFromEnv, verifyStripeWebhook } from "../_shared/stripe.ts";
import { adminClient } from "../_shared/supabase.ts";
import { handleEvent, isHandledEventType, type Outcome } from "./handlers.ts";

/** Stripe event payloads are well under this; larger bodies are refused (413). */
export const MAX_WEBHOOK_BODY_BYTES = 1024 * 1024;

export interface Deps {
  env?: Env;
  /** One fetch for Supabase + Stripe (tests inject FakeSupabase's FakeFetch). */
  fetch?: typeof fetch;
  logger?: Logger;
  /** Clock for the ledger and membership stamps (tests). */
  now?: () => Date;
  /** Stripe SDK retries (tests pass 0). */
  maxNetworkRetries?: number;
}

export interface WebhookResponse {
  received: true;
  /** False for event types this endpoint does not act on (acknowledged, not recorded). */
  handled: boolean;
  /** A replay of an already processed event. */
  duplicate: boolean;
  /** What processing did ("applied" / "ignored"); null for duplicates and unhandled types. */
  result: Outcome["result"] | null;
}

/**
 * Everything after signature verification that fails maps to 500 so Stripe
 * redelivers. HttpErrors raised on purpose (e.g. 409 while another delivery
 * holds the event) keep their status. The cause is only logged.
 */
function processingError(err: unknown): HttpError {
  if (err instanceof HttpError) return err;
  return new HttpError(
    "internal_error",
    "The event could not be processed. Stripe will retry.",
    { cause: err },
  );
}

export function makeHandler(deps: Deps = {}): (req: Request) => Promise<Response> {
  const now = deps.now ?? (() => new Date());
  return createHandler(
    { name: "stripe-webhook", cors: false, env: deps.env, logger: deps.logger },
    async (req, ctx): Promise<WebhookResponse> => {
      const rawBody = await readText(req, { maxBytes: MAX_WEBHOOK_BODY_BYTES });
      const stripe = stripeFromEnv(ctx.env, {
        fetch: deps.fetch,
        maxNetworkRetries: deps.maxNetworkRetries,
      });
      const event = await verifyStripeWebhook(
        stripe,
        rawBody,
        req.headers.get("stripe-signature"),
        ctx.env.stripeWebhookSecret(),
      );
      const account = eventAccount(event);
      const log = ctx.log.child({ event_id: event.id, event_type: event.type, account });

      if (!isHandledEventType(event.type)) {
        log.info("stripe_event_unhandled");
        return { received: true, handled: false, duplicate: false, result: null };
      }

      const admin = adminClient({ env: ctx.env, fetch: deps.fetch });
      let outcome: Outcome | null = null;
      try {
        const status = await processStripeEventOnce(
          admin,
          { id: event.id, type: event.type, account },
          async ({ attempt }) => {
            outcome = await handleEvent({
              admin,
              stripe,
              event,
              account,
              log: attempt > 1 ? log.child({ attempt }) : log,
              now,
            });
          },
          { log, now },
        );
        const result: Outcome | null = outcome;
        return {
          received: true,
          handled: true,
          duplicate: status === "duplicate",
          result: result === null ? null : (result as Outcome).result,
        };
      } catch (err) {
        throw processingError(err);
      }
    },
  );
}

if (import.meta.main) Deno.serve(makeHandler());
