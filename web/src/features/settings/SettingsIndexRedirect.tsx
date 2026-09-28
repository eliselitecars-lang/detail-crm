import { ShieldOff } from 'lucide-react';
import { Navigate } from 'react-router';
import { EmptyState } from '@/components/ui';
import { can } from '@/features/shop/permissions';
import { useShop } from '@/features/shop/shopContext';
import { SETTINGS_SECTIONS } from './sections';

/** /app/settings (and unknown sub-paths) → the first section the role may open. */
export function SettingsIndexRedirect() {
  const { permissions } = useShop();
  const first = SETTINGS_SECTIONS.find((s) => can(permissions, s.view));
  if (!first) {
    return (
      <EmptyState
        icon={<ShieldOff aria-hidden="true" />}
        title="You don’t have access to this page"
        description="Ask the shop owner or an admin if you need access."
      />
    );
  }
  return <Navigate to={`/app/settings/${first.path}`} replace />;
}
