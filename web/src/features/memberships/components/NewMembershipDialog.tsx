import { useState } from 'react';
import { Button, Dialog, FormField, Select, useToast } from '@/components/ui';
import { formatCents } from '@/lib/money';
import { useShop } from '@/features/shop/shopContext';
import type { PickerCustomer } from '@/features/quotes/shared/api';
import { CustomerCombobox, VehicleSelect } from '@/features/quotes/shared/CustomerPicker';
import { billingLabel, useCreateMembership, usePlans } from '../api';
import type { CheckoutTarget } from './CheckoutLinkDialog';

export interface NewMembershipDialogProps {
  open: boolean;
  onClose: () => void;
  /** Called with the new (incomplete) membership, e.g. to open the checkout link. */
  onCreated: (membership: CheckoutTarget) => void;
}

export function NewMembershipDialog(props: NewMembershipDialogProps) {
  return (
    <Dialog
      open={props.open}
      onClose={props.onClose}
      title="New membership"
      description="Creates the membership; it becomes active when the customer completes checkout."
    >
      {props.open && <NewMembershipForm {...props} />}
    </Dialog>
  );
}

function NewMembershipForm({ onClose, onCreated }: NewMembershipDialogProps) {
  const toast = useToast();
  const { currency } = useShop();
  const plans = usePlans();
  const create = useCreateMembership();
  const [customer, setCustomer] = useState<PickerCustomer | null>(null);
  const [planId, setPlanId] = useState('');
  const [vehicleId, setVehicleId] = useState<string | null>(null);
  const [submitted, setSubmitted] = useState(false);

  const available = (plans.data ?? []).filter((p) => p.active);
  const errors = {
    customer: customer ? undefined : 'Choose a customer.',
    plan: planId ? undefined : 'Choose a plan.',
  };

  const submit = async () => {
    setSubmitted(true);
    if (!customer || !planId) return;
    try {
      const membership = await create.mutateAsync({ planId, customerId: customer.id, vehicleId });
      const plan = available.find((p) => p.id === planId) ?? null;
      toast.success('Membership created');
      onCreated({
        id: membership.id,
        customer,
        plan: plan
          ? {
              id: plan.id,
              name: plan.name,
              price_cents: plan.price_cents,
              interval: plan.interval,
              interval_count: plan.interval_count,
            }
          : null,
      });
    } catch (error) {
      toast.error(error);
    }
  };

  return (
    <form
      noValidate
      className="flex flex-col gap-4"
      onSubmit={(event) => {
        event.preventDefault();
        void submit();
      }}
    >
      <FormField label="Customer" required error={submitted ? errors.customer : undefined}>
        <CustomerCombobox
          value={customer}
          onChange={(next) => {
            setCustomer(next);
            setVehicleId(null);
          }}
        />
      </FormField>
      <FormField
        label="Plan"
        required
        error={submitted ? errors.plan : undefined}
        help={
          plans.isError
            ? 'Couldn’t load plans.'
            : plans.isSuccess && available.length === 0
              ? 'No plans are available. Create one on the Plans tab.'
              : undefined
        }
      >
        <Select
          value={planId}
          onChange={(event) => setPlanId(event.target.value)}
          placeholder={plans.isPending ? 'Loading plans…' : 'Choose a plan'}
          disabled={plans.isPending}
          options={available.map((p) => ({
            value: p.id,
            label: `${p.name} — ${billingLabel(formatCents(p.price_cents, { currency }), p.interval, p.interval_count)}`,
          }))}
        />
      </FormField>
      <FormField label="Vehicle" help="Optional. Limit the membership to one vehicle.">
        <VehicleSelect
          customerId={customer?.id ?? null}
          value={vehicleId}
          onChange={setVehicleId}
          emptyLabel="Any of the customer’s vehicles"
        />
      </FormField>
      <div className="flex flex-wrap justify-end gap-2">
        <Button variant="secondary" onClick={onClose} disabled={create.isPending}>
          Cancel
        </Button>
        <Button type="submit" loading={create.isPending}>
          Create membership
        </Button>
      </div>
    </form>
  );
}
