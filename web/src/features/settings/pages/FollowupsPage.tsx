import { zodResolver } from '@hookform/resolvers/zod';
import { Pencil } from 'lucide-react';
import type { ComponentProps } from 'react';
import { Controller, useForm, useWatch, type Control, type UseFormRegister } from 'react-hook-form';
import { Link } from 'react-router';
import { z } from 'zod';
import {
  buttonClasses,
  FormField,
  Input,
  SectionCard,
  Select,
  Switch,
  useToast,
} from '@/components/ui';
import { FormFieldContext } from '@/components/ui/formFieldContext';
import { toAppError } from '@/lib/errors';
import {
  useMessageTemplates,
  useUpdateTemplate,
  type MessageTemplate,
  type TemplateKey,
} from '../api';
import { FormActions } from '../components/FormActions';
import { QueryView, SettingsSectionLayout } from '../components/SettingsSectionLayout';
import {
  useFollowupSettings,
  useUpdateFollowupSettings,
  type FollowupPatch,
  HOUR_UNITS,
  joinHours,
  splitHours,
  type FollowupSettings,
} from '../data/followups';
import { zIntText } from '../schemas';
import { useSettingsAccess } from '../useSettingsAccess';

/** The four document follow-ups and their template keys (0085). */
const KINDS = [
  {
    kind: 'quote',
    key: 'quote_reminder',
    title: 'Quotes waiting for an answer',
    description:
      'Reminds the customer about a quote you sent that they haven’t approved or declined. Stops when they answer, when the quote expires, or when you pause it on the quote.',
    firstLabel: 'First reminder after the quote is sent',
    unit: 'hours',
  },
  {
    kind: 'deposit',
    key: 'deposit_reminder',
    title: 'Unpaid deposits',
    description:
      'Reminds the customer to pay the deposit for an upcoming appointment. Stops when the deposit is paid, the appointment starts or is cancelled, or you pause it on the job.',
    firstLabel: 'First reminder after the appointment is booked',
    unit: 'hours',
  },
  {
    kind: 'invoice',
    key: 'invoice_reminder',
    title: 'Unpaid invoices (before the due date)',
    description:
      'Reminds the customer about a sent invoice that still has a balance. Stops when it’s paid or voided, or when you pause it on the invoice.',
    firstLabel: 'First reminder after the invoice is sent',
    unit: 'hours',
  },
  {
    kind: 'overdue',
    key: 'invoice_overdue',
    title: 'Past-due invoices',
    description:
      'Tells the customer an invoice is past its due date. Notices go out at 10:00 AM shop time on the days you choose.',
    firstLabel: 'First notice (days after the due date)',
    unit: 'days',
  },
] as const satisfies readonly {
  kind: 'quote' | 'deposit' | 'invoice' | 'overdue';
  key: TemplateKey;
  title: string;
  description: string;
  firstLabel: string;
  unit: 'hours' | 'days';
}[];

type Kind = (typeof KINDS)[number]['kind'];

const hoursBlock = z
  .object({
    enabled: z.boolean(),
    firstValue: z.string(),
    firstUnit: z.enum(HOUR_UNITS),
    repeatValue: z.string(),
    repeatUnit: z.enum(HOUR_UNITS),
    maxAttempts: zIntText('Number of reminders', 0, 10),
  })
  .superRefine((v, ctx) => {
    if (joinHours(v.firstValue, v.firstUnit) === null) {
      ctx.addIssue({
        code: 'custom',
        path: ['firstValue'],
        message: 'Enter a whole number from 1 hour to 90 days.',
      });
    }
    if (joinHours(v.repeatValue, v.repeatUnit) === null) {
      ctx.addIssue({
        code: 'custom',
        path: ['repeatValue'],
        message: 'Enter a whole number from 1 hour to 90 days.',
      });
    }
  });

const daysBlock = z.object({
  enabled: z.boolean(),
  firstValue: zIntText('Days after the due date', 0, 90),
  repeatValue: zIntText('Days between notices', 1, 90),
  maxAttempts: zIntText('Number of notices', 0, 10),
});

const followupsSchema = z.object({
  quote: hoursBlock,
  deposit: hoursBlock,
  invoice: hoursBlock,
  overdue: daysBlock,
});
type FollowupsInput = z.input<typeof followupsSchema>;
type FollowupsValues = z.output<typeof followupsSchema>;

function hoursInput(enabled: boolean, first: number, repeat: number, max: number) {
  const f = splitHours(first);
  const r = splitHours(repeat);
  return {
    enabled,
    firstValue: f.value,
    firstUnit: f.unit,
    repeatValue: r.value,
    repeatUnit: r.unit,
    maxAttempts: String(max),
  };
}

