/**
 * Campaigns — audience filter + form rules (pure, unit-tested). The audience
 * JSON shape is the database contract (migration 0035,
 * campaign_audience_valid): every key optional, combined with AND.
 *   tags               any-of (case-insensitive)
 *   lifecycle          'lead' | 'customer'
 *   last_visit_before  local date (shop tz): last completed job strictly before
 *   last_visit_after   local date (shop tz): last completed job on or after
 */
import { z } from 'zod';
import { Constants, type Json } from '@/lib/database.types';
import { formatLocalDate, isLocalDate } from '@/lib/dates';
import { toAppError } from '@/lib/errors';

export const CAMPAIGN_STATUSES = Constants.public.Enums.campaign_status;
export type CampaignStatus = (typeof CAMPAIGN_STATUSES)[number];
export type CampaignChannel = (typeof Constants.public.Enums.message_channel)[number];
export type Lifecycle = (typeof Constants.public.Enums.customer_lifecycle)[number];

export const MAX_TAGS = 50;
/**
 * Synchronous form bounds only: launch_campaign cuts every rendered SMS to
 * 1,600 characters (opt-out footer included). The exact room left after the
 * footer and the rendered length come from preview_campaign_message.
 */
export const SMS_BODY_MAX = 1600;
export const EMAIL_BODY_MAX = 50000;

const localDate = z.string().refine(isLocalDate, 'Use a valid date.');

export const audienceSchema = z
  .object({
    tags: z.array(z.string().trim().min(1).max(100)).max(MAX_TAGS).optional(),
    lifecycle: z.enum(Constants.public.Enums.customer_lifecycle).optional(),
    last_visit_before: localDate.optional(),
    last_visit_after: localDate.optional(),
  })
  .strict();
export type Audience = z.infer<typeof audienceSchema>;

/** Editable form state for the audience builder ('' = no filter). */
export interface AudienceForm {
  tags: string[];
  lifecycle: Lifecycle | '';
  lastVisitBefore: string;
  lastVisitAfter: string;
}

export const EMPTY_AUDIENCE_FORM: AudienceForm = {
  tags: [],
  lifecycle: '',
  lastVisitBefore: '',
  lastVisitAfter: '',
};

/** Form → the jsonb stored in campaigns.audience (empty filters omitted). */
export function audienceFromForm(form: AudienceForm): Audience {
  const audience: Audience = {};
  const tags = normalizeTags(form.tags);
  if (tags.length > 0) audience.tags = tags;
  if (form.lifecycle) audience.lifecycle = form.lifecycle;
  if (form.lastVisitBefore) audience.last_visit_before = form.lastVisitBefore;
  if (form.lastVisitAfter) audience.last_visit_after = form.lastVisitAfter;
  return audience;
}

/** Stored jsonb → form. Unknown/invalid content falls back to "everyone". */
export function audienceToForm(value: Json | null | undefined): AudienceForm {
  const parsed = audienceSchema.safeParse(value ?? {});
  if (!parsed.success) return { ...EMPTY_AUDIENCE_FORM };
  const a = parsed.data;
  return {
    tags: a.tags ?? [],
    lifecycle: a.lifecycle ?? '',
    lastVisitBefore: a.last_visit_before ?? '',
    lastVisitAfter: a.last_visit_after ?? '',
  };
}

export function audienceToJson(audience: Audience): { [key: string]: Json } {
  const json: { [key: string]: Json } = {};
  if (audience.tags) json.tags = audience.tags;
  if (audience.lifecycle) json.lifecycle = audience.lifecycle;
  if (audience.last_visit_before) json.last_visit_before = audience.last_visit_before;
  if (audience.last_visit_after) json.last_visit_after = audience.last_visit_after;
  return json;
}

/** Trims, drops blanks and case-insensitive duplicates (first spelling wins). */
export function normalizeTags(tags: readonly string[]): string[] {
  const seen = new Set<string>();
  const out: string[] = [];
  for (const raw of tags) {
    const tag = raw.trim();
    if (!tag || tag.length > 100) continue;
    const key = tag.toLowerCase();
    if (seen.has(key)) continue;
    seen.add(key);
    out.push(tag);
  }
  return out.slice(0, MAX_TAGS);
}

/** A range that can never match (after ≥ before), shown as a warning. */
export function audienceRangeError(form: AudienceForm): string | null {
  if (form.lastVisitAfter && form.lastVisitBefore && form.lastVisitAfter >= form.lastVisitBefore) {
    return '“Last visit on or after” must be earlier than “last visit before”, or nobody matches.';
  }
  return null;
}

/** Plain-English summary of who a campaign goes to. */
export function describeAudience(audience: Audience, channel: CampaignChannel): string {
  const parts: string[] = [];
  parts.push(channel === 'sms' ? 'Customers opted in to texts' : 'Customers opted in to email');
  if (audience.lifecycle)
    parts.push(audience.lifecycle === 'lead' ? 'who are leads' : 'who are customers (not leads)');
  if (audience.tags && audience.tags.length > 0)
    parts.push(`tagged ${audience.tags.map((t) => `“${t}”`).join(' or ')}`);
  if (audience.last_visit_after && audience.last_visit_before)
    parts.push(
      `whose last visit was between ${formatLocalDate(audience.last_visit_after)} and ${formatLocalDate(audience.last_visit_before)} (exclusive)`,
    );
  else if (audience.last_visit_after)
    parts.push(`whose last visit was on or after ${formatLocalDate(audience.last_visit_after)}`);
  else if (audience.last_visit_before)
    parts.push(`whose last visit was before ${formatLocalDate(audience.last_visit_before)}`);
  return parts.join(', ');
}

