/**
 * Pure editing logic for the template editor: drafts per channel row,
 * validation mirroring CHECK constraints (0032), and minimal update patches.
 */
import type { MessageTemplate, TemplateChannel, TemplatePatch } from '../api';
import { splitMinutes, type DurationUnit } from '../schemas';
import { BODY_LIMITS, offsetFromInput, type TemplateKeyMeta } from './meta';

/** Most appointment reminders per appointment (comms_reminder_offsets_valid). */
export const MAX_REMINDERS = 3;

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

/** The stored reminder offsets of a key (several, or the single offset_minutes). */
export function reminderOffsetsOf(
  rows: readonly Pick<MessageTemplate, 'offset_minutes' | 'reminder_offsets_minutes'>[],
): number[] {
  const row = rows.find((r) => r.offset_minutes !== null);
  if (!row) return [];
  const many = row.reminder_offsets_minutes;
  if (many && many.length > 0) return [...many].sort((a, b) => b - a);
  return row.offset_minutes === null ? [] : [row.offset_minutes];
}

/** Drafts → offsets sorted nearest-first (as the server stores them); null if any is invalid. */
export function remindersFromDrafts(
  meta: TemplateKeyMeta,
  drafts: readonly OffsetDraft[],
): number[] | null {
  const offsets: number[] = [];
  for (const draft of drafts) {
    const offset = offsetFromInput(meta, draft.value, draft.unit);
    if (offset === null) return null;
    offsets.push(offset);
  }
  if (offsets.length === 0 || new Set(offsets).size !== offsets.length) return null;
  return offsets.sort((a, b) => b - a);
}

export function remindersError(
  meta: TemplateKeyMeta,
  drafts: readonly OffsetDraft[],
): string | undefined {
  if (drafts.length === 0) return 'Add at least one reminder.';
  if (drafts.length > MAX_REMINDERS) return `Use at most ${MAX_REMINDERS} reminders.`;
  for (const draft of drafts) {
    const problem = offsetError(meta, draft);
    if (problem) return problem;
  }
  if (remindersFromDrafts(meta, drafts) === null) return 'Each reminder needs a different time.';
  return undefined;
}

/**
 * The update for a new reminder schedule: one reminder is stored the pre-P-4
 * way (reminder_offsets_minutes null), several as the sorted list with
 * offset_minutes = the nearest (0086 message_templates_before_write).
 */
export function remindersPatch(offsets: readonly number[]): TemplatePatch {
  const sorted = [...offsets].sort((a, b) => b - a);
  const nearest = sorted[0] ?? 0;
  return sorted.length === 1
    ? { offset_minutes: nearest, reminder_offsets_minutes: null }
    : { offset_minutes: nearest, reminder_offsets_minutes: sorted };
}
