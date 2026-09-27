import { ArrowDown, ArrowUp, ListChecks, Plus, Trash2, X } from 'lucide-react';
import { useId, useMemo, useRef, useState } from 'react';
import {
  Badge,
  Button,
  ConfirmDialog,
  Dialog,
  EmptyState,
  ErrorState,
  FormField,
  IconButton,
  Input,
  LoadingState,
  SectionCard,
  Select,
  useToast,
} from '@/components/ui';
import {
  useChecklistTemplates,
  useDeleteChecklistTemplate,
  useSaveChecklistTemplate,
  useServices,
} from '../api';
import {
  checklistItemsError,
  checklistPayload,
  KIND_LABELS,
  MAX_CHECKLIST_ITEMS,
  moveItem,
  parseChecklistItems,
  type ChecklistDraftItem,
  type ChecklistTemplateRow,
} from '../model';

export function ChecklistsTab({ canManage }: { canManage: boolean }) {
  const toast = useToast();
  const templates = useChecklistTemplates();
  const services = useServices();
  const remove = useDeleteChecklistTemplate();
  const [editing, setEditing] = useState<ChecklistTemplateRow | 'new' | null>(null);
  const [deleting, setDeleting] = useState<ChecklistTemplateRow | null>(null);

  const serviceName = useMemo(
    () => new Map((services.data ?? []).map((s) => [s.id, s.name])),
    [services.data],
  );
  const list = templates.data ?? [];

  let body;
  if (templates.isPending) body = <LoadingState label="Loading checklists…" variant="rows" />;
  else if (templates.error)
    body = (
      <ErrorState
        error={templates.error}
        title="Couldn’t load checklists"
        onRetry={() => void templates.refetch()}
        retrying={templates.isRefetching}
      />
    );
  else if (list.length === 0)
    body = (
      <EmptyState
        icon={<ListChecks aria-hidden="true" />}
        title="No checklist templates yet"
        description="Checklists linked to a service are added to every job that includes it."
        action={
          canManage ? (
            <Button leadingIcon={<Plus />} onClick={() => setEditing('new')}>
              New checklist
            </Button>
          ) : undefined
        }
      />
    );
  else
    body = (
      <ul className="divide-line divide-y" aria-label="Checklist templates">
        {list.map((template) => {
          const count = parseChecklistItems(template.items).length;
          const linked = template.service_id ? serviceName.get(template.service_id) : undefined;
          return (
            <li key={template.id} className="flex items-center gap-3 px-4 py-3 sm:px-5">
              <div className="min-w-0 flex-1">
                <p className="text-ink truncate font-medium">{template.name}</p>
                <p className="text-muted flex flex-wrap items-center gap-2 text-xs">
                  <span>{count === 1 ? '1 item' : `${count} items`}</span>
                  {linked ? (
                    <Badge tone="info">Auto-added with {linked}</Badge>
                  ) : (
                    <span>Added manually</span>
                  )}
                </p>
              </div>
              {canManage ? (
                <div className="flex shrink-0 items-center gap-1">
                  <Button size="sm" variant="secondary" onClick={() => setEditing(template)}>
                    Edit
                  </Button>
                  <IconButton
                    label={`Delete ${template.name}`}
                    icon={<Trash2 className="size-4" />}
                    size="sm"
                    variant="danger"
                    onClick={() => setDeleting(template)}
                  />
                </div>
              ) : (
                <Button size="sm" variant="ghost" onClick={() => setEditing(template)}>
                  View
                </Button>
              )}
            </li>
          );
        })}
      </ul>
    );

  return (
    <>
      <SectionCard
        title="Checklist templates"
        flush
        actions={
          canManage && list.length > 0 ? (
            <Button size="sm" leadingIcon={<Plus />} onClick={() => setEditing('new')}>
              New checklist
            </Button>
          ) : undefined
        }
      >
        {body}
      </SectionCard>
      {editing !== null && (
        <ChecklistTemplateDialog
          template={editing === 'new' ? null : editing}
          readOnly={!canManage}
          onClose={() => setEditing(null)}
        />
      )}
      <ConfirmDialog
        open={deleting !== null}
        onClose={() => setDeleting(null)}
        tone="danger"
        loading={remove.isPending}
        title={`Delete ${deleting?.name ?? 'checklist'}?`}
        description="Checklists already on jobs stay as they are."
        confirmLabel="Delete"
        onConfirm={async () => {
          if (!deleting) return;
          try {
            await remove.mutateAsync(deleting.id);
            toast.success('Checklist deleted');
          } catch (error) {
            toast.error(error);
          } finally {
            setDeleting(null);
          }
        }}
      />
    </>
  );
}

let draftSeq = 0;
const draftKey = () => `draft-${++draftSeq}`;

