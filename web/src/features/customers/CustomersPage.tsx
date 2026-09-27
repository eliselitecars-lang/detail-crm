// FEATURE_STUB: placeholder page owned by the customers feature; replace this file.
import { Construction } from 'lucide-react';
import { Card, EmptyState, PageHeader } from '@/components/ui';

export default function CustomersPage() {
  return (
    <>
      <PageHeader title="Customers" description="Customers, vehicles and their history." />
      <Card>
        <EmptyState icon={<Construction aria-hidden="true" />} title="Customers is coming soon" />
      </Card>
    </>
  );
}
