import { Plus, RotateCcw, Trash2, X } from 'lucide-react';
import { useRef, useState } from 'react';
import {
  Button,
  ConfirmDialog,
  Dialog,
  EmptyState,
  FormField,
  IconButton,
  Input,
  Select,
  Switch,
  Tabs,
  Textarea,
  useToast,
} from '@/components/ui';
import { toAppError } from '@/lib/errors';
import {
  useAddTemplateChannel,
  useDefaultTemplates,
  useDeleteTemplate,
  useResetTemplate,
  useUpdateTemplate,
  type MessageTemplate,
  type TemplateChannel,
} from '../api';
import { DURATION_UNITS, type DurationUnit } from '../schemas';
import {
  MAX_REMINDERS,
  draftFromRow,
  insertPlaceholder,
  reminderOffsetsOf,
  remindersError,
  remindersFromDrafts,
  remindersPatch,
  requiredPlaceholderText,
  isEmptyPatch,
  offsetDraftFrom,
  offsetError,
  patchFor,
  validateDraft,
  type ChannelDraft,
  type DraftErrors,
  type OffsetDraft,
} from '../templates/drafts';
import {
  BODY_LIMITS,
  CHANNEL_LABELS,
  missingRequiredPlaceholders,
  offsetFromInput,
  placeholdersFor,
  type TemplateKeyMeta,
} from '../templates/meta';
import { placeholdersIn, renderTemplate, smsSegments } from '../templates/render';

export interface TemplateEditorDialogProps {
  meta: TemplateKeyMeta;
  /** This key's rows (one per channel that exists). */
  rows: readonly MessageTemplate[];
  previewVars: Readonly<Record<string, string>>;
  canEdit: boolean;
  /** Free trial: an always-sent message (invite) goes out in the default wording (0124). */
  trialDefaultWording?: boolean;
  onClose: () => void;
}

const UNIT_LABELS: Record<DurationUnit, string> = {
  minutes: 'minutes',
  hours: 'hours',
  days: 'days',
};

