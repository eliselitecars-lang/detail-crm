import { Banknote, Copy, CreditCard, Hourglass, MoreHorizontal, Send } from 'lucide-react';
import { useState } from 'react';
import { useNavigate, useParams } from 'react-router';
import {
  Badge,
  Button,
  ConfirmDialog,
  DropdownMenu,
  ErrorState,
  FormField,
  LoadingState,
  PageHeader,
  StatusBadge,
  Textarea,
  useToast,
  type DropdownMenuEntry,
} from '@/components/ui';
import { formatLocalDate, shopToday, utcToShopLocal } from '@/lib/dates';
import { useRealtime } from '@/lib/useRealtime';
import { useCan } from '@/features/shop/useCan';
import { useShop } from '@/features/shop/shopContext';
import { useCustomer, useCustomerVehicles } from '@/features/quotes/shared/api';
import { DiscountEditor } from '@/features/quotes/shared/DiscountEditor';
import { copyText, publicDocUrl } from '@/features/quotes/shared/format';
import { LineItemsEditor } from '@/features/quotes/shared/LineItemsEditor';
import type { DocLine } from '@/features/quotes/shared/lines';
import { SendDocumentDialog } from '@/features/quotes/shared/SendDocumentDialog';
import { TotalsCard } from '@/features/quotes/shared/TotalsCard';
import {
  areInvoiceLinesEditable,
  cancelOpenPaymentsSummary,
  invoiceKeys,
  isInvoiceOverdue,
  isPaymentInFlight,
  isPaymentInProgressError,
  useCancelOpenPayments,
  useDeleteInvoice,
  useInvoice,
  useInvoiceLineMutations,
  useInvoiceLines,
  useInvoicePayments,
  useMarkInvoiceSent,
  useUpdateInvoice,
  useVoidInvoice,
  type InvoiceRow,
} from './api';
import { ChargeCardDialog } from './components/ChargeCardDialog';
import { InvoiceDetailsCard } from './components/InvoiceDetailsCard';
import { InvoicePaymentsCard } from './components/InvoicePaymentsCard';
import { RecordPaymentDialog } from './components/RecordPaymentDialog';

export default function InvoiceDetailPage() {
  const { invoiceId = '' } = useParams();
  const { shopId } = useShop();
  const invoice = useInvoice(invoiceId);
  const lines = useInvoiceLines(invoiceId);
  // Card payments land through the Stripe webhook: refresh balances live.
  useRealtime({ table: 'payments', shopId, invalidate: [invoiceKeys.all(shopId)] });

  if (invoice.isPending || lines.isPending) return <LoadingState label="Loading invoice…" />;
  if (invoice.isError || lines.isError) {
    return (
      <>
        <PageHeader title="Invoice" back={{ to: '/app/invoices', label: 'Invoices' }} />
        <ErrorState
          error={invoice.error ?? lines.error}
          onRetry={() => {
            void invoice.refetch();
            void lines.refetch();
          }}
        />
      </>
    );
  }
  return <InvoiceView invoice={invoice.data} lines={lines.data} />;
}

type Pending = 'send' | 'record' | 'charge' | 'void' | 'delete' | 'cancelOpen' | null;

