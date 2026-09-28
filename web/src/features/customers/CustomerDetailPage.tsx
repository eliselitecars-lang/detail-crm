import {
  Archive,
  ArchiveRestore,
  Briefcase,
  FileText,
  Mail,
  Merge,
  MessageSquare,
  MessagesSquare,
  Pencil,
  Phone,
  UserX,
} from 'lucide-react';
import { useState } from 'react';
import { Link, useParams, useSearchParams } from 'react-router';
import {
  Badge,
  Button,
  buttonClasses,
  Card,
  ConfirmDialog,
  EmptyState,
  ErrorState,
  LoadingState,
  PageHeader,
  Tabs,
  useToast,
  type TabItem,
} from '@/components/ui';
import { useShop } from '@/features/shop/shopContext';
import { useCan } from '@/features/shop/useCan';
import { toAppError } from '@/lib/errors';
import { phoneHref } from '@/lib/phone';
import { useCustomer, useSetCustomerArchived } from './api';
import { CustomerFormDialog } from './components/CustomerFormDialog';
import { DocumentsTab } from './components/DocumentsTab';
import { InvoicesTab, JobsTab, MembershipsTab, QuotesTab } from './components/HistoryTabs';
import { MergeCustomerDialog } from './components/MergeCustomerDialog';
import { OverviewTab } from './components/OverviewTab';
import { SavedCardsTab } from './components/SavedCardsTab';
import { VehiclesTab } from './components/VehiclesTab';
import { customerName, LIFECYCLE_LABELS, type CustomerRow } from './model';

type TabValue =
  'overview' | 'vehicles' | 'jobs' | 'quotes' | 'invoices' | 'memberships' | 'cards' | 'documents';

export default function CustomerDetailPage() {
  const { customerId = '' } = useParams();
  const { shopId } = useShop();
  const customer = useCustomer(shopId, customerId);

  if (customer.isPending) return <LoadingState label="Loading customer…" />;
  if (customer.isError) {
    const notFound = toAppError(customer.error).kind === 'not_found';
    return (
      <>
        <PageHeader title="Customer" back={{ to: '/app/customers', label: 'Customers' }} />
        <Card>
          {notFound ? (
            <EmptyState
              icon={<UserX aria-hidden="true" />}
              title="Customer not found"
              description="It may have been deleted, or you don’t have access to it."
            />
          ) : (
            <ErrorState
              error={customer.error}
              onRetry={() => void customer.refetch()}
              retrying={customer.isRefetching}
            />
          )}
        </Card>
      </>
    );
  }
  return <CustomerDetail customer={customer.data} />;
}

