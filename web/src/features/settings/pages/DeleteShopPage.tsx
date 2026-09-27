import { AlertTriangle, Trash2 } from 'lucide-react';
import { useId, useRef, useState, type FormEvent } from 'react';
import { Link, useNavigate } from 'react-router';
import { Button, Dialog, FormField, Input, SectionCard, useToast } from '@/components/ui';
import { useShop } from '@/features/shop/shopContext';
import { errorMessage } from '@/lib/errors';
import { useBillingMembershipCount, useDeleteShop } from '../api';
import { QueryView, SettingsSectionLayout } from '../components/SettingsSectionLayout';
import { confirmationMatches } from '../deleteShop';

/**
 * Owner only (route guard + nav: shop.delete; RLS shops_delete). Deleting
 * cascades every tenant row; it is blocked while Stripe subscriptions could
 * keep billing customers of the deleted shop.
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
  const { shop } = useShop();
  const [open, setOpen] = useState(false);
  const blocked = billingMemberships > 0;
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
        </ul>
        {blocked && (
          <p
            role="alert"
            className="rounded-card border-warning bg-warning-soft text-warning-ink flex gap-2 border px-3 py-2"
          >
            <AlertTriangle className="mt-0.5 size-4 shrink-0" aria-hidden="true" />
            <span>
              {billingMemberships === 1
                ? '1 membership still bills a customer'
                : `${billingMemberships} memberships still bill customers`}{' '}
              through Stripe. Deleting the shop would not stop those charges — cancel them on the{' '}
              <Link to="/app/memberships" className="text-primary font-medium underline">
                Memberships page
              </Link>{' '}
              first.
            </span>
          </p>
        )}
        <div>
          <Button variant="danger" disabled={blocked} onClick={() => setOpen(true)}>
            <Trash2 className="size-4" aria-hidden="true" />
            Delete shop…
          </Button>
        </div>
      </div>
      <DeleteShopDialog open={open} onClose={() => setOpen(false)} shopName={shop.name} />
    </SectionCard>
  );
}

function DeleteShopDialog({
  open,
  onClose,
  shopName,
}: {
  open: boolean;
  onClose: () => void;
  shopName: string;
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
      await remove.mutateAsync();
      toast.success(`${shopName} was deleted`);
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
      description="Everything in this shop is permanently deleted. This cannot be undone."
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
            {errorMessage(remove.error)}
          </p>
        )}
      </form>
    </Dialog>
  );
}