export function TemplateEditorDialog({
  meta,
  rows,
  previewVars,
  canEdit,
  trialDefaultWording = false,
  onClose,
}: TemplateEditorDialogProps) {
  const toast = useToast();
  const update = useUpdateTemplate();
  const [channel, setChannel] = useState<TemplateChannel>(meta.channels[0] ?? 'sms');
  const [drafts, setDrafts] = useState<Partial<Record<TemplateChannel, ChannelDraft>>>({});
  const storedOffset = rows.find((r) => r.offset_minutes !== null)?.offset_minutes ?? null;
  const [offsetState, setOffsetState] = useState<OffsetDraft>(() => offsetDraftFrom(storedOffset));
  const storedReminders = reminderOffsetsOf(rows);
  const storedRemindersKey = storedReminders.join(',');
  const [reminderState, setReminderState] = useState<{ base: string; items: OffsetDraft[] }>(
    () => ({ base: storedRemindersKey, items: storedReminders.map(offsetDraftFrom) }),
  );
  const reminderDrafts =
    reminderState.base === storedRemindersKey
      ? reminderState.items
      : storedReminders.map(offsetDraftFrom);
  const setReminderDrafts = (items: OffsetDraft[]) =>
    setReminderState({ base: storedRemindersKey, items });
  const multi = meta.multipleReminders === true;
  const nextReminders = multi ? remindersFromDrafts(meta, reminderDrafts) : null;
  const remindersProblem = multi ? remindersError(meta, reminderDrafts) : undefined;
  const remindersChanged =
    multi && nextReminders !== null && nextReminders.join(',') !== storedRemindersKey;
  const [showErrors, setShowErrors] = useState(false);
  const [saving, setSaving] = useState(false);

  // Drafts started from an older version of a row (after reset/save) are dropped.
  const draftFor = (row: MessageTemplate): ChannelDraft => {
    const draft = drafts[row.channel];
    return draft && draft.base === row.updated_at ? draft : draftFromRow(row);
  };
  const offsetDraft =
    offsetState.base === storedOffset ? offsetState : offsetDraftFrom(storedOffset);

  const edit = (row: MessageTemplate, patch: Partial<ChannelDraft>) =>
    setDrafts((prev) => ({ ...prev, [row.channel]: { ...draftFor(row), ...patch } }));

  const nextOffset =
    meta.timing && !multi ? offsetFromInput(meta, offsetDraft.value, offsetDraft.unit) : null;
  const offsetChanged =
    meta.timing !== undefined && !multi && nextOffset !== null && nextOffset !== storedOffset;
  const offsetProblem = multi ? remindersProblem : offsetError(meta, offsetDraft);
  const changed = rows.filter((row) => !isEmptyPatch(patchFor(row, draftFor(row))));
  const dirty =
    changed.length > 0 ||
    offsetChanged ||
    remindersChanged ||
    (meta.timing !== undefined && offsetProblem !== undefined);

  const save = async () => {
    const invalid = rows.some(
      (row) => Object.keys(validateDraft(row.channel, draftFor(row), meta)).length > 0,
    );
    if (invalid || offsetProblem) {
      setShowErrors(true);
      const firstBad = rows.find(
        (row) => Object.keys(validateDraft(row.channel, draftFor(row), meta)).length > 0,
      );
      if (firstBad) setChannel(firstBad.channel);
      return;
    }
    setSaving(true);
    try {
      let offsetSaved = !offsetChanged && !remindersChanged;
      for (const row of rows) {
        const patch = patchFor(row, draftFor(row));
        if (!offsetSaved) {
          // One row carries the schedule; the server copies it to the other channel.
          if (remindersChanged && nextReminders)
            Object.assign(patch, remindersPatch(nextReminders));
          else patch.offset_minutes = nextOffset;
          offsetSaved = true;
        }
        if (!isEmptyPatch(patch)) await update.mutateAsync({ id: row.id, patch });
      }
      toast.success(`${meta.label} saved`);
      onClose();
    } catch (error) {
      toast.error(toAppError(error));
    } finally {
      setSaving(false);
    }
  };

  const items = meta.channels.map((ch) => {
    const row = rows.find((r) => r.channel === ch);
    return {
      value: ch,
      label: (
        <span className="inline-flex items-center gap-1.5">
          {CHANNEL_LABELS[ch]}
          {row && !draftFor(row).enabled && <span className="text-muted text-xs">(off)</span>}
        </span>
      ),
      content: row ? (
        <ChannelEditor
          key={row.id}
          row={row}
          draft={draftFor(row)}
          errors={showErrors ? validateDraft(row.channel, draftFor(row), meta) : {}}
          onChange={(patch) => edit(row, patch)}
          previewVars={previewVars}
          meta={meta}
          canEdit={canEdit}
          trialDefaultWording={trialDefaultWording}
        />
      ) : (
        <MissingChannel meta={meta} channel={ch} canEdit={canEdit} offset={storedOffset} />
      ),
    };
  });

  return (
    <Dialog
      open
      onClose={onClose}
      dismissible={!saving}
      size="xl"
      title={meta.label}
      description={meta.description}
      footer={
        <>
          <Button variant="secondary" onClick={onClose} disabled={saving}>
            {canEdit ? 'Cancel' : 'Close'}
          </Button>
          {canEdit && rows.length > 0 && (
            <Button loading={saving} disabled={!dirty} onClick={() => void save()}>
              Save changes
            </Button>
          )}
        </>
      }
    >
      <div className="flex flex-col gap-4">
        {meta.timing && !multi && (
          <fieldset disabled={!canEdit} className="flex min-w-0 flex-col gap-1.5">
            <legend className="text-ink mb-1.5 text-sm font-medium">When to send</legend>
            <div className="flex flex-wrap items-center gap-2">
              <div className="w-24 shrink-0">
                <Input
                  aria-label="Send timing amount"
                  inputMode="numeric"
                  value={offsetDraft.value}
                  aria-invalid={showErrors && offsetProblem ? true : undefined}
                  onChange={(event) =>
                    setOffsetState({ ...offsetDraft, value: event.target.value })
                  }
                />
              </div>
              <Select
                aria-label="Send timing unit"
                className="w-32"
                value={offsetDraft.unit}
                options={DURATION_UNITS.map((u) => ({ value: u, label: UNIT_LABELS[u] }))}
                onChange={(event) => {
                  const unit = DURATION_UNITS.find((u) => u === event.target.value);
                  if (unit) setOffsetState({ ...offsetDraft, unit });
                }}
              />
              <span className="text-muted text-sm">
                {meta.timing.direction === 'before_start'
                  ? 'before the appointment starts'
                  : 'after the job is completed'}
              </span>
            </div>
            {offsetProblem && (showErrors || offsetDraft.value.trim() !== '') ? (
              <p role="alert" className="text-danger-ink text-xs font-medium">
                {offsetProblem}
              </p>
            ) : (
              <p className="text-muted text-xs">Applies to both the text and the email.</p>
            )}
          </fieldset>
        )}
        {meta.timing && multi && (
          <fieldset disabled={!canEdit} className="flex min-w-0 flex-col gap-2">
            <legend className="text-ink mb-1.5 text-sm font-medium">When to send</legend>
            <ul className="flex flex-col gap-2">
              {reminderDrafts.map((draft, index) => (
                <li key={index} className="flex flex-wrap items-center gap-2">
                  <div className="w-24 shrink-0">
                    <Input
                      aria-label={`Reminder ${index + 1} amount`}
                      inputMode="numeric"
                      value={draft.value}
                      aria-invalid={showErrors && remindersProblem ? true : undefined}
                      onChange={(event) =>
                        setReminderDrafts(
                          reminderDrafts.map((d, i) =>
                            i === index ? { ...d, value: event.target.value } : d,
                          ),
                        )
                      }
                    />
                  </div>
                  <Select
                    aria-label={`Reminder ${index + 1} unit`}
                    className="w-32"
                    value={draft.unit}
                    options={DURATION_UNITS.map((u) => ({ value: u, label: UNIT_LABELS[u] }))}
                    onChange={(event) => {
                      const unit = DURATION_UNITS.find((u) => u === event.target.value);
                      if (unit) {
                        setReminderDrafts(
                          reminderDrafts.map((d, i) => (i === index ? { ...d, unit } : d)),
                        );
                      }
                    }}
                  />
                  <span className="text-muted text-sm">before the appointment starts</span>
                  {reminderDrafts.length > 1 && canEdit && (
                    <IconButton
                      label={`Remove reminder ${index + 1}`}
                      variant="ghost"
                      size="sm"
                      icon={<X aria-hidden="true" />}
                      onClick={() =>
                        setReminderDrafts(reminderDrafts.filter((_, i) => i !== index))
                      }
                    />
                  )}
                </li>
              ))}
            </ul>
            {canEdit && reminderDrafts.length < MAX_REMINDERS && (
              <div>
                <Button
                  variant="ghost"
                  size="sm"
                  leadingIcon={<Plus className="size-4" aria-hidden="true" />}
                  onClick={() =>
                    setReminderDrafts([...reminderDrafts, { base: null, value: '', unit: 'hours' }])
                  }
                >
                  Add another reminder
                </Button>
              </div>
            )}
            {remindersProblem &&
            (showErrors || reminderDrafts.some((d) => d.value.trim() !== '')) ? (
              <p role="alert" className="text-danger-ink text-xs font-medium">
                {remindersProblem}
              </p>
            ) : (
              <p className="text-muted text-xs">
                Up to {MAX_REMINDERS} reminders, e.g. 2 days and 2 hours before. They apply to both
                the text and the email; a customer never gets two at once.
              </p>
            )}
          </fieldset>
        )}
        {meta.timingNote && <p className="text-muted text-sm">{meta.timingNote}</p>}
        <Tabs label="Message channel" items={items} value={channel} onChange={setChannel} />
      </div>
    </Dialog>
  );
}

