/**
 * billing-webhook — Stripe webhook of the PLATFORM account for shop
 * subscription billing (docs/BILLING.md). A separate endpoint from the
 * Connect webhook (`stripe-webhook`, shops' own payments): its own URL, its
 * own signing secret (STRIPE_BILLING_WEBHOOK_SECRET) and only the events in
 * HANDLED_EVENT_TYPES. verify_jwt is false: Stripe authenticates with the
 * Stripe-Signature header, verified over the RAW body before anything is
 * parsed.
 *
 *   POST /functions/v1/billing-webhook
 *     200 { received: true, handled, duplicate, result }  processed / replay / not ours
 *     400 invalid_signature                               missing or bad signature
 *     409 conflict                                        another delivery is processing it
 *     500 internal_error                                  processing failed; Stripe retries
 *     500 server_misconfigured                            STRIPE_BILLING_WEBHOOK_SECRET unset
 *
 * Connect events (with `account`) are acknowledged and never processed, and
 * never enter the stripe_events ledger that stripe-webhook shares.
 * Idempotency: processStripeEventOnce (stripe_events); a replay of a
 * processed event is acknowledged without running again.
 */
import type { Env } from "../_shared/env.ts";
import { HttpError } from "../_shared/errors.ts";
import { createHandler, readText } from "../_shared/http.ts";
import type { Logger } from "../_shared/log.ts";
import { processStripeEventOnce } from "../_shared/stripe_events.ts";
import { stripeFromEnv, verifyStripeWebhook } from "../_shared/stripe.ts";
import { adminClient } from "../_shared/supabase.ts";
import { handleBillingEvent, isHandledEventType, type Outcome } from "./handlers.ts";

/** Stripe event payloads are well under this; larger bodies are refused (413). */
export const MAX_WEBHOOK_BODY_BYTES = 1024 * 1024;

export interface Deps {
  env?: Env;
  /** One fetch for Supabase + Stripe (tests inject FakeSupabase's FakeFetch). */
  fetch?: typeof fetch;
  logger?: Logger;
  /** Clock for the event ledger (tests). */
  now?: () => Date;
  /** Stripe SDK retries (tests pass 0). */
  maxNetworkRetries?: number;
}

export interface WebhookResponse {
  received: true;
  /** False for Connect events and event types this endpoint does not act on. */
  handled: boolean;
  /** A replay of an already processed event. */
  duplicate: boolean;
  /** "applied" / "ignored"; null for duplicates, Connect events and unhandled types. */
  result: Outcome["result"] | null;
}

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
    { name: "billing-webhook", cors: false, env: deps.env, logger: deps.logger },
    async (req, ctx): Promise<WebhookResponse> => {
      const rawBody = await readText(req, { maxBytes: MAX_WEBHOOK_BODY_BYTES });
      const signature = req.headers.get("stripe-signature");
      // Unsigned requests are refused before any secret is needed.
      if (!signature) throw new HttpError("invalid_signature", "Missing Stripe-Signature header.");
      const stripe = stripeFromEnv(ctx.env, {
        fetch: deps.fetch,
        maxNetworkRetries: deps.maxNetworkRetries,
      });
      const event = await verifyStripeWebhook(
        stripe,
        rawBody,
        signature,
        ctx.env.stripeBillingWebhookSecret(),
      );
      const log = ctx.log.child({ event_id: event.id, event_type: event.type });

      // Platform events only: a connected account's event is never billing.
      if (typeof event.account === "string" && event.account !== "") {
        log.warn("billing_event_connect_ignored", { account: event.account });
        return { received: true, handled: false, duplicate: false, result: null };
      }
      if (!isHandledEventType(event.type)) {
        log.info("billing_event_unhandled");
        return { received: true, handled: false, duplicate: false, result: null };
      }

      const admin = adminClient({ env: ctx.env, fetch: deps.fetch });
      let outcome: Outcome | null = null;
      try {
        const status = await processStripeEventOnce(
          admin,
          { id: event.id, type: event.type, account: null },
          async ({ attempt }) => {
            outcome = await handleBillingEvent({
              admin,
              stripe,
              event,
              log: attempt > 1 ? log.child({ attempt }) : log,
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