function toInput(s: FollowupSettings): FollowupsInput {
  return {
    quote: hoursInput(
      s.quote_enabled,
      s.quote_first_after_hours,
      s.quote_repeat_every_hours,
      s.quote_max_attempts,
    ),
    deposit: hoursInput(
      s.deposit_enabled,
      s.deposit_first_after_hours,
      s.deposit_repeat_every_hours,
      s.deposit_max_attempts,
    ),
    invoice: hoursInput(
      s.invoice_enabled,
      s.invoice_first_after_hours,
      s.invoice_repeat_every_hours,
      s.invoice_max_attempts,
    ),
    overdue: {
      enabled: s.overdue_enabled,
      firstValue: String(s.overdue_first_after_days),
      repeatValue: String(s.overdue_repeat_every_days),
      maxAttempts: String(s.overdue_max_attempts),
    },
  };
}

function toPatch(v: FollowupsValues): FollowupPatch {
  const hours = (b: FollowupsValues['quote']) => ({
    first: joinHours(b.firstValue, b.firstUnit) ?? 1,
    repeat: joinHours(b.repeatValue, b.repeatUnit) ?? 1,
  });
  const q = hours(v.quote);
  const d = hours(v.deposit);
  const i = hours(v.invoice);
  return {
    quote_enabled: v.quote.enabled,
    quote_first_after_hours: q.first,
    quote_repeat_every_hours: q.repeat,
    quote_max_attempts: v.quote.maxAttempts,
    deposit_enabled: v.deposit.enabled,
    deposit_first_after_hours: d.first,
    deposit_repeat_every_hours: d.repeat,
    deposit_max_attempts: v.deposit.maxAttempts,
    invoice_enabled: v.invoice.enabled,
    invoice_first_after_hours: i.first,
    invoice_repeat_every_hours: i.repeat,
    invoice_max_attempts: v.invoice.maxAttempts,
    overdue_enabled: v.overdue.enabled,
    overdue_first_after_days: v.overdue.firstValue,
    overdue_repeat_every_days: v.overdue.repeatValue,
    overdue_max_attempts: v.overdue.maxAttempts,
  };
}

export default function FollowupsPage() {
  const { readOnly, canEdit } = useSettingsAccess();
  const settings = useFollowupSettings();
  const templates = useMessageTemplates();
  return (
    <SettingsSectionLayout section="followups" readOnly={readOnly}>
      <QueryView query={settings} label="follow-up settings">
        {(row) => (
          <QueryView query={templates} label="message templates">
            {(rows) => (
              <FollowupsForm
                key={row.updated_at}
                settings={row}
                templates={rows}
                canEdit={canEdit}
              />
            )}
          </QueryView>
        )}
      </QueryView>
    </SettingsSectionLayout>
  );
}

function FollowupsForm({
  settings,
  templates,
  canEdit,
}: {
  settings: FollowupSettings;
  templates: readonly MessageTemplate[];
  canEdit: boolean;
}) {
  const toast = useToast();
  const update = useUpdateFollowupSettings();
  const updateTemplate = useUpdateTemplate();
  const {
    register,
    control,
    handleSubmit,
    reset,
    formState: { errors, isDirty },
  } = useForm<FollowupsInput, unknown, FollowupsValues>({
    resolver: zodResolver(followupsSchema),
    defaultValues: toInput(settings),
  });

  const onSubmit = handleSubmit(async (values) => {
    try {
      const saved = await update.mutateAsync(toPatch(values));
      // A follow-up needs at least one channel on: turning a kind on with every
      // channel off also turns its text and email on.
      let channelsOn = 0;
      for (const { kind, key } of KINDS) {
        if (!values[kind].enabled) continue;
        const rows = templates.filter((t) => t.key === key);
        if (rows.length === 0 || rows.some((t) => t.enabled)) continue;
        for (const row of rows) {
          await updateTemplate.mutateAsync({ id: row.id, patch: { enabled: true } });
          channelsOn += 1;
        }
      }
      reset(toInput(saved));
      toast.success(
        channelsOn > 0 ? 'Follow-ups saved and their messages turned on' : 'Follow-ups saved',
      );
    } catch (error) {
      toast.error(toAppError(error));
    }
  });

  return (
    <form onSubmit={(e) => void onSubmit(e)} noValidate className="flex flex-col gap-4">
      <p className="text-muted text-sm">
        Follow-ups go out by text and email (each channel that’s on in its message), never more than
        once per run, and stop as soon as they’re no longer needed. Customers who opted out of texts
        or emails don’t get them.
      </p>
      <fieldset disabled={!canEdit} className="flex min-w-0 flex-col gap-4">
        <legend className="sr-only">Automatic follow-ups</legend>
        {KINDS.map((meta) => (
          <KindCard
            key={meta.kind}
            meta={meta}
            control={control}
            register={register}
            errors={errors[meta.kind]}
            rows={templates.filter((t) => t.key === meta.key)}
            canEdit={canEdit}
          />
        ))}
      </fieldset>
      {canEdit && (
        <FormActions
          dirty={isDirty}
          saving={update.isPending || updateTemplate.isPending}
          onDiscard={() => reset(toInput(settings))}
        />
      )}
    </form>
  );
}

