import { zodResolver } from '@hookform/resolvers/zod';
import { useMemo, useState } from 'react';
import { Controller, useForm, useWatch } from 'react-hook-form';
import { z } from 'zod';
import {
  Button,
  Checkbox,
  Dialog,
  ErrorState,
  FormField,
  Input,
  LoadingState,
  MoneyInput,
  SearchInput,
  Select,
  Switch,
  Textarea,
  useToast,
} from '@/components/ui';
import { bpsToPercentInput } from '@/lib/money';
import { zOptionalText, zPercentBps, zRequiredText } from '@/lib/validation';
import { useCatalogServices } from '@/features/quotes/shared/api';
import { useSavePlan, type PlanRow } from '../api';

const planSchema = z
  .object({
    name: zRequiredText('Name', 120),
    description: zOptionalText(5000),
    price_cents: z
      .number({ error: 'Enter a price.' })
      .int()
      .min(1, 'The price must be more than zero.'),
    interval: z.enum(['month', 'year']),
    interval_count: z.string(),
    included_service_ids: z.array(z.string()).max(100, 'Choose up to 100 services.'),
    discount: zPercentBps(100),
    active: z.boolean(),
  })
  .superRefine((value, ctx) => {
    const count = Number(value.interval_count);
    if (value.interval === 'year' && count !== 1) {
      ctx.addIssue({
        code: 'custom',
        path: ['interval_count'],
        message: 'Yearly plans bill every year.',
      });
    }
    if (value.interval === 'month' && !(Number.isInteger(count) && count >= 1 && count <= 12)) {
      ctx.addIssue({ code: 'custom', path: ['interval_count'], message: 'Choose 1 to 12 months.' });
    }
  });

type PlanFormInput = z.input<typeof planSchema>;
type PlanFormOutput = z.output<typeof planSchema>;

export interface PlanDialogProps {
  open: boolean;
  onClose: () => void;
  /** null = new plan */
  plan: PlanRow | null;
}

function defaults(plan: PlanRow | null): PlanFormInput {
  return {
    name: plan?.name ?? '',
    description: plan?.description ?? '',
    price_cents: plan?.price_cents ?? Number.NaN,
    interval: plan?.interval ?? 'month',
    interval_count: String(plan?.interval_count ?? 1),
    included_service_ids: plan?.included_service_ids ?? [],
    discount: plan ? bpsToPercentInput(plan.discount_bps) : '0',
    active: plan?.active ?? true,
  };
}

const MONTH_OPTIONS = Array.from({ length: 12 }, (_, i) => ({
  value: String(i + 1),
  label: i === 0 ? 'Every month' : `Every ${i + 1} months`,
}));

export function PlanDialog({ open, onClose, plan }: PlanDialogProps) {
  return (
    <Dialog
      open={open}
      onClose={onClose}
      size="lg"
      title={plan ? `Edit ${plan.name}` : 'New membership plan'}
      description="Recurring billing through Stripe. Changing the price or billing period applies to new sign-ups; current members keep their price."
    >
      {open && <PlanForm plan={plan} onClose={onClose} />}
    </Dialog>
  );
}

