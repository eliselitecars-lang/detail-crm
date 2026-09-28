import { screen, waitFor, within } from '@testing-library/react';
import { useImperativeHandle, useState, type Ref } from 'react';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import type { SignaturePadHandle } from '@/components/ui';
import { renderRoute } from '@/test/render';
import {
  mockRpc,
  pgError,
  resetSupabaseMock,
  setFunctionResult,
  supabase,
} from '@/test/supabaseMock';
import type { JobReport } from './api';
import JobReportPage from './JobReportPage';
import { marksByView, pairBeforeAfter, photoLabel, vehicleText } from './model';

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

const TOKEN = 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee';
const SHOP = 'ffffffff-ffff-4fff-8fff-ffffffffffff';
const PRE = '12121212-1212-4121-8121-121212121212';

function photo(
  id: string,
  kind: 'before' | 'after' | 'other',
  extra: Record<string, unknown> = {},
) {
  return {
    id,
    kind,
    caption: null,
    media_type: 'image',
    duration_seconds: null,
    has_poster: false,
    created_at: '2026-09-20T15:00:00Z',
    ...extra,
  };
}

const preInspection = {
  id: PRE,
  kind: 'pre',
  mileage: 45210,
  fuel_level: 50,
  marks: [
    {
      id: 'm1',
      view: 'front',
      x: 0.3,
      y: 0.4,
      damage: 'chip',
      note: 'Stone chip',
      has_photo: true,
    },
  ],
  signed_at: null,
  signed_by_name: null,
  signed_remotely: false,
  can_acknowledge: true,
};

function report(overrides: Partial<Record<keyof JobReport, unknown>> = {}) {
  return {
    shop: {
      name: 'Glacier Detailing',
      logo_path: null,
      brand_color: '#1F6FEB',
      phone: '+12055550100',
      email: null,
      review_url: 'https://g.page/r/review',
      timezone: 'America/Chicago',
    },
    job: {
      number: 1042,
      status: 'completed',
      completed_at: '2026-09-20T20:00:00Z',
      local_date: '2026-09-20',
    },
    vehicle: { year: 2021, make: 'Toyota', model: 'Camry', color: 'Blue' },
    services: ['Full detail', 'Hand wax'],
    message: 'Thanks for trusting us!',
    published_at: '2026-09-20T21:00:00Z',
    photos: [
      photo('p1', 'before'),
      photo('p2', 'after', { caption: 'Hood, after polish' }),
      photo('p3', 'other'),
      photo('v1', 'after', { media_type: 'video', duration_seconds: 42, has_poster: true }),
    ],
    inspections: [
      {
        id: PRE,
        kind: 'pre',
        mileage: 45210,
        fuel_level: 50,
        marks: [
          {
            id: 'm1',
            view: 'front',
            x: 0.3,
            y: 0.4,
            damage: 'chip',
            note: 'Stone chip',
            has_photo: true,
          },
        ],
        signed_at: null,
        signed_by_name: null,
        signed_remotely: false,
        can_acknowledge: true,
      },
    ],
    documents: [
      { id: 'd1', file_name: 'Warranty.pdf', content_type: 'application/pdf', size_bytes: 2048 },
    ],
    signature_upload_prefix: `${SHOP}/reports/${TOKEN}/`,
    ...overrides,
  };
}

const url = (name: string) =>
  `https://unit-test.supabase.co/storage/v1/object/sign/${name}?token=t`;

function media() {
  setFunctionResult('public-media', {
    data: {
      expires_in: 600,
      items: [
        { ref_id: 'p1', kind: 'photo', url: url('p1.jpg') },
        { ref_id: 'p2', kind: 'photo', url: url('p2.jpg') },
        { ref_id: 'p3', kind: 'photo', url: url('p3.jpg') },
        { ref_id: 'v1', kind: 'video', url: url('v1.mp4') },
        { ref_id: 'v1', kind: 'poster', url: url('v1.jpg') },
        { ref_id: 'm1', kind: 'mark_photo', url: url('m1.jpg') },
        { ref_id: 'd1', kind: 'document', url: url('d1.pdf') },
      ],
    },
  });
}

function render(token = TOKEN) {
  return renderRoute(<JobReportPage />, {
    path: `/r/${token}`,
    routePath: '/r/:token',
    shop: null,
  });
}

beforeEach(() => {
  resetSupabaseMock();
});

