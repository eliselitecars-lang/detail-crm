// FEATURE_STUB: placeholder page owned by the reports feature; replace this file.
import { Construction } from 'lucide-react';
import { Card, EmptyState, PageHeader } from '@/components/ui';

export default function ReportsPage() {
  return (
    <>
      <PageHeader title="Reports" description="Revenue, services, team and customer reports." />
      <Card>
        <EmptyState icon={<Construction aria-hidden="true" />} title="Reports is coming soon" />
      </Card>
    </>
  );
}