export function ChecklistTemplateDialog({
  template,
  readOnly,
  onClose,
}: {
  template: ChecklistTemplateRow | null;
  readOnly: boolean;
  onClose: () => void;
}) {
  const toast = useToast();
  const services = useServices();
  const save = useSaveChecklistTemplate();
  const formId = useId();
  const newItemRef = useRef<HTMLInputElement>(null);
  const [name, setName] = useState(template?.name ?? '');
  const [serviceId, setServiceId] = useState(template?.service_id ?? '');
  const [items, setItems] = useState<ChecklistDraftItem[]>(() =>
    parseChecklistItems(template?.items).map((i) => ({ key: i.id, id: i.id, label: i.label })),
  );
  const [newLabel, setNewLabel] = useState('');
  const [nameError, setNameError] = useState<string | null>(null);
  const [itemsError, setItemsError] = useState<string | null>(null);

  const serviceOptions = (services.data ?? [])
    .filter((s) => s.archived_at === null || s.id === template?.service_id)
    .map((s) => ({ value: s.id, label: `${s.name} (${KIND_LABELS[s.kind]})` }));

  const addItem = () => {
    const label = newLabel.trim();
    if (label === '') return;
    if (items.length >= MAX_CHECKLIST_ITEMS) {
      setItemsError(`Use at most ${MAX_CHECKLIST_ITEMS} items.`);
      return;
    }
    setItems((prev) => [...prev, { key: draftKey(), id: null, label }]);
    setNewLabel('');
    setItemsError(null);
    newItemRef.current?.focus();
  };

  const submit = async () => {
    const trimmed = name.trim();
    const nextNameError =
      trimmed === ''
        ? 'Name is required.'
        : trimmed.length > 120
          ? 'Name must be 120 characters or fewer.'
          : null;
    const nextItemsError = checklistItemsError(items);
    setNameError(nextNameError);
    setItemsError(nextItemsError);
    if (nextNameError || nextItemsError) return;
    try {
      await save.mutateAsync({
        ...(template ? { id: template.id } : {}),
        name: trimmed,
        serviceId: serviceId === '' ? null : serviceId,
        items: checklistPayload(items),
      });
      toast.success(template ? 'Checklist saved' : 'Checklist created');
      onClose();
    } catch (error) {
      toast.error(error);
    }
  };

  if (readOnly && template) {
    const linked = (services.data ?? []).find((s) => s.id === template.service_id);
    return (
      <Dialog open onClose={onClose} title={template.name} size="md">
        <p className="text-muted mb-3 text-sm">
          {linked ? `Added automatically to jobs with ${linked.name}.` : 'Added to jobs manually.'}
        </p>
        {items.length === 0 ? (
          <p className="text-muted text-sm">This checklist has no items.</p>
        ) : (
          <ol className="text-ink list-decimal space-y-1 pl-5 text-sm">
            {items.map((item) => (
              <li key={item.key}>{item.label}</li>
            ))}
          </ol>
        )}
      </Dialog>
    );
  }

  return (
    <Dialog
      open
      onClose={onClose}
      title={template ? 'Edit checklist' : 'New checklist'}
      size="lg"
      footer={
        <div className="flex flex-col-reverse gap-2 sm:flex-row sm:justify-end">
          <Button variant="secondary" onClick={onClose}>
            Cancel
          </Button>
          <Button type="submit" form={formId} loading={save.isPending}>
            {template ? 'Save checklist' : 'Create checklist'}
          </Button>
        </div>
      }
    >
      <form
        id={formId}
        noValidate
        className="flex flex-col gap-4"
        onSubmit={(event) => {
          event.preventDefault();
          void submit();
        }}
      >
        <FormField label="Name" required error={nameError}>
          <Input value={name} onChange={(e) => setName(e.target.value)} autoComplete="off" />
        </FormField>
        <FormField
          label="Linked service"
          help="When a job includes this service (or a package containing it), the checklist is added automatically."
        >
          <Select
            placeholder="None — add manually"
            value={serviceId}
            onChange={(e) => setServiceId(e.target.value)}
            options={serviceOptions}
          />
        </FormField>
        <fieldset className="flex flex-col gap-2">
          <legend className="text-ink mb-1 text-sm font-medium">Items</legend>
          {items.length === 0 ? (
            <p className="text-muted text-sm">No items yet. Add the steps below.</p>
          ) : (
            <ol className="flex flex-col gap-2" aria-label="Checklist items">
              {items.map((item, index) => (
                <li key={item.key} className="flex items-center gap-1.5">
                  <span className="text-muted tabular w-6 shrink-0 text-right text-xs">
                    {index + 1}.
                  </span>
                  <Input
                    aria-label={`Item ${index + 1}`}
                    value={item.label}
                    maxLength={200}
                    onChange={(e) =>
                      setItems((prev) =>
                        prev.map((p) => (p.key === item.key ? { ...p, label: e.target.value } : p)),
                      )
                    }
                    className="min-w-0 flex-1"
                  />
                  <IconButton
                    label={`Move item ${index + 1} up`}
                    icon={<ArrowUp className="size-4" />}
                    size="sm"
                    disabled={index === 0}
                    onClick={() => setItems((prev) => moveItem(prev, index, index - 1))}
                  />
                  <IconButton
                    label={`Move item ${index + 1} down`}
                    icon={<ArrowDown className="size-4" />}
                    size="sm"
                    disabled={index === items.length - 1}
                    onClick={() => setItems((prev) => moveItem(prev, index, index + 1))}
                  />
                  <IconButton
                    label={`Remove item ${index + 1}`}
                    icon={<X className="size-4" />}
                    size="sm"
                    variant="danger"
                    onClick={() => setItems((prev) => prev.filter((p) => p.key !== item.key))}
                  />
                </li>
              ))}
            </ol>
          )}
          <div className="flex gap-2">
            <Input
              ref={newItemRef}
              aria-label="New item"
              placeholder="Add an item…"
              value={newLabel}
              maxLength={200}
              onChange={(e) => setNewLabel(e.target.value)}
              onKeyDown={(e) => {
                if (e.key === 'Enter') {
                  e.preventDefault();
                  addItem();
                }
              }}
              className="min-w-0 flex-1"
            />
            <Button variant="secondary" leadingIcon={<Plus />} onClick={addItem}>
              Add
            </Button>
          </div>
          {itemsError && (
            <p role="alert" className="text-danger-ink text-xs font-medium">
              {itemsError}
            </p>
          )}
        </fieldset>
      </form>
    </Dialog>
  );
}
