import { render } from '@testing-library/react';
import { useRef } from 'react';
import { afterEach, describe, expect, it, vi } from 'vitest';
import {
  EMBED_HEIGHT_MESSAGE,
  EMBED_SCROLL_TOP_MESSAGE,
  isEmbedMode,
  requestEmbedScrollTop,
  useEmbedHeight,
} from './embed';

function Probe() {
  const ref = useRef<HTMLDivElement>(null);
  useEmbedHeight(ref);
  return <div ref={ref}>content</div>;
}

afterEach(() => {
  vi.restoreAllMocks();
});

describe('embed mode', () => {
  it('is on only with ?embed=1', () => {
    expect(isEmbedMode(new URLSearchParams('embed=1'))).toBe(true);
    expect(isEmbedMode(new URLSearchParams('embed=true'))).toBe(false);
  });

  it('posts only its height to the parent, and only when framed', () => {
    const post = vi.spyOn(window.parent, 'postMessage');
    vi.spyOn(HTMLElement.prototype, 'getBoundingClientRect').mockReturnValue({
      height: 812.3,
    } as DOMRect);
    const { unmount } = render(<Probe />);
    expect(post).not.toHaveBeenCalled();
    unmount();

    vi.spyOn(window, 'top', 'get').mockReturnValue({} as Window);
    render(<Probe />);
    expect(post).toHaveBeenCalledWith({ type: EMBED_HEIGHT_MESSAGE, height: 813 }, '*');
  });

  it('asks the parent to show the frame’s top only when framed, else scrolls itself', () => {
    const post = vi.spyOn(window.parent, 'postMessage');
    const scroll = vi.spyOn(window, 'scrollTo').mockImplementation(() => undefined);
    requestEmbedScrollTop();
    expect(post).not.toHaveBeenCalled();
    expect(scroll).toHaveBeenCalledWith({ top: 0 });

    vi.spyOn(window, 'top', 'get').mockReturnValue({} as Window);
    requestEmbedScrollTop();
    expect(post).toHaveBeenCalledWith({ type: EMBED_SCROLL_TOP_MESSAGE }, '*');
  });
});
