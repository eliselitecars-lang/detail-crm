import { Asterisk, Plus, Trash2 } from 'lucide-react';
import { useState } from 'react';
import {
  Badge,
  Button,
  Checkbox,
  ConfirmDialog,
  EmptyState,
  ErrorState,
  IconButton,
  Input,
  LoadingState,
  SectionCard,
  Select,
  useToast,
} from '@/components/ui';
import { formatDateTime } from '@/lib/dates';
import { useShop } from '@/features/shop/shopContext';
import { useCan } from '@/features/shop/useCan';
import {
  useAddChecklistItem,
  useApplyChecklistTemplate,
  useChecklist,
  useChecklistTemplates,
  useDeleteChecklistItem,
  useSetChecklistItemRequired,
  useToggleChecklistItem,
} from '../../fieldApi';

export function ChecklistCard({ jobId }: { jobId: string }) {
  const { timezone } = useShop();
  const canManage = useCan('jobs.manage');
  const toast = useToast();
  const items = useChecklist(jobId);
  const toggle = useToggleChecklistItem(jobId);
  const add = useAddChecklistItem(jobId);
  const remove = useDeleteChecklistItem(jobId);
  const templates = useChecklistTemplates(canManage);
  const apply = useApplyChecklistTemplate(jobId);
  const setRequired = useSetChecklistItemRequired(jobId);
  const [label, setLabel] = useState('');
  const [required, setRequiredDraft] = useState(false);
  const [templateId, setTemplateId] = useState('');
  const [itemToRemove, setItemToRemove] = useState<{ id: string; label: string } | null>(null);

  const rows = items.data ?? [];
  const done = rows.filter((i) => i.done_at).length;
  const openRequired = rows.filter((i) => i.required && !i.done_at).length;

  const onAdd = async () => {
    if (!label.trim()) return;
    try {
      await add.mutateAsync({
        label,
        sort: rows.reduce((max, i) => Math.max(max, i.sort), 0) + 1,
        required,
      });
      setLabel('');
      setRequiredDraft(false);
    } catch (error) {
      toast.error(error);
    }
  };

  const onApply = async () => {
    if (!templateId) return;
    try {
      const count = await apply.mutateAsync(templateId);
      toast.success(count === 0 ? 'Those items are already on the job' : `${count} items added`);
      setTemplateId('');
    } catch (error) {
      toast.error(error);
    }
  };

  return (
    <SectionCard
      title="Checklist"
      description={
        rows.length > 0
          ? `${done} of ${rows.length} done${openRequired > 0 ? ` · ${openRequired} required to finish` : ''}`
          : undefined
      }
    >
      {items.isPending ? (
        <LoadingState label="Loading checklist…" />
      ) : items.isError ? (
        <ErrorState compact error={items.error} onRetry={() => void items.refetch()} />
      ) : rows.length === 0 ? (
        <EmptyState
          compact
          title="No checklist items"
          description={canManage ? 'Apply a template or add items below.' : undefined}
        />
      ) : (
        <ul className="flex flex-col gap-2.5">
          {rows.map((item) => (
            <li key={item.id} className="flex items-start justify-between gap-2">
              <Checkbox
                label={
                  <>
                    {item.label}
                    {item.required && (
                      <Badge tone={item.done_at ? 'neutral' : 'warning'} className="ml-2">
                        Required
                      </Badge>
                    )}
                  </>
                }
                description={
                  item.done_at ? `Done ${formatDateTime(item.done_at, timezone)}` : undefined
                }
                checked={item.done_at !== null}
                onChange={(e) =>
                  toggle
                    .mutateAsync({ id: item.id, done: e.target.checked })
                    .catch((error: unknown) => toast.error(error))
                }
              />
              {canManage && (
                <span className="flex shrink-0 gap-0.5">
                  <IconButton
                    size="sm"
                    variant={item.required ? 'secondary' : 'ghost'}
                    label={`Required to complete: ${item.label}`}
                    aria-pressed={item.required}
                    icon={<Asterisk className="size-4" />}
                    disabled={setRequired.isPending}
                    onClick={() =>
                      setRequired
                        .mutateAsync({ id: item.id, required: !item.required })
                        .catch((error: unknown) => toast.error(error))
                    }
                  />
                  <IconButton
                    size="sm"
                    variant="danger"
                    label={`Remove ${item.label}`}
                    icon={<Trash2 className="size-4" />}
                    onClick={() => setItemToRemove({ id: item.id, label: item.label })}
                  />
                </span>
              )}
            </li>
          ))}
        </ul>
      )}
      {canManage && (
        <div className="border-line mt-4 flex flex-col gap-3 border-t pt-4">
          <form
            className="flex flex-wrap gap-2 sm:flex-nowrap"
            onSubmit={(e) => {
              e.preventDefault();
              void onAdd();
            }}
          >
            <Input
              aria-label="New checklist item"
              placeholder="Add an item…"
              maxLength={200}
              value={label}
              onChange={(e) => setLabel(e.target.value)}
            />
            <Checkbox
              className="shrink-0 self-center"
              label="Required"
              checked={required}
              onChange={(e) => setRequiredDraft(e.target.checked)}
            />
            <Button
              type="submit"
              variant="secondary"
              loading={add.isPending}
              disabled={!label.trim()}
              leadingIcon={<Plus className="size-4" aria-hidden="true" />}
            >
              Add
            </Button>
          </form>
          {(templates.data?.length ?? 0) > 0 && (
            <div className="flex gap-2">
              <Select
                aria-label="Checklist template"
                value={templateId}
                onChange={(e) => setTemplateId(e.target.value)}
                placeholder="Apply a template…"
                options={(templates.data ?? []).map((t) => ({ value: t.id, label: t.name }))}
              />
              <Button
                variant="secondary"
                loading={apply.isPending}
                disabled={!templateId}
                onClick={() => void onApply()}
              >
                Apply
              </Button>
            </div>
          )}
        </div>
      )}
      <ConfirmDialog
        open={itemToRemove !== null}
        onClose={() => setItemToRemove(null)}
        tone="danger"
        title="Remove this item?"
        description={itemToRemove?.label}
        confirmLabel="Remove"
        loading={remove.isPending}
        onConfirm={async () => {
          if (!itemToRemove) return;
          try {
            await remove.mutateAsync(itemToRemove.id);
            setItemToRemove(null);
          } catch (error) {
            toast.error(error);
          }
        }}
      />
    </SectionCard>
  );
}