function ChannelEditor({
  row,
  draft,
  errors,
  onChange,
  previewVars,
  meta,
  canEdit,
  trialDefaultWording,
}: {
  row: MessageTemplate;
  draft: ChannelDraft;
  errors: DraftErrors;
  onChange: (patch: Partial<ChannelDraft>) => void;
  previewVars: Readonly<Record<string, string>>;
  meta: TemplateKeyMeta;
  canEdit: boolean;
  trialDefaultWording: boolean;
}) {
  const toast = useToast();
  const bodyRef = useRef<HTMLTextAreaElement>(null);
  const reset = useResetTemplate();
  const remove = useDeleteTemplate();
  const [confirm, setConfirm] = useState<'reset' | 'remove' | null>(null);
  const isSms = row.channel === 'sms';
  const placeholders = placeholdersFor(meta.key);
  const known = new Set(placeholders.map((p) => p.name));
  const unknown = placeholdersIn(`${draft.subject}\n${draft.body}`).filter((n) => !known.has(n));
  // Wording that is on but leaves out a required placeholder is never sent
  // (the server uses the default wording); say so as it is typed.
  const missing = draft.enabled ? missingRequiredPlaceholders(meta, draft.body) : [];
  const defaultSent = meta.alwaysSent === true && (!draft.enabled || missing.length > 0);
  const preview = renderTemplate(draft.body, previewVars);
  const previewSubject = renderTemplate(draft.subject, previewVars);
  const segments = smsSegments(preview);

  const insert = (name: string) => {
    const el = bodyRef.current;
    const start = el?.selectionStart ?? draft.body.length;
    const end = el?.selectionEnd ?? draft.body.length;
    const next = insertPlaceholder(draft.body, name, start, end);
    onChange({ body: next.text });
    requestAnimationFrame(() => {
      if (!bodyRef.current) return;
      bodyRef.current.focus();
      bodyRef.current.setSelectionRange(next.caret, next.caret);
    });
  };

  return (
    <div className="grid gap-4 lg:grid-cols-[minmax(0,1fr)_minmax(0,1fr)]">
      <fieldset disabled={!canEdit} className="flex min-w-0 flex-col gap-4">
        <legend className="sr-only">{CHANNEL_LABELS[row.channel]} wording</legend>
        <Switch
          label={meta.alwaysSent ? 'Use this wording' : `Send the ${isSms ? 'text' : 'email'}`}
          description={
            meta.alwaysSent
              ? 'Invitations are always emailed. Turn off to send the default wording instead.'
              : 'Turn off to stop sending this message on this channel.'
          }
          checked={draft.enabled}
          onCheckedChange={(enabled) => onChange({ enabled })}
          disabled={!canEdit}
        />
        {!isSms && (
          <FormField label="Subject" required error={errors.subject}>
            <Input
              maxLength={200}
              value={draft.subject}
              onChange={(event) => onChange({ subject: event.target.value })}
            />
          </FormField>
        )}
        <FormField
          label="Message"
          required
          error={errors.body}
          help={
            isSms
              ? `${draft.body.length.toLocaleString('en-US')} / ${BODY_LIMITS.sms.toLocaleString('en-US')} characters · about ${segments.segments} text${segments.segments === 1 ? '' : 's'} when sent${segments.unicode ? ' (special characters use shorter texts)' : ''}`
              : `${draft.body.length.toLocaleString('en-US')} / ${BODY_LIMITS.email.toLocaleString('en-US')} characters`
          }
        >
          <Textarea
            ref={bodyRef}
            rows={isSms ? 5 : 10}
            value={draft.body}
            onChange={(event) => onChange({ body: event.target.value })}
          />
        </FormField>
        {canEdit && (
          <div>
            <p className="text-ink mb-1.5 text-sm font-medium" id={`chips-${row.id}`}>
              Insert a placeholder
            </p>
            <div
              role="group"
              aria-labelledby={`chips-${row.id}`}
              className="flex flex-wrap gap-1.5"
            >
              {placeholders.map((p) => (
                <button
                  key={p.name}
                  type="button"
                  onClick={() => insert(p.name)}
                  title={`Insert {{${p.name}}}`}
                  className="border-line bg-surface-2 text-ink hover:bg-surface-3 focus-visible:outline-primary rounded-full border px-2.5 py-1 text-xs font-medium focus-visible:outline-2 focus-visible:outline-offset-2"
                >
                  {p.label}
                </button>
              ))}
            </div>
          </div>
        )}
        {missing.length > 0 && !errors.body && (
          <p
            role="note"
            className="bg-warning-soft text-warning-ink rounded-control px-3 py-2 text-xs"
          >
            {requiredPlaceholderText(missing)}
          </p>
        )}
        {unknown.length > 0 && (
          <p
            role="note"
            className="bg-warning-soft text-warning-ink rounded-control px-3 py-2 text-xs"
          >
            Unknown placeholder{unknown.length === 1 ? '' : 's'}{' '}
            {unknown.map((n) => `{{${n}}}`).join(', ')} will be left blank when sent.
          </p>
        )}
        {canEdit && (
          <div className="flex flex-wrap gap-2">
            <Button
              variant="ghost"
              size="sm"
              leadingIcon={<RotateCcw className="size-4" aria-hidden="true" />}
              onClick={() => setConfirm('reset')}
            >
              Reset to default wording
            </Button>
            {meta.channels.length > 1 && (
              <Button
                variant="ghost"
                size="sm"
                leadingIcon={<Trash2 className="size-4" aria-hidden="true" />}
                onClick={() => setConfirm('remove')}
              >
                Remove {isSms ? 'text' : 'email'} version
              </Button>
            )}
          </div>
        )}
      </fieldset>

      <section aria-label="Preview" className="flex min-w-0 flex-col gap-2">
        <h3 className="text-ink text-sm font-medium">Preview</h3>
        {meta.alwaysSent && trialDefaultWording ? (
          <p className="text-muted text-xs">
            Not what’s sent yet: during your free trial, invitations use the default wording.
          </p>
        ) : (
          defaultSent && (
            <p className="text-muted text-xs">
              Not what’s sent: while this wording is{' '}
              {draft.enabled ? 'missing the invitation link' : 'off'}, invitations use the default
              wording.
            </p>
          )
        )}
        <div className="border-line bg-surface-2 rounded-card flex flex-col gap-2 border p-3">
          {!isSms && (
            <p className="text-ink border-line border-b pb-2 text-sm font-semibold break-words">
              {previewSubject || <span className="text-muted font-normal">No subject</span>}
            </p>
          )}
          <p
            className={
              isSms
                ? 'bg-primary text-primary-fg max-w-[85%] self-start rounded-2xl rounded-bl-sm px-3 py-2 text-sm break-words whitespace-pre-wrap'
                : 'text-ink text-sm break-words whitespace-pre-wrap'
            }
          >
            {preview || <span className="text-muted">Nothing to preview yet.</span>}
          </p>
        </div>
        <p className="text-muted text-xs">
          Your shop’s details are filled in. [Bracketed] values are replaced with each customer’s
          and job’s details when the message is sent.
        </p>
      </section>

      <ConfirmDialog
        open={confirm === 'reset'}
        onClose={() => setConfirm(null)}
        title="Reset to the default wording?"
        description="Replaces this version’s subject, message, on/off setting and timing with the original defaults."
        confirmLabel="Reset"
        loading={reset.isPending}
        onConfirm={async () => {
          try {
            await reset.mutateAsync(row.id);
            toast.success('Default wording restored');
            setConfirm(null);
          } catch (error) {
            toast.error(error);
          }
        }}
      />
      <ConfirmDialog
        open={confirm === 'remove'}
        onClose={() => setConfirm(null)}
        tone="danger"
        title={`Remove the ${isSms ? 'text' : 'email'} version?`}
        description={`${meta.label} will no longer be sent by ${isSms ? 'text' : 'email'}. You can add it back later with the default wording.`}
        confirmLabel="Remove"
        loading={remove.isPending}
        onConfirm={async () => {
          try {
            await remove.mutateAsync(row.id);
            toast.success(`${isSms ? 'Text' : 'Email'} version removed`);
            setConfirm(null);
          } catch (error) {
            toast.error(error);
          }
        }}
      />
    </div>
  );
}

