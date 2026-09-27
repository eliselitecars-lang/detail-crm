// FEATURE_STUB: placeholder page owned by the settings feature; replace this file.
import { Construction } from 'lucide-react';
import { Card, EmptyState, PageHeader } from '@/components/ui';

export default function SettingsPage() {
  return (
    <>
      <PageHeader
        title="Settings"
        description="Business details, booking, hours, payments and templates."
      />
      <Card>
        <EmptyState icon={<Construction aria-hidden="true" />} title="Settings is coming soon" />
      </Card>
    </>
  );
}
