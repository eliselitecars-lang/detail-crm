import { NavLink } from 'react-router';
import { cn } from '@/lib/cn';
import type { NavGroup } from './navItems';

export interface SidebarNavProps {
  groups: readonly NavGroup[];
  /** Called after a link is chosen (closes the mobile drawer). */
  onNavigate?: () => void;
}

export function SidebarNav({ groups, onNavigate }: SidebarNavProps) {
  return (
    <nav aria-label="Main" className="flex flex-col gap-5 px-3 py-4">
      {groups.map((group) => (
        <div key={group.label}>
          <p className="text-subtle px-2 pb-1.5 text-[11px] font-semibold tracking-wider uppercase">
            {group.label}
          </p>
          <ul className="flex flex-col gap-0.5">
            {group.items.map((item) => (
              <li key={item.to}>
                <NavLink
                  to={item.to}
                  end={item.end ?? false}
                  onClick={onNavigate}
                  className={({ isActive }) =>
                    cn(
                      'rounded-control flex items-center gap-2.5 px-2 py-1.5 text-sm font-medium transition-colors',
                      isActive
                        ? 'bg-primary-soft text-primary-ink'
                        : 'text-muted hover:bg-surface-2 hover:text-ink',
                    )
                  }
                >
                  <item.icon className="size-4 shrink-0" aria-hidden="true" />
                  {item.label}
                </NavLink>
              </li>
            ))}
          </ul>
        </div>
      ))}
    </nav>
  );
}
