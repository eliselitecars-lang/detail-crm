import { UserRound } from 'lucide-react';
import { useState } from 'react';
import { Dialog, ErrorState, SearchInput, Spinner } from '@/components/ui';
import { useCustomerSearch, type CustomerHit } from '../api';

export interface NewConversationDialogProps {
  open: boolean;
  onClose: () => void;
  onPick: (customer: CustomerHit) => void;
}

/** Find a customer to start (or jump to) a conversation with. */
export function NewConversationDialog({ open, onClose, onPick }: NewConversationDialogProps) {
  const [query, setQuery] = useState('');
  const search = useCustomerSearch(query);
  const q = query.trim();

  return (
    <Dialog
      open={open}
      onClose={() => {
        setQuery('');
        onClose();
      }}
      title="New message"
      description="Search for a customer by name, phone or email."
      size="md"
    >
      <div className="flex flex-col gap-3">
        <SearchInput
          value={query}
          onChange={setQuery}
          label="Search customers"
          placeholder="Name, phone or email"
        />
        <div aria-live="polite" className="min-h-24">
          {q.length < 2 ? (
            <p className="text-muted text-sm">Type at least 2 characters.</p>
          ) : search.isPending ? (
            <p className="text-muted flex items-center gap-2 text-sm">
              <Spinner /> Searching…
            </p>
          ) : search.error ? (
            <ErrorState
              error={search.error}
              onRetry={() => void search.refetch()}
              retrying={search.isRefetching}
              compact
            />
          ) : (search.data ?? []).length === 0 ? (
            <p className="text-muted text-sm">No customers match “{q}”.</p>
          ) : (
            <ul className="divide-line border-line rounded-control divide-y border">
              {(search.data ?? []).map((hit) => (
                <li key={hit.id}>
                  <button
                    type="button"
                    className="hover:bg-surface-2 focus-visible:ring-primary flex w-full items-center gap-3 px-3 py-2.5 text-left outline-none focus-visible:ring-2 focus-visible:ring-inset"
                    onClick={() => {
                      setQuery('');
                      onPick(hit);
                    }}
                  >
                    <UserRound className="text-muted size-4 shrink-0" aria-hidden="true" />
                    <span className="min-w-0">
                      <span className="text-ink block truncate text-sm font-medium">
                        {hit.title}
                      </span>
                      {hit.subtitle && (
                        <span className="text-muted block truncate text-xs">{hit.subtitle}</span>
                      )}
                    </span>
                  </button>
                </li>
              ))}
            </ul>
          )}
        </div>
      </div>
    </Dialog>
  );
}
