import { zodResolver } from '@hookform/resolvers/zod';
import { Controller, useForm, useWatch } from 'react-hook-form';
import {
  Button,
  Dialog,
  FormField,
  Input,
  MoneyInput,
  Select,
  Switch,
  Textarea,
  useToast,
} from '@/components/ui';
import { useCan } from '@/features/shop/useCan';
import { useCategories, useCreateService, useUpdateService } from '../api';
import {
  COMMISSION_KIND_LABELS,
  KIND_LABELS,
  MAX_PHOTO_MINIMUM,
  SERVICE_KINDS,
  serviceColumns,
  serviceFormDefaults,
  serviceFormSchema,
  type ServiceFormInput,
  type ServiceFormOutput,
  type ServiceKind,
  type ServiceRow,
} from '../model';

export interface ServiceFormDialogProps {
  open: boolean;
  onClose: () => void;
  /** Edit this service; omit to create one. */
  service?: ServiceRow | null;
  /** Default kind for a new item. */
  defaultKind?: ServiceKind;
  onCreated?: (id: string) => void;
}

/** Create / edit the details of a service, package, add-on or product. */
export function ServiceFormDialog({
  open,
  onClose,
  service,
  defaultKind,
  onCreated,
}: ServiceFormDialogProps) {
  return (
    <Dialog
      open={open}
      onClose={onClose}
      title={service ? `Edit ${service.name}` : 'New catalog item'}
      description={
        service
          ? undefined
          : 'Add the details now; prices, contents and add-ons are set on the next page.'
      }
      size="lg"
    >
      {open && (
        <ServiceForm
          service={service ?? null}
          defaultKind={defaultKind}
          onClose={onClose}
          onCreated={onCreated}
        />
      )}
    </Dialog>
  );
}

