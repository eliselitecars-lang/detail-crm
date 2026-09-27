// FEATURE_STUB: placeholder page owned by the invoices feature; replace this file.
import { Construction } from 'lucide-react';
import { Card, EmptyState, PageHeader } from '@/components/ui';

export default function InvoicesPage() {
  return (
    <>
      <PageHeader title="Invoices" description="Invoices, balances and payment links." />
      <Card>
        <EmptyState icon={<Construction aria-hidden="true" />} title="Invoices is coming soon" />
      </Card>
    </>
  );
}
