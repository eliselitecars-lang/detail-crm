// FEATURE_STUB: placeholder page owned by the dashboard feature; replace this file.
import { Construction } from 'lucide-react';
import { Card, EmptyState, PageHeader } from '@/components/ui';

export default function DashboardPage() {
  return (
    <>
      <PageHeader title="Dashboard" description="Today's jobs, revenue and what needs attention." />
      <Card>
        <EmptyState icon={<Construction aria-hidden="true" />} title="Dashboard is coming soon" />
      </Card>
    </>
  );
}
