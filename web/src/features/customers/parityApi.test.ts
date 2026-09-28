import { describe, expect, it } from 'vitest';
import { customerDocumentPath, mergeCountsText, referralShareUrl } from './parityApi';

describe('customer parity helpers', () => {
  it('stores customer files in their 4-segment folder with a safe name', () => {
    expect(customerDocumentPath('shop-1', 'cust-1', 'uuid-1', 'Fleet agreement (v2).pdf')).toBe(
      'shop-1/customers/cust-1/uuid-1-Fleet-agreement-v2.pdf',
    );
  });

  it('summarises what a merge moves', () => {
    expect(mergeCountsText({ jobs: 3, vehicles: 1, invoices: 0, series: 2 })).toBe(
      '1 vehicle, 3 jobs, 2 recurring series',
    );
    expect(mergeCountsText({ jobs: 0 })).toBe('No records to move');
  });

  it('uses the server share link, else a booking link on this origin', () => {
    expect(
      referralShareUrl({ code: 'AB12CD34', share_url: 'https://app/book/x?coupon=AB12CD34' }, 'x'),
    ).toBe('https://app/book/x?coupon=AB12CD34');
    expect(
      referralShareUrl({ code: 'AB12CD34', share_url: null }, 'glacier', 'https://crm.test/'),
    ).toBe('https://crm.test/book/glacier?coupon=AB12CD34');
  });
});
