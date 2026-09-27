import { zodResolver } from '@hookform/resolvers/zod';
import { Eye, FileSignature, Pencil, Plus, Trash2 } from 'lucide-react';
import { useState } from 'react';
import { Controller, useForm } from 'react-hook-form';
import {
  Button,
  Card,
  ConfirmDialog,
  Dialog,
  EmptyState,
  FormField,
  IconButton,
  Input,
  RadioGroup,
  Switch,
  Table,
  Textarea,
  useToast,
  type Column,
} from '@/components/ui';
import {
  useDeleteFormTemplate,
  useFormTemplates,
  useSaveFormTemplate,
  type FormAttachTo,
  type FormTemplate,
} from '../api';
import { QueryView, SettingsSectionLayout } from '../components/SettingsSectionLayout';
import { formTemplateSchema, type FormTemplateValues } from '../schemas';
import { useSettingsAccess } from '../useSettingsAccess';

const ATTACH_LABELS: Record<FormAttachTo, string> = {
  all_jobs: 'Every job',
  online_booking: 'Online bookings',
  manual: 'Added by staff',
};

const ATTACH_OPTIONS = [
  {
    value: 'manual',
    label: 'Only when staff add it',
    description: 'Attach it to a job yourself when it applies.',
  },
  {
    value: 'online_booking',
    label: 'Every online booking',
    description: 'Sent automatically when a customer books online.',
  },
  {
    value: 'all_jobs',
    label: 'Every job',
    description: 'Attached to all new jobs, however they are created.',
  },
] as const;

type Editing = { form: FormTemplate | null } | null;

export default function FormsPage() {
  const { readOnly, canEdit } = useSettingsAccess();
  const query = useFormTemplates();
  const save = useSaveFormTemplate();
  const remove = useDeleteFormTemplate();
  const toast = useToast();
  const [editing, setEditing] = useState<Editing>(null);
  const [deleting, setDeleting] = useState<FormTemplate | null>(null);

  const columns: Column<FormTemplate>[] = [
    { key: 'name', header: 'Name', primary: true, cell: (f) => f.name },
    { key: 'attach', header: 'Attached to', cell: (f) => ATTACH_LABELS[f.attach_to] },
    {
      key: 'signature',
      header: 'Signature',
      cell: (f) => (f.requires_signature ? 'Required' : 'Not required'),
    },
    {
      key: 'active',
      header: 'In use',
      cell: (f) => (
        <Switch
          aria-label={`${f.name} in use`}
          checked={f.active}
          disabled={!canEdit || save.isPending}
          className="justify-end md:justify-start"
          onCheckedChange={(active) =>
            save.mutate(
              { id: f.id, active },
              {
                onSuccess: () => toast.success(`${f.name} ${active ? 'turned on' : 'turned off'}`),
                onError: (error) => toast.error(error),
              },
            )
          }
        />
      ),
    },
    ...(canEdit
      ? [
          {
            key: 'actions',
            header: <span className="sr-only">Actions</span>,
            align: 'right' as const,
            cell: (f: FormTemplate) => (
              <div className="flex justify-end gap-1">
                <IconButton
                  label={`Edit ${f.name}`}
                  icon={<Pencil />}
                  size="sm"
                  onClick={() => setEditing({ form: f })}
                />
                <IconButton
                  label={`Delete ${f.name}`}
                  icon={<Trash2 />}
                  size="sm"
                  variant="danger"
                  onClick={() => setDeleting(f)}
                />
              </div>
            ),
          },
        ]
      : [
          {
            key: 'actions',
            header: <span className="sr-only">Actions</span>,
            align: 'right' as const,
            cell: (f: FormTemplate) => (
              <IconButton
                label={`View ${f.name}`}
                icon={<Eye />}
                size="sm"
                onClick={() => setEditing({ form: f })}
              />
            ),
          },
        ]),
  ];

  return (
    <SettingsSectionLayout
      section="forms"
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
      <QueryView query={query} label="forms">
        {(forms) =>
          forms.length === 0 ? (
            <Card>
              <EmptyState
                icon={<FileSignature aria-hidden="true" />}
                title="No forms yet"
                description="Write waivers, pre-existing damage acknowledgements or coating care agreements for customers to sign."
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
            <Card className="overflow-hidden">
              <Table caption="Forms" columns={columns} rows={forms} getRowId={(f) => f.id} />
            </Card>
          )
        }
      </QueryView>
      {editing && (
        <FormTemplateDialog
          form={editing.form}
          readOnly={!canEdit}
          onClose={() => setEditing(null)}
        />
      )}
      <ConfirmDialog
        open={deleting !== null}
        onClose={() => setDeleting(null)}
        tone="danger"
        title={`Delete ${deleting?.name ?? 'form'}?`}
        description="Forms already sent or signed keep their text and signatures. To stop using it but keep it for later, turn it off instead."
        confirmLabel="Delete"
        loading={remove.isPending}
        onConfirm={async () => {
          if (!deleting) return;
          try {
            await remove.mutateAsync(deleting.id);
            toast.success(`${deleting.name} deleted`);
            setDeleting(null);
          } catch (error) {
            toast.error(error);
          }
        }}
      />
    </SettingsSectionLayout>
  );
}