interface BlockErrors {
  firstValue?: { message?: string | undefined } | undefined;
  repeatValue?: { message?: string | undefined } | undefined;
  maxAttempts?: { message?: string | undefined } | undefined;
}

function KindCard({
  meta,
  control,
  register,
  errors,
  rows,
  canEdit,
}: {
  meta: (typeof KINDS)[number];
  control: Control<FollowupsInput, unknown, FollowupsValues>;
  register: UseFormRegister<FollowupsInput>;
  errors: BlockErrors | undefined;
  rows: readonly MessageTemplate[];
  canEdit: boolean;
}) {
  const kind: Kind = meta.kind;
  const hoursKind = kind === 'overdue' ? 'quote' : kind;
  const enabled = useWatch({ control, name: `${kind}.enabled` });
  const anyChannelOn = rows.some((r) => r.enabled);
  const channels = rows
    .map((r) => `${r.channel === 'sms' ? 'Text' : 'Email'} ${r.enabled ? 'on' : 'off'}`)
    .join(' · ');
  const unitOptions = HOUR_UNITS.map((u) => ({ value: u, label: u }));

  return (
    <SectionCard
      title={meta.title}
      description={meta.description}
      actions={
        <Link
          to={`/app/settings/templates?edit=${meta.key}`}
          className={buttonClasses({ variant: 'secondary', size: 'sm' })}
        >
          <Pencil className="size-4" aria-hidden="true" />
          {canEdit ? 'Edit wording' : 'View wording'}
        </Link>
      }
    >
      <div className="flex flex-col gap-4">
        <Controller
          control={control}
          name={`${kind}.enabled`}
          render={({ field }) => (
            <Switch
              label="Send automatically"
              description={
                channels ? `Message: ${channels}` : 'This message has no text or email version.'
              }
              checked={field.value}
              onCheckedChange={field.onChange}
              disabled={!canEdit}
            />
          )}
        />
        {enabled && !anyChannelOn && (
          <p
            role="note"
            className="bg-warning-soft text-warning-ink rounded-control px-3 py-2 text-xs"
          >
            Its text and email are both off. Saving turns them on, or choose one in the wording.
          </p>
        )}
        {enabled && (
          <div className="grid gap-4 sm:grid-cols-3">
            {meta.unit === 'hours' ? (
              <>
                <FormField label={meta.firstLabel} error={errors?.firstValue?.message}>
                  <div className="flex gap-2">
                    <Input
                      inputMode="numeric"
                      className="min-w-0 flex-1"
                      {...register(`${hoursKind}.firstValue`)}
                    />
                    <UnitSelect
                      aria-label="Unit for the first reminder"
                      className="w-24 shrink-0"
                      options={unitOptions}
                      {...register(`${hoursKind}.firstUnit`)}
                    />
                  </div>
                </FormField>
                <FormField label="Then every" error={errors?.repeatValue?.message}>
                  <div className="flex gap-2">
                    <Input
                      inputMode="numeric"
                      className="min-w-0 flex-1"
                      {...register(`${hoursKind}.repeatValue`)}
                    />
                    <UnitSelect
                      aria-label="Unit for the repeat"
                      className="w-24 shrink-0"
                      options={unitOptions}
                      {...register(`${hoursKind}.repeatUnit`)}
                    />
                  </div>
                </FormField>
              </>
            ) : (
              <>
                <FormField
                  label={meta.firstLabel}
                  error={errors?.firstValue?.message}
                  help="0 = on the due date itself."
                >
                  <Input inputMode="numeric" {...register('overdue.firstValue')} />
                </FormField>
                <FormField label="Then every (days)" error={errors?.repeatValue?.message}>
                  <Input inputMode="numeric" {...register('overdue.repeatValue')} />
                </FormField>
              </>
            )}
            <FormField
              label={meta.unit === 'days' ? 'Number of notices' : 'Number of reminders'}
              error={errors?.maxAttempts?.message}
              help="Up to 10. 0 sends none."
            >
              <Input inputMode="numeric" {...register(`${kind}.maxAttempts`)} />
            </FormField>
          </div>
        )}
      </div>
    </SectionCard>
  );
}

/**
 * The unit picker beside a number inside a FormField. It is a control of its
 * own (named by aria-label), so it must not take the field's id, error
 * description or invalid state, which belong to the number input.
 */
function UnitSelect(props: ComponentProps<typeof Select>) {
  return (
    <FormFieldContext value={null}>
      <Select {...props} />
    </FormFieldContext>
  );
}
