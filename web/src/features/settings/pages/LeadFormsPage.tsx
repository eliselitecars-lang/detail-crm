import { zodResolver } from '@hookform/resolvers/zod';
import {
  Archive,
  ClipboardList,
  Code,
  ExternalLink,
  Pencil,
  Plus,
  QrCode as QrIcon,
} from 'lucide-react';
import { useState } from 'react';
import { Controller, useForm } from 'react-hook-form';
import { Link } from 'react-router';
import { z } from 'zod';
import {
  Badge,
  Button,
  buttonClasses,
  Card,
  Checkbox,
  ConfirmDialog,
  CopyField,
  Dialog,
  EmptyState,
  FormField,
  IconButton,
  Input,
  QrCode,
  SectionCard,
  Select,
  Switch,
  Textarea,
  useToast,
} from '@/components/ui';
import { useShop } from '@/features/shop/shopContext';
import { toAppError } from '@/lib/errors';
import { zOptionalText, zRequiredText } from '@/lib/validation';
import { EmbedSnippets } from '../components/EmbedSnippets';
import { QueryView, SettingsSectionLayout } from '../components/SettingsSectionLayout';
import { useCustomFields, type CustomField } from '../data/customFields';
import {
  leadFormUrl,
  useArchiveLeadForm,
  useLeadForms,
  useLeadSubmissionCounts,
  useSaveLeadForm,
  type CustomerSource,
  type LeadForm,
} from '../data/leadForms';
import { useSettingsAccess } from '../useSettingsAccess';

const SOURCES = [
  'other',
  'google',
  'facebook',
  'instagram',
  'referral',
  'walk_in',
] as const satisfies readonly CustomerSource[];

const SOURCE_LABELS: Record<(typeof SOURCES)[number], string> = {
  other: 'Other / website',
  google: 'Google',
  facebook: 'Facebook',
  instagram: 'Instagram',
  referral: 'Referral',
  walk_in: 'Walk-in',
};

export default function LeadFormsPage() {
  const { readOnly, canEdit } = useSettingsAccess();
  const forms = useLeadForms();
  const fields = useCustomFields('customer');
  const counts = useLeadSubmissionCounts(forms.data?.map((f) => f.id) ?? []);
  const [editing, setEditing] = useState<{ form: LeadForm | null } | null>(null);

  return (
    <SettingsSectionLayout
      section="lead-forms"
      readOnly={readOnly}
      actions={
        canEdit && (
          <Button
            leadingIcon={<Plus className="size-4" aria-hidden="true" />}
            onClick={() => setEditing({ form: null })}
          >
            New form
          </Button>
        )
      }
    >
      <p className="text-muted text-sm">
        Put a contact form on your website, social profiles or a flyer (QR code). Each submission
        adds a lead to your customer list — or is linked to the existing customer with the same
        email or phone, without changing their details — and can notify your managers. Promotional
        texts and emails need the consent the person ticks on the form.
      </p>
      <QueryView query={forms} label="lead forms">
        {(rows) =>
          rows.length === 0 ? (
            <Card>
              <EmptyState
                icon={<ClipboardList aria-hidden="true" />}
                title="No lead forms yet"
                description="Create a form to collect enquiries from your website."
                action={
                  canEdit && (
                    <Button variant="secondary" onClick={() => setEditing({ form: null })}>
                      New form
                    </Button>
                  )
                }
              />
            </Card>
          ) : (
            <ul className="flex flex-col gap-4">
              {rows.map((form) => (
                <li key={form.id}>
                  <FormCard
                    form={form}
                    fields={fields.data ?? []}
                    submissions={counts.data?.get(form.id) ?? null}
                    canEdit={canEdit}
                    onEdit={() => setEditing({ form })}
                  />
                </li>
              ))}
            </ul>
          )
        }
      </QueryView>
      {editing && (
        <QueryView query={fields} label="customer fields">
          {(customerFields) => (
            <FormDialog
              form={editing.form}
              fields={customerFields}
              onClose={() => setEditing(null)}
            />
          )}
        </QueryView>
      )}
    </SettingsSectionLayout>
  );
}