function FormTemplateDialog({
  form,
  readOnly,
  onClose,
}: {
  form: FormTemplate | null;
  readOnly: boolean;
  onClose: () => void;
}) {
  const toast = useToast();
  const save = useSaveFormTemplate();
  const {
    register,
    control,
    handleSubmit,
    formState: { errors },
  } = useForm<FormTemplateValues>({
    resolver: zodResolver(formTemplateSchema),
    defaultValues: {
      name: form?.name ?? '',
      body: form?.body ?? '',
      requiresSignature: form?.requires_signature ?? true,
      attachTo: form?.attach_to ?? 'manual',
      active: form?.active ?? true,
    },
  });

  const onSubmit = handleSubmit(async (v) => {
    try {
      await save.mutateAsync({
        id: form?.id,
        name: v.name,
        body: v.body,
        requires_signature: v.requiresSignature,
        attach_to: v.attachTo,
        active: v.active,
      });
      toast.success(form ? 'Form saved' : 'Form created');
      onClose();
    } catch (error) {
      toast.error(error);
    }
  });

  const formId = 'form-template-form';
  return (
    <Dialog
      open
      onClose={onClose}
      dismissible={!save.isPending}
      size="xl"
      title={form ? (readOnly ? form.name : `Edit ${form.name}`) : 'New form'}
      description="Customers read this text and sign it on your device or from a link. Changes apply to forms sent from now on."
      footer={
        <>
          <Button variant="secondary" onClick={onClose} disabled={save.isPending}>
            {readOnly ? 'Close' : 'Cancel'}
          </Button>
          {!readOnly && (
            <Button type="submit" form={formId} loading={save.isPending}>
              {form ? 'Save form' : 'Create form'}
            </Button>
          )}
        </>
      }
    >
      <form id={formId} noValidate onSubmit={(e) => void onSubmit(e)}>
        <fieldset disabled={readOnly} className="flex min-w-0 flex-col gap-4">
          <legend className="sr-only">Form template</legend>
          <FormField
            label="Name"
            required
            error={errors.name?.message}
            help="e.g. Liability waiver."
          >
            <Input maxLength={120} {...register('name')} />
          </FormField>
          <FormField
            label="Form text"
            required
            error={errors.body?.message}
            help="Markdown is supported: **bold**, _italic_, # headings and - bullet lists."
          >
            <Textarea rows={12} className="font-mono text-xs sm:text-sm" {...register('body')} />
          </FormField>
          <Controller
            control={control}
            name="attachTo"
            render={({ field }) => (
              <RadioGroup
                label="When to attach it"
                value={field.value}
                onChange={field.onChange}
                options={ATTACH_OPTIONS}
                disabled={readOnly}
              />
            )}
          />
          <Controller
            control={control}
            name="requiresSignature"
            render={({ field }) => (
              <Switch
                label="Require a signature"
                description="Off: the customer only needs to read it."
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
                label="In use"
                description="Turned-off forms aren’t attached to new jobs."
                checked={field.value}
                onCheckedChange={field.onChange}
              />
            )}
          />
        </fieldset>
      </form>
    </Dialog>
  );
}
