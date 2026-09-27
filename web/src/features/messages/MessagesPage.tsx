// FEATURE_STUB: placeholder page owned by the messages feature; replace this file.
import { Construction } from 'lucide-react';
import { Card, EmptyState, PageHeader } from '@/components/ui';

export default function MessagesPage() {
  return (
    <>
      <PageHeader title="Messages" description="Two-way text and email conversations." />
      <Card>
        <EmptyState icon={<Construction aria-hidden="true" />} title="Messages is coming soon" />
      </Card>
    </>
  );
}
