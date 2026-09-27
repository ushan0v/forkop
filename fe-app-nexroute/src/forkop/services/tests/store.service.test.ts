import { describe, expect, it, vi } from 'vitest';
import { StoreService } from '../store.service';

describe('StoreService', () => {
  it('diffs only keys provided to set', () => {
    const store = new StoreService({
      light: { value: 1 },
      heavy: { items: [{ id: 1 }] },
    });
    const listener = vi.fn();

    store.subscribe(listener);
    listener.mockClear();

    store.set({ light: { value: 2 } });

    expect(listener).toHaveBeenCalledTimes(1);
    expect(listener.mock.calls[0][2]).toEqual({ light: { value: 2 } });
  });

  it('does not notify when provided values are unchanged', () => {
    const store = new StoreService({
      light: { value: 1 },
      heavy: { items: [{ id: 1 }] },
    });
    const listener = vi.fn();

    store.subscribe(listener);
    listener.mockClear();

    store.set({ light: { value: 1 } });

    expect(listener).not.toHaveBeenCalled();
  });
});
