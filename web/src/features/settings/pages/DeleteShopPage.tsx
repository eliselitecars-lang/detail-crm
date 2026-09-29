import { Info, Trash2 } from 'lucide-react';
import { useId, useRef, useState, type FormEvent } from 'react';
import { useNavigate } from 'react-router';
import { Button, Dialog, FormField, Input, SectionCard, useToast } from '@/components/ui';
import { useShopBillingStatus, useShopEntitlement } from '@/features/billing/api';
import { entitlementShowsSubscription, hasLiveSubscription } from '@/features/billing/model';
import { useShop } from '@/features/shop/shopContext';
import { deleteShopErrorMessage, useBillingMembershipCount, useDeleteShop } from '../api';
import { QueryView, SettingsSectionLayout } from '../components/SettingsSectionLayout';
import { confirmationMatches } from '../deleteShop';

/**
 * Owner only (route guard + nav: shop.delete; the payments function checks
 * the owner again). The server stops the shop's own platform subscription
 * from renewing, cancels its customers' memberships in Stripe, expires open
 * pay links and then deletes the shop (every tenant row cascades); after the
 * delete the platform subscription is cancelled now. That happens whenever
 * a subscription can still bill, even with platform billing switched off.
 */
export default function DeleteShopPage() {
  const query = useBillingMembershipCount(true);
  return (
    <SettingsSectionLayout section="delete-shop">
      <QueryView query={query} label="shop details">
        {(billing) => <DeleteShopCard billingMemberships={billing} />}
      </QueryView>
    </SettingsSectionLayout>
  );
}

function DeleteShopCard({ billingMemberships }: { billingMemberships: number }) {
  const { shop, shopId } = useShop();
  const [open, setOpen] = useState(false);
  // Deleting also ends the shop's own subscription whenever one can still
  // bill: shop_billing says so, or (row unreadable) the entitlement does.
  // Billing switched off platform-wide doesn't stop an existing one billing.
  const entitlement = useShopEntitlement(shopId).data;
  const billing = useShopBillingStatus(shopId, true).data;
  const endsSubscription =
    (billing != null && hasLiveSubscription(billing.status)) ||
    (entitlement != null && entitlementShowsSubscription(entitlement, { liveOnly: true }));
  return (
    <SectionCard
      title="Delete this shop"
      description="Permanently removes the shop for everyone on your team. This cannot be undone."
    >
      <div className="flex flex-col gap-4 text-sm">
        <ul className="text-muted flex list-disc flex-col gap-1.5 pl-5">
          <li>
            All customers, vehicles, jobs, quotes, invoices, payment records, memberships, messages,
            photos, forms and settings of <strong className="text-ink">{shop.name}</strong> are
            deleted.
          </li>
          <li>Your team members and customers lose access to this shop immediately.</li>
          <li>Your public booking page and portal links stop working.</li>
          <li>
            Your Stripe account is not closed: money already collected stays in Stripe, and you
            manage or close the account at stripe.com.
          </li>
          {endsSubscription && (
            <li>
              This shop’s Detail CRM subscription is cancelled right away, so it isn’t charged
              again.
            </li>
          )}
        </ul>
        {billingMemberships > 0 && (
          <p
            role="status"
            className="rounded-card border-primary/25 bg-primary-soft text-primary-ink flex gap-2 border px-3 py-2"
          >
            <Info className="mt-0.5 size-4 shrink-0" aria-hidden="true" />
            <span>
              {billingMemberships === 1
                ? '1 active membership will be cancelled in Stripe'
                : `${billingMemberships} active memberships will be cancelled in Stripe`}
              , so those customers are not charged again. Open pay and deposit links stop working.
            </span>
          </p>
        )}
        <div>
          <Button variant="danger" onClick={() => setOpen(true)}>
            <Trash2 className="size-4" aria-hidden="true" />
            Delete shop…
          </Button>
        </div>
      </div>
      <DeleteShopDialog
        open={open}
        onClose={() => setOpen(false)}
        shopName={shop.name}
        endsSubscription={endsSubscription}
      />
    </SectionCard>
  );
}

function DeleteShopDialog({
  open,
  onClose,
  shopName,
  endsSubscription,
}: {
  open: boolean;
  onClose: () => void;
  shopName: string;
  endsSubscription: boolean;
}) {
  const toast = useToast();
  const navigate = useNavigate();
  const remove = useDeleteShop();
  const [typed, setTyped] = useState('');
  const inputRef = useRef<HTMLInputElement>(null);
  const formId = useId();
  const matches = confirmationMatches(typed, shopName);

  const close = () => {
    if (remove.isPending) return;
    setTyped('');
    remove.reset();
    onClose();
  };

  const onSubmit = async (event: FormEvent) => {
    event.preventDefault();
    if (!matches || remove.isPending) return;
    try {
      const result = await remove.mutateAsync(typed.trim());
      toast.success(
        `${shopName} was deleted`,
        result.platform_subscription_cancelled ? 'Its subscription was cancelled.' : undefined,
      );
      await navigate('/app', { replace: true });
    } catch {
      // Shown inline below (remove.error).
    }
  };

  return (
    <Dialog
      open={open}
      onClose={close}
      role="alertdialog"
      size="sm"
      title={`Delete ${shopName}?`}
      description={
        endsSubscription
          ? 'Everything in this shop is permanently deleted and its subscription is cancelled. This cannot be undone.'
          : 'Everything in this shop is permanently deleted. This cannot be undone.'
      }
      dismissible={!remove.isPending}
      initialFocus={inputRef}
      footer={
        <>
          <Button variant="secondary" onClick={close} disabled={remove.isPending}>
            Cancel
          </Button>
          <Button
            type="submit"
            form={formId}
            variant="danger"
            disabled={!matches}
            loading={remove.isPending}
          >
            Delete shop permanently
          </Button>
        </>
      }
    >
      <form
        id={formId}
        noValidate
        onSubmit={(e) => void onSubmit(e)}
        className="flex flex-col gap-3"
      >
        <FormField
          label={`Type the shop name “${shopName}” to confirm`}
          help="This makes sure the right shop is deleted."
        >
          <Input
            ref={inputRef}
            value={typed}
            autoComplete="off"
            spellCheck={false}
            onChange={(e) => setTyped(e.target.value)}
          />
        </FormField>
        {remove.isError && (
          <p
            role="alert"
            className="bg-danger-soft text-danger-ink rounded-control px-3 py-2 text-sm"
          >
            {deleteShopErrorMessage(remove.error)}
          </p>
        )}
      </form>
    </Dialog>
  );
}
