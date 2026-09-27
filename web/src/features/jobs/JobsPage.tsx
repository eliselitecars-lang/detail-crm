// FEATURE_STUB: placeholder page owned by the jobs feature; replace this file.
import { Construction } from 'lucide-react';
import { Card, EmptyState, PageHeader } from '@/components/ui';

export default function JobsPage() {
  return (
    <>
      <PageHeader title="Jobs" description="Work orders from request to completion." />
      <Card>
        <EmptyState icon={<Construction aria-hidden="true" />} title="Jobs is coming soon" />
      </Card>
    </>
  );
}
