import { Menu } from 'lucide-react';
import { useState } from 'react';
import { Link, Outlet, useNavigation } from 'react-router';
import { Drawer, IconButton } from '@/components/ui';
import { BillingBanner } from '@/features/billing/BillingBanner';
import { useBillingErrorToasts } from '@/features/billing/useBillingErrorToasts';
import { useShop } from '@/features/shop/shopContext';
import { GlobalSearch } from './GlobalSearch';
import { Logo } from './Logo';
import { visibleNav } from './navItems';
import { NotificationsBell } from './NotificationsBell';
import { ShopSwitcher } from './ShopSwitcher';
import { SidebarNav } from './SidebarNav';
import { UserMenu } from './UserMenu';

/**
 * Staff layout: grouped sidebar (drawer below lg), top bar with shop
 * switcher, global search, notifications and user menu. Feature pages render
 * in <Outlet/> and own their PageHeader. The shop's subscription banner
 * (features/billing) sits above the page; subscription refusals in error
 * toasts get the owner's "Go to Billing" action.
 */
export function AppShell() {
  const { permissions, role } = useShop();
  useBillingErrorToasts(role);
  const groups = visibleNav(permissions);
  const [mobileOpen, setMobileOpen] = useState(false);
  const navigation = useNavigation();
  const busy = navigation.state === 'loading';

  return (
    <div className="bg-canvas flex min-h-dvh">
      <a
        href="#main"
        className="rounded-control bg-surface sr-only z-50 px-3 py-2 text-sm font-medium focus:not-sr-only focus:fixed focus:top-2 focus:left-2"
      >
        Skip to content
      </a>

      <aside className="border-line bg-surface sticky top-0 hidden h-dvh w-60 shrink-0 flex-col border-r lg:flex">
        <div className="border-line flex h-14 items-center border-b px-4">
          <Link to="/app" className="rounded-control">
            <Logo />
          </Link>
        </div>
        <div className="min-h-0 flex-1 overflow-y-auto">
          <SidebarNav groups={groups} />
        </div>
      </aside>

      <Drawer
        open={mobileOpen}
        onClose={() => setMobileOpen(false)}
        title="Menu"
        side="left"
        widthClassName="max-w-72"
      >
        <SidebarNav groups={groups} onNavigate={() => setMobileOpen(false)} />
      </Drawer>

      <div className="flex min-w-0 flex-1 flex-col">
        <header className="border-line bg-surface/95 sticky top-0 z-30 border-b backdrop-blur">
          <div className="flex h-14 items-center gap-2 px-3 sm:px-4">
            <IconButton
              label="Open menu"
              icon={<Menu />}
              className="lg:hidden"
              aria-expanded={mobileOpen}
              onClick={() => setMobileOpen(true)}
            />
            <ShopSwitcher />
            <div className="flex min-w-0 flex-1 justify-end px-1 sm:justify-center sm:px-4">
              <GlobalSearch />
            </div>
            <NotificationsBell />
            <UserMenu />
          </div>
          <div
            role="progressbar"
            aria-hidden={!busy}
            aria-label="Loading page"
            className={`bg-primary h-0.5 origin-left transition-transform duration-500 ${busy ? 'scale-x-75' : 'scale-x-0'}`}
          />
        </header>
        <main
          id="main"
          tabIndex={-1}
          className="min-w-0 flex-1 px-4 py-5 outline-none sm:px-6 sm:py-6 lg:px-8"
        >
          <div className="mx-auto w-full max-w-7xl">
            <BillingBanner />
            <Outlet />
          </div>
        </main>
      </div>
    </div>
  );
}