function InvoiceView({ invoice, lines }: { invoice: InvoiceRow; lines: DocLine[] }) {
  const { timezone, currency } = useShop();
  const toast = useToast();
  const navigate = useNavigate();
  const canManage = useCan('invoices.manage');
  const canViewList = useCan('invoices.view');
  const canCollect = useCan('payments.collect');
  const canCharge = useCan('cards.charge');
  const canVoid = useCan('invoices.void');
  const customer = useCustomer(invoice.customer_id);
  const vehicles = useCustomerVehicles(canManage ? invoice.customer_id : null);
  const update = useUpdateInvoice(invoice.id);
  const lineMutations = useInvoiceLineMutations(invoice.id, lines);
  const markSent = useMarkInvoiceSent(invoice.id);
  const voidInvoice = useVoidInvoice(invoice.id);
  const remove = useDeleteInvoice();
  const cancelOpen = useCancelOpenPayments(invoice.id);
  const payments = useInvoicePayments(invoice.id);
  const [pending, setPending] = useState<Pending>(null);
  const [voidReason, setVoidReason] = useState('');
  /** The server refused a change because a card payment is in flight. */
  const [heldByPayment, setHeldByPayment] = useState(false);

  const today = shopToday(timezone);
  const label = `Invoice #${invoice.number}`;
  const link = publicDocUrl('invoice', invoice.public_token);
  const isVoid = invoice.status === 'void';
  const payable =
    (invoice.status === 'open' || invoice.status === 'partially_paid') && invoice.balance_cents > 0;
  const overdue = isInvoiceOverdue(invoice);
  const linesEditable = canManage && areInvoiceLinesEditable(invoice);
  const firstVehicle = vehicles.data?.find((v) => v.category_id) ?? null;
  const paymentInFlight = (payments.data ?? []).some((p) => isPaymentInFlight(p));
  const canCancelOpen = canManage && !isVoid;
  const showHold = canCancelOpen && (paymentInFlight || heldByPayment);

  /** Runs a change and, when an in-flight payment blocked it, offers to release the hold. */
  const holdAware = async <T,>(work: Promise<T>): Promise<T> => {
    try {
      return await work;
    } catch (error) {
      if (isPaymentInProgressError(error)) setHeldByPayment(true);
      throw error;
    }
  };

  const runCancelOpen = async () => {
    try {
      const result = await cancelOpen.mutateAsync();
      const summary = cancelOpenPaymentsSummary(result);
      if (result.in_progress > 0) toast.info(summary.title, summary.description);
      else toast.success(summary.title, summary.description);
      setHeldByPayment(false);
      setPending(null);
    } catch (error) {
      toast.error(error);
    }
  };

  const copyLink = async () => {
    if (await copyText(link)) toast.success('Pay link copied');
    else toast.error('Couldn’t copy the link', link);
  };

  const menu: DropdownMenuEntry[] = [];
  if (
    canCancelOpen &&
    (invoice.status === 'open' || invoice.status === 'partially_paid' || showHold)
  ) {
    menu.push({
      key: 'cancel-open',
      label: 'Cancel open payments…',
      onSelect: () => setPending('cancelOpen'),
    });
  }
  if (canVoid && !isVoid) {
    menu.push({
      key: 'void',
      label: 'Void invoice…',
      tone: 'danger',
      onSelect: () => setPending('void'),
    });
  }
  if (canManage && invoice.status === 'draft') {
    menu.push({
      key: 'delete',
      label: 'Delete draft…',
      tone: 'danger',
      onSelect: () => setPending('delete'),
    });
  }

  const lockedMessage = isVoid
    ? 'This invoice is void.'
    : 'Lines can’t change after money has been received on the invoice.';

  return (
    <>
      <PageHeader
        title={label}
        back={canViewList ? { to: '/app/invoices', label: 'Invoices' } : undefined}
        meta={
          <>
            <StatusBadge kind="invoice" status={invoice.status} />
            {overdue && <Badge tone="danger">Overdue</Badge>}
          </>
        }
        description={
          invoice.due_at
            ? `Due ${formatLocalDate(utcToShopLocal(invoice.due_at, timezone).date)}`
            : invoice.status === 'draft'
              ? 'Draft — not sent yet'
              : undefined
        }
        actions={
          <div className="flex flex-wrap items-center gap-2">
            {canCollect && payable && (
              <Button
                variant="money"
                leadingIcon={<Banknote className="size-4" aria-hidden="true" />}
                onClick={() => setPending('record')}
              >
                Record payment
              </Button>
            )}
            {canCharge && payable && (
              <Button
                variant="money"
                leadingIcon={<CreditCard className="size-4" aria-hidden="true" />}
                onClick={() => setPending('charge')}
              >
                Charge card
              </Button>
            )}
            {canManage && !isVoid && (
              <Button
                variant={invoice.status === 'draft' ? 'primary' : 'secondary'}
                leadingIcon={<Send className="size-4" aria-hidden="true" />}
                onClick={() => setPending('send')}
                disabled={invoice.status === 'draft' && lines.length === 0}
                title={
                  invoice.status === 'draft' && lines.length === 0
                    ? 'Add at least one line item first'
                    : undefined
                }
              >
                {invoice.status === 'draft' ? 'Send invoice' : 'Resend'}
              </Button>
            )}
            {!isVoid && invoice.status !== 'draft' && (
              <Button
                variant="secondary"
                leadingIcon={<Copy className="size-4" aria-hidden="true" />}
                onClick={() => void copyLink()}
              >
                Copy pay link
              </Button>
            )}
            {menu.length > 0 && (
              <DropdownMenu
                items={menu}
                trigger={(props) => (
                  <Button {...props} variant="secondary" aria-label="More invoice actions">
                    <MoreHorizontal className="size-4" aria-hidden="true" />
                  </Button>
                )}
              />
            )}
          </div>
        }
      />

      {showHold && (
        <div
          role="status"
          className="bg-warning-soft text-warning-ink rounded-card mb-4 flex flex-col gap-3 px-4 py-3 text-sm sm:flex-row sm:items-center"
        >
          <Hourglass className="size-5 shrink-0" aria-hidden="true" />
          <div className="min-w-0 flex-1">
            <p className="font-medium">A card payment is in progress on this invoice.</p>
            <p className="mt-0.5">
              Until it finishes or is cancelled, the invoice can’t be voided, edited or charged. If
              the customer walked away from it, cancel it to release the invoice.
            </p>
          </div>
          <Button
            size="sm"
            variant="secondary"
            className="shrink-0"
            onClick={() => setPending('cancelOpen')}
          >
            Cancel open payments
          </Button>
        </div>
      )}

      <div className="grid grid-cols-1 gap-4 lg:grid-cols-3">
        <div className="flex min-w-0 flex-col gap-4 lg:col-span-2">
          <LineItemsEditor
            lines={lines}
            currency={currency}
            editable={linesEditable}
            lockedMessage={canManage ? lockedMessage : undefined}
            supportsOptional={false}
            pricing={{
              customerId: invoice.customer_id,
              vehicleId: firstVehicle?.id ?? null,
              vehicleCategoryId: firstVehicle?.category_id ?? null,
            }}
            onAdd={(drafts) => holdAware(lineMutations.add.mutateAsync(drafts))}
            onUpdate={(id, patch) => holdAware(lineMutations.update.mutateAsync({ id, patch }))}
            onRemove={(id) => holdAware(lineMutations.remove.mutateAsync(id))}
          />
          <InvoicePaymentsCard invoiceId={invoice.id} currency={currency} timezone={timezone} />
        </div>
        <div className="flex min-w-0 flex-col gap-4">
          <TotalsCard
            currency={currency}
            subtotalCents={invoice.subtotal_cents}
            discountCents={invoice.discount_cents}
            taxCents={invoice.tax_cents}
            taxRateBps={invoice.tax_rate_bps}
            totalCents={invoice.total_cents}
            // A draft bills nothing yet: no "Paid" row unless money is already on it.
            paidCents={
              invoice.status !== 'draft' || invoice.amount_paid_cents > 0
                ? invoice.amount_paid_cents
                : undefined
            }
            tipCents={invoice.tip_cents}
            balanceCents={isVoid ? undefined : invoice.balance_cents}
            notIssued={invoice.status === 'draft'}
          />
          <InvoiceDetailsCard
            invoice={invoice}
            customer={customer.data}
            timezone={timezone}
            today={today}
            editable={canManage && !isVoid}
          />
          {(canManage || invoice.discount_kind !== 'none') && (
            <DiscountEditor
              kind={invoice.discount_kind}
              value={invoice.discount_value}
              currency={currency}
              editable={linesEditable}
              onSave={(kind, value) =>
                holdAware(
                  update.mutateAsync({
                    discount_kind: kind,
                    discount_value: kind === 'none' ? 0 : value,
                  }),
                )
              }
            />
          )}
        </div>
      </div>

      {customer.data && canManage && (
        <SendDocumentDialog
          open={pending === 'send'}
          onClose={() => setPending(null)}
          kind="invoice"
          documentLabel={label}
          customer={customer.data}
          link={link}
          amountCents={invoice.total_cents}
          balanceCents={invoice.balance_cents}
          jobId={invoice.job_id}
          resend={invoice.status !== 'draft'}
          onMarkSent={() => markSent.mutateAsync()}
        />
      )}
      <RecordPaymentDialog
        open={pending === 'record'}
        onClose={() => setPending(null)}
        invoiceId={invoice.id}
        invoiceNumber={invoice.number}
        balanceCents={invoice.balance_cents}
        currency={currency}
      />
      {canCharge && (
        <ChargeCardDialog
          open={pending === 'charge'}
          onClose={() => setPending(null)}
          invoiceId={invoice.id}
          invoiceNumber={invoice.number}
          customerId={invoice.customer_id}
          balanceCents={invoice.balance_cents}
          currency={currency}
          onTextPayLink={() => setPending('send')}
        />
      )}
      <ConfirmDialog
        open={pending === 'void'}
        onClose={() => setPending(null)}
        loading={voidInvoice.isPending}
        tone="danger"
        title={`Void ${label.toLowerCase()}?`}
        description="A void invoice can’t be paid or reopened. Deposits tied to the job move back to the job for a replacement invoice. Money not tied to a job must be refunded first."
        confirmLabel="Void invoice"
        onConfirm={async () => {
          try {
            await voidInvoice.mutateAsync(voidReason.trim() || null);
            toast.success(`${label} voided`);
            setPending(null);
            setVoidReason('');
          } catch (error) {
            if (canCancelOpen && isPaymentInProgressError(error)) {
              setHeldByPayment(true);
              setPending(null);
              toast.show({
                tone: 'error',
                title: 'A card payment is in progress on this invoice',
                description: 'Cancel the open payments first, then void the invoice.',
                action: { label: 'Cancel open payments', onClick: () => setPending('cancelOpen') },
              });
            } else {
              toast.error(error);
            }
          }
        }}
      >
        <FormField
          label="Reason"
          help="Optional."
          error={voidReason.length > 1000 ? 'Use 1,000 characters or fewer.' : undefined}
        >
          <Textarea
            rows={2}
            value={voidReason}
            onChange={(event) => setVoidReason(event.target.value)}
          />
        </FormField>
      </ConfirmDialog>
      {canCancelOpen && (
        <ConfirmDialog
          open={pending === 'cancelOpen'}
          onClose={() => setPending(null)}
          loading={cancelOpen.isPending}
          tone="danger"
          title="Cancel open card payments?"
          description="Cancels card payments on this invoice that were started but never confirmed (for example a payment sheet left open on a phone) and expires its open pay links. Payments the bank is already processing are not touched. The customer can still pay later with a fresh link."
          confirmLabel="Cancel open payments"
          cancelLabel="Keep them"
          onConfirm={runCancelOpen}
        />
      )}
      <ConfirmDialog
        open={pending === 'delete'}
        onClose={() => setPending(null)}
        loading={remove.isPending}
        tone="danger"
        title={`Delete ${label.toLowerCase()}?`}
        description="This draft and its line items are deleted permanently."
        confirmLabel="Delete draft"
        onConfirm={async () => {
          try {
            await remove.mutateAsync(invoice.id);
            toast.success(`${label} deleted`);
            await navigate('/app/invoices', { replace: true });
          } catch (error) {
            toast.error(error);
          }
        }}
      />
    </>
  );
}
