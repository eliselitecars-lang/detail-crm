import { render, screen } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { createRef } from 'react';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { SignaturePad, type SignaturePadHandle } from './SignaturePad';

// jsdom has no canvas: signature_pad and the 2D context are stand-ins.
vi.mock('signature_pad', () => ({
  default: class FakeSignaturePad {
    on = vi.fn();
    off = vi.fn();
    clear = vi.fn();
    isEmpty = vi.fn(() => true);
    toData = vi.fn(() => []);
    fromData = vi.fn();
    toDataURL = vi.fn(() => 'data:image/png;base64,DRAWN');
    addEventListener = vi.fn();
    removeEventListener = vi.fn();
  },
}));

const fillText = vi.fn();
beforeEach(() => {
  fillText.mockClear();
  vi.spyOn(HTMLCanvasElement.prototype, 'getContext').mockImplementation((() => ({
    save: vi.fn(),
    restore: vi.fn(),
    scale: vi.fn(),
    setTransform: vi.fn(),
    clearRect: vi.fn(),
    measureText: (text: string) => ({ width: text.length * 10 }),
    fillText,
    font: '',
    fillStyle: '',
    textAlign: 'start',
    textBaseline: 'alphabetic',
  })) as never);
  vi.spyOn(HTMLCanvasElement.prototype, 'toBlob').mockImplementation(function (cb) {
    cb(new Blob(['png'], { type: 'image/png' }));
  });
  vi.spyOn(HTMLCanvasElement.prototype, 'toDataURL').mockReturnValue('data:image/png;base64,TYPED');
});
afterEach(() => vi.restoreAllMocks());

describe('SignaturePad', () => {
  it('can be signed with the keyboard: Type renders the text and exports the same PNG', async () => {
    const user = userEvent.setup();
    const ref = createRef<SignaturePadHandle>();
    const onChange = vi.fn();
    render(
      <SignaturePad
        ref={ref}
        label="Your signature"
        typedDefault="  Ana Diaz "
        onChange={onChange}
      />,
    );
    expect(
      screen.getByRole('img', { name: /Your signature \(empty — draw .* or choose Type\)/ }),
    ).toBeInTheDocument();
    expect(ref.current?.isEmpty()).toBe(true);
    expect(await ref.current?.toBlob()).toBeNull();

    // Keyboard only: Tab to the radios, arrow to "Type".
    await user.tab();
    expect(screen.getByRole('radio', { name: 'Draw' })).toHaveFocus();
    await user.keyboard('{ArrowRight}');
    expect(screen.getByRole('radio', { name: 'Type' })).toBeChecked();

    // Starts from the signer's name.
    const typed = screen.getByLabelText('Type your signature');
    expect(typed).toHaveValue('Ana Diaz');
    expect(onChange).toHaveBeenLastCalledWith(true);
    expect(ref.current?.isEmpty()).toBe(false);
    expect(
      screen.getByRole('img', { name: 'Your signature (typed: Ana Diaz)' }),
    ).toBeInTheDocument();
    expect(fillText).toHaveBeenCalledWith(
      'Ana Diaz',
      expect.any(Number),
      expect.any(Number),
      expect.any(Number),
    );

    await user.clear(typed);
    expect(onChange).toHaveBeenLastCalledWith(false);
    expect(ref.current?.isEmpty()).toBe(true);
    await user.type(typed, 'A. Diaz');
    expect(ref.current?.isEmpty()).toBe(false);
    const blob = await ref.current?.toBlob();
    expect(blob?.type).toBe('image/png');
    expect(ref.current?.toDataURL()).toBe('data:image/png;base64,TYPED');
    expect(fillText).toHaveBeenLastCalledWith(
      'A. Diaz',
      expect.any(Number),
      expect.any(Number),
      expect.any(Number),
    );
  });

  it('clearing a typed signature empties it; switching back to Draw starts empty', async () => {
    const user = userEvent.setup();
    const ref = createRef<SignaturePadHandle>();
    render(<SignaturePad ref={ref} label="Customer signature" />);
    await user.click(screen.getByRole('radio', { name: 'Type' }));
    const typed = screen.getByLabelText('Type your signature');
    expect(typed).toHaveValue('');
    await user.type(typed, 'Jo');
    await user.click(screen.getByRole('button', { name: 'Clear signature' }));
    expect(typed).toHaveValue('');
    expect(ref.current?.isEmpty()).toBe(true);
    await user.type(typed, 'Jo');
    await user.click(screen.getByRole('radio', { name: 'Draw' }));
    expect(screen.queryByLabelText('Type your signature')).not.toBeInTheDocument();
    expect(ref.current?.isEmpty()).toBe(true);
    expect(screen.getByRole('button', { name: 'Clear signature' })).toBeDisabled();
  });

  it('is disabled as a whole', () => {
    render(<SignaturePad label="Your signature" disabled />);
    expect(screen.getByRole('radio', { name: 'Type' })).toBeDisabled();
    expect(screen.getByRole('button', { name: 'Clear signature' })).toBeDisabled();
  });
});
