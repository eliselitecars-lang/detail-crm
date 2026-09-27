// FEATURE_STUB: placeholder page owned by the notifications feature; replace this file.
import { Construction } from 'lucide-react';
import { Card, EmptyState, PageHeader } from '@/components/ui';

export default function NotificationsPage() {
  return (
    <>
      <PageHeader title="Notifications" description="Everything that happened in your shop." />
      <Card>
        <EmptyState
          icon={<Construction aria-hidden="true" />}
          title="Notifications is coming soon"
        />
      </Card>
    </>
  );
}
