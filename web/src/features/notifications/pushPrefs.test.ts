import { describe, expect, it } from 'vitest';
import { ALL_KINDS, isMuted, MEMBER_KINDS, nextPushKinds, pushableKinds } from './pushPrefs';

describe('push preferences', () => {
  it('lists every kind for managers and only member kinds for technicians', () => {
    expect(pushableKinds('technician')).toEqual([...MEMBER_KINDS]);
    expect(new Set(pushableKinds('manager'))).toEqual(new Set(ALL_KINDS));
  });

  it('keeps hidden kinds as saved (or on, when never saved)', () => {
    const visible = pushableKinds('technician');
    expect(nextPushKinds(null, visible, new Set(['task_due']))).toEqual(
      ALL_KINDS.filter((k) => !MEMBER_KINDS.includes(k) || k === 'task_due'),
    );
    expect(nextPushKinds(['low_stock'], visible, new Set())).toEqual(['low_stock']);
  });

  it('knows whether a pause is running', () => {
    const now = new Date('2026-09-28T12:00:00Z');
    expect(isMuted('2026-09-29T00:00:00Z', now)).toBe(true);
    expect(isMuted('2026-09-28T11:00:00Z', now)).toBe(false);
    expect(isMuted(null, now)).toBe(false);
  });
});
