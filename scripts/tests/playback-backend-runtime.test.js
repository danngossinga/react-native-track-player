const assert = require('node:assert/strict');
const test = require('node:test');
const { setPlaybackBackendOn } = require('../../lib/src/playbackBackend.js');

test('setPlaybackBackend rejects invalid config before bridge dispatch', async () => {
  const calls = [];
  let reads = 0;
  const bridge = {
    get setPlaybackBackend() {
      reads += 1;
      return async (config) => {
        calls.push(config);
        return { state: 'ready', playbackBackend: config };
      };
    },
  };

  for (const value of [
    null,
    {},
    { type: 'other' },
    { type: 'pingPong', engineMode: 'other' },
  ]) {
    await assert.rejects(
      () => setPlaybackBackendOn(bridge, value),
      (error) => error.code === 'invalid_playback_backend_config'
    );
  }

  assert.equal(calls.length, 0);
  assert.equal(reads, 0);
  const valid = Object.freeze({ type: 'standard' });
  await setPlaybackBackendOn(bridge, valid);
  assert.equal(reads, 1);
  assert.deepEqual(calls, [valid]);
  assert.equal(calls[0], valid);
});
