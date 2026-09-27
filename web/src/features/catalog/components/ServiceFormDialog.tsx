import { zodResolver } from '@hookform/resolvers/zod';
import { Controller, useForm } from 'react-hook-form';
import {
  Button,
  Dialog,
  FormField,
  Input,
  Select,
  Switch,
  Textarea,
  useToast,
} from '@/components/ui';
import { useCategories, useCreateService, useUpdateService } from '../api';
import {
  KIND_LABELS,
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

  const onSubmit = async (values: ServiceFormOutput) => {
    try {
      if (service) {
        await update.mutateAsync(serviceColumns(values));
        toast.success('Saved');
        onClose();
      } else {
        const id = await create.mutateAsync(serviceColumns(values));
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
