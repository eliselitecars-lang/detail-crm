import { Plus, Trash2 } from 'lucide-react';
import { useState } from 'react';
import {
  Button,
  Checkbox,
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
  const [label, setLabel] = useState('');
  const [templateId, setTemplateId] = useState('');

  const rows = items.data ?? [];
  const done = rows.filter((i) => i.done_at).length;

  const onAdd = async () => {
    if (!label.trim()) return;
    try {
      await add.mutateAsync({
        label,
        sort: rows.reduce((max, i) => Math.max(max, i.sort), 0) + 1,
      });
      setLabel('');
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
      description={rows.length > 0 ? `${done} of ${rows.length} done` : undefined}
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
                label={item.label}
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
                <IconButton
                  size="sm"
                  variant="danger"
                  label={`Remove ${item.label}`}
                  icon={<Trash2 className="size-4" />}
                  onClick={() =>
                    remove.mutateAsync(item.id).catch((error: unknown) => toast.error(error))
                  }
                />
              )}
            </li>
          ))}
        </ul>
      )}
      {canManage && (
        <div className="border-line mt-4 flex flex-col gap-3 border-t pt-4">
          <form
            className="flex gap-2"
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
    </SectionCard>
  );
}
