import type { ReactNode } from 'react';
import { ShieldOff } from 'lucide-react';
import { EmptyState } from '@/components/ui';
import { can, permissionContextOf, type Capability, type ShopRole } from './permissions';
import { useShopContext } from './shopContext';

export interface RequireRoleProps {
  /** Allowed if the current role has this capability… */
  capability?: Capability;
  /** …and/or is one of these roles. */
  roles?: readonly ShopRole[];
  children: ReactNode;
  /** Rendered when denied (defaults to a "no access" state). */
  fallback?: ReactNode;
}

/** Route/section guard by capability and/or role (see permissions.ts). */
export function RequireRole({ capability, roles, children, fallback }: RequireRoleProps) {
  const { membership } = useShopContext();
  const allowed =
    membership !== null &&
    (capability === undefined || can(permissionContextOf(membership), capability)) &&
    (roles === undefined || roles.includes(membership.role));
  if (allowed) return <>{children}</>;
  return (
    <>
      {fallback ?? (
        <EmptyState
          icon={<ShieldOff aria-hidden="true" />}
          title="You don’t have access to this page"
          description="Ask the shop owner or an admin if you need access."
        />
      )}
    </>
  );
}