function FormCard({
  form,
  fields,
  submissions,
  canEdit,
  onEdit,
}: {
  form: LeadForm;
  fields: readonly CustomField[];
  submissions: number | null;
  canEdit: boolean;
  onEdit: () => void;
}) {
  const { shop } = useShop();
  const toast = useToast();
  const archive = useArchiveLeadForm();
  const [panel, setPanel] = useState<'qr' | 'embed' | null>(null);
  const [confirmArchive, setConfirmArchive] = useState(false);
  const url = leadFormUrl(form.token);
  const byId = new Map(fields.map((f) => [f.id, f]));
  const asked = form.field_ids
    .map((id) => byId.get(id))
    .filter((f): f is CustomField => f !== undefined && !f.archived_at)
    .map((f) => f.label);
  const extras = [
    'Name, email, phone',
    form.ask_vehicle ? 'vehicle' : null,
    form.ask_message ? 'message' : null,
    ...asked,
  ].filter(Boolean);

  return (
    <SectionCard
      title={form.name}
      description={`Asks: ${extras.join(', ')}`}
      actions={
        <span className="flex items-center gap-1">
          <Badge tone={form.active ? 'success' : 'neutral'} dot>
            {form.active ? 'Live' : 'Off'}
          </Badge>
          {canEdit && (
            <>
              <IconButton
                label={`Edit ${form.name}`}
                icon={<Pencil />}
                size="sm"
                onClick={onEdit}
              />
              <IconButton
                label={`Archive ${form.name}`}
                icon={<Archive />}
                size="sm"
                onClick={() => setConfirmArchive(true)}
              />
            </>
          )}
        </span>
      }
    >
      <div className="flex flex-col gap-3">
        <CopyField
          value={url}
          label={`Link to ${form.name}`}
          copiedMessage="Form link copied"
          actions={
            <>
              <Button
                variant="ghost"
                leadingIcon={<QrIcon className="size-4" aria-hidden="true" />}
                aria-expanded={panel === 'qr'}
                onClick={() => setPanel(panel === 'qr' ? null : 'qr')}
              >
                QR code
              </Button>
              <Button
                variant="ghost"
                leadingIcon={<Code className="size-4" aria-hidden="true" />}
                aria-expanded={panel === 'embed'}
                onClick={() => setPanel(panel === 'embed' ? null : 'embed')}
              >
                Embed
              </Button>
              <a
                href={url}
                target="_blank"
                rel="noreferrer"
                className={buttonClasses({ variant: 'ghost' })}
              >
                <ExternalLink className="size-4" aria-hidden="true" />
                Open
                <span className="sr-only"> {form.name} in a new tab</span>
              </a>
            </>
          }
        />
        {panel === 'qr' && (
          <QrCode
            value={url}
            label={`QR code for the lead form ${form.name}`}
            fileName={`${shop.slug}-${form.name}`}
          />
        )}
        {panel === 'embed' && (
          <EmbedSnippets target={{ slug: shop.slug, leadToken: form.token }} title={form.name} />
        )}
        <p className="text-muted text-xs">
          {submissions === null
            ? 'Submissions: —'
            : `${submissions.toLocaleString('en-US')} submission${submissions === 1 ? '' : 's'} in the last 30 days`}
          {' · '}
          {form.notify_staff ? 'Managers are notified' : 'No notification'}
          {' · '}
          {form.auto_reply ? (
            <>
              Auto-reply on (
              <Link
                className="text-primary underline"
                to="/app/settings/templates?edit=lead_received"
              >
                wording
              </Link>
              )
            </>
          ) : (
            'No auto-reply'
          )}
        </p>
      </div>
      <ConfirmDialog
        open={confirmArchive}
        onClose={() => setConfirmArchive(false)}
        tone="danger"
        title={`Archive ${form.name}?`}
        description="The link and embedded forms stop working. Leads it already created stay in your customer list."
        confirmLabel="Archive"
        loading={archive.isPending}
        onConfirm={async () => {
          try {
            await archive.mutateAsync(form.id);
            toast.success(`${form.name} archived`);
            setConfirmArchive(false);
          } catch (error) {
            toast.error(error);
          }
        }}
      />
    </SectionCard>
  );
}

