/**
 * SMS opt-outs learned from Twilio rather than from an inbound STOP.
 *
 * Twilio answers 21610 when the recipient has replied STOP to the sending
 * number (carrier/Advanced Opt-Out). If the STOP webhook itself was lost, or
 * the recipient unsubscribed at the carrier, our customers row still looks
 * textable and every automation keeps queueing texts that can never be
 * delivered. This records the opt-out the same way record_inbound_sms does
 * for STOP (0033): every customer of the shop with that number gets
 * sms_opted_out_at (kept if already set) and sms_opt_in = false, and SMS
 * still queued to the number are cancelled. Service role, shop-scoped.
 */
import { DbError, type Services } from "./lib.ts";

/** Twilio: "Attempt to send to unsubscribed recipient". */
export const TWILIO_UNSUBSCRIBED = "21610";

export const OPTED_OUT_ERROR = "the recipient opted out before sending";

/** Returns how many customer rows were newly opted out. Throws DbError. */
export async function recordSmsOptOut(
  svc: Services,
  shopId: string,
  phone: string,
): Promise<number> {
  const { data: customers, error } = await svc.admin.from("customers")
    .update({ sms_opted_out_at: svc.now().toISOString(), sms_opt_in: false })
    .eq("shop_id", shopId).eq("phone", phone).is("sms_opted_out_at", null)
    .select("id");
  if (error) throw new DbError("customers opt-out", error);

  const { error: cancelError } = await svc.admin.from("messages")
    .update({ status: "cancelled", error: OPTED_OUT_ERROR })
    .eq("shop_id", shopId).eq("to_address", phone).eq("channel", "sms")
    .eq("direction", "outbound").eq("status", "queued");
  if (cancelError) throw new DbError("messages opt-out cancel", cancelError);

  const count = Array.isArray(customers) ? customers.length : 0;
  svc.log.info("sms_opt_out_recorded", {
    shop_id: shopId,
    source: "twilio_21610",
    customers: count,
  });
  return count;
}
