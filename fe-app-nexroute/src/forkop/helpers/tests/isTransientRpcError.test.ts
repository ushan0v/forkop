import { describe, expect, it } from 'vitest';

import { isTransientRpcError } from '../isTransientRpcError';

describe('isTransientRpcError', () => {
  it('detects LuCI RPC reply races caused by interrupted page requests', () => {
    expect(isTransientRpcError('No related RPC reply')).toBe(true);
    expect(isTransientRpcError('Request aborted while waiting for RPC')).toBe(
      true,
    );
  });

  it('does not treat backend action failures as transient transport errors', () => {
    expect(
      isTransientRpcError('Another component action is already running'),
    ).toBe(false);
    expect(isTransientRpcError('Component action job was not found')).toBe(
      false,
    );
  });
});
