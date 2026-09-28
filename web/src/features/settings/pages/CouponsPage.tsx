import { zodResolver } from '@hookform/resolvers/zod';
import { Pencil, Plus, TicketPercent, Trash2 } from 'lucide-react';
import { useMemo, useState } from 'react';
import { Controller, useForm, useWatch, type Control, type FieldErrors } from 'react-hook-form';
import {
  Badge,
  Button,
  Card,
  Combobox,
  ConfirmDialog,
  DateInput,
  Dialog,
  EmptyState,
  FormField,
  IconButton,
  Input,
  MoneyInput,
  RadioGroup,
  Switch,
  Table,
  useToast,
  type BadgeTone,
  type Column,
} from '@/components/ui';
import { useShop } from '@/features/shop/shopContext';
import { toAppError } from '@/lib/errors';
import { useCoupons, useDeleteCoupon, useSaveCoupon, type Coupon } from '../api';
import {
  COUPON_STATE_LABELS,
  couponRestrictions,
  couponState,
  couponToFormInput,
  describeDiscount,
  describeWindow,
  type CouponState,
} from '../coupons';
import { QueryView, SettingsSectionLayout } from '../components/SettingsSectionLayout';
import { ServiceChecklist } from '../components/ServiceChecklist';
import {
  customerLabel,
  useCustomerOption,
  useCustomerOptions,
  useServiceOptions,
  type CustomerOption,
} from '../data/pickers';
import { couponSchema, type CouponFormInput, type CouponFormValues } from '../schemas';
import { useSettingsAccess } from '../useSettingsAccess';

const STATE_TONES: Record<CouponState, BadgeTone> = {
  active: 'success',
  inactive: 'neutral',
  scheduled: 'info',
  expired: 'neutral',
  used_up: 'warning',
};

type Editing = { coupon: Coupon | null } | null;

export default function CouponsPage() {
  const { readOnly, canEdit } = useSettingsAccess();
  const { timezone, currency } = useShop();
  const query = useCoupons();
  const remove = useDeleteCoupon();
  const toast = useToast();
  const [editing, setEditing] = useState<Editing>(null);
  const [deleting, setDeleting] = useState<Coupon | null>(null);

  const columns: Column<Coupon>[] = [
    {
      key: 'code',
      header: 'Code',
      primary: true,
      cell: (c) => (
        <span className="flex flex-col">
          <span className="font-mono font-semibold">{c.code}</span>
          {c.description && <span className="text-muted text-xs font-normal">{c.description}</span>}
        </span>
      ),
    },
    { key: 'discount', header: 'Discount', cell: (c) => describeDiscount(c, currency) },
    { key: 'window', header: 'Valid', cell: (c) => describeWindow(c, timezone) },
    {
      key: 'limits',
      header: 'Limits',
      hideOnMobile: true,
      cell: (c) => {
        const limits = couponRestrictions(c, currency);
        return limits.length === 0 ? (
          <span className="text-muted">None</span>
        ) : (
          <span className="flex flex-wrap gap-1">
            {limits.map((l) => (
              <Badge key={l} tone="neutral">
                {l}
              </Badge>
            ))}
          </span>
        );
      },
    },
    {
      key: 'redemptions',
      header: 'Used',
      align: 'right',
      cell: (c) => (
        <span className="tabular-nums">
          {c.redemptions}
          {c.max_redemptions !== null && <span className="text-muted"> / {c.max_redemptions}</span>}
        </span>
      ),
    },
    {
      key: 'status',
      header: 'Status',
      cell: (c) => {
        const state = couponState(c);
        return (
          <span className="inline-flex flex-wrap justify-end gap-1 md:justify-start">
            <Badge tone={STATE_TONES[state]}>{COUPON_STATE_LABELS[state]}</Badge>
            {c.online_only && <Badge tone="info">Online only</Badge>}
          </span>
        );
      },
    },
    ...(canEdit
      ? [
          {
            key: 'actions',
            header: <span className="sr-only">Actions</span>,
            align: 'right' as const,
            cell: (c: Coupon) => (
              <div className="flex justify-end gap-1">
                <IconButton
                  label={`Edit coupon ${c.code}`}
                  icon={<Pencil />}
                  size="sm"
                  onClick={() => setEditing({ coupon: c })}
                />
                <IconButton
                  label={`Delete coupon ${c.code}`}
                  icon={<Trash2 />}
                  size="sm"
                  variant="danger"
                  onClick={() => setDeleting(c)}
                />
              </div>
            ),
          },
        ]
      : []),
  ];

  return (
    <SettingsSectionLayout
      section="coupons"
      readOnly={readOnly}
      actions={
        canEdit && (
          <Button
            leadingIcon={<Plus className="size-4" aria-hidden="true" />}
            onClick={() => setEditing({ coupon: null })}
          >
            Add coupon
          </Button>
        )
      }
    >
      <QueryView query={query} label="coupons">
        {(coupons) =>
          coupons.length === 0 ? (
            <Card>
              <EmptyState
                icon={<TicketPercent aria-hidden="true" />}
                title="No coupons yet"
                description="Create codes customers can enter when booking online, or that staff apply to jobs."
                action={
                  canEdit && (
                    <Button variant="secondary" onClick={() => setEditing({ coupon: null })}>
                      Add coupon
                    </Button>
                  )
                }
              />
            </Card>
          ) : (
            <Card className="overflow-hidden">
              <Table caption="Coupons" columns={columns} rows={coupons} getRowId={(c) => c.id} />
            </Card>
          )
        }
      </QueryView>

      {editing && <CouponDialog coupon={editing.coupon} onClose={() => setEditing(null)} />}
      <ConfirmDialog
        open={deleting !== null}
        onClose={() => setDeleting(null)}
        tone="danger"
        title={`Delete coupon ${deleting?.code ?? ''}?`}
        description={
          deleting && deleting.redemptions > 0
            ? `It has been used ${deleting.redemptions} time${deleting.redemptions === 1 ? '' : 's'}. Jobs that used it keep their discount but lose the link to the code. To stop new use but keep the history, turn it off instead.`
            : 'Customers will no longer be able to use this code.'
        }
        confirmLabel="Delete"
        loading={remove.isPending}
        onConfirm={async () => {
          if (!deleting) return;
          try {
            await remove.mutateAsync(deleting.id);
            toast.success(`Coupon ${deleting.code} deleted`);
            setDeleting(null);
          } catch (error) {
            toast.error(error);
          }
        }}
      />
    </SettingsSectionLayout>
  );
}