function ServiceForm({
  service,
  defaultKind,
  onClose,
  onCreated,
}: {
  service: ServiceRow | null;
  defaultKind: ServiceKind | undefined;
  onClose: () => void;
  onCreated: ((id: string) => void) | undefined;
}) {
  const toast = useToast();
  // Service commissions are pay settings: owners / admins only (0065 guard).
  const canSetCommission = useCan('compensation.manage');
  const categories = useCategories();
  const create = useCreateService();
  const update = useUpdateService(service?.id ?? '');
  const defaults = serviceFormDefaults(service);
  if (!service && defaultKind) defaults.kind = defaultKind;
  const {
    register,
    control,
    handleSubmit,
    formState: { errors, isSubmitting },
  } = useForm<ServiceFormInput, unknown, ServiceFormOutput>({
    resolver: zodResolver(serviceFormSchema),
    defaultValues: defaults,
  });
  const kind = useWatch({ control, name: 'kind' });
  const commissionKind = useWatch({ control, name: 'commissionKind' });

  const onSubmit = async (values: ServiceFormOutput) => {
    try {
      if (service) {
        await update.mutateAsync(serviceColumns(values, { commission: canSetCommission }));
        toast.success('Saved');
        onClose();
      } else {
        const id = await create.mutateAsync(
          serviceColumns(values, { commission: canSetCommission }),
        );
        toast.success(`${KIND_LABELS[values.kind]} created`);
        onClose();
        onCreated?.(id);
      }
    } catch (error) {
      toast.error(error);
    }
  };

  return (
    <form
      noValidate
      onSubmit={(event) => void handleSubmit(onSubmit)(event)}
      className="flex flex-col gap-4"
    >
      <FormField label="Name" required error={errors.name?.message}>
        <Input autoComplete="off" {...register('name')} />
      </FormField>
      <div className="grid gap-4 sm:grid-cols-2">
        <FormField
          label="Type"
          error={errors.kind?.message}
          help={
            service
              ? 'A package with contents, or an add-on offered on services, keeps its type.'
              : undefined
          }
        >
          <Select
            options={SERVICE_KINDS.map((k) => ({ value: k, label: KIND_LABELS[k] }))}
            {...register('kind')}
          />
        </FormField>
        <FormField label="Category" error={errors.categoryId?.message}>
          <Select
            placeholder="No category"
            options={(categories.data ?? []).map((c) => ({ value: c.id, label: c.name }))}
            {...register('categoryId')}
          />
        </FormField>
      </div>
      <FormField label="Description" error={errors.description?.message}>
        <Textarea rows={3} {...register('description')} />
      </FormField>
      <div className="grid gap-4 sm:grid-cols-2">
        <FormField
          label="Duration (minutes)"
          required
          error={errors.durationMinutes?.message}
          help="Default time on the calendar; prices can override it per vehicle size."
        >
          <Input inputMode="numeric" {...register('durationMinutes')} />
        </FormField>
        <FormField
          label="Sort order"
          error={errors.sort?.message}
          help="Lower numbers are listed first."
        >
          <Input inputMode="numeric" {...register('sort')} />
        </FormField>
      </div>
      <div className="border-line rounded-control flex flex-col gap-3 border p-3">
        <Controller
          control={control}
          name="active"
          render={({ field }) => (
            <Switch
              label="Active"
              description="Inactive items can’t be added to new jobs, quotes or bookings."
              checked={field.value}
              onCheckedChange={field.onChange}
            />
          )}
        />
        <Controller
          control={control}
          name="onlineBookable"
          render={({ field }) => (
            <Switch
              label="Bookable online"
              description="Shown on your public booking page."
              checked={field.value}
              onCheckedChange={field.onChange}
            />
          )}
        />
        <Controller
          control={control}
          name="taxable"
          render={({ field }) => (
            <Switch
              label="Taxable"
              description="Sales tax applies to this item."
              checked={field.value}
              onCheckedChange={field.onChange}
            />
          )}
        />
      </div>
      {kind !== 'product' && (
        <fieldset className="border-line rounded-control flex flex-col gap-3 border p-3">
          <legend className="text-ink px-1 text-sm font-medium">Required photos</legend>
          <p className="text-muted -mt-1 text-xs">
            A job with this item can’t be started until it has this many “before” photos, or
            completed until it has this many “after” photos (videos don’t count). Managers can
            override with a reason.
          </p>
          <div className="grid gap-4 sm:grid-cols-2">
            <FormField label="Minimum “before” photos" error={errors.minBeforePhotos?.message}>
              <Input inputMode="numeric" {...register('minBeforePhotos')} />
            </FormField>
            <FormField label="Minimum “after” photos" error={errors.minAfterPhotos?.message}>
              <Input inputMode="numeric" {...register('minAfterPhotos')} />
            </FormField>
          </div>
          <p className="text-subtle text-xs">0 = no minimum; at most {MAX_PHOTO_MINIMUM}.</p>
        </fieldset>
      )}
      {canSetCommission && (
        <fieldset className="border-line rounded-control flex flex-col gap-3 border p-3">
          <legend className="text-ink px-1 text-sm font-medium">Service commission</legend>
          <p className="text-muted -mt-1 text-xs">
            Paid to the technicians who did the work (split between them), instead of their usual
            commission on this line. Only owners and admins see this.
          </p>
          <div className="grid gap-4 sm:grid-cols-2">
            <FormField label="Commission" error={errors.commissionKind?.message}>
              <Select
                options={(['none', 'percent', 'flat'] as const).map((k) => ({
                  value: k,
                  label: COMMISSION_KIND_LABELS[k],
                }))}
                {...register('commissionKind')}
              />
            </FormField>
            {commissionKind === 'percent' && (
              <FormField
                label="Percent of the line"
                required
                error={errors.commissionPercent?.message}
                help="Of the line after discounts, before tax."
              >
                <Input inputMode="decimal" trailing="%" {...register('commissionPercent')} />
              </FormField>
            )}
            {commissionKind === 'flat' && (
              <FormField
                label="Amount per unit sold"
                required
                error={errors.commissionCents?.message}
              >
                <Controller
                  control={control}
                  name="commissionCents"
                  render={({ field }) => (
                    <MoneyInput
                      value={field.value}
                      onChange={field.onChange}
                      onBlur={field.onBlur}
                    />
                  )}
                />
              </FormField>
            )}
          </div>
        </fieldset>
      )}
      <div className="flex flex-col-reverse gap-2 sm:flex-row sm:justify-end">
        <Button variant="secondary" onClick={onClose}>
          Cancel
        </Button>
        <Button type="submit" loading={isSubmitting}>
          {service ? 'Save changes' : 'Create'}
        </Button>
      </div>
    </form>
  );
}
