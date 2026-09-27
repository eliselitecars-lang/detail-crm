// FEATURE_STUB: placeholder page owned by the timesheets feature; replace this file.
import { Construction } from 'lucide-react';
import { Card, EmptyState, PageHeader } from '@/components/ui';

export default function TimesheetsPage() {
  return (
    <>
      <PageHeader title="Timesheets" description="Clock in/out and time entries." />
      <Card>
        <EmptyState icon={<Construction aria-hidden="true" />} title="Timesheets is coming soon" />
      </Card>
    </>
  );
}
