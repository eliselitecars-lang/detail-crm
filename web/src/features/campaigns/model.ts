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

export const CAMPAIGN_STATUSES = Constants.public.Enums.campaign_status;
export type CampaignStatus = (typeof CAMPAIGN_STATUSES)[number];
export type CampaignChannel = (typeof Constants.public.Enums.message_channel)[number];
export type Lifecycle = (typeof Constants.public.Enums.customer_lifecycle)[number];

export const MAX_TAGS = 50;
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

/** SMS campaigns get "Reply STOP to opt out." appended by the server unless the text mentions STOP. */
export function smsNeedsStopFooter(body: string): boolean {
  return !/\bstop\b/i.test(body);
}

export interface RecipientStats {
  recipients: number;
  pending: number;
  sent: number;
  delivered: number;
  failed: number;
  cancelled: number;
}
