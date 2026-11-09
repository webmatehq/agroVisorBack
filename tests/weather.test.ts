import test from 'node:test';
import assert from 'node:assert/strict';
import {weather} from '../src/providers.js';

test('weather requests the parcel coordinates and selected history period', async () => {
  const originalFetch = globalThis.fetch;
  let requested: URL | undefined;
  globalThis.fetch = async (input) => {
    requested = new URL(String(input));
    return new Response(JSON.stringify({timezone: 'America/Argentina/Cordoba'}), {status: 200});
  };
  try {
    const result = await weather({latitude: -31.08, longitude: -58.29, timezone: 'auto'}, 30);
    assert.equal(requested?.searchParams.get('latitude'), '-31.08');
    assert.equal(requested?.searchParams.get('longitude'), '-58.29');
    assert.equal(requested?.searchParams.get('timezone'), 'auto');
    assert.equal(requested?.searchParams.get('past_days'), '30');
    assert.equal(result.timezone, 'America/Argentina/Cordoba');
  } finally {
    globalThis.fetch = originalFetch;
  }
});
