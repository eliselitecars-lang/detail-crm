// FEATURE_STUB: placeholder page owned by the memberships feature; replace this file.
import { Construction } from 'lucide-react';
import { Card, EmptyState, PageHeader } from '@/components/ui';

export default function MembershipsPage() {
  return (
    <>
      <PageHeader title="Memberships" description="Recurring plans and subscribers." />
      <Card>
        <EmptyState icon={<Construction aria-hidden="true" />} title="Memberships is coming soon" />
      </Card>
    </>
  );
}