function CouponDialog({ coupon, onClose }: { coupon: Coupon | null; onClose: () => void }) {
  const { timezone } = useShop();
  const toast = useToast();
  const save = useSaveCoupon();
  const schema = useMemo(() => couponSchema(timezone), [timezone]);
  const {
    register,
    control,
    handleSubmit,
    setError,
    formState: { errors },
  } = useForm<CouponFormInput, unknown, CouponFormValues>({
    resolver: zodResolver(schema),
    defaultValues: couponToFormInput(coupon, timezone),
  });
  const kind = useWatch({ control, name: 'kind' });

  const onSubmit = handleSubmit(async (values) => {
    try {
      await save.mutateAsync({ id: coupon?.id, ...values });
      toast.success(coupon ? 'Coupon updated' : 'Coupon created');
      onClose();
    } catch (error) {
      const appError = toAppError(error);
      if (appError.code === '23505') {
        setError('code', { message: 'You already have a coupon with this code.' });
        return;
      }
      toast.error(appError);
    }
  });

  const formId = 'coupon-form';
  return (
    <Dialog
      open
      onClose={onClose}
      dismissible={!save.isPending}
      size="lg"
      title={coupon ? `Edit coupon ${coupon.code}` : 'New coupon'}
      description={
        coupon
          ? `Used ${coupon.redemptions} time${coupon.redemptions === 1 ? '' : 's'} so far.`
          : undefined
      }
      footer={
        <>
          <Button variant="secondary" onClick={onClose} disabled={save.isPending}>
            Cancel
          </Button>
          <Button type="submit" form={formId} loading={save.isPending}>
            {coupon ? 'Save' : 'Create coupon'}
          </Button>
        </>
      }
    >
      <form
        id={formId}
        noValidate
        onSubmit={(e) => void onSubmit(e)}
        className="grid gap-4 sm:grid-cols-2"
      >
        <FormField
          label="Code"
          required
          error={errors.code?.message}
          help="What customers type, e.g. SPRING15. Not case-sensitive."
        >
          <Input
            autoCapitalize="characters"
            className="font-mono uppercase"
            maxLength={40}
            {...register('code')}
          />
        </FormField>
        <FormField
          label="Description"
          error={errors.description?.message}
          help="Internal note (optional)."
        >
          <Input maxLength={500} {...register('description')} />
        </FormField>
        <Controller
          control={control}
          name="kind"
          render={({ field }) => (
            <RadioGroup
              label="Discount type"
              value={field.value}
              onChange={field.onChange}
              options={[
                { value: 'percent', label: 'Percent off' },
                { value: 'fixed', label: 'Amount off' },
              ]}
            />
          )}
        />
        {kind === 'percent' ? (
          <FormField label="Percent off" required error={errors.percent?.message}>
            <Input inputMode="decimal" trailing="%" {...register('percent')} />
          </FormField>
        ) : (
          <FormField label="Amount off" required error={errors.amountCents?.message}>
            <Controller
              control={control}
              name="amountCents"
              render={({ field }) => (
                <MoneyInput
                  value={field.value}
                  onChange={field.onChange}
                  onBlur={field.onBlur}
                  name={field.name}
                  ref={field.ref}
                />
              )}
            />
          </FormField>
        )}
        <FormField
          label="First day"
          error={errors.startDate?.message}
          help="Leave empty to start now."
        >
          <DateInput {...register('startDate')} />
        </FormField>
        <FormField
          label="Last day"
          error={errors.endDate?.message}
          help="Leave empty for no end date."
        >
          <DateInput {...register('endDate')} />
        </FormField>
        <FormField
          label="Maximum uses"
          error={errors.maxRedemptions?.message}
          help="Total times the code can be used. Leave empty for unlimited."
        >
          <Input inputMode="numeric" {...register('maxRedemptions')} />
        </FormField>
        <div className="flex flex-col gap-3 sm:col-span-2">
          <Controller
            control={control}
            name="onlineOnly"
            render={({ field }) => (
              <Switch
                label="Online booking only"
                description="Only customers booking on your booking page can use it."
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
                label="Active"
                description="Turn off to stop the code working without deleting it."
                checked={field.value}
                onCheckedChange={field.onChange}
              />
            )}
          />
        </div>
        <CouponRestrictionsFields control={control} errors={errors} />
      </form>
    </Dialog>
  );
}

