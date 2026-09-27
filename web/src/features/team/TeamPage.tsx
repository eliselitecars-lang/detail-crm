// FEATURE_STUB: placeholder page owned by the team feature; replace this file.
import { Construction } from 'lucide-react';
import { Card, EmptyState, PageHeader } from '@/components/ui';

export default function TeamPage() {
  return (
    <>
      <PageHeader title="Team" description="Invites, roles and pay rates." />
      <Card>
        <EmptyState icon={<Construction aria-hidden="true" />} title="Team is coming soon" />
      </Card>
    </>
  );
}
