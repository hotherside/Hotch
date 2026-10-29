import test from 'node:test';
import assert from 'node:assert/strict';
import {mergeUsage, MAX_USAGE_AGE, readingStatus} from '../gnome-extension/data.js';

const good = {provider: 'claude', windows: [{percent: 42}], fetchedAt: 100, error: null};
const failure = {provider: 'claude', windows: [], fetchedAt: null, error: 'Signed out'};

test('failed refresh preserves successful timestamp and exposes error', () => {
    const [result] = mergeUsage([failure], [good], 160);
    assert.equal(result.fetchedAt, 100);
    assert.equal(result.error, 'Signed out');
    assert.equal(result.stale, true);
    assert.match(readingStatus(result, 160), /1m old.*Signed out/);
    assert.equal(good.error, null);
});

test('repeated failures cannot extend the cache lifetime', () => {
    const first = mergeUsage([failure], [good], 160);
    assert.deepEqual(mergeUsage([failure], first, 100 + MAX_USAGE_AGE), [failure]);
});

test('a successful empty result clears old usage and a recovery replaces it', () => {
    const empty = {...failure, error: null};
    assert.deepEqual(mergeUsage([empty], [good], 160), [empty]);
    const recovered = {...good, fetchedAt: 180, windows: [{percent: 43}]};
    assert.deepEqual(mergeUsage([recovered], [good], 180), [recovered]);
});
