import { useState } from 'react';
import { Button, Dialog, RadioGroup, useToast } from '@/components/ui';
import { formatDate } from '@/lib/dates';
import { useShop } from '@/features/shop/shopContext';
import { customerName } from '@/features/quotes/shared/format';
import { useCancelMembership, type SubscriberRow } from '../api';

export interface CancelMembershipDialogProps {
  membership: SubscriberRow | null;
  onClose: () => void;
}

export function CancelMembershipDialog({ membership, onClose }: CancelMembershipDialogProps) {
  return (
    <Dialog
      open={membership !== null}
      onClose={onClose}
      title="Cancel membership"
      description={
        membership
          ? `${membership.plan?.name ?? 'Membership'} for ${customerName(membership.customer)}`
          : undefined
      }
      size="sm"
      role="alertdialog"
    >
      {membership && <CancelForm membership={membership} onClose={onClose} />}
    </Dialog>
  );
}

function CancelForm({ membership, onClose }: { membership: SubscriberRow; onClose: () => void }) {
  const toast = useToast();
  const { timezone } = useShop();
  const cancel = useCancelMembership();
  const billed = membership.stripe_subscription_id !== null && membership.status !== 'incomplete';
  const canWait =
    billed && membership.current_period_end !== null && !membership.cancel_at_period_end;
  const [when, setWhen] = useState<'period_end' | 'now'>(canWait ? 'period_end' : 'now');

  const submit = async () => {
    try {
      const result = await cancel.mutateAsync({
        membershipId: membership.id,
        atPeriodEnd: when === 'period_end',
      });
      toast.success(
        result.cancel_at_period_end && result.current_period_end
          ? `Membership ends ${formatDate(result.current_period_end, timezone)}`
          : 'Membership cancelled',
      );
      onClose();
    } catch (error) {
      toast.error(error);
    }
  };

  return (
    <div className="flex flex-col gap-4">
      {billed ? (
        <RadioGroup<'period_end' | 'now'>
          label="When should it end?"
          value={when}
          onChange={setWhen}
          options={[
            {
              value: 'period_end',
              label: 'At the end of the paid period',
              description: membership.current_period_end
                ? `Keeps benefits until ${formatDate(membership.current_period_end, timezone)}; no further charges.`
                : 'No further charges.',
              disabled: !canWait,
            },
            {
              value: 'now',
              label: 'Immediately',
              description: 'Stops billing and benefits now. No automatic refund is issued.',
            },
          ]}
        />
      ) : (
        <p className="text-ink text-sm">
          This membership was never paid for, so nothing is billed. Cancelling abandons it.
        </p>
      )}
      <div className="flex flex-wrap justify-end gap-2">
        <Button variant="secondary" onClick={onClose} disabled={cancel.isPending}>
          Keep membership
        </Button>
        <Button variant="danger" loading={cancel.isPending} onClick={() => void submit()}>
          Cancel membership
        </Button>
      </div>
    </div>
  );
}
