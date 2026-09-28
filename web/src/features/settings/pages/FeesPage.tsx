import { zodResolver } from '@hookform/resolvers/zod';
import { Pencil, Plus, Receipt, Trash2 } from 'lucide-react';
import { useState } from 'react';
import { Controller, useForm } from 'react-hook-form';
import { z } from 'zod';
import {
  Badge,
  Button,
  Card,
  ConfirmDialog,
  Dialog,
  EmptyState,
  FormField,
  IconButton,
  Input,
  MoneyInput,
  Select,
  Switch,
  Table,
  useToast,
  type Column,
} from '@/components/ui';
import { useShop } from '@/features/shop/shopContext';
import { toAppError } from '@/lib/errors';
import { formatCents } from '@/lib/money';
import { zRequiredText } from '@/lib/validation';
import { QueryView, SettingsSectionLayout } from '../components/SettingsSectionLayout';
import {
  FEE_AUTO_APPLY_LABELS,
  useDeleteFee,
  useSaveFee,
  useShopFees,
  type FeeAutoApply,
  type ShopFee,
} from '../data/fees';
import { useSettingsAccess } from '../useSettingsAccess';

const AUTO_APPLY = ['none', 'mobile', 'shop', 'both'] as const satisfies readonly FeeAutoApply[];

const feeSchema = z.object({
  name: zRequiredText('Name', 80),
  amountCents: z
    .number({ error: 'Enter an amount.' })
    .int()
    .min(1, 'The amount must be more than zero.'),
  taxable: z.boolean(),
  autoApply: z.enum(AUTO_APPLY),
  active: z.boolean(),
});
type FeeFormInput = z.input<typeof feeSchema>;
type FeeFormValues = z.output<typeof feeSchema>;

export default function FeesPage() {
  const { readOnly, canEdit } = useSettingsAccess();
  const { currency } = useShop();
  const query = useShopFees();
  const remove = useDeleteFee();
  const toast = useToast();
  const [editing, setEditing] = useState<{ fee: ShopFee | null } | null>(null);
  const [deleting, setDeleting] = useState<ShopFee | null>(null);

  const columns: Column<ShopFee>[] = [
    { key: 'name', header: 'Fee', primary: true, cell: (f) => f.name },
    {
      key: 'amount',
      header: 'Amount',
      align: 'right',
      cell: (f) => (
        <span className="tabular-nums">{formatCents(f.amount_cents, { currency })}</span>
      ),
    },
    { key: 'apply', header: 'When', cell: (f) => FEE_AUTO_APPLY_LABELS[f.auto_apply] },
    {
      key: 'status',
      header: 'Status',
      cell: (f) => (
        <span className="inline-flex flex-wrap gap-1">
          <Badge tone={f.active ? 'success' : 'neutral'}>{f.active ? 'On' : 'Off'}</Badge>
          {f.taxable && <Badge tone="info">Taxable</Badge>}
        </span>
      ),
    },
    ...(canEdit
      ? [
          {
            key: 'actions',
            header: <span className="sr-only">Actions</span>,
            align: 'right' as const,
            cell: (f: ShopFee) => (
              <div className="flex justify-end gap-1">
                <IconButton
                  label={`Edit fee ${f.name}`}
                  icon={<Pencil />}
                  size="sm"
                  onClick={() => setEditing({ fee: f })}
                />
                <IconButton
                  label={`Delete fee ${f.name}`}
                  icon={<Trash2 />}
                  size="sm"
                  variant="danger"
                  onClick={() => setDeleting(f)}
                />
              </div>
            ),
          },
        ]
      : []),
  ];

  return (
    <SettingsSectionLayout
      section="fees"
      readOnly={readOnly}
      actions={
        canEdit && (
          <Button
            leadingIcon={<Plus className="size-4" aria-hidden="true" />}
            onClick={() => setEditing({ fee: null })}
          >
            Add fee
          </Button>
        )
      }
    >
      <p className="text-muted text-sm">
        A fee is added to a job, quote or invoice as a normal line, so it counts toward the total
        and deposit like any service. Automatic fees are added when a job is created with that
        location (including online bookings) and removed if the location changes.
      </p>
      <QueryView query={query} label="fees">
        {(fees) =>
          fees.length === 0 ? (
            <Card>
              <EmptyState
                icon={<Receipt aria-hidden="true" />}
                title="No fees yet"
                description="Add fees you charge often, such as a travel fee for mobile jobs."
                action={
                  canEdit && (
                    <Button variant="secondary" onClick={() => setEditing({ fee: null })}>
                      Add fee
                    </Button>
                  )
                }
              />
            </Card>
          ) : (
            <Card className="overflow-hidden">
              <Table caption="Fees" columns={columns} rows={fees} getRowId={(f) => f.id} />
            </Card>
          )
        }
      </QueryView>

      {editing && (
        <FeeDialog
          fee={editing.fee}
          nextSort={(query.data?.length ?? 0) + 1}
          onClose={() => setEditing(null)}
        />
      )}
      <ConfirmDialog
        open={deleting !== null}
        onClose={() => setDeleting(null)}
        tone="danger"
        title={`Delete the fee ${deleting?.name ?? ''}?`}
        description="Jobs, quotes and invoices that already have it keep their line. To stop using it but keep it for later, turn it off instead."
        confirmLabel="Delete"
        loading={remove.isPending}
        onConfirm={async () => {
          if (!deleting) return;
          try {
            await remove.mutateAsync(deleting.id);
            toast.success(`${deleting.name} deleted`);
            setDeleting(null);
          } catch (error) {
            toast.error(error);
          }
        }}
      />
    </SettingsSectionLayout>
  );
}

