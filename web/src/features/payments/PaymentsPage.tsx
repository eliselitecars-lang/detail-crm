// FEATURE_STUB: placeholder page owned by the payments feature; replace this file.
import { Construction } from 'lucide-react';
import { Card, EmptyState, PageHeader } from '@/components/ui';

export default function PaymentsPage() {
  return (
    <>
      <PageHeader title="Payments" description="Card, cash and check payments, refunds and tips." />
      <Card>
        <EmptyState icon={<Construction aria-hidden="true" />} title="Payments is coming soon" />
      </Card>
    </>
  );
}