function MissingChannel({
  meta,
  channel,
  canEdit,
  offset,
}: {
  meta: TemplateKeyMeta;
  channel: TemplateChannel;
  canEdit: boolean;
  offset: number | null;
}) {
  const toast = useToast();
  const defaults = useDefaultTemplates(canEdit);
  const add = useAddTemplateChannel();
  const fallback = defaults.data?.find((d) => d.key === meta.key && d.channel === channel);
  const label = channel === 'sms' ? 'text' : 'email';

  return (
    <EmptyState
      compact
      title={`No ${label} version`}
      description={`${meta.label} isn’t sent by ${label}.`}
      action={
        canEdit && (
          <Button
            variant="secondary"
            leadingIcon={<Plus className="size-4" aria-hidden="true" />}
            loading={add.isPending || defaults.isPending}
            disabled={!fallback}
            onClick={() => {
              if (!fallback) return;
              add.mutate(
                {
                  key: meta.key,
                  channel,
                  subject: channel === 'email' ? fallback.subject : null,
                  body: fallback.body,
                  offset_minutes: meta.timing ? (offset ?? fallback.offset_minutes) : null,
                },
                {
                  onSuccess: () =>
                    toast.success(`${channel === 'sms' ? 'Text' : 'Email'} version added`),
                  onError: (error) => toast.error(error),
                },
              );
            }}
          >
            Add {label} version
          </Button>
        )
      }
    />
  );
}
