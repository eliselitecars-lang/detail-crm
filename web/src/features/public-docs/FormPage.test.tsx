import { screen } from '@testing-library/react';
import { useImperativeHandle, useState, type Ref } from 'react';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import type { SignaturePadHandle } from '@/components/ui';
import { renderRoute } from '@/test/render';
import FormPage from './FormPage';
import { mockRpc, pgError, resetSupabaseMock, supabase } from '@/test/supabaseMock';
import { DOC_TOKEN, formFixture } from './testFixtures';

vi.mock('@/lib/supabase', () => import('@/test/supabaseMock'));

// jsdom has no canvas: a stand-in pad whose "Draw" button signs.
vi.mock('@/components/ui/SignaturePad', () => ({
  SignaturePad: function FakePad({
    ref,
    label,
    onChange,
  }: {
    ref?: Ref<SignaturePadHandle>;
    label: string;
    onChange?: (signed: boolean) => void;
  }) {
    const [signed, setSigned] = useState(false);
    useImperativeHandle(ref, () => ({
      clear: () => setSigned(false),
      isEmpty: () => !signed,
      toDataURL: () => (signed ? 'data:image/png;base64,AAAA' : null),
      toBlob: () => Promise.resolve(signed ? new Blob(['png'], { type: 'image/png' }) : null),
    }));
    return (
      <button
        type="button"
        onClick={() => {
          setSigned(true);
          onChange?.(true);
        }}
      >
        Draw {label}
      </button>
    );
  },
}));

function render() {
  return renderRoute(<FormPage />, { path: `/f/${DOC_TOKEN}`, routePath: '/f/:token', shop: null });
}

beforeEach(() => {
  resetSupabaseMock();
});

describe('FormPage', () => {
  it('renders the form body safely', async () => {
    mockRpc({
      public_get_form: {
        data: formFixture({ body: '## Terms\n\n<b>not bold</b> **bold**' }),
      },
    });
    const { container } = render();
    expect(
      await screen.findByRole('heading', { name: 'Vehicle waiver', level: 1 }),
    ).toBeInTheDocument();
    expect(screen.getByRole('heading', { name: 'Terms', level: 3 })).toBeInTheDocument();
    expect(container.querySelector('main b')).toBeNull();
    expect(screen.getByText(/<b>not bold<\/b>/)).toBeInTheDocument();
  });

  it('uploads the signature into the published folder, then signs', async () => {
    const signed = formFixture({
      status: 'signed',
      signer_name: 'Ana Diaz',
      signed_at: '2026-09-27T15:00:00Z',
    });
    const calls = mockRpc({
      public_get_form: { data: formFixture() },
      public_sign_form: { data: { ...signed, signature_upload_prefix: null } },
    });
    supabase.storage
      .from('signatures')
      .upload.mockResolvedValue({ data: { path: 'x' }, error: null });
    const { user } = render();
    await user.click(await screen.findByRole('button', { name: 'Sign form' }));
    expect(screen.getByText('Type your full name.')).toBeInTheDocument();
    expect(
      screen.getByText('Sign in the box: draw your signature, or choose Type and type it.'),
    ).toBeInTheDocument();
    expect(supabase.storage.from('signatures').upload).not.toHaveBeenCalled();

    await user.type(screen.getByLabelText(/^Your full name/), 'Ana Diaz');
    await user.click(screen.getByRole('button', { name: 'Draw Your signature' }));
    await user.click(screen.getByRole('button', { name: 'Sign form' }));

    expect(await screen.findByText('Signed — thank you!')).toBeInTheDocument();
    const [path, blob, options] = supabase.storage.from('signatures').upload.mock.calls[0] as [
      string,
      Blob,
      object,
    ];
    expect(path).toMatch(new RegExp(`^shop-1/forms/${DOC_TOKEN}/signature-[0-9a-f-]{36}\\.png$`));
    expect(path.split('/')).toHaveLength(4);
    expect(blob).toBeInstanceOf(Blob);
    expect(options).toMatchObject({ contentType: 'image/png', upsert: false });
    expect(calls.find((c) => c.fn === 'public_sign_form')?.args).toEqual({
      p_token: DOC_TOKEN,
      p_signer_name: 'Ana Diaz',
      p_signature_path: path,
    });
    expect(screen.queryByRole('button', { name: 'Sign form' })).not.toBeInTheDocument();
  });

  it('acknowledges a form that needs no drawn signature', async () => {
    const calls = mockRpc({
      public_get_form: { data: formFixture({ requires_signature: false }) },
      public_sign_form: {
        data: formFixture({ requires_signature: false, status: 'signed', signer_name: 'Ana' }),
      },
    });
    const { user } = render();
    await user.type(await screen.findByLabelText(/^Your full name/), 'Ana');
    await user.click(screen.getByRole('button', { name: 'I agree' }));
    expect(await screen.findByText('Signed — thank you!')).toBeInTheDocument();
    expect(supabase.storage.from('signatures').upload).not.toHaveBeenCalled();
    expect(calls.find((c) => c.fn === 'public_sign_form')?.args).toEqual({
      p_token: DOC_TOKEN,
      p_signer_name: 'Ana',
    });
  });

  it('reports a failed upload without signing', async () => {
    const calls = mockRpc({ public_get_form: { data: formFixture() } });
    supabase.storage
      .from('signatures')
      .upload.mockResolvedValue({ data: null, error: { message: 'denied' } });
    const { user } = render();
    await user.type(await screen.findByLabelText(/^Your full name/), 'Ana');
    await user.click(screen.getByRole('button', { name: 'Draw Your signature' }));
    await user.click(screen.getByRole('button', { name: 'Sign form' }));
    expect(
      await screen.findByText(
        'Your signature could not be saved. Check your connection and try again.',
      ),
    ).toBeInTheDocument();
    expect(calls.some((c) => c.fn === 'public_sign_form')).toBe(false);
  });

  it('shows the void state', async () => {
    mockRpc({ public_get_form: { data: formFixture({ status: 'void' }) } });
    render();
    expect(await screen.findByText('This form is no longer needed')).toBeInTheDocument();
    expect(screen.queryByRole('button', { name: 'Sign form' })).not.toBeInTheDocument();
  });

  it('shows not found for an unknown form', async () => {
    mockRpc({ public_get_form: pgError('PT404', 'form not found') });
    render();
    expect(await screen.findByText('We couldn’t find this form')).toBeInTheDocument();
  });
});
