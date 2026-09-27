import { zodResolver } from '@hookform/resolvers/zod';
import { Pencil, Plus, Trash2, Warehouse } from 'lucide-react';
import { useState } from 'react';
import { useForm } from 'react-hook-form';
import {
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
  Table,
  useToast,
  type Column,
} from '@/components/ui';
import {
  useArchiveResource,
  useResources,
  useSaveResource,
  type Resource,
  type ResourceKind,
} from '../api';
import { QueryView, SettingsSectionLayout } from '../components/SettingsSectionLayout';
import { RESOURCE_KINDS, resourceSchema, type ResourceValues } from '../schemas';
import { nextSortPosition } from '../reorder';
import { useSettingsAccess } from '../useSettingsAccess';

const RESOURCE_KIND_LABELS: Record<ResourceKind, string> = {
  bay: 'Bay',
  van: 'Van',
  other: 'Other',
};

type Editing = { resource: Resource | null } | null;

export default function ResourcesPage() {
  const { readOnly, canEdit } = useSettingsAccess();
  const query = useResources();
  const save = useSaveResource();
  const archive = useArchiveResource();
  const toast = useToast();
  const [editing, setEditing] = useState<Editing>(null);
  const [removing, setRemoving] = useState<Resource | null>(null);

  const toggleActive = (resource: Resource, active: boolean) =>
    save.mutate(
      { id: resource.id, active },
      {
        onSuccess: () =>
          toast.success(`${resource.name} ${active ? 'is available' : 'turned off'}`),
        onError: (error) => toast.error(error),
      },
    );

  const columns: Column<Resource>[] = [
    { key: 'name', header: 'Name', primary: true, cell: (r) => r.name },
    { key: 'kind', header: 'Type', cell: (r) => RESOURCE_KIND_LABELS[r.kind] },
    {
      key: 'active',
      header: 'Available',
      cell: (r) => (
        <Switch
          aria-label={`${r.name} available for scheduling`}
          checked={r.active}
          disabled={!canEdit || save.isPending}
          onCheckedChange={(active) => toggleActive(r, active)}
          className="justify-end md:justify-start"
        />
      ),
    },
    ...(canEdit
      ? [
          {
            key: 'actions',
            header: <span className="sr-only">Actions</span>,
            align: 'right' as const,
            cell: (r: Resource) => (
              <div className="flex justify-end gap-1">
                <IconButton
                  label={`Edit ${r.name}`}
                  icon={<Pencil />}
                  size="sm"
                  onClick={() => setEditing({ resource: r })}
                />
                <IconButton
                  label={`Remove ${r.name}`}
                  icon={<Trash2 />}
                  size="sm"
                  variant="danger"
                  onClick={() => setRemoving(r)}
                />
              </div>
            ),
          },
        ]
      : []),
  ];

  return (
    <SettingsSectionLayout
      section="resources"
      readOnly={readOnly}
      actions={
        canEdit && (
          <Button
            leadingIcon={<Plus className="size-4" aria-hidden="true" />}
            onClick={() => setEditing({ resource: null })}
          >
            Add resource
          </Button>
        )
      }
    >
      <QueryView query={query} label="bays and vans">
        {(resources) =>
          resources.length === 0 ? (
            <Card>
              <EmptyState
                icon={<Warehouse aria-hidden="true" />}
                title="No bays or vans yet"
                description="Add the bays in your shop or the vans you work from to schedule jobs on them."
                action={
                  canEdit && (
                    <Button variant="secondary" onClick={() => setEditing({ resource: null })}>
                      Add resource
                    </Button>
                  )
                }
              />
            </Card>
          ) : (
            <Card className="overflow-hidden">
              <Table
                caption="Bays and vans"
                columns={columns}
                rows={resources}
                getRowId={(r) => r.id}
              />
            </Card>
          )
        }
      </QueryView>

      {editing && (
        <ResourceDialog
          resource={editing.resource}
          nextSort={nextSortPosition(query.data ?? [])}
          onClose={() => setEditing(null)}
        />
      )}
      <ConfirmDialog
        open={removing !== null}
        onClose={() => setRemoving(null)}
        tone="danger"
        title={`Remove ${removing?.name ?? 'resource'}?`}
        description="It will no longer be offered for scheduling. Past jobs keep their history."
        confirmLabel="Remove"
        loading={archive.isPending}
        onConfirm={async () => {
          if (!removing) return;
          try {
            await archive.mutateAsync(removing.id);
            toast.success(`${removing.name} removed`);
            setRemoving(null);
          } catch (error) {
            toast.error(error);
          }
        }}
      />
    </SettingsSectionLayout>
  );
}

function ResourceDialog({
  resource,
  nextSort,
  onClose,
}: {
  resource: Resource | null;
  nextSort: number;
  onClose: () => void;
}) {
  const toast = useToast();
  const save = useSaveResource();
  const {
    register,
    handleSubmit,
    formState: { errors },
  } = useForm<ResourceValues>({
    resolver: zodResolver(resourceSchema),
    defaultValues: { name: resource?.name ?? '', kind: resource?.kind ?? 'bay' },
  });
  const onSubmit = handleSubmit(async (values) => {
    try {
      await save.mutateAsync(
        resource ? { id: resource.id, ...values } : { ...values, sort: nextSort, active: true },
      );
      toast.success(resource ? 'Resource updated' : 'Resource added');
      onClose();
    } catch (error) {
      toast.error(error);
    }
  });
  const formId = 'resource-form';
  return (
    <Dialog
      open
      onClose={onClose}
      dismissible={!save.isPending}
      title={resource ? `Edit ${resource.name}` : 'Add a bay or van'}
      footer={
        <>
          <Button variant="secondary" onClick={onClose} disabled={save.isPending}>
            Cancel
          </Button>
          <Button type="submit" form={formId} loading={save.isPending}>
            {resource ? 'Save' : 'Add'}
          </Button>
        </>
      }
    >
      <form
        id={formId}
        noValidate
        onSubmit={(e) => void onSubmit(e)}
        className="flex flex-col gap-4"
      >
        <FormField label="Name" required error={errors.name?.message} help="e.g. Bay 1 or Van 2.">
          <Input maxLength={80} {...register('name')} />
        </FormField>
        <FormField label="Type" error={errors.kind?.message}>
          <Select
            options={RESOURCE_KINDS.map((kind) => ({
              value: kind,
              label: RESOURCE_KIND_LABELS[kind],
            }))}
            {...register('kind')}
          />
        </FormField>
      </form>
    </Dialog>
  );
}