/** Placeholders a campaign body may use (customer/shop level — no job). */
export const CAMPAIGN_PLACEHOLDERS: readonly { name: string; help: string }[] = [
  { name: 'customer_first_name', help: 'First name (else company, else “there”)' },
  { name: 'customer_name', help: 'Full name (else company)' },
  { name: 'shop_name', help: 'Your shop name' },
  { name: 'shop_phone', help: 'Your shop phone' },
  { name: 'booking_page_link', help: 'Link to your online booking page' },
  { name: 'review_link', help: 'Your review link' },
  { name: 'portal_link', help: 'Link to the client portal (visits, memberships, card)' },
  { name: 'unsubscribe_link', help: 'Email unsubscribe link (added automatically if missing)' },
];

export const campaignFormSchema = z
  .object({
    name: z
      .string()
      .trim()
      .min(1, 'Name is required.')
      .max(200, 'Keep the name under 200 characters.'),
    channel: z.enum(Constants.public.Enums.message_channel),
    subject: z.string().trim().max(200, 'Keep the subject under 200 characters.'),
    body: z.string().trim().min(1, 'Write the message.'),
    sendDate: z.string(),
    sendTime: z.string(),
  })
  .superRefine((v, ctx) => {
    if (v.channel === 'email' && v.subject === '')
      ctx.addIssue({
        code: 'custom',
        path: ['subject'],
        message: 'Email campaigns need a subject.',
      });
    const max = v.channel === 'sms' ? SMS_BODY_MAX : EMAIL_BODY_MAX;
    if (v.body.length > max)
      ctx.addIssue({
        code: 'custom',
        path: ['body'],
        message: `Keep it under ${max.toLocaleString()} characters.`,
      });
    if ((v.sendDate === '') !== (v.sendTime === ''))
      ctx.addIssue({
        code: 'custom',
        path: [v.sendDate === '' ? 'sendDate' : 'sendTime'],
        message: 'Set both a date and a time, or leave both empty to send at launch.',
      });
    if (v.sendDate !== '' && !isLocalDate(v.sendDate))
      ctx.addIssue({ code: 'custom', path: ['sendDate'], message: 'Use a valid date.' });
  });
export type CampaignFormValues = z.input<typeof campaignFormSchema>;

/** Whether the text has {{placeholders}}, which are filled in per customer at launch. */
export function hasPlaceholders(body: string): boolean {
  return /\{\{[ \t]*[a-z_]+[ \t]*\}\}/i.test(body);
}

/** preview_campaign_message (0090): the message as launch_campaign renders it. */
export const campaignPreviewSchema = z.object({
  /** Email: the rendered subject (or the shop name); null for SMS. */
  subject: z.string().nullable(),
  /** Final text: SMS with the opt-out line when needed; email with the unsubscribe footer. */
  body: z.string(),
  /** Rendered length before any footer. */
  body_length: z.number().int(),
  /** Longest rendered text that is sent whole (SMS: less the opt-out line when it is added). */
  max_body_length: z.number().int(),
  /** SMS: “Reply STOP to opt out.” is appended. */
  footer_added: z.boolean(),
  /** body_length > max_body_length: the message is cut at launch. */
  truncated: z.boolean(),
});
export type CampaignPreview = z.infer<typeof campaignPreviewSchema>;

export interface RecipientStats {
  recipients: number;
  pending: number;
  sent: number;
  delivered: number;
  failed: number;
  cancelled: number;
}

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

/** An unsubscribe link token is the campaign email's message id (a uuid). */
export function isUnsubscribeToken(value: string | undefined): value is string {
  return typeof value === 'string' && UUID_RE.test(value);
}

/**
 * What still arrives after the unsubscribe link (0126: a marketing-only
 * opt-out — only campaigns and the follow_up / service_followup templates
 * are marketing; everything else is transactional).
 */
export const UNSUBSCRIBE_STILL_SENT =
  'booking confirmations, appointment reminders, quotes, invoices and receipts';

/** What marketing email means on the unsubscribe page and in the portal. */
export const MARKETING_EMAILS_ARE = 'campaigns, promotions and service follow-ups';

/**
 * The /u/:token page's "You're unsubscribed" text for the address's opt-out
 * scope (public_unsubscribe_info): 'marketing' (the link, or the portal) or
 * 'all' (Stop all emails, an unsubscribe from before 0126, or recorded by the
 * shop). When nobody can resubscribe the address (no current customer of the
 * shop has it), a different address is the only way back, and it says so.
 */
export function unsubscribedText(
  shopName: string,
  scope: 'marketing' | 'all' | null | undefined,
  canResubscribe: boolean,
): string {
  if (scope === 'all') {
    return `This address is opted out of all emails from ${shopName}, including ${UNSUBSCRIBE_STILL_SENT}.${
      canResubscribe
        ? ''
        : ` If you want emails from ${shopName} again, give them a different email address.`
    }`;
  }
  return `${shopName} won’t send marketing emails — ${MARKETING_EMAILS_ARE} — to this address any more. You’ll still get ${UNSUBSCRIBE_STILL_SENT} from them.`;
}

/**
 * An email choice that failed (the /u page, the portal toggle), in plain
 * words: a rate limit (HTTP 429 / PT429) says to wait; anything else is the
 * mapped error (network, server).
 */
export function emailChoiceErrorMessage(error: unknown): string {
  const appError = toAppError(error);
  if (appError.kind === 'rate_limited' || appError.code === 'PT429' || appError.status === 429) {
    return 'Too many requests from your connection. Wait a minute, then try again.';
  }
  return appError.message;
}
