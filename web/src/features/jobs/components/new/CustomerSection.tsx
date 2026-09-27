import { useEffect, useState, type KeyboardEvent } from 'react';
import {
  Button,
  Combobox,
  FormField,
  Input,
  PhoneInput,
  SectionCard,
  useToast,
} from '@/components/ui';
import { formatPhone } from '@/lib/phone';
import { zOptionalEmail, zOptionalPhone } from '@/lib/validation';
import { useCreateCustomer, useCustomerSearch, type CustomerOption } from '../../newJobApi';
import { customerName } from '../../model';

function useDebounced<T>(value: T, ms: number): T {
  const [debounced, setDebounced] = useState(value);
  useEffect(() => {
    const timer = setTimeout(() => setDebounced(value), ms);
    return () => clearTimeout(timer);
  }, [value, ms]);
  return debounced;
}

export interface CustomerSectionProps {
  customer: CustomerOption | null;
  loading: boolean;
  onChange: (customer: CustomerOption | null) => void;
}

export function CustomerSection({ customer, loading, onChange }: CustomerSectionProps) {
  const [query, setQuery] = useState('');
  const debounced = useDebounced(query, 250);
  const search = useCustomerSearch(debounced);
  const [creating, setCreating] = useState<string | null>(null);

  if (customer) {
    return (
      <SectionCard
        title="Customer"
        actions={
          <Button size="sm" variant="ghost" onClick={() => onChange(null)}>
            Change
          </Button>
        }
      >
        <p className="text-ink font-semibold">{customerName(customer)}</p>
        <p className="text-muted text-sm">
          {[customer.phone ? formatPhone(customer.phone) : null, customer.email]
            .filter(Boolean)
            .join(' · ') || 'No contact details'}
        </p>
      </SectionCard>
    );
  }

  return (
    <SectionCard title="Customer" description="Search by name, phone or email, or create one.">
      {creating !== null ? (
        <NewCustomerForm
          initialName={creating}
          onCancel={() => setCreating(null)}
          onCreated={(c) => {
            setCreating(null);
            onChange(c);
          }}
        />
      ) : (
        <div className="flex flex-col gap-3">
          <FormField label="Customer" required>
            <Combobox<CustomerOption>
              value={null}
              onChange={(c) => onChange(c)}
              options={search.data ?? []}
              loading={search.isFetching || loading}
              onQueryChange={setQuery}
              getOptionValue={(c) => c.id}
              getOptionLabel={customerName}
              renderOption={(c) => (
                <span className="flex flex-col">
                  <span>{customerName(c)}</span>
                  <span className="text-muted text-xs">
                    {[c.phone ? formatPhone(c.phone) : null, c.email].filter(Boolean).join(' · ')}
                  </span>
                </span>
              )}
              placeholder="Search customers…"
              emptyText={search.isError ? 'Search failed — try again' : 'No customers found'}
              onCreate={(q) => setCreating(q)}
              createLabel={(q) => `New customer “${q}”`}
            />
          </FormField>
          <div>
            <Button size="sm" variant="secondary" onClick={() => setCreating('')}>
              New customer
            </Button>
          </div>
        </div>
      )}
    </SectionCard>
  );
}

function splitName(text: string): { first: string; last: string } {
  const parts = text.trim().split(/\s+/).filter(Boolean);
  if (parts.length <= 1) return { first: parts[0] ?? '', last: '' };
  return { first: parts.slice(0, -1).join(' '), last: parts[parts.length - 1] ?? '' };
}

function NewCustomerForm({
  initialName,
  onCancel,
  onCreated,
}: {
  initialName: string;
  onCancel: () => void;
  onCreated: (customer: CustomerOption) => void;
}) {
  const toast = useToast();
  const create = useCreateCustomer();
  const initial = splitName(initialName);
  const [first, setFirst] = useState(initial.first);
  const [last, setLast] = useState(initial.last);
  const [company, setCompany] = useState('');
  const [phone, setPhone] = useState('');
  const [email, setEmail] = useState('');
  const [errors, setErrors] = useState<Record<string, string>>({});

  const submit = async () => {
    const next: Record<string, string> = {};
    const phoneResult = zOptionalPhone.safeParse(phone);
    const emailResult = zOptionalEmail.safeParse(email);
    if (!first.trim() && !last.trim() && !company.trim()) next.first = 'Enter a name or company.';
    if (!phoneResult.success) next.phone = phoneResult.error.issues[0]?.message ?? 'Invalid phone.';
    if (!emailResult.success) next.email = emailResult.error.issues[0]?.message ?? 'Invalid email.';
    setErrors(next);
    if (Object.keys(next).length > 0 || !phoneResult.success || !emailResult.success) return;
    try {
      const customer = await create.mutateAsync({
        first_name: first.trim() || null,
        last_name: last.trim() || null,
        company: company.trim() || null,
        phone: phoneResult.data,
        email: emailResult.data,
      });
      toast.success('Customer created');
      onCreated(customer);
    } catch (error) {
      toast.error(error);
    }
  };

  // Enter in a field saves this record instead of submitting the job form.
  const submitOnEnter = (e: KeyboardEvent<HTMLInputElement>) => {
    if (e.key === 'Enter') {
      e.preventDefault();
      void submit();
    }
  };

  return (
    // Not a <form>: this sits inside the New job form (forms can't nest).
    <div role="group" className="grid grid-cols-1 gap-3 sm:grid-cols-2" aria-label="New customer">
      <FormField label="First name" error={errors.first}>
        <Input
          onKeyDown={submitOnEnter}
          value={first}
          maxLength={100}
          autoComplete="off"
          onChange={(e) => setFirst(e.target.value)}
        />
      </FormField>
      <FormField label="Last name">
        <Input
          onKeyDown={submitOnEnter}
          value={last}
          maxLength={100}
          autoComplete="off"
          onChange={(e) => setLast(e.target.value)}
        />
      </FormField>
      <FormField label="Company" className="sm:col-span-2">
        <Input
          onKeyDown={submitOnEnter}
          value={company}
          maxLength={200}
          onChange={(e) => setCompany(e.target.value)}
        />
      </FormField>
      <FormField label="Mobile phone" error={errors.phone}>
        <PhoneInput
          onKeyDown={submitOnEnter}
          value={phone}
          onChange={setPhone}
          autoComplete="off"
        />
      </FormField>
      <FormField label="Email" error={errors.email}>
        <Input
          onKeyDown={submitOnEnter}
          type="email"
          value={email}
          autoComplete="off"
          onChange={(e) => setEmail(e.target.value)}
        />
      </FormField>
      <div className="flex gap-2 sm:col-span-2">
        <Button loading={create.isPending} onClick={() => void submit()}>
          Create customer
        </Button>
        <Button type="button" variant="ghost" onClick={onCancel} disabled={create.isPending}>
          Cancel
        </Button>
      </div>
    </div>
  );
}
