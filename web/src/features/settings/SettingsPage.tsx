import { useEffect, useRef } from 'react';
import { NavLink, Outlet, useLocation } from 'react-router';
import { PageHeader } from '@/components/ui';
import { can } from '@/features/shop/permissions';
import { useShop } from '@/features/shop/shopContext';
import { cn } from '@/lib/cn';
import { SETTINGS_SECTIONS } from './sections';

/**
 * /app/settings layout: page header, the settings sub-nav (vertical list on
 * large screens, a horizontally scrolling tab row on phones) and the active
 * section in <Outlet/>. Sections the role cannot use are not listed.
 */
export default function SettingsPage() {
  const { permissions } = useShop();
  const sections = SETTINGS_SECTIONS.filter((section) => can(permissions, section.view));
  const listRef = useRef<HTMLUListElement>(null);
  const { pathname } = useLocation();

  // Phones: the sub-nav is a horizontal strip; keep the current section in view.
  useEffect(() => {
    const list = listRef.current;
    const active = list?.querySelector<HTMLElement>('[aria-current="page"]');
    if (!list || !active || list.scrollWidth <= list.clientWidth) return;
    list.scrollLeft = active.offsetLeft - (list.clientWidth - active.offsetWidth) / 2;
  }, [pathname]);

  return (
    <>
      <PageHeader
        title="Settings"
        description="Business details, booking, hours, payments and templates."
      />
      <div className="grid min-w-0 gap-6 lg:grid-cols-[13.5rem_minmax(0,1fr)]">
        <nav aria-label="Settings" className="min-w-0">
          <ul
            ref={listRef}
            className="relative -mx-1 flex gap-1 overflow-x-auto px-1 pb-1 lg:mx-0 lg:flex-col lg:overflow-visible lg:px-0 lg:pb-0"
          >
            {sections.map((section) => (
              <li key={section.path} className="shrink-0">
                <NavLink
                  to={section.path}
                  className={({ isActive }) =>
                    cn(
                      'rounded-control focus-visible:outline-primary block px-3 py-2 text-sm font-medium whitespace-nowrap transition-colors focus-visible:outline-2 focus-visible:outline-offset-2',
                      isActive
                        ? 'bg-primary-soft text-primary-ink'
                        : 'text-muted hover:bg-surface-2 hover:text-ink',
                    )
                  }
                >
                  {section.label}
                </NavLink>
              </li>
            ))}
          </ul>
        </nav>
        <div className="min-w-0">
          <Outlet />
        </div>
      </div>
    </>
  );
}