function PlanForm({ plan, onClose }: { plan: PlanRow | null; onClose: () => void }) {
  const toast = useToast();
  const save = useSavePlan();
  const services = useCatalogServices();
  const [serviceSearch, setServiceSearch] = useState('');
  const form = useForm<PlanFormInput, unknown, PlanFormOutput>({
    resolver: zodResolver(planSchema),
    defaultValues: defaults(plan),
  });
  const { errors, isSubmitting } = form.formState;
  const interval = useWatch({ control: form.control, name: 'interval' });

  const visibleServices = useMemo(() => {
    const term = serviceSearch.trim().toLowerCase();
    const list = services.data ?? [];
    return term ? list.filter((s) => s.name.toLowerCase().includes(term)) : list;
  }, [services.data, serviceSearch]);

  const submit = form.handleSubmit(async (values) => {
    try {
      await save.mutateAsync({
        id: plan?.id ?? null,
        input: {
          name: values.name,
          description: values.description,
          price_cents: values.price_cents,
          interval: values.interval,
          interval_count: values.interval === 'year' ? 1 : Number(values.interval_count),
          included_service_ids: values.included_service_ids,
          discount_bps: values.discount,
          active: values.active,
        },
      });
      toast.success(plan ? 'Plan saved' : 'Plan created');
      onClose();
    } catch (error) {
      toast.error(error);
    }
  });

  return (
    <form noValidate className="flex flex-col gap-4" onSubmit={(event) => void submit(event)}>
      <FormField label="Name" required error={errors.name?.message}>
        <Input autoComplete="off" {...form.register('name')} />
      </FormField>
      <FormField
        label="Description"
        error={errors.description?.message}
        help="Shown to customers at checkout."
      >
        <Textarea rows={2} {...form.register('description')} />
      </FormField>
      <div className="grid grid-cols-1 gap-4 sm:grid-cols-3">
        <FormField label="Price" required error={errors.price_cents?.message}>
          <Controller
            control={form.control}
            name="price_cents"
            render={({ field }) => (
              <MoneyInput
                value={Number.isNaN(field.value) ? null : field.value}
                onChange={(cents) => field.onChange(cents ?? Number.NaN)}
                onBlur={field.onBlur}
                name={field.name}
              />
            )}
          />
        </FormField>
        <FormField label="Billed" required error={errors.interval?.message}>
          <Select
            {...form.register('interval', {
              onChange: (event: { target: { value: string } }) => {
                if (event.target.value === 'year') form.setValue('interval_count', '1');
              },
            })}
            options={[
              { value: 'month', label: 'Monthly' },
              { value: 'year', label: 'Yearly' },
            ]}
          />
        </FormField>
        <FormField label="Frequency" error={errors.interval_count?.message}>
          <Select
            {...form.register('interval_count')}
            disabled={interval === 'year'}
            options={interval === 'year' ? [{ value: '1', label: 'Every year' }] : MONTH_OPTIONS}
          />
        </FormField>
      </div>
      <FormField
        label="Member discount on other services"
        error={errors.discount?.message}
        help="Percent off services that aren’t included. 0 for none."
      >
        <Input
          inputMode="decimal"
          trailing="%"
          className="max-w-40"
          {...form.register('discount')}
        />
      </FormField>

      <Controller
        control={form.control}
        name="included_service_ids"
        render={({ field }) => (
          <fieldset className="flex flex-col gap-2">
            <legend className="text-ink text-sm font-medium">Included services</legend>
            <p className="text-muted text-xs">
              Included services are priced at no charge for active members when you price work from
              the catalog.
            </p>
            {services.isPending ? (
              <LoadingState label="Loading services…" />
            ) : services.isError ? (
              <ErrorState compact error={services.error} onRetry={() => void services.refetch()} />
            ) : (services.data ?? []).length === 0 ? (
              <p className="text-muted text-sm">Your catalog has no active services yet.</p>
            ) : (
              <>
                <SearchInput
                  label="Search services"
                  value={serviceSearch}
                  onChange={setServiceSearch}
                  debounceMs={0}
                />
                <div className="border-line rounded-control max-h-56 overflow-y-auto border p-3">
                  <div className="flex flex-col gap-2">
                    {visibleServices.map((service) => (
                      <Checkbox
                        key={service.id}
                        label={service.name}
                        checked={field.value.includes(service.id)}
                        onChange={(event) =>
                          field.onChange(
                            event.target.checked
                              ? [...field.value, service.id]
                              : field.value.filter((id) => id !== service.id),
                          )
                        }
                      />
                    ))}
                    {visibleServices.length === 0 && (
                      <p className="text-muted text-sm">No services match.</p>
                    )}
                  </div>
                </div>
                <p className="text-muted text-xs" aria-live="polite">
                  {field.value.length} selected
                </p>
              </>
            )}
            {errors.included_service_ids?.message && (
              <p role="alert" className="text-danger-ink text-xs font-medium">
                {errors.included_service_ids.message}
              </p>
            )}
          </fieldset>
        )}
      />

      <Controller
        control={form.control}
        name="active"
        render={({ field }) => (
          <Switch
            checked={field.value}
            onCheckedChange={field.onChange}
            label="Available for new sign-ups"
            description="Turn off to stop offering the plan without affecting current members."
          />
        )}
      />

      <div className="flex flex-wrap justify-end gap-2">
        <Button variant="secondary" onClick={onClose} disabled={isSubmitting}>
          Cancel
        </Button>
        <Button type="submit" loading={isSubmitting}>
          {plan ? 'Save plan' : 'Create plan'}
        </Button>
      </div>
    </form>
  );
}
