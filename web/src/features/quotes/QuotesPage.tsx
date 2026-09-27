// FEATURE_STUB: placeholder page owned by the quotes feature; replace this file.
import { Construction } from 'lucide-react';
import { Card, EmptyState, PageHeader } from '@/components/ui';

export default function QuotesPage() {
  return (
    <>
      <PageHeader title="Quotes" description="Estimates customers can approve online." />
      <Card>
        <EmptyState icon={<Construction aria-hidden="true" />} title="Quotes is coming soon" />
      </Card>
    </>
  );
}
