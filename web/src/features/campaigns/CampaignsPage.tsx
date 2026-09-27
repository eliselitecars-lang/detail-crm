// FEATURE_STUB: placeholder page owned by the campaigns feature; replace this file.
import { Construction } from 'lucide-react';
import { Card, EmptyState, PageHeader } from '@/components/ui';

export default function CampaignsPage() {
  return (
    <>
      <PageHeader title="Campaigns" description="Text and email blasts to opted-in customers." />
      <Card>
        <EmptyState icon={<Construction aria-hidden="true" />} title="Campaigns is coming soon" />
      </Card>
    </>
  );
}
