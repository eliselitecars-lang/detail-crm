import { LogOut, Monitor, Moon, Sun, UserRound } from 'lucide-react';
import { useLocation, useNavigate } from 'react-router';
import { Avatar, DropdownMenu } from '@/components/ui';
import { useTheme } from '@/app/themeContext';
import { useAuth } from '@/features/auth/authContext';
import { useShop } from '@/features/shop/shopContext';

export function UserMenu() {
  const { user, signOut } = useAuth();
  const { displayName } = useShop();
  const { preference, setPreference } = useTheme();
  const navigate = useNavigate();
  const location = useLocation();
  const name = displayName || user?.email || 'Account';
  const mark = (value: typeof preference) => (preference === value ? ' (current)' : '');

  return (
    <DropdownMenu
      header={
        <div className="min-w-0">
          <p className="text-ink truncate text-sm font-medium">{name}</p>
          {user?.email && <p className="text-muted truncate text-xs">{user.email}</p>}
        </div>
      }
      items={[
        {
          key: 'light',
          label: `Light theme${mark('light')}`,
          icon: <Sun />,
          onSelect: () => setPreference('light'),
        },
        {
          key: 'dark',
          label: `Dark theme${mark('dark')}`,
          icon: <Moon />,
          onSelect: () => setPreference('dark'),
        },
        {
          key: 'system',
          label: `Match system${mark('system')}`,
          icon: <Monitor />,
          onSelect: () => setPreference('system'),
        },
        { key: 'sep', separator: true },
        {
          key: 'account',
          label: 'Your account',
          icon: <UserRound />,
          onSelect: () =>
            void navigate('/account', {
              state: { from: `${location.pathname}${location.search}` },
            }),
        },
        {
          key: 'signout',
          label: 'Sign out',
          icon: <LogOut />,
          onSelect: () => {
            void signOut().then(() => navigate('/login', { replace: true }));
          },
        },
      ]}
      trigger={({ ref, ...props }) => (
        <button
          ref={ref}
          type="button"
          {...props}
          aria-label={`Account menu for ${name}`}
          className="focus-visible:outline-primary rounded-full focus-visible:outline-2 focus-visible:outline-offset-2"
        >
          <Avatar name={name} size="sm" />
        </button>
      )}
    />
  );
}
