import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';

const read = (path) => readFileSync(new URL(`../../${path}`, import.meta.url), 'utf8');

test('remote commands expose the optional native-handled marker', () => {
  const payloads = read('src/interfaces/events/EventPayloadByEvent.ts');
  const shared = read('src/interfaces/events/RemoteHandledEvent.ts');
  const seek = read('src/interfaces/events/RemoteSeekEvent.ts');
  const jumpForward = read('src/interfaces/events/RemoteJumpForwardEvent.ts');
  const jumpBackward = read('src/interfaces/events/RemoteJumpBackwardEvent.ts');

  assert.match(shared, /export interface RemoteHandledEvent/);
  assert.match(shared, /handledByNative\?: boolean/);
  for (const event of ['RemotePlay', 'RemotePause', 'RemoteStop', 'RemoteNext', 'RemotePrevious']) {
    assert.match(payloads, new RegExp(`\\[Event\\.${event}\\]: RemoteHandledEvent`));
  }
  for (const payload of [seek, jumpForward, jumpBackward]) {
    assert.match(payload, /extends RemoteHandledEvent/);
  }
});
