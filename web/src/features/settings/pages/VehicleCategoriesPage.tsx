import { zodResolver } from '@hookform/resolvers/zod';
import { ArrowDown, ArrowUp, CarFront, Pencil, Plus, Trash2 } from 'lucide-react';
import { useState } from 'react';
import { useForm } from 'react-hook-form';
import { toAppError } from '@/lib/errors';
import {
  Button,
  Card,
  ConfirmDialog,
  Dialog,
  EmptyState,
  ErrorState,
  FormField,
  IconButton,
  Input,
  Spinner,
  useToast,
} from '@/components/ui';
import {
  useCategoryUsage,
  useDeleteVehicleCategory,
  useReorderVehicleCategories,
  useSaveVehicleCategory,
  useVehicleCategories,
  type VehicleCategory,
} from '../api';
import { QueryView, SettingsSectionLayout } from '../components/SettingsSectionLayout';
import { moveItem } from '../reorder';
import { categorySchema } from '../schemas';
import { useSettingsAccess } from '../useSettingsAccess';

type Editing = { category: VehicleCategory | null } | null;

export default function VehicleCategoriesPage() {
  const { readOnly, canEdit } = useSettingsAccess();
  const query = useVehicleCategories();
  const reorder = useReorderVehicleCategories();
  const toast = useToast();
  const [editing, setEditing] = useState<Editing>(null);
  const [deleting, setDeleting] = useState<VehicleCategory | null>(null);

  const move = (list: VehicleCategory[], index: number, delta: -1 | 1) => {
    const next = moveItem(list, index, index + delta);
    reorder.mutate(next, { onError: (error) => toast.error(error) });
  };

  return (
    <SettingsSectionLayout
      section="vehicle-categories"
      readOnly={readOnly}
      actions={
        canEdit && (
          <Button
            leadingIcon={<Plus className="size-4" aria-hidden="true" />}
            onClick={() => setEditing({ category: null })}
          >
            Add category
          </Button>
        )
      }
    >
      <QueryView query={query} label="vehicle categories">
        {(categories) =>
          categories.length === 0 ? (
            <Card>
              <EmptyState
                icon={<CarFront aria-hidden="true" />}
                title="No vehicle categories"
                description="Add size classes like Car, SUV or Truck to set different prices per vehicle size."
                action={
                  canEdit && (
                    <Button variant="secondary" onClick={() => setEditing({ category: null })}>
                      Add category
                    </Button>
                  )
                }
              />
            </Card>
          ) : (
            <Card className="overflow-hidden">
              <p className="text-muted border-line border-b px-4 py-2.5 text-sm">
                Categories appear in this order on your booking page and price lists.
              </p>
              <ol
                aria-label="Vehicle categories"
                aria-busy={reorder.isPending}
                className="divide-line divide-y"
              >
                {categories.map((category, index) => (
                  <li key={category.id} className="flex items-center gap-2 px-4 py-2.5">
                    <span
                      className="text-muted w-6 shrink-0 text-right text-sm tabular-nums"
                      aria-hidden="true"
                    >
                      {index + 1}.
                    </span>
                    <span className="text-ink min-w-0 flex-1 truncate text-sm font-medium">
                      {category.name}
                    </span>
                    {canEdit && (
                      <div className="flex shrink-0 gap-0.5">
                        <IconButton
                          label={`Move ${category.name} up`}
                          icon={<ArrowUp />}
                          size="sm"
                          disabled={index === 0 || reorder.isPending}
                          onClick={() => move(categories, index, -1)}
                        />
                        <IconButton
                          label={`Move ${category.name} down`}
                          icon={<ArrowDown />}
                          size="sm"
                          disabled={index === categories.length - 1 || reorder.isPending}
                          onClick={() => move(categories, index, 1)}
                        />
                        <IconButton
                          label={`Rename ${category.name}`}
                          icon={<Pencil />}
                          size="sm"
                          onClick={() => setEditing({ category })}
                        />
                        <IconButton
                          label={`Delete ${category.name}`}
                          icon={<Trash2 />}
                          size="sm"
                          variant="danger"
                          onClick={() => setDeleting(category)}
                        />
                      </div>
                    )}
                  </li>
                ))}
              </ol>
            </Card>
          )
        }
      </QueryView>

      {editing && (
        <CategoryDialog
          category={editing.category}
          nextSort={(query.data?.reduce((max, c) => Math.max(max, c.sort), 0) ?? 0) + 1}
          onClose={() => setEditing(null)}
        />
      )}
      {deleting && <DeleteCategoryDialog category={deleting} onClose={() => setDeleting(null)} />}
    </SettingsSectionLayout>
  );
}