function CouponRestrictionsFields({
  control,
  errors,
}: {
  control: Control<CouponFormInput, unknown, CouponFormValues>;
  errors: FieldErrors<CouponFormInput>;
}) {
  const services = useServiceOptions();
  const limitServices = useWatch({ control, name: 'limitServices' });
  const customerId = useWatch({ control, name: 'customerId' });
  const [customerQuery, setCustomerQuery] = useState('');
  const customers = useCustomerOptions(customerQuery);
  const selectedCustomer = useCustomerOption(customerId ?? null);

  return (
    <fieldset className="border-line flex flex-col gap-4 border-t pt-4 sm:col-span-2">
      <legend className="text-ink float-left mb-1 w-full text-sm font-semibold">
        Restrictions
      </legend>
      <Controller
        control={control}
        name="limitServices"
        render={({ field }) => (
          <Switch
            label="Only for some services"
            description="The discount applies only to these services; the job needs at least one of them."
            checked={field.value}
            onCheckedChange={field.onChange}
          />
        )}
      />
      {limitServices && (
        <Controller
          control={control}
          name="serviceIds"
          render={({ field }) =>
            services.isPending ? (
              <p className="text-muted text-sm">Loading services…</p>
            ) : services.isError ? (
              <p role="alert" className="text-danger-ink text-sm">
                Couldn’t load your services.
              </p>
            ) : (
              <ServiceChecklist
                legend="Services the coupon applies to"
                services={services.data}
                value={field.value}
                onChange={field.onChange}
                max={100}
                error={errors.serviceIds?.message}
              />
            )
          }
        />
      )}
      <FormField
        label="Minimum spend"
        error={errors.minSubtotalCents?.message}
        help="On the services the coupon applies to, before tax. Leave empty for none."
        className="max-w-xs"
      >
        <Controller
          control={control}
          name="minSubtotalCents"
          render={({ field }) => (
            <MoneyInput
              value={field.value}
              onChange={field.onChange}
              onBlur={field.onBlur}
              name={field.name}
              ref={field.ref}
            />
          )}
        />
      </FormField>
      <Controller
        control={control}
        name="oncePerCustomer"
        render={({ field }) => (
          <Switch
            label="Once per customer"
            description="Each customer can use the code on one job."
            checked={field.value}
            onCheckedChange={field.onChange}
          />
        )}
      />
      <Controller
        control={control}
        name="newCustomersOnly"
        render={({ field }) => (
          <Switch
            label="New customers only"
            description="Only customers without a completed job or a payment can use it."
            checked={field.value}
            onCheckedChange={field.onChange}
          />
        )}
      />
      {errors.newCustomersOnly?.message && (
        <p role="alert" className="text-danger-ink text-xs font-medium">
          {errors.newCustomersOnly.message}
        </p>
      )}
      <FormField
        label="Only for this customer"
        help="Leave empty so anyone can use the code."
        className="max-w-md"
      >
        <Controller
          control={control}
          name="customerId"
          render={({ field }) => (
            <Combobox<CustomerOption>
              value={
                field.value
                  ? (customers.data?.find((c) => c.id === field.value) ??
                    selectedCustomer.data ??
                    null)
                  : null
              }
              onChange={(c) => field.onChange(c?.id ?? null)}
              options={customers.data ?? []}
              onQueryChange={setCustomerQuery}
              getOptionValue={(c) => c.id}
              getOptionLabel={customerLabel}
              loading={customers.isFetching}
              placeholder="Search customers…"
              emptyText="No customers match"
            />
          )}
        />
      </FormField>
    </fieldset>
  );
}