function CustomerDetail({ customer }: { customer: CustomerRow }) {
  const { shopId } = useShop();
  const toast = useToast();
  const [params, setParams] = useSearchParams();
  const canManage = useCan('customers.manage');
  const canCreateJob = useCan('jobs.manage');
  const canQuote = useCan('quotes.manage');
  const canInbox = useCan('messages.inbox');
  const canQuotes = useCan('quotes.view');
  const canInvoices = useCan('invoices.view');
  const canMemberships = useCan('memberships.view');
  const canCards = useCan('cards.view');
  const canMerge = useCan('customers.merge');
  const [editing, setEditing] = useState(false);
  const [merging, setMerging] = useState(false);
  const [confirmArchive, setConfirmArchive] = useState(false);
  const setArchived = useSetCustomerArchived(shopId);

  const name = customerName(customer);
  const archived = customer.archived_at !== null;
  const merged = Boolean(customer.merged_into_id);
  const tel = phoneHref(customer.phone);
  const sms = phoneHref(customer.phone, 'sms');

  const items: TabItem<TabValue>[] = [
    { value: 'overview', label: 'Overview', content: <OverviewTab customer={customer} /> },
    {
      value: 'vehicles',
      label: 'Vehicles',
      content: <VehiclesTab customerId={customer.id} archivedCustomer={archived} />,
    },
    { value: 'jobs', label: 'Jobs', content: <JobsTab customerId={customer.id} /> },
  ];
  if (canQuotes)
    items.push({
      value: 'quotes',
      label: 'Quotes',
      content: <QuotesTab customerId={customer.id} />,
    });
  if (canInvoices)
    items.push({
      value: 'invoices',
      label: 'Invoices',
      content: <InvoicesTab customerId={customer.id} />,
    });
  if (canMemberships)
    items.push({
      value: 'memberships',
      label: 'Memberships',
      content: <MembershipsTab customerId={customer.id} />,
    });
  if (canCards)
    items.push({
      value: 'cards',
      label: 'Saved cards',
      content: <SavedCardsTab customer={customer} />,
    });
  if (canManage)
    items.push({
      value: 'documents',
      label: 'Files',
      content: <DocumentsTab customerId={customer.id} archivedCustomer={archived} />,
    });

  const requested = params.get('tab');
  const tab: TabValue = items.find((i) => i.value === requested)?.value ?? 'overview';

  const toggleArchive = async (next: boolean) => {
    try {
      await setArchived.mutateAsync({ id: customer.id, archived: next });
      toast.success(next ? 'Customer archived' : 'Customer restored');
      setConfirmArchive(false);
    } catch (error) {
      toast.error(toAppError(error).message);
    }
  };

  const linkClass = buttonClasses({ variant: 'secondary', size: 'sm' });

  return (
    <>
      <PageHeader
        title={name}
        back={{ to: '/app/customers', label: 'Customers' }}
        meta={
          <>
            {customer.company && (customer.first_name || customer.last_name) && (
              <span className="text-muted text-sm">{customer.company}</span>
            )}
            <Badge tone={customer.lifecycle === 'lead' ? 'warning' : 'neutral'}>
              {LIFECYCLE_LABELS[customer.lifecycle]}
            </Badge>
            {archived && !merged && <Badge>Archived</Badge>}
            {merged && <Badge>Merged</Badge>}
          </>
        }
        actions={
          canManage &&
          !merged && (
            <>
              <Button
                variant="secondary"
                size="sm"
                leadingIcon={<Pencil className="size-4" aria-hidden="true" />}
                onClick={() => setEditing(true)}
              >
                Edit
              </Button>
              {archived ? (
                <Button
                  variant="secondary"
                  size="sm"
                  loading={setArchived.isPending}
                  leadingIcon={<ArchiveRestore className="size-4" aria-hidden="true" />}
                  onClick={() => void toggleArchive(false)}
                >
                  Restore
                </Button>
              ) : (
                <Button
                  variant="secondary"
                  size="sm"
                  leadingIcon={<Archive className="size-4" aria-hidden="true" />}
                  onClick={() => setConfirmArchive(true)}
                >
                  Archive
                </Button>
              )}
              {canMerge && (
                <Button
                  variant="secondary"
                  size="sm"
                  leadingIcon={<Merge className="size-4" aria-hidden="true" />}
                  onClick={() => setMerging(true)}
                >
                  Merge into…
                </Button>
              )}
            </>
          )
        }
      />

      {customer.merged_into_id && <MergedBanner targetId={customer.merged_into_id} />}

      <nav aria-label="Quick actions" className="mb-5 flex flex-wrap gap-2">
        {tel && (
          <a href={tel} className={linkClass}>
            <Phone className="size-4" aria-hidden="true" />
            Call
          </a>
        )}
        {sms && !customer.sms_opted_out_at && (
          <a href={sms} className={linkClass}>
            <MessageSquare className="size-4" aria-hidden="true" />
            Text
          </a>
        )}
        {customer.email && (
          <a href={`mailto:${customer.email}`} className={linkClass}>
            <Mail className="size-4" aria-hidden="true" />
            Email
          </a>
        )}
        {canInbox && (
          <Link to={`/app/messages?customer=${customer.id}`} className={linkClass}>
            <MessagesSquare className="size-4" aria-hidden="true" />
            Messages
          </Link>
        )}
        {canCreateJob && !archived && (
          <Link to={`/app/jobs/new?customerId=${customer.id}`} className={linkClass}>
            <Briefcase className="size-4" aria-hidden="true" />
            New job
          </Link>
        )}
        {canQuote && !archived && (
          <Link to={`/app/quotes/new?customerId=${customer.id}`} className={linkClass}>
            <FileText className="size-4" aria-hidden="true" />
            New quote
          </Link>
        )}
      </nav>

      <Tabs
        label="Customer sections"
        items={items}
        value={tab}
        onChange={(value) => {
          const next = new URLSearchParams(params);
          if (value === 'overview') next.delete('tab');
          else next.set('tab', value);
          setParams(next, { replace: true });
        }}
      />

      {editing && <CustomerFormDialog open customer={customer} onClose={() => setEditing(false)} />}
      {canMerge && !merged && (
        <MergeCustomerDialog
          open={merging}
          onClose={() => setMerging(false)}
          source={{ id: customer.id, name }}
        />
      )}
      <ConfirmDialog
        open={confirmArchive}
        onClose={() => setConfirmArchive(false)}
        onConfirm={() => toggleArchive(true)}
        loading={setArchived.isPending}
        title={`Archive ${name}?`}
        description="Archived customers are hidden from lists and pickers. Their jobs, invoices and history are kept, and you can restore them anytime."
        confirmLabel="Archive customer"
      />
    </>
  );
}

/** A merged duplicate: everything now lives on the customer it was merged into. */
function MergedBanner({ targetId }: { targetId: string }) {
  const { shopId } = useShop();
  const target = useCustomer(shopId, targetId);
  return (
    <p
      role="status"
      className="bg-warning-soft text-warning-ink rounded-card mb-5 flex flex-wrap items-center gap-2 px-4 py-3 text-sm"
    >
      <Merge className="size-4 shrink-0" aria-hidden="true" />
      <span>
        This customer was merged into{' '}
        {target.data ? (
          <Link
            to={`/app/customers/${targetId}`}
            className="font-medium underline underline-offset-2"
          >
            {customerName(target.data)}
          </Link>
        ) : (
          <Link
            to={`/app/customers/${targetId}`}
            className="font-medium underline underline-offset-2"
          >
            another customer
          </Link>
        )}
        . Their records moved there.
      </span>
    </p>
  );
}