function CategoryDialog({
  category,
  nextSort,
  onClose,
}: {
  category: VehicleCategory | null;
  nextSort: number;
  onClose: () => void;
}) {
  const toast = useToast();
  const save = useSaveVehicleCategory();
  const {
    register,
    handleSubmit,
    setError,
    formState: { errors },
  } = useForm<{ name: string }>({
    resolver: zodResolver(categorySchema),
    defaultValues: { name: category?.name ?? '' },
  });
  const onSubmit = handleSubmit(async ({ name }) => {
    try {
      await save.mutateAsync(category ? { id: category.id, name } : { name, sort: nextSort });
      toast.success(category ? 'Category renamed' : 'Category added');
      onClose();
    } catch (error) {
      if (toAppError(error).code === '23505') {
        setError('name', { message: 'You already have a category with that name.' });
        return;
      }
      toast.error(error);
    }
  });
  const formId = 'vehicle-category-form';
  return (
    <Dialog
      open
      onClose={onClose}
      dismissible={!save.isPending}
      title={category ? `Rename ${category.name}` : 'Add vehicle category'}
      footer={
        <>
          <Button variant="secondary" onClick={onClose} disabled={save.isPending}>
            Cancel
          </Button>
          <Button type="submit" form={formId} loading={save.isPending}>
            {category ? 'Save' : 'Add'}
          </Button>
        </>
      }
    >
      <form id={formId} noValidate onSubmit={(e) => void onSubmit(e)}>
        <FormField
          label="Name"
          required
          error={errors.name?.message}
          help="e.g. Sedan, Mid-size SUV."
        >
          <Input maxLength={60} {...register('name')} />
        </FormField>
      </form>
    </Dialog>
  );
}

/**
 * Deleting a category removes its catalog prices (ON DELETE CASCADE) and
 * clears it from vehicles (SET NULL) — the database won't refuse, so the
 * usage is counted and spelled out before the owner confirms.
 */
function DeleteCategoryDialog({
  category,
  onClose,
}: {
  category: VehicleCategory;
  onClose: () => void;
}) {
  const toast = useToast();
  const usage = useCategoryUsage(category.id);
  const remove = useDeleteVehicleCategory();

  let body;
  if (usage.isPending) {
    body = (
      <p className="text-muted flex items-center gap-2 text-sm" role="status">
        <Spinner className="size-4" /> Checking where this category is used…
      </p>
    );
  } else if (usage.isError) {
    body = (
      <ErrorState
        compact
        title="Couldn’t check where this category is used"
        error={usage.error}
        onRetry={() => void usage.refetch()}
        retrying={usage.isRefetching}
      />
    );
  } else if (usage.data.prices === 0 && usage.data.vehicles === 0) {
    body = <p className="text-muted text-sm">No prices or vehicles use this category.</p>;
  } else {
    body = (
      <div role="alert" className="bg-warning-soft text-warning-ink rounded-control p-3 text-sm">
        <p className="font-medium">This category is in use:</p>
        <ul className="mt-1 list-disc pl-5">
          {usage.data.prices > 0 && (
            <li>
              {usage.data.prices} service price{usage.data.prices === 1 ? '' : 's'} for this size
              will be deleted.
            </li>
          )}
          {usage.data.vehicles > 0 && (
            <li>
              {usage.data.vehicles} vehicle{usage.data.vehicles === 1 ? '' : 's'} will no longer
              have a size category.
            </li>
          )}
        </ul>
      </div>
    );
  }

  return (
    <ConfirmDialog
      open
      onClose={onClose}
      tone="danger"
      title={`Delete ${category.name}?`}
      confirmLabel={
        usage.data && usage.data.prices + usage.data.vehicles > 0 ? 'Delete anyway' : 'Delete'
      }
      loading={remove.isPending || usage.isPending}
      onConfirm={async () => {
        if (!usage.isSuccess) return;
        try {
          await remove.mutateAsync(category.id);
          toast.success(`${category.name} deleted`);
          onClose();
        } catch (error) {
          toast.error(error);
        }
      }}
    >
      {body}
    </ConfirmDialog>
  );
}
