import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { socket } from '../socket.service';

class FakeWebSocket {
  static CONNECTING = 0;
  static OPEN = 1;
  static instances: FakeWebSocket[] = [];

  readyState = FakeWebSocket.CONNECTING;
  private listeners = new Map<string, Array<(event: Event) => void>>();

  constructor(_url: string) {
    FakeWebSocket.instances.push(this);
  }

  addEventListener(type: string, listener: (event: Event) => void) {
    const listeners = this.listeners.get(type) || [];
    listeners.push(listener);
    this.listeners.set(type, listeners);
  }

  emit(type: string, event: Event = new Event(type)) {
    for (const listener of this.listeners.get(type) || []) {
      listener(event);
    }
  }

  close() {
    this.emit('close');
  }
  send() {}
}

describe('socket service', () => {
  beforeEach(() => {
    vi.useFakeTimers();
    socket.resetAll();
    FakeWebSocket.instances = [];
    vi.stubGlobal('WebSocket', FakeWebSocket);
  });

  afterEach(() => {
    socket.resetAll();
    vi.useRealTimers();
    vi.unstubAllGlobals();
  });

  it('keeps the initial subscriber when the first connection fails', () => {
    const onError = vi.fn();

    socket.subscribe('ws://router.test', vi.fn(), onError);
    FakeWebSocket.instances[0].emit('error');

    expect(onError).toHaveBeenCalledOnce();
  });

  it('reconnects after unexpected closure and preserves subscribers', () => {
    const listener = vi.fn();

    socket.subscribe('ws://router.test', listener);
    FakeWebSocket.instances[0].emit('close');
    vi.advanceTimersByTime(1000);

    expect(FakeWebSocket.instances).toHaveLength(2);
    FakeWebSocket.instances[1].emit('message', {
      data: 'restored',
    } as MessageEvent);
    expect(listener).toHaveBeenCalledWith('restored');
  });

  it('uses 1, 2, then 5 second reconnect delays', () => {
    socket.subscribe('ws://router.test', vi.fn());

    FakeWebSocket.instances[0].emit('close');
    vi.advanceTimersByTime(1000);
    FakeWebSocket.instances[1].emit('close');
    vi.advanceTimersByTime(2000);
    FakeWebSocket.instances[2].emit('close');
    vi.advanceTimersByTime(5000);

    expect(FakeWebSocket.instances).toHaveLength(4);
  });

  it('does not reconnect after manual disconnect', () => {
    socket.subscribe('ws://router.test', vi.fn());
    socket.disconnect('ws://router.test');
    vi.advanceTimersByTime(10000);

    expect(FakeWebSocket.instances).toHaveLength(1);
  });
});
