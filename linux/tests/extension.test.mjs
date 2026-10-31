import test from 'node:test';
import assert from 'node:assert/strict';
import {mergeUsage, MAX_USAGE_AGE, readingStatus, updateNotice} from '../gnome-extension/data.js';

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

test('update notice respects a skipped version and the preference, and links only release pages', () => {
    const update = {current: '2.3.0', latest: '2.4.0', checkedAt: 100, available: true,
        url: 'https://github.com/hotherside/Hotch/releases/tag/v2.4.0'};
    const on = {updateChecks: true, updateSkipped: ''};
    assert.deepEqual(updateNotice(update, on), {version: '2.4.0', url: update.url});
    assert.deepEqual(updateNotice(update, {...on, updateSkipped: '2.3.9'}), {version: '2.4.0', url: update.url});
    assert.equal(updateNotice(update, {...on, updateSkipped: '2.4.0'}), null);
    assert.equal(updateNotice(update, {...on, updateChecks: false}), null);
    assert.equal(updateNotice({...update, available: false}, on), null);
    for (const url of ['https://example.com/hotch_2.4.0-1_amd64.deb',
        'https://github.com/hotherside/Hotch/releases/tag/v2.5.0',
        'https://github.com/hotherside/Hotch/releases/tag/../../../../x/y/releases'])
        assert.equal(updateNotice({...update, url}, on), null, url);
    assert.equal(updateNotice({...update, latest: '2.5.0-rc.1',
        url: 'https://github.com/hotherside/Hotch/releases/tag/v2.5.0-rc.1'}, on), null);
    assert.equal(updateNotice(undefined, on), null);
});
