import { Plus } from 'lucide-react';
import { useState } from 'react';
import { useNavigate, useSearchParams } from 'react-router';
import { Button, PageHeader, Tabs } from '@/components/ui';
import { useCan } from '@/features/shop/useCan';
import { CategoriesTab } from './components/CategoriesTab';
import { ChecklistsTab } from './components/ChecklistsTab';
import { ServiceFormDialog } from './components/ServiceFormDialog';
import { ServicesTab } from './components/ServicesTab';

const TABS = ['services', 'categories', 'checklists'] as const;
type CatalogTab = (typeof TABS)[number];

function isTab(value: string | null): value is CatalogTab {
  return value !== null && (TABS as readonly string[]).includes(value);
}

export default function CatalogPage() {
  const canManage = useCan('catalog.manage');
  const navigate = useNavigate();
  const [params, setParams] = useSearchParams();
  const tabParam = params.get('tab');
  const tab: CatalogTab = isTab(tabParam) ? tabParam : 'services';
  const [creating, setCreating] = useState(false);

  const setTab = (next: CatalogTab) => {
    const nextParams = new URLSearchParams(params);
    if (next === 'services') nextParams.delete('tab');
    else nextParams.set('tab', next);
    setParams(nextParams, { replace: true });
  };

  return (
    <>
      <PageHeader
        title="Catalog"
        description={
          canManage
            ? 'Services, packages, add-ons and products, prices by vehicle size, and job checklists.'
            : 'The services your shop offers and their job checklists.'
        }
        actions={
          canManage ? (
            <Button leadingIcon={<Plus />} onClick={() => setCreating(true)}>
              New item
            </Button>
          ) : undefined
        }
      />
      <Tabs
        label="Catalog sections"
        value={tab}
        onChange={setTab}
        items={[
          {
            value: 'services',
            label: 'Services',
            content: <ServicesTab canManage={canManage} onNew={() => setCreating(true)} />,
          },
          {
            value: 'categories',
            label: 'Categories',
            content: <CategoriesTab canManage={canManage} />,
          },
          {
            value: 'checklists',
            label: 'Checklists',
            content: <ChecklistsTab canManage={canManage} />,
          },
        ]}
      />
      {canManage && (
        <ServiceFormDialog
          open={creating}
          onClose={() => setCreating(false)}
          onCreated={(id) => void navigate(`/app/catalog/services/${id}`)}
        />
      )}
    </>
  );
}
