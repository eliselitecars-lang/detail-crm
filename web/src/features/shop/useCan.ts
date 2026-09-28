import { can, permissionContextOf, type Capability } from './permissions';
import { useShopContext } from './shopContext';

/**
 * `useCan('payments.refund')` → boolean for the current shop/role. UI-only
 * convenience; the server enforces the same rules.
 */
export function useCan(capability: Capability): boolean {
  const { membership } = useShopContext();
  if (!membership) return false;
  return can(permissionContextOf(membership), capability);
}
