import { useEffect, useRef } from 'react';
import { NavLink, Outlet, useLocation } from 'react-router';
import { PageHeader } from '@/components/ui';
import { can } from '@/features/shop/permissions';
import { useShop } from '@/features/shop/shopContext';
import { cn } from '@/lib/cn';
import { SETTINGS_GROUPS, SETTINGS_SECTIONS } from './sections';

/**
 * /app/settings layout: page header, the settings sub-nav (vertical list on
 * large screens, a horizontally scrolling tab row on phones) and the active
 * section in <Outlet/>. Sections the role cannot use are not listed.
 */
export default function SettingsPage() {
  const { permissions } = useShop();
  const sections = SETTINGS_SECTIONS.filter((section) => can(permissions, section.view));
  const groups = SETTINGS_GROUPS.map((group) => ({
    group,
    items: sections.filter((section) => section.group === group),
  })).filter((g) => g.items.length > 0);
  const grouped = groups.length > 1;
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
        description={
          sections.some((s) => s.view === 'settings.view')
            ? 'Business details, booking, payments, messages and integrations.'
            : 'Your personal settings for this shop.'
        }
      />
      <div className="grid min-w-0 gap-6 lg:grid-cols-[13.5rem_minmax(0,1fr)]">
        <nav aria-label="Settings" className="min-w-0">
          <ul
            ref={listRef}
            className="relative -mx-1 flex gap-1 overflow-x-auto px-1 pb-1 lg:mx-0 lg:flex-col lg:overflow-visible lg:px-0 lg:pb-0"
          >
            {groups.map(({ group, items }) =>
              items.map((section, index) => (
                <li
                  key={section.path}
                  className={cn('shrink-0', grouped && index === 0 && 'lg:mt-3 lg:first:mt-0')}
                >
                  {grouped && index === 0 && (
                    <p
                      aria-hidden="true"
                      className="text-subtle hidden px-3 pb-1 text-xs font-semibold tracking-wide uppercase lg:block"
                    >
                      {group}
                    </p>
                  )}
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
              )),
            )}
          </ul>
        </nav>
        <div className="min-w-0">
          <Outlet />
        </div>
      </div>
    </>
  );
}
