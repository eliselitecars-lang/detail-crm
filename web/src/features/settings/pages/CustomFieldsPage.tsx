import { zodResolver } from '@hookform/resolvers/zod';
import {
  Archive,
  ArchiveRestore,
  ArrowDown,
  ArrowUp,
  ListPlus,
  Pencil,
  Plus,
  Trash2,
} from 'lucide-react';
import { useMemo, useState } from 'react';
import { Controller, useForm, useWatch } from 'react-hook-form';
import { z } from 'zod';
import {
  Badge,
  Button,
  Card,
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
import { CustomFieldInputs } from '@/components/customFields';
import {
  CUSTOM_FIELD_LIMITS,
  CUSTOM_FIELD_TYPE_LABELS,
  CUSTOM_FIELD_TYPES,
  customFieldOptionsProblem,
  parseOptionLines,
  suggestFieldKey,
  type CustomFieldDraft,
  type CustomFieldEntity,
} from '@/lib/customFields';
import { toAppError } from '@/lib/errors';
import { zOptionalText, zRequiredText } from '@/lib/validation';
import { QueryView, SettingsSectionLayout } from '../components/SettingsSectionLayout';
import {
  toFieldDef,
  useArchiveCustomField,
  useCustomFields,
  useDeleteCustomField,
  useReorderCustomFields,
  useSaveCustomField,
  type CustomField,
} from '../data/customFields';
import { moveItem, nextSortPosition } from '../reorder';
import { useSettingsAccess } from '../useSettingsAccess';

const ENTITY_LABELS: Record<CustomFieldEntity, string> = {
  customer: 'Customer fields',
  job: 'Job fields & booking questions',
};

const SCOPE_OPTIONS = [
  { value: '', label: 'Every booking' },
  { value: 'mobile', label: 'Mobile bookings only' },
  { value: 'shop', label: 'In-shop bookings only' },
];

export default function CustomFieldsPage() {
  const { readOnly, canEdit } = useSettingsAccess();
  const [entity, setEntity] = useState<CustomFieldEntity>('customer');
  return (
    <SettingsSectionLayout section="custom-fields" readOnly={readOnly}>
      <Tabs
        label="Field type"
        value={entity}
        onChange={setEntity}
        items={(['customer', 'job'] as const).map((value) => ({
          value,
          label: ENTITY_LABELS[value],
          content: <EntityFields key={value} entity={value} canEdit={canEdit} />,
        }))}
      />
    </SettingsSectionLayout>
  );
}

function EntityFields({ entity, canEdit }: { entity: CustomFieldEntity; canEdit: boolean }) {
  const toast = useToast();
  const query = useCustomFields(entity);
  const reorder = useReorderCustomFields();
  const archive = useArchiveCustomField();
  const remove = useDeleteCustomField();
  const [editing, setEditing] = useState<{ field: CustomField | null } | null>(null);
  const [deleting, setDeleting] = useState<CustomField | null>(null);
  const [preview, setPreview] = useState<CustomFieldDraft>({});

  const intro =
    entity === 'customer'
      ? 'Extra details you keep on every customer, like a referral source or a preferred contact time. Lead forms can ask them too.'
      : 'Extra details on jobs, like a gate code or where to park. Fields marked “Ask when booking” become questions on your online booking page.';

  return (
    <div className="flex flex-col gap-4 pt-4">
      <div className="flex flex-wrap items-start justify-between gap-3">
        <p className="text-muted max-w-2xl text-sm">{intro}</p>
        {canEdit && (
          <Button
            leadingIcon={<Plus className="size-4" aria-hidden="true" />}
            onClick={() => setEditing({ field: null })}
          >
            Add field
          </Button>
        )}
      </div>
      <QueryView query={query} label="custom fields">
        {(fields) => {
          const live = fields.filter((f) => !f.archived_at);
          const archived = fields.filter((f) => f.archived_at);
          const move = (index: number, delta: -1 | 1) =>
            reorder.mutate(moveItem(live, index, index + delta), {
              onError: (error) => toast.error(error),
            });
          if (fields.length === 0) {
            return (
              <Card>
                <EmptyState
                  icon={<ListPlus aria-hidden="true" />}
                  title="No fields yet"
                  description={
                    entity === 'customer'
                      ? 'Add a field to keep more details on your customers.'
                      : 'Add a field to keep more details on jobs or ask questions when customers book.'
                  }
                  action={
                    canEdit && (
                      <Button variant="secondary" onClick={() => setEditing({ field: null })}>
                        Add field
                      </Button>
                    )
                  }
                />
              </Card>
            );
          }
          return (
            <>
              <Card className="overflow-hidden">
                <ul className="divide-line divide-y" aria-label={ENTITY_LABELS[entity]}>
                  {live.map((field, index) => (
                    <FieldRow
                      key={field.id}
                      field={field}
                      canEdit={canEdit}
                      first={index === 0}
                      last={index === live.length - 1}
                      busy={reorder.isPending || archive.isPending}
                      onUp={() => move(index, -1)}
                      onDown={() => move(index, 1)}
                      onEdit={() => setEditing({ field })}
                      onArchive={() =>
                        archive.mutate(
                          { id: field.id, archived: true },
                          {
                            onSuccess: () => toast.success(`${field.label} archived`),
                            onError: (error) => toast.error(error),
                          },
                        )
                      }
                      onDelete={() => setDeleting(field)}
                    />
                  ))}
                  {live.length === 0 && (
                    <li className="text-muted px-4 py-3 text-sm">Every field is archived.</li>
                  )}
                </ul>
              </Card>
              {archived.length > 0 && (
                <Card className="overflow-hidden">
                  <p className="text-ink border-line border-b px-4 py-2 text-sm font-medium">
                    Archived
                  </p>
                  <ul className="divide-line divide-y">
                    {archived.map((field) => (
                      <li key={field.id} className="flex items-center gap-3 px-4 py-3">
                        <div className="min-w-0 flex-1">
                          <p className="text-muted text-sm">{field.label}</p>
                          <p className="text-subtle font-mono text-xs">{field.key}</p>
                        </div>
                        {canEdit && (
                          <Button
                            variant="ghost"
                            size="sm"
                            leadingIcon={<ArchiveRestore className="size-4" aria-hidden="true" />}
                            onClick={() =>
                              archive.mutate(
                                { id: field.id, archived: false },
                                {
                                  onSuccess: () => toast.success(`${field.label} restored`),
                                  onError: (error) => toast.error(error),
                                },
                              )
                            }
                          >
                            Restore<span className="sr-only"> {field.label}</span>
                          </Button>
                        )}
                      </li>
                    ))}
                  </ul>
                </Card>
              )}
              {live.length > 0 && (
                <Card className="p-4">
                  <h3 className="text-ink text-sm font-medium">Preview</h3>
                  <p className="text-muted mb-3 text-xs">
                    How the fields look when staff fill them in
                    {entity === 'job' ? ' (booking questions show on the booking page)' : ''}.
                  </p>
                  <CustomFieldInputs
                    fields={live.map(toFieldDef)}
                    value={preview}
                    onChange={setPreview}
                    showRequired
                    columns={2}
                  />
                </Card>
              )}
            </>
          );
        }}
      </QueryView>

      {editing && (
        <FieldDialog
          entity={entity}
          field={editing.field}
          nextSort={nextSortPosition(query.data ?? [])}
          onClose={() => setEditing(null)}
        />
      )}
      <ConfirmDialog
        open={deleting !== null}
        onClose={() => setDeleting(null)}
        tone="danger"
        title={`Delete the field ${deleting?.label ?? ''}?`}
        description="Only fields no customer or job has answered can be deleted. A field with saved answers can be archived instead: its answers are kept and it’s no longer asked."
        confirmLabel="Delete"
        loading={remove.isPending}
        onConfirm={async () => {
          if (!deleting) return;
          try {
            await remove.mutateAsync(deleting.id);
            toast.success(`${deleting.label} deleted`);
            setDeleting(null);
          } catch (error) {
            const appError = toAppError(error);
            toast.error(
              appError.code === '23514'
                ? 'This field has saved answers, so it can’t be deleted. Archive it instead.'
                : appError,
            );
            setDeleting(null);
          }
        }}
      />
    </div>
  );
}

function FieldRow({
  field,
  canEdit,
  first,
  last,
  busy,
  onUp,
  onDown,
  onEdit,
  onArchive,
  onDelete,
}: {
  field: CustomField;
  canEdit: boolean;
  first: boolean;
  last: boolean;
  busy: boolean;
  onUp: () => void;
  onDown: () => void;
  onEdit: () => void;
  onArchive: () => void;
  onDelete: () => void;
}) {
  return (
    <li className="flex flex-col gap-2 px-4 py-3 sm:flex-row sm:items-center">
      <div className="min-w-0 flex-1">
        <p className="text-ink text-sm font-medium">{field.label}</p>
        <p className="text-muted text-xs">
          <span className="font-mono">{field.key}</span> · {CUSTOM_FIELD_TYPE_LABELS[field.type]}
          {field.options.length > 0 && ` · ${field.options.join(', ')}`}
        </p>
        <div className="mt-1 flex flex-wrap gap-1">
          {field.required && <Badge tone="warning">Required</Badge>}
          {field.show_in_booking && (
            <Badge tone="info">
              Asked when booking
              {field.location_scope === 'mobile'
                ? ' (mobile)'
                : field.location_scope === 'shop'
                  ? ' (in shop)'
                  : ''}
            </Badge>
          )}
          {field.show_in_lead_form && <Badge tone="info">Lead forms</Badge>}
        </div>
      </div>
      {canEdit && (
        <div className="flex shrink-0 gap-1">
          <IconButton
            label={`Move ${field.label} up`}
            icon={<ArrowUp />}
            size="sm"
            disabled={first || busy}
            onClick={onUp}
          />
          <IconButton
            label={`Move ${field.label} down`}
            icon={<ArrowDown />}
            size="sm"
            disabled={last || busy}
            onClick={onDown}
          />
          <IconButton label={`Edit ${field.label}`} icon={<Pencil />} size="sm" onClick={onEdit} />
          <IconButton
            label={`Archive ${field.label}`}
            icon={<Archive />}
            size="sm"
            disabled={busy}
            onClick={onArchive}
          />
          <IconButton
            label={`Delete ${field.label}`}
            icon={<Trash2 />}
            size="sm"
            variant="danger"
            onClick={onDelete}
          />
        </div>
      )}
    </li>
  );
}

const fieldSchema = z
  .object({
    label: zRequiredText('Label', CUSTOM_FIELD_LIMITS.labelMax),
    key: z.string().trim(),
    type: z.enum(CUSTOM_FIELD_TYPES),
    optionsText: z.string(),
    helpText: zOptionalText(CUSTOM_FIELD_LIMITS.helpMax),
    required: z.boolean(),
    showInBooking: z.boolean(),
    showInLeadForm: z.boolean(),
    locationScope: z.enum(['', 'shop', 'mobile']),
  })
  .superRefine((v, ctx) => {
    if (!CUSTOM_FIELD_LIMITS.keyPattern.test(v.key)) {
      ctx.addIssue({
        code: 'custom',
        path: ['key'],
        message:
          'Use a lowercase letter first, then lowercase letters, numbers or _ (up to 40 characters).',
      });
    }
    const problem = customFieldOptionsProblem(v.type, parseOptionLines(v.optionsText));
    if (problem) ctx.addIssue({ code: 'custom', path: ['optionsText'], message: problem });
  });
type FieldFormInput = z.input<typeof fieldSchema>;
type FieldFormValues = z.output<typeof fieldSchema>;

function FieldDialog({
  entity,
  field,
  nextSort,
  onClose,
}: {
  entity: CustomFieldEntity;
  field: CustomField | null;
  nextSort: number;
  onClose: () => void;
}) {
  const toast = useToast();
  const save = useSaveCustomField();
  const [keyTouched, setKeyTouched] = useState(field !== null);
  const {
    register,
    control,
    handleSubmit,
    setValue,
    setError,
    formState: { errors },
  } = useForm<FieldFormInput, unknown, FieldFormValues>({
    resolver: zodResolver(fieldSchema),
    defaultValues: {
      label: field?.label ?? '',
      key: field?.key ?? '',
      type: field?.type ?? 'text',
      optionsText: field?.options.join('\n') ?? '',
      helpText: field?.help_text ?? '',
      required: field?.required ?? false,
      showInBooking: field?.show_in_booking ?? false,
      showInLeadForm: field?.show_in_lead_form ?? false,
      locationScope: field?.location_scope ?? '',
    },
  });
  const type = useWatch({ control, name: 'type' });
  const showInBooking = useWatch({ control, name: 'showInBooking' });
  const hasOptions = type === 'select' || type === 'multiselect';
  const typeOptions = useMemo(
    () => CUSTOM_FIELD_TYPES.map((t) => ({ value: t, label: CUSTOM_FIELD_TYPE_LABELS[t] })),
    [],
  );

  const onSubmit = handleSubmit(async (v) => {
    try {
      await save.mutateAsync({
        id: field?.id,
        entity,
        key: v.key,
        label: v.label,
        type: v.type,
        options: hasOptions ? parseOptionLines(v.optionsText) : [],
        help_text: v.helpText,
        required: v.required,
        show_in_booking: entity === 'job' && v.showInBooking,
        show_in_lead_form: entity === 'customer' && v.showInLeadForm,
        location_scope:
          entity === 'job' && v.showInBooking && v.locationScope !== '' ? v.locationScope : null,
        ...(field ? {} : { sort: nextSort }),
      });
      toast.success(field ? 'Field saved' : 'Field added');
      onClose();
    } catch (error) {
      const appError = toAppError(error);
      if (appError.message.includes('key')) {
        setError('key', { message: appError.message });
        return;
      }
      if (appError.code === '23514') {
        toast.error(
          'This field has saved answers, so its key and type can’t change. Archive it and add a new field instead.',
        );
        return;
      }
      toast.error(appError);
    }
  });

  const formId = 'custom-field-form';
  return (
    <Dialog
      open
      onClose={onClose}
      dismissible={!save.isPending}
      size="lg"
      title={
        field ? `Edit ${field.label}` : `New ${entity === 'customer' ? 'customer' : 'job'} field`
      }
      footer={
        <>
          <Button variant="secondary" onClick={onClose} disabled={save.isPending}>
            Cancel
          </Button>
          <Button type="submit" form={formId} loading={save.isPending}>
            {field ? 'Save' : 'Add field'}
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
        <FormField label="Label" required error={errors.label?.message} help="What people see.">
          <Input
            maxLength={CUSTOM_FIELD_LIMITS.labelMax}
            autoComplete="off"
            {...register('label', {
              onChange: (event: { target: { value: string } }) => {
                if (!keyTouched) setValue('key', suggestFieldKey(event.target.value));
              },
            })}
          />
        </FormField>
        <FormField
          label="Key"
          required
          error={errors.key?.message}
          help={
            field
              ? 'Used in imports and exports. It can only change while nothing is saved in the field.'
              : 'Used in imports and exports, e.g. gate_code.'
          }
        >
          <Input
            className="font-mono"
            maxLength={40}
            autoComplete="off"
            {...register('key', { onChange: () => setKeyTouched(true) })}
          />
        </FormField>
        <FormField
          label="Type"
          error={errors.type?.message}
          help={field ? 'Changes only while nothing is saved in the field.' : undefined}
        >
          <Select options={typeOptions} {...register('type')} />
        </FormField>
        <FormField
          label="Help text"
          error={errors.helpText?.message}
          help="Optional hint under the field."
        >
          <Input maxLength={CUSTOM_FIELD_LIMITS.helpMax} {...register('helpText')} />
        </FormField>
        {hasOptions && (
          <FormField
            label="Options"
            required
            error={errors.optionsText?.message}
            help="One per line, up to 50."
            className="sm:col-span-2"
          >
            <Textarea rows={4} {...register('optionsText')} />
          </FormField>
        )}
        <div className="flex flex-col gap-3 sm:col-span-2">
          <Controller
            control={control}
            name="required"
            render={({ field: f }) => (
              <Switch
                label="Required"
                description={
                  entity === 'job'
                    ? 'Customers must answer it when booking online. Staff can leave it empty.'
                    : 'People must answer it on lead forms. Staff can leave it empty.'
                }
                checked={f.value}
                onCheckedChange={f.onChange}
              />
            )}
          />
          {entity === 'job' ? (
            <>
              <Controller
                control={control}
                name="showInBooking"
                render={({ field: f }) => (
                  <Switch
                    label="Ask when booking"
                    description="Show it as a question on your online booking page."
                    checked={f.value}
                    onCheckedChange={f.onChange}
                  />
                )}
              />
              {showInBooking && (
                <FormField label="Ask on" className="max-w-xs">
                  <Select options={SCOPE_OPTIONS} {...register('locationScope')} />
                </FormField>
              )}
            </>
          ) : (
            <Controller
              control={control}
              name="showInLeadForm"
              render={({ field: f }) => (
                <Switch
                  label="Offer on lead forms"
                  description="Lets you add it to your website lead forms."
                  checked={f.value}
                  onCheckedChange={f.onChange}
                />
              )}
            />
          )}
        </div>
      </form>
    </Dialog>
  );
}
