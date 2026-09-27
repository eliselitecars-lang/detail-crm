/**
 * Pure editing logic for the template editor: drafts per channel row,
 * validation mirroring CHECK constraints (0032), and minimal update patches.
 */
import type { MessageTemplate, TemplateChannel, TemplatePatch } from '../api';
import { splitMinutes, type DurationUnit } from '../schemas';
import { BODY_LIMITS, offsetFromInput, type TemplateKeyMeta } from './meta';

export interface ChannelDraft {
  /** updated_at of the row the draft was started from (stale drafts are dropped). */
  base: string;
  enabled: boolean;
  subject: string;
  body: string;
}

export interface OffsetDraft {
  base: number | null;
  value: string;
  unit: DurationUnit;
}

export function draftFromRow(row: MessageTemplate): ChannelDraft {
  return { base: row.updated_at, enabled: row.enabled, subject: row.subject ?? '', body: row.body };
}

export function offsetDraftFrom(offset: number | null): OffsetDraft {
  const { value, unit } = splitMinutes(offset ?? 0);
  return { base: offset, value, unit };
}

export interface DraftErrors {
  subject?: string;
  body?: string;
}

export function validateDraft(channel: TemplateChannel, draft: ChannelDraft): DraftErrors {
  const errors: DraftErrors = {};
  if (draft.body.trim().length === 0) errors.body = 'Write the message.';
  else if (draft.body.length > BODY_LIMITS[channel]) {
    errors.body = `Keep it to ${BODY_LIMITS[channel].toLocaleString('en-US')} characters or fewer.`;
  }
  if (channel === 'email') {
    const subject = draft.subject.trim();
    if (subject.length === 0) errors.subject = 'Add a subject line.';
    else if (subject.length > 200) errors.subject = 'Keep the subject to 200 characters or fewer.';
  }
  return errors;
}

export function offsetError(meta: TemplateKeyMeta, draft: OffsetDraft): string | undefined {
  if (!meta.timing) return undefined;
  if (offsetFromInput(meta, draft.value, draft.unit) !== null) return undefined;
  const max = meta.timing.maxMinutes === 43200 ? '30 days' : '365 days';
  return `Enter a whole number up to ${max}.`;
}

/** Only the fields that changed (the server trims body/subject the same way). */
export function patchFor(row: MessageTemplate, draft: ChannelDraft): TemplatePatch {
  const patch: TemplatePatch = {};
  if (draft.enabled !== row.enabled) patch.enabled = draft.enabled;
  if (draft.body !== row.body) patch.body = draft.body;
  if (row.channel === 'email' && draft.subject !== (row.subject ?? '')) {
    patch.subject = draft.subject.trim();
  }
  return patch;
}

export function isEmptyPatch(patch: TemplatePatch): boolean {
  return Object.keys(patch).length === 0;
}

/** Inserts `{{name}}` into `text` at [start, end) and returns the new text + caret. */
export function insertPlaceholder(
  text: string,
  name: string,
  start: number,
  end: number,
): { text: string; caret: number } {
  const token = `{{${name}}}`;
  const from = Math.max(0, Math.min(start, text.length));
  const to = Math.max(from, Math.min(end, text.length));
  return { text: text.slice(0, from) + token + text.slice(to), caret: from + token.length };
}
