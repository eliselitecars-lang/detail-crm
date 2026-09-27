import { useState } from 'react';
import {
  Button,
  Dialog,
  ErrorState,
  FormField,
  Input,
  LoadingState,
  MoneyInput,
  RadioGroup,
  Select,
  useToast,
} from '@/components/ui';
import { bpsToPercentInput, formatBps, formatCents, parsePercentToBps } from '@/lib/money';
import { useShop } from '@/features/shop/shopContext';
import { useActiveCoupons, useUpdateJob, type JobDetail } from '../../api';

type Mode = 'none' | 'percent' | 'fixed' | 'coupon';

/**
 * Document discount: manual (percent / fixed) or a coupon. A coupon's
 * discount is derived and redeemed by the server (jobs_apply_coupon); we
 * only attach or detach it. The discount amount itself is computed by the
 * jobs totals trigger.
 */
export function DiscountDialog({ job, onClose }: { job: JobDetail; onClose: () => void }) {
  const { currency } = useShop();
  const toast = useToast();
  const update = useUpdateJob(job.id);
  const coupons = useActiveCoupons(true);
  const [mode, setMode] = useState<Mode>(
    job.coupon_id ? 'coupon' : job.discount_kind === 'none' ? 'none' : job.discount_kind,
  );
  const [percent, setPercent] = useState(
    job.discount_kind === 'percent' && !job.coupon_id ? bpsToPercentInput(job.discount_value) : '',
  );
  const [fixed, setFixed] = useState<number | null>(
    job.discount_kind === 'fixed' && !job.coupon_id ? job.discount_value : null,
  );
  const [couponId, setCouponId] = useState(job.coupon_id ?? '');
  const [error, setError] = useState<string | null>(null);

  const save = async () => {
    setError(null);
    let patch: Parameters<typeof update.mutateAsync>[0];
    if (mode === 'coupon') {
      if (!couponId) {
        setError('Choose a coupon.');
        return;
      }
      patch = { coupon_id: couponId };
    } else if (mode === 'percent') {
      const bps = parsePercentToBps(percent);
      if (bps === null || bps <= 0) {
        setError('Enter a percentage between 0 and 100.');
        return;
      }
      patch = { coupon_id: null, discount_kind: 'percent', discount_value: bps };
    } else if (mode === 'fixed') {
      if (fixed === null || fixed <= 0) {
        setError('Enter an amount.');
        return;
      }
      patch = { coupon_id: null, discount_kind: 'fixed', discount_value: fixed };
    } else {
      patch = { coupon_id: null, discount_kind: 'none', discount_value: 0 };
    }
    try {
      await update.mutateAsync(patch);
      toast.success('Discount saved');
      onClose();
    } catch (err) {
      toast.error(err);
    }
  };

  return (
    <Dialog
      open
      onClose={onClose}
      title="Discount"
      description="Applies to the subtotal; the server recalculates tax and the total."
      size="sm"
      dismissible={!update.isPending}
      footer={
        <>
          <Button variant="secondary" onClick={onClose} disabled={update.isPending}>
            Cancel
          </Button>
          <Button loading={update.isPending} onClick={() => void save()}>
            Save
          </Button>
        </>
      }
    >
      <div className="flex flex-col gap-4">
        <RadioGroup<Mode>
          label="Discount type"
          value={mode}
          onChange={setMode}
          options={[
            { value: 'none', label: 'No discount' },
            { value: 'percent', label: 'Percent off' },
            { value: 'fixed', label: 'Amount off' },
            { value: 'coupon', label: 'Coupon' },
          ]}
        />
        {mode === 'percent' && (
          <FormField label="Percent">
            <Input
              inputMode="decimal"
              trailing="%"
              value={percent}
              onChange={(e) => setPercent(e.target.value)}
            />
          </FormField>
        )}
        {mode === 'fixed' && (
          <FormField label="Amount">
            <MoneyInput value={fixed} onChange={setFixed} />
          </FormField>
        )}
        {mode === 'coupon' &&
          (coupons.isPending ? (
            <LoadingState label="Loading coupons…" />
          ) : coupons.isError ? (
            <ErrorState compact error={coupons.error} onRetry={() => void coupons.refetch()} />
          ) : (
            <FormField
              label="Coupon"
              help={coupons.data.length === 0 ? 'No active coupons. Add one in Settings.' : undefined}
            >
              <Select
                value={couponId}
                onChange={(e) => setCouponId(e.target.value)}
                placeholder="Choose a coupon"
                options={coupons.data.map((c) => ({
                  value: c.id,
                  label: `${c.code} — ${c.kind === 'percent' ? formatBps(c.value) : formatCents(c.value, { currency })} off`,
                }))}
              />
            </FormField>
          ))}
        {error && (
          <p role="alert" className="text-danger-ink text-sm">
            {error}
          </p>
        )}
      </div>
    </Dialog>
  );
}