describe('JobReportPage', () => {
  it('shows before & after pairs, other photos, videos, damage marks and documents', async () => {
    mockRpc({ public_get_job_report: { data: report() } });
    media();
    render();
    expect(
      await screen.findByRole('heading', { name: 'Your job report', level: 1 }),
    ).toBeInTheDocument();
    expect(
      screen.getByText(/Job #1042 · September 20, 2026 · 2021 Toyota Camry, Blue/),
    ).toBeInTheDocument();
    expect(screen.getByText('Thanks for trusting us!')).toBeInTheDocument();
    const pair = await screen.findByRole('img', { name: 'Hood, after polish' });
    expect(pair).toHaveAttribute('src', url('p2.jpg'));
    expect(screen.getByRole('img', { name: 'Before photo 1' })).toHaveAttribute(
      'src',
      url('p1.jpg'),
    );
    const videos = screen.getByRole('list', { name: 'Videos' });
    const video = videos.querySelector('video');
    expect(video).toHaveAttribute('src', url('v1.mp4'));
    expect(video).toHaveAttribute('poster', url('v1.jpg'));
    expect(screen.getByText('Stone chip')).toBeInTheDocument();
    expect(screen.getByRole('link', { name: /Photo of mark 1/ })).toHaveAttribute(
      'href',
      url('m1.jpg'),
    );
    expect(screen.getByRole('link', { name: /Open Warranty\.pdf/ })).toHaveAttribute(
      'href',
      url('d1.pdf'),
    );
    expect(screen.getByRole('link', { name: /Leave Glacier Detailing a review/ })).toHaveAttribute(
      'href',
      'https://g.page/r/review',
    );
    expect(supabase.rpc).toHaveBeenCalledWith('public_get_job_report', { p_token: TOKEN });
    expect(supabase.functions.invoke).toHaveBeenCalledWith('public-media', {
      body: { action: 'job_report', token: TOKEN },
    });
  });

  it('signs off the pre-service inspection with a drawn signature', async () => {
    const signedReport = report({
      inspections: [
        {
          ...preInspection,
          signed_at: '2026-09-21T10:00:00Z',
          signed_by_name: 'Ana Lee',
          signed_remotely: true,
          can_acknowledge: false,
        },
      ],
      signature_upload_prefix: null,
    });
    const calls = mockRpc({
      public_get_job_report: { data: report() },
      public_ack_inspection: { data: signedReport },
    });
    media();
    const { user } = render();
    const form = await screen.findByRole('form', { name: 'Review and sign' });
    await user.click(within(form).getByRole('button', { name: 'Sign inspection' }));
    expect(within(form).getByText('Type your full name.')).toBeInTheDocument();
    expect(
      within(form).getByText('Sign in the box: draw your signature, or choose Type and type it.'),
    ).toBeInTheDocument();
    expect(calls.some((c) => c.fn === 'public_ack_inspection')).toBe(false);

    await user.type(within(form).getByRole('textbox', { name: /Your full name/ }), 'Ana Lee');
    await user.click(within(form).getByRole('button', { name: 'Draw Your signature' }));
    await user.click(within(form).getByRole('button', { name: 'Sign inspection' }));

    await waitFor(() => expect(calls.some((c) => c.fn === 'public_ack_inspection')).toBe(true));
    const upload = supabase.storage.from('signatures').upload;
    const [path] = upload.mock.calls[0] as [string, Blob, unknown];
    expect(path).toMatch(new RegExp(`^${SHOP}/reports/${TOKEN}/signature-[0-9a-f-]{36}\\.png$`));
    expect(calls.find((c) => c.fn === 'public_ack_inspection')?.args).toEqual({
      p_token: TOKEN,
      p_inspection_id: PRE,
      p_signer_name: 'Ana Lee',
      p_signature_path: path,
    });
    expect(await screen.findByText('Signed by Ana Lee')).toBeInTheDocument();
    // 10:00Z in the shop's zone (Chicago, CDT), never the browser's (Honolulu)
    expect(
      screen.getByText(
        (_, el) =>
          el?.tagName === 'P' && el.textContent === 'Signed online on Mon, Sep 21, 2026 · 5:00 AM',
      ),
    ).toBeInTheDocument();
    expect(screen.queryByRole('form', { name: 'Review and sign' })).not.toBeInTheDocument();
  });

  it('explains a revoked or unknown link', async () => {
    mockRpc({ public_get_job_report: pgError('PT404', 'job report not found') });
    render();
    expect(await screen.findByText('We couldn’t find this job report')).toBeInTheDocument();
  });

  it('rejects a malformed token without calling the server', async () => {
    mockRpc({});
    render('not-a-token');
    expect(await screen.findByText('We couldn’t find this job report')).toBeInTheDocument();
    expect(supabase.rpc).not.toHaveBeenCalled();
  });
});

describe('job report helpers', () => {
  it('pairs before and after photos in order and keeps the rest', () => {
    const photos = [
      photo('b1', 'before'),
      photo('b2', 'before'),
      photo('a1', 'after'),
      photo('o1', 'other'),
    ].map((p) => ({ ...p, media_type: 'image' as const }));
    const { pairs, rest } = pairBeforeAfter(photos);
    expect(pairs.map((p) => [p.before.id, p.after.id])).toEqual([['b1', 'a1']]);
    expect(rest.map((p) => p.id)).toEqual(['b2', 'o1']);
    expect(photoLabel({ ...photos[3]!, caption: null }, 0)).toBe('Job photo 1');
    expect(vehicleText({ year: 2021, make: 'Toyota', model: null, color: 'Red' })).toBe(
      '2021 Toyota, Red',
    );
    expect(vehicleText(null)).toBeNull();
  });

  it('numbers damage marks across views', () => {
    const groups = marksByView([
      { id: 'a', view: 'rear', x: 0, y: 0, damage: 'dent', note: null, has_photo: false },
      { id: 'b', view: 'front', x: 0, y: 0, damage: 'chip', note: null, has_photo: false },
    ]);
    expect(groups.map((g) => [g.view, g.marks.map((m) => m.number)])).toEqual([
      ['front', [2]],
      ['rear', [1]],
    ]);
  });
});
