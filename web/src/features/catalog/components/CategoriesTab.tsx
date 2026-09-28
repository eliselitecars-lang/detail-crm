import { zodResolver } from '@hookform/resolvers/zod';
import { ArrowDown, ArrowUp, CalendarDays, FolderTree, Pencil, Plus, Trash2 } from 'lucide-react';
import { useState } from 'react';
import { useForm } from 'react-hook-form';
import {
  Button,
  Checkbox,
  ConfirmDialog,
  Dialog,
  EmptyState,
  ErrorState,
  FormField,
  IconButton,
  Input,
  LoadingState,
  SectionCard,
  useToast,
} from '@/components/ui';
import {
  useCategories,
  useDeleteCategory,
  useReorder,
  useSaveCategory,
  useSaveCategoryWeekdays,
  useServices,
} from '../api';
import {
  categoryFormSchema,
  describeWeekdays,
  moveItem,
  resequence,
  WEEKDAY_LONG,
  weekdaysValue,
  type CategoryFormInput,
  type CategoryRow,
} from '../model';

export function CategoriesTab({ canManage }: { canManage: boolean }) {
  const toast = useToast();
  const categories = useCategories();
  const services = useServices();
  const reorder = useReorder('service_categories');
  const remove = useDeleteCategory();
  const [editing, setEditing] = useState<CategoryRow | 'new' | null>(null);
  const [deleting, setDeleting] = useState<CategoryRow | null>(null);
  const [scheduling, setScheduling] = useState<CategoryRow | null>(null);

  const list = categories.data ?? [];
  /** Item count label; never "0 items" just because services haven't loaded. */
  const countLabel = (id: string): string => {
    if (services.isPending) return 'Counting items…';
    if (services.error) return 'Item count unavailable';
    const count = services.data.filter(
      (s) => s.category_id === id && s.archived_at === null,
    ).length;
    return count === 1 ? '1 item' : `${count} items`;
  };

  const move = (index: number, delta: number) => {
    const changes = resequence(moveItem(list, index, index + delta));
    reorder.mutate(changes, { onError: (error) => toast.error(error) });
  };

  let body;
  if (categories.isPending) body = <LoadingState label="Loading categories…" variant="rows" />;
  else if (categories.error)
    body = (
      <ErrorState
        error={categories.error}
        title="Couldn’t load categories"
        onRetry={() => void categories.refetch()}
        retrying={categories.isRefetching}
      />
    );
  else if (list.length === 0)
    body = (
      <EmptyState
        icon={<FolderTree aria-hidden="true" />}
        title="No categories yet"
        description="Group services (for example Exterior, Interior, Coatings) to keep menus tidy."
        action={
          canManage ? (
            <Button leadingIcon={<Plus />} onClick={() => setEditing('new')}>
              New category
            </Button>
          ) : undefined
        }
      />
    );
  else
    body = (
      <>
        {services.error && (
          <div className="border-line border-b">
            <ErrorState
              compact
              error={services.error}
              title="Couldn’t count items per category"
              onRetry={() => void services.refetch()}
              retrying={services.isRefetching}
            />
          </div>
        )}
        <ul className="divide-line divide-y" aria-label="Service categories">
          {list.map((category, index) => {
            return (
              <li key={category.id} className="flex items-center gap-3 px-4 py-3 sm:px-5">
                <div className="min-w-0 flex-1">
                  <p className="text-ink truncate font-medium">{category.name}</p>
                  <p className="text-muted text-xs">
                    {countLabel(category.id)}
                    {(category.bookable_weekdays ?? null) !== null && (
                      <> · Online booking: {describeWeekdays(category.bookable_weekdays)}</>
                    )}
                  </p>
                </div>
                {canManage && (
                  <div className="flex shrink-0 items-center gap-0.5">
                    <IconButton
                      label={`Move ${category.name} up`}
                      icon={<ArrowUp className="size-4" />}
                      size="sm"
                      disabled={index === 0 || reorder.isPending}
                      onClick={() => move(index, -1)}
                    />
                    <IconButton
                      label={`Move ${category.name} down`}
                      icon={<ArrowDown className="size-4" />}
                      size="sm"
                      disabled={index === list.length - 1 || reorder.isPending}
                      onClick={() => move(index, 1)}
                    />
                    <IconButton
                      label={`Online booking days for ${category.name}`}
                      icon={<CalendarDays className="size-4" />}
                      size="sm"
                      onClick={() => setScheduling(category)}
                    />
                    <IconButton
                      label={`Rename ${category.name}`}
                      icon={<Pencil className="size-4" />}
                      size="sm"
                      onClick={() => setEditing(category)}
                    />
                    <IconButton
                      label={`Delete ${category.name}`}
                      icon={<Trash2 className="size-4" />}
                      size="sm"
                      variant="danger"
                      onClick={() => setDeleting(category)}
                    />
                  </div>
                )}
              </li>
            );
          })}
        </ul>
      </>
    );

  const lastSort = list.reduce((max, c) => Math.max(max, c.sort), 0);

  return (
    <>
      <SectionCard
        title="Categories"
        flush
        actions={
          canManage && list.length > 0 ? (
            <Button size="sm" leadingIcon={<Plus />} onClick={() => setEditing('new')}>
              New category
            </Button>
          ) : undefined
        }
      >
        {body}
      </SectionCard>
      {editing !== null && (
        <CategoryDialog
          category={editing === 'new' ? null : editing}
          nextSort={lastSort + 10}
          onClose={() => setEditing(null)}
        />
      )}
      {scheduling !== null && (
        <WeekdaysDialog category={scheduling} onClose={() => setScheduling(null)} />
      )}
      <ConfirmDialog
        open={deleting !== null}
        onClose={() => setDeleting(null)}
        tone="danger"
        loading={remove.isPending}
        title={`Delete ${deleting?.name ?? 'category'}?`}
        description="Items in this category stay in the catalog without a category."
        confirmLabel="Delete"
        onConfirm={async () => {
          if (!deleting) return;
          try {
            await remove.mutateAsync(deleting.id);
            toast.success('Category deleted');
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

function CategoryDialog({
  category,
  nextSort,
  onClose,
}: {
  category: CategoryRow | null;
  nextSort: number;
  onClose: () => void;
}) {
  const toast = useToast();
  const save = useSaveCategory();
  const {
    register,
    handleSubmit,
    formState: { errors, isSubmitting },
  } = useForm<CategoryFormInput>({
    resolver: zodResolver(categoryFormSchema),
    defaultValues: { name: category?.name ?? '' },
  });
  return (
    <Dialog open onClose={onClose} title={category ? 'Rename category' : 'New category'} size="sm">
      <form
        noValidate
        className="flex flex-col gap-4"
        onSubmit={(event) =>
          void handleSubmit(async ({ name }) => {
            try {
              await save.mutateAsync(
                category ? { id: category.id, name } : { name, sort: nextSort },
              );
              toast.success(category ? 'Category renamed' : 'Category added');
              onClose();
            } catch (error) {
              toast.error(error);
            }
          })(event)
        }
      >
        <FormField label="Name" required error={errors.name?.message}>
          <Input autoComplete="off" {...register('name')} />
        </FormField>
        <div className="flex flex-col-reverse gap-2 sm:flex-row sm:justify-end">
          <Button variant="secondary" onClick={onClose}>
            Cancel
          </Button>
          <Button type="submit" loading={isSubmitting}>
            {category ? 'Save' : 'Add category'}
          </Button>
        </div>
      </form>
    </Dialog>
  );
}

/** Weekdays on which this category's services can START online (P-17). */
function WeekdaysDialog({ category, onClose }: { category: CategoryRow; onClose: () => void }) {
  const toast = useToast();
  const save = useSaveCategoryWeekdays();
  const [selected, setSelected] = useState<Set<number>>(
    () => new Set(category.bookable_weekdays ?? [0, 1, 2, 3, 4, 5, 6]),
  );
  const toggle = (day: number, on: boolean) =>
    setSelected((prev) => {
      const next = new Set(prev);
      if (on) next.add(day);
      else next.delete(day);
      return next;
    });

  const submit = async () => {
    try {
      await save.mutateAsync({ id: category.id, weekdays: weekdaysValue(selected) });
      toast.success('Booking days saved', category.name);
      onClose();
    } catch (error) {
      toast.error(error);
    }
  };

  return (
    <Dialog
      open
      onClose={onClose}
      dismissible={!save.isPending}
      title={`Online booking days · ${category.name}`}
      description="Customers booking online can only start services of this category on the days ticked. Staff can still schedule them any day."
      size="sm"
      footer={
        <div className="flex flex-col-reverse gap-2 sm:flex-row sm:justify-end">
          <Button variant="secondary" onClick={onClose} disabled={save.isPending}>
            Cancel
          </Button>
          <Button loading={save.isPending} onClick={() => void submit()}>
            Save days
          </Button>
        </div>
      }
    >
      <fieldset className="flex flex-col gap-2">
        <legend className="sr-only">Bookable days</legend>
        {WEEKDAY_LONG.map((label, day) => (
          <Checkbox
            key={label}
            checked={selected.has(day)}
            onChange={(event) => toggle(day, event.target.checked)}
            label={label}
          />
        ))}
      </fieldset>
      {selected.size === 0 && (
        <p className="text-warning-ink mt-3 text-sm" role="status">
          With no days ticked, services of this category can’t be booked online at all.
        </p>
      )}
    </Dialog>
  );
}
