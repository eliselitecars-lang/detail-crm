// FEATURE_STUB: placeholder page owned by the calendar feature; replace this file.
import { Construction } from 'lucide-react';
import { Card, EmptyState, PageHeader } from '@/components/ui';

export default function CalendarPage() {
  return (
    <>
      <PageHeader
        title="Calendar"
        description="Day, week and month schedule with drag-to-reschedule."
      />
      <Card>
        <EmptyState icon={<Construction aria-hidden="true" />} title="Calendar is coming soon" />
      </Card>
    </>
  );
}
