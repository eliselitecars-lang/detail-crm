import { ClipboardList, Car, FileText, Receipt, Search, User } from 'lucide-react';
import { useEffect, useId, useRef, useState } from 'react';
import { useNavigate } from 'react-router';
import { Dialog, Input, Spinner } from '@/components/ui';
import { useShop } from '@/features/shop/shopContext';
import { cn } from '@/lib/cn';
import { errorMessage } from '@/lib/errors';
import { searchResultHref, useShopSearch, type SearchKind, type SearchResult } from './shellApi';

const KIND_ICON: Record<SearchKind, typeof User> = {
  customer: User,
  vehicle: Car,
  job: ClipboardList,
  quote: FileText,
  invoice: Receipt,
};

const KIND_LABEL: Record<SearchKind, string> = {
  customer: 'Customer',
  vehicle: 'Vehicle',
  job: 'Job',
  quote: 'Quote',
  invoice: 'Invoice',
};

function useDebounced<T>(value: T, ms: number): T {
  const [debounced, setDebounced] = useState(value);
  useEffect(() => {
    const t = setTimeout(() => setDebounced(value), ms);
    return () => clearTimeout(t);
  }, [value, ms]);
  return debounced;
}

const isMac =
  typeof navigator !== 'undefined' &&
  /mac|iphone|ipad/i.test(navigator.platform || navigator.userAgent);

/** Top-bar search trigger + Cmd/Ctrl-K dialog over search_shop. */
export function GlobalSearch() {
  const [open, setOpen] = useState(false);

  useEffect(() => {
    const onKeyDown = (event: KeyboardEvent) => {
      if ((event.metaKey || event.ctrlKey) && event.key.toLowerCase() === 'k') {
        event.preventDefault();
        setOpen(true);
      }
    };
    window.addEventListener('keydown', onKeyDown);
    return () => window.removeEventListener('keydown', onKeyDown);
  }, []);

  return (
    <>
      <button
        type="button"
        onClick={() => setOpen(true)}
        aria-keyshortcuts={isMac ? 'Meta+K' : 'Control+K'}
        aria-label="Search"
        className="rounded-control text-muted hover:bg-surface-2 sm:border-line sm:bg-surface-2 sm:text-subtle sm:hover:border-line-strong flex h-9 w-9 items-center justify-center gap-2 sm:w-full sm:max-w-md sm:justify-start sm:border sm:px-3"
      >
        <Search className="size-[18px] shrink-0 sm:size-4" aria-hidden="true" />
        <span className="hidden flex-1 truncate text-left text-sm sm:inline" aria-hidden="true">
          Search customers, jobs, invoices…
        </span>
        <kbd className="border-line bg-surface text-muted hidden rounded border px-1.5 text-[11px] font-medium sm:inline">
          {isMac ? '⌘K' : 'Ctrl K'}
        </kbd>
      </button>
      {open && <SearchDialog onClose={() => setOpen(false)} />}
    </>
  );
}

function SearchDialog({ onClose }: { onClose: () => void }) {
  const { shopId } = useShop();
  const navigate = useNavigate();
  const inputRef = useRef<HTMLInputElement>(null);
  const listId = useId();
  const [query, setQuery] = useState('');
  const [active, setActive] = useState(0);
  const debounced = useDebounced(query, 200);
  const search = useShopSearch(shopId, debounced);
  const tooShort = debounced.trim().length < 2;
  const results: SearchResult[] = tooShort ? [] : (search.data ?? []);
  const navigable = results.filter((r) => searchResultHref(r) !== null);
  // The listbox exists only in this state; every combobox ARIA reference
  // (aria-controls / -expanded / -activedescendant) follows it so no IDREF
  // ever points at a missing element.
  const listShown = !tooShort && !search.isError && !search.isPending && navigable.length > 0;
  const options = listShown ? navigable : [];

  const go = (result: SearchResult | undefined) => {
    const href = result ? searchResultHref(result) : null;
    if (!href) return;
    onClose();
    void navigate(href);
  };

  return (
    <Dialog
      open
      onClose={onClose}
      title="Search"
      size="lg"
      initialFocus={inputRef}
      className="sm:mt-[10vh] sm:self-start"
    >
      <Input
        ref={inputRef}
        role="combobox"
        aria-expanded={listShown}
        aria-controls={listShown ? listId : undefined}
        aria-activedescendant={listShown ? `${listId}-${active}` : undefined}
        aria-autocomplete="list"
        aria-label="Search this shop"
        placeholder="Name, phone, email, plate, VIN, job or invoice number…"
        leading={<Search />}
        trailing={search.isFetching ? <Spinner className="text-subtle mr-2 size-4" /> : undefined}
        value={query}
        onChange={(event) => {
          setQuery(event.target.value);
          setActive(0);
        }}
        onKeyDown={(event) => {
          if (event.key === 'ArrowDown') {
            event.preventDefault();
            setActive((i) => (options.length === 0 ? 0 : (i + 1) % options.length));
          } else if (event.key === 'ArrowUp') {
            event.preventDefault();
            setActive((i) =>
              options.length === 0 ? 0 : (i - 1 + options.length) % options.length,
            );
          } else if (event.key === 'Enter') {
            event.preventDefault();
            go(options[active]);
          }
        }}
        inputSize="lg"
      />
      <div className="mt-3 min-h-24" aria-live="polite">
        {tooShort ? (
          <p className="text-muted px-1 py-6 text-center text-sm">
            Type at least 2 characters to search.
          </p>
        ) : search.isError ? (
          <p role="alert" className="text-danger-ink px-1 py-6 text-center text-sm">
            {errorMessage(search.error)}
          </p>
        ) : search.isPending ? (
          <p className="text-muted px-1 py-6 text-center text-sm">Searching…</p>
        ) : !listShown ? (
          <p className="text-muted px-1 py-6 text-center text-sm">
            No matches for “{debounced.trim()}”.
          </p>
        ) : (
          <ul
            id={listId}
            role="listbox"
            aria-label="Search results"
            className="flex flex-col gap-0.5"
          >
            {options.map((result, index) => {
              const Icon = KIND_ICON[result.kind];
              return (
                // Keyboard selection happens in the combobox input (aria-activedescendant).
                // eslint-disable-next-line jsx-a11y/click-events-have-key-events
                <li
                  key={`${result.kind}:${result.id}`}
                  id={`${listId}-${index}`}
                  role="option"
                  aria-selected={index === active}
                  onMouseDown={(event) => event.preventDefault()}
                  onMouseMove={() => setActive(index)}
                  onClick={() => go(result)}
                  className={cn(
                    'rounded-control flex cursor-pointer items-center gap-3 px-3 py-2',
                    index === active ? 'bg-primary-soft' : 'hover:bg-surface-2',
                  )}
                >
                  <Icon className="text-muted size-4 shrink-0" aria-hidden="true" />
                  <span className="min-w-0 flex-1">
                    <span className="text-ink block truncate text-sm font-medium">
                      {result.title}
                    </span>
                    {result.subtitle && (
                      <span className="text-muted block truncate text-xs">{result.subtitle}</span>
                    )}
                  </span>
                  <span className="text-subtle text-xs">{KIND_LABEL[result.kind]}</span>
                </li>
              );
            })}
          </ul>
        )}
      </div>
    </Dialog>
  );
}
