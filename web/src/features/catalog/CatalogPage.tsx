// FEATURE_STUB: placeholder page owned by the catalog feature; replace this file.
import { Construction } from 'lucide-react';
import { Card, EmptyState, PageHeader } from '@/components/ui';

export default function CatalogPage() {
  return (
    <>
      <PageHeader
        title="Catalog"
        description="Services, packages, add-ons and prices by vehicle size."
      />
      <Card>
        <EmptyState icon={<Construction aria-hidden="true" />} title="Catalog is coming soon" />
      </Card>
    </>
  );
}