function FeeDialog({
  fee,
  nextSort,
  onClose,
}: {
  fee: ShopFee | null;
  nextSort: number;
  onClose: () => void;
}) {
  const toast = useToast();
  const save = useSaveFee();
  const {
    register,
    control,
    handleSubmit,
    formState: { errors },
  } = useForm<FeeFormInput, unknown, FeeFormValues>({
    resolver: zodResolver(feeSchema),
    defaultValues: {
      name: fee?.name ?? '',
      amountCents: fee?.amount_cents ?? Number.NaN,
      taxable: fee?.taxable ?? false,
      autoApply: fee?.auto_apply ?? 'none',
      active: fee?.active ?? true,
    },
  });

  const onSubmit = handleSubmit(async (v) => {
    try {
      await save.mutateAsync({
        id: fee?.id,
        name: v.name,
        amount_cents: v.amountCents,
        taxable: v.taxable,
        auto_apply: v.autoApply,
        active: v.active,
        ...(fee ? {} : { sort: nextSort }),
      });
      toast.success(fee ? 'Fee saved' : 'Fee added');
      onClose();
    } catch (error) {
      toast.error(toAppError(error));
    }
  });

  const formId = 'fee-form';
  return (
    <Dialog
      open
      onClose={onClose}
      dismissible={!save.isPending}
      title={fee ? `Edit ${fee.name}` : 'New fee'}
      footer={
        <>
          <Button variant="secondary" onClick={onClose} disabled={save.isPending}>
            Cancel
          </Button>
          <Button type="submit" form={formId} loading={save.isPending}>
            {fee ? 'Save' : 'Add fee'}
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
        <FormField
          label="Name"
          required
          error={errors.name?.message}
          help="Shown on the line, e.g. Travel fee."
        >
          <Input maxLength={80} autoComplete="off" {...register('name')} />
        </FormField>
        <FormField label="Amount" required error={errors.amountCents?.message}>
          <Controller
            control={control}
            name="amountCents"
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
        <FormField label="When to add it" error={errors.autoApply?.message}>
          <Select
            options={AUTO_APPLY.map((v) => ({ value: v, label: FEE_AUTO_APPLY_LABELS[v] }))}
            {...register('autoApply')}
          />
        </FormField>
        <Controller
          control={control}
          name="taxable"
          render={({ field }) => (
            <Switch
              label="Taxable"
              description="Sales tax applies to this fee."
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
              label="On"
              description="Off: not offered and never added automatically."
              checked={field.value}
              onCheckedChange={field.onChange}
            />
          )}
        />
      </form>
    </Dialog>
  );
}
