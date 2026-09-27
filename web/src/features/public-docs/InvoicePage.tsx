// FEATURE_STUB: placeholder page owned by the public-docs feature; replace this file.
import { Construction } from 'lucide-react';
import { PublicLayout } from '@/components/layout/PublicLayout';
import { Card, EmptyState } from '@/components/ui';

export default function InvoicePage() {
  return (
    <PublicLayout shop={null}>
      <Card>
        <EmptyState
          icon={<Construction aria-hidden="true" />}
          title="Your invoice"
          description="This page is coming soon."
        />
      </Card>
    </PublicLayout>
  );
}