const MAX_FIELDS = 30;

const formSchema = z.object({
  name: zRequiredText('Name', 120),
  headline: zOptionalText(200),
  intro: zOptionalText(2000),
  defaultSource: z.enum(SOURCES),
  fieldIds: z.array(z.string()).max(MAX_FIELDS, `Choose up to ${MAX_FIELDS} fields.`),
  askVehicle: z.boolean(),
  askMessage: z.boolean(),
  successMessage: zOptionalText(500),
  notifyStaff: z.boolean(),
  autoReply: z.boolean(),
  active: z.boolean(),
});
type FormInput = z.input<typeof formSchema>;
type FormValues = z.output<typeof formSchema>;

function isSource(value: string): value is (typeof SOURCES)[number] {
  return (SOURCES as readonly string[]).includes(value);
}

function FormDialog({
  form,
  fields,
  onClose,
}: {
  form: LeadForm | null;
  fields: readonly CustomField[];
  onClose: () => void;
}) {
  const toast = useToast();
  const save = useSaveLeadForm();
  // Fields offered: live customer fields marked for lead forms, plus any the
  // form already asks (so they can be removed).
  const offered = fields.filter(
    (f) => !f.archived_at && (f.show_in_lead_form || form?.field_ids.includes(f.id)),
  );
  const offeredIds = new Set(offered.map((f) => f.id));
  const {
    register,
    control,
    handleSubmit,
    formState: { errors },
  } = useForm<FormInput, unknown, FormValues>({
    resolver: zodResolver(formSchema),
    defaultValues: {
      name: form?.name ?? '',
      headline: form?.headline ?? '',
      intro: form?.intro ?? '',
      defaultSource: form && isSource(form.default_source) ? form.default_source : 'other',
      fieldIds: (form?.field_ids ?? []).filter((id) => offeredIds.has(id)),
      askVehicle: form?.ask_vehicle ?? true,
      askMessage: form?.ask_message ?? true,
      successMessage: form?.success_message ?? '',
      notifyStaff: form?.notify_staff ?? true,
      autoReply: form?.auto_reply ?? false,
      active: form?.active ?? true,
    },
  });

  const onSubmit = handleSubmit(async (v) => {
    try {
      await save.mutateAsync({
        id: form?.id,
        name: v.name,
        headline: v.headline,
        intro: v.intro,
        default_source: v.defaultSource,
        field_ids: v.fieldIds,
        ask_vehicle: v.askVehicle,
        ask_message: v.askMessage,
        success_message: v.successMessage,
        notify_staff: v.notifyStaff,
        auto_reply: v.autoReply,
        active: v.active,
      });
      toast.success(form ? 'Form saved' : 'Form created');
      onClose();
    } catch (error) {
      toast.error(toAppError(error));
    }
  });

  const formId = 'lead-form-form';
  return (
    <Dialog
      open
      onClose={onClose}
      dismissible={!save.isPending}
      size="lg"
      title={form ? `Edit ${form.name}` : 'New lead form'}
      footer={
        <>
          <Button variant="secondary" onClick={onClose} disabled={save.isPending}>
            Cancel
          </Button>
          <Button type="submit" form={formId} loading={save.isPending}>
            {form ? 'Save' : 'Create form'}
          </Button>
        </>
      }
    >
      <form
        id={formId}
        noValidate
        onSubmit={(e) => void onSubmit(e)}
        className="grid gap-4 sm:grid-cols-2"
      >
        <FormField
          label="Name"
          required
          error={errors.name?.message}
          help="For you, e.g. Website contact."
        >
          <Input maxLength={120} autoComplete="off" {...register('name')} />
        </FormField>
        <FormField
          label="Lead source"
          error={errors.defaultSource?.message}
          help="Recorded on new leads from this form."
        >
          <Select
            options={SOURCES.map((s) => ({ value: s, label: SOURCE_LABELS[s] }))}
            {...register('defaultSource')}
          />
        </FormField>
        <FormField
          label="Heading"
          error={errors.headline?.message}
          help="Optional, e.g. Get a free quote."
          className="sm:col-span-2"
        >
          <Input maxLength={200} {...register('headline')} />
        </FormField>
        <FormField
          label="Introduction"
          error={errors.intro?.message}
          help="Optional text above the form."
          className="sm:col-span-2"
        >
          <Textarea rows={2} maxLength={2000} {...register('intro')} />
        </FormField>
        <fieldset className="flex flex-col gap-2 sm:col-span-2">
          <legend className="text-ink mb-1 text-sm font-medium">Questions</legend>
          <p className="text-muted text-xs">
            Name, email and phone are always asked. Add customer fields in Settings → Custom fields
            (with “Offer on lead forms” on).
          </p>
          <div className="flex flex-wrap gap-x-6 gap-y-2">
            <Controller
              control={control}
              name="askVehicle"
              render={({ field }) => (
                <Checkbox
                  label="Vehicle (year, make, model)"
                  checked={field.value}
                  onChange={(e) => field.onChange(e.target.checked)}
                />
              )}
            />
            <Controller
              control={control}
              name="askMessage"
              render={({ field }) => (
                <Checkbox
                  label="Message"
                  checked={field.value}
                  onChange={(e) => field.onChange(e.target.checked)}
                />
              )}
            />
          </div>
          <Controller
            control={control}
            name="fieldIds"
            render={({ field }) =>
              offered.length === 0 ? (
                <p className="text-muted text-sm">
                  No customer fields are offered on lead forms yet.
                </p>
              ) : (
                <ul className="flex flex-col gap-2" aria-label="Customer fields to ask">
                  {offered.map((f) => (
                    <li key={f.id}>
                      <Checkbox
                        label={f.label}
                        description={f.required ? 'Required' : undefined}
                        checked={field.value.includes(f.id)}
                        onChange={(e) =>
                          field.onChange(
                            e.target.checked
                              ? [...field.value, f.id]
                              : field.value.filter((id) => id !== f.id),
                          )
                        }
                      />
                    </li>
                  ))}
                </ul>
              )
            }
          />
          {errors.fieldIds?.message && (
            <p role="alert" className="text-danger-ink text-xs font-medium">
              {errors.fieldIds.message}
            </p>
          )}
        </fieldset>
        <FormField
          label="Thank-you message"
          error={errors.successMessage?.message}
          help="Shown after sending. Leave empty for a standard message."
          className="sm:col-span-2"
        >
          <Input maxLength={500} {...register('successMessage')} />
        </FormField>
        <div className="flex flex-col gap-3 sm:col-span-2">
          <Controller
            control={control}
            name="notifyStaff"
            render={({ field }) => (
              <Switch
                label="Notify managers"
                description="Owners, admins and managers get a notification for each new lead."
                checked={field.value}
                onCheckedChange={field.onChange}
              />
            )}
          />
          <Controller
            control={control}
            name="autoReply"
            render={({ field }) => (
              <Switch
                label="Send an auto-reply"
                description="Sends the “Lead received” message by text and/or email (each channel that’s on in Messages & automations)."
                checked={field.value}
                onCheckedChange={field.onChange}
              />
            )}
          />
          <Controller
            control={control}
            name="active"
            render={({ field }) => (
              <Switch
                label="Form is on"
                description="Off: the link shows that the form isn’t available."
                checked={field.value}
                onCheckedChange={field.onChange}
              />
            )}
          />
        </div>
      </form>
    </Dialog>
  );
}
