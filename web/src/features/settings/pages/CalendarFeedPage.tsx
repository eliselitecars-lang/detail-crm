import { CalendarPlus, RefreshCw, Trash2 } from 'lucide-react';
import { useState } from 'react';
import {
  Badge,
  Button,
  buttonClasses,
  Card,
  ConfirmDialog,
  CopyField,
  EmptyState,
  SectionCard,
  Switch,
  useToast,
} from '@/components/ui';
import { useCan } from '@/features/shop/useCan';
import { useShop } from '@/features/shop/shopContext';
import { formatDateTime } from '@/lib/dates';
import { QueryView, SettingsSectionLayout } from '../components/SettingsSectionLayout';
import {
  calendarFeedUrls,
  useCreateCalendarFeed,
  useMyCalendarFeed,
  useRevokeCalendarFeed,
  type CalendarFeed,
} from '../data/calendarFeed';

/**
 * /app/settings/calendar-feed — every member: a private iCal link of their
 * jobs (and, for managers who choose it, every job of the shop).
 */
export default function CalendarFeedPage() {
  const query = useMyCalendarFeed();
  return (
    <SettingsSectionLayout section="calendar-feed">
      <QueryView query={query} label="your calendar feed">
        {(feed) => (feed ? <FeedCard feed={feed} /> : <NoFeed />)}
      </QueryView>
      <HowTo />
    </SettingsSectionLayout>
  );
}

function NoFeed() {
  const toast = useToast();
  const canIncludeAll = useCan('jobs.view');
  const create = useCreateCalendarFeed();
  const [includeAll, setIncludeAll] = useState(false);
  return (
    <Card>
      <EmptyState
        icon={<CalendarPlus aria-hidden="true" />}
        title="No calendar feed yet"
        description="Create a private link and add it to your phone or computer calendar. Your jobs show up there and stay in sync."
        action={
          <div className="flex flex-col items-center gap-3">
            {canIncludeAll && (
              <Switch
                label="Include every job of the shop"
                description="Off: only jobs assigned to you."
                checked={includeAll}
                onCheckedChange={setIncludeAll}
              />
            )}
            <Button
              loading={create.isPending}
              onClick={() =>
                create.mutate(includeAll, {
                  onSuccess: () => toast.success('Calendar feed created'),
                  onError: (error) => toast.error(error),
                })
              }
            >
              Create my calendar link
            </Button>
          </div>
        }
      />
    </Card>
  );
}

function FeedCard({ feed }: { feed: CalendarFeed }) {
  const toast = useToast();
  const { timezone } = useShop();
  const canIncludeAll = useCan('jobs.view');
  const create = useCreateCalendarFeed();
  const revoke = useRevokeCalendarFeed();
  const [confirm, setConfirm] = useState<'rotate' | 'revoke' | { includeAll: boolean } | null>(
    null,
  );
  const urls = calendarFeedUrls(feed.token);

  return (
    <SectionCard
      title="Your calendar link"
      description="Anyone with this link can see the calendar. Keep it private, and get a new link if it was shared by mistake."
      actions={
        <Badge tone="success" dot>
          {feed.include_all ? 'Every job' : 'My jobs'}
        </Badge>
      }
    >
      <div className="flex flex-col gap-4">
        {urls ? (
          <>
            <CopyField
              value={urls.https}
              label="Calendar link"
              copiedMessage="Calendar link copied"
            />
            <div className="flex flex-wrap gap-2">
              <a href={urls.webcal} className={buttonClasses({ variant: 'secondary' })}>
                <CalendarPlus className="size-4" aria-hidden="true" />
                Open in calendar app
              </a>
            </div>
          </>
        ) : (
          <p className="text-muted text-sm">
            The app isn’t connected to its server, so no link can be shown.
          </p>
        )}
        <p className="text-muted text-xs">
          Created {formatDateTime(feed.created_at, timezone)}
          {feed.last_accessed_at
            ? ` · last read by a calendar ${formatDateTime(feed.last_accessed_at, timezone)}`
            : ' · not read by a calendar yet'}
        </p>
        {canIncludeAll && (
          <Switch
            label="Include every job of the shop"
            description="Changing this makes a new link; update it in your calendar app."
            checked={feed.include_all}
            onCheckedChange={(includeAll) => setConfirm({ includeAll })}
          />
        )}
        <div className="flex flex-wrap gap-2">
          <Button
            variant="secondary"
            leadingIcon={<RefreshCw className="size-4" aria-hidden="true" />}
            onClick={() => setConfirm('rotate')}
          >
            Get a new link
          </Button>
          <Button
            variant="ghost"
            leadingIcon={<Trash2 className="size-4" aria-hidden="true" />}
            onClick={() => setConfirm('revoke')}
          >
            Turn off the feed
          </Button>
        </div>
      </div>

      <ConfirmDialog
        open={confirm !== null && confirm !== 'revoke'}
        onClose={() => setConfirm(null)}
        title="Make a new calendar link?"
        description="The current link stops working. Calendars subscribed to it stop updating until you add the new link."
        confirmLabel="Make a new link"
        loading={create.isPending}
        onConfirm={async () => {
          const includeAll =
            typeof confirm === 'object' && confirm !== null ? confirm.includeAll : feed.include_all;
          try {
            await create.mutateAsync(includeAll);
            toast.success('New calendar link ready');
            setConfirm(null);
          } catch (error) {
            toast.error(error);
          }
        }}
      />
      <ConfirmDialog
        open={confirm === 'revoke'}
        onClose={() => setConfirm(null)}
        tone="danger"
        title="Turn off your calendar feed?"
        description="The link stops working and subscribed calendars stop updating. You can make a new link any time."
        confirmLabel="Turn off"
        loading={revoke.isPending}
        onConfirm={async () => {
          try {
            await revoke.mutateAsync();
            toast.success('Calendar feed turned off');
            setConfirm(null);
          } catch (error) {
            toast.error(error);
          }
        }}
      />
    </SectionCard>
  );
}

function HowTo() {
  return (
    <SectionCard title="Add it to your calendar" level={3}>
      <div className="text-muted grid gap-4 text-sm sm:grid-cols-3">
        <div>
          <p className="text-ink font-medium">Google Calendar</p>
          <p className="mt-1">
            On a computer, open Google Calendar → Other calendars → + → From URL, paste the link and
            click Add calendar. Google refreshes it every few hours.
          </p>
        </div>
        <div>
          <p className="text-ink font-medium">iPhone / Mac</p>
          <p className="mt-1">
            Tap “Open in calendar app”, or go to Settings → Calendar → Accounts → Add Account →
            Other → Add Subscribed Calendar and paste the link.
          </p>
        </div>
        <div>
          <p className="text-ink font-medium">Outlook</p>
          <p className="mt-1">
            Add calendar → Subscribe from web, paste the link and give it a name.
          </p>
        </div>
      </div>
      <p className="text-muted mt-4 text-xs">
        The feed shows jobs and calendar events from a week ago to 90 days ahead. Each job shows its
        time, number, services, the customer’s first name and last initial (or company), the vehicle
        and the address — never phone numbers, emails, prices or notes. Your calendar app’s provider
        (Google, Apple or Microsoft) keeps a copy of what it fetches. It’s read-only: change jobs in
        the app.
      </p>
    </SectionCard>
  );
}
