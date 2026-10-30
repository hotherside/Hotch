import test from 'node:test';
import assert from 'node:assert/strict';
import {normalizeSettings, displayedPercent, focusAction, focusReading, clockText,
    privateClipboard, rememberClipboard, companionPosition} from '../gnome-extension/model.js';

test('invalid stored preferences fall back safely while existing pill position survives', () => {
    const result = normalizeSettings({home: 'bogus', providers: 'claude', refreshSeconds: 0, clipboardEnabled: 'yes', pillX: -150});
    assert.equal(result.home, 'panel');
    assert.equal(result.refreshSeconds, 60);
    assert.equal(result.clipboardEnabled, false);
    assert.deepEqual(result.providers, ['claude', 'codex']);
    assert.equal(result.pillX, -150);
    assert.equal(normalizeSettings(null).focus.startedAt, null);
    assert.deepEqual(normalizeSettings({providers: []}).providers, []);
    assert.equal(displayedPercent(30, 'remaining'), 70);
    assert.equal(result.updateChecks, true);
    assert.equal(result.updateSkipped, '');
});

test('update preferences keep only a boolean switch and a release version to skip', () => {
    assert.equal(normalizeSettings({updateChecks: false}).updateChecks, false);
    assert.equal(normalizeSettings({updateChecks: 'off'}).updateChecks, true);
    assert.equal(normalizeSettings({updateSkipped: '2.4.0'}).updateSkipped, '2.4.0');
    assert.equal(normalizeSettings({updateSkipped: '2.5.0-beta.1'}).updateSkipped, '2.5.0-beta.1');
    for (const bad of ['latest', '2.4', '2.4.0+build', 7, null])
        assert.equal(normalizeSettings({updateSkipped: bad}).updateSkipped, '');
});

test('Focus pause, resume, restart and completion retain elapsed time', () => {
    let state = normalizeSettings().focus;
    state = focusAction(state, 'start', 100);
    state = focusAction(state, 'pause', 200);
    assert.equal(focusReading(state, 500).elapsed, 100);
    state = focusAction(state, 'start', 500);
    state = JSON.parse(JSON.stringify(state));
    assert.equal(focusReading(state, 600).seconds, 1300);
    assert.equal(focusReading(state, 2000).done, true);
    state = focusAction(state, 'complete', 2000);
    assert.equal(state.startedAt, null);
    assert.equal(state.elapsed, 1500);
    assert.equal(focusAction(state, 'start', 3000).elapsed, 0);
    assert.equal(focusAction(state, 'reset', 3000).elapsed, 0);
    assert.equal(clockText(3661), '1:01:01');
    const stopwatch = {...state, mode: 'stopwatch', elapsed: 0, startedAt: 100};
    assert.equal(focusReading(stopwatch, 2000).done, false);
    assert.equal(focusReading(stopwatch, 2000).seconds, 1900);
});

test('clipboard skips privacy markers and bounds memory without duplicating copies', () => {
    assert.equal(privateClipboard(['text/plain', 'x-kde-passwordManagerHint']), true);
    assert.equal(privateClipboard(['org.nspasteboard.ConcealedType']), true);
    assert.equal(privateClipboard(['text/plain;charset=utf-8']), false);
    let items = [];
    for (let i = 0; i < 10; i++) items = rememberClipboard(items, String(i));
    assert.equal(items.length, 5);
    assert.deepEqual(rememberClipboard(items, '7'), ['7', '9', '8', '6', '5']);
    assert.equal(rememberClipboard(items, 'x'.repeat(30000))[0].length, 20000);
    assert.deepEqual(rememberClipboard(items, '   '), items);
});

test('edges anchor and floating companions remain on negative-coordinate displays', () => {
    const monitor = {x: -1920, y: 0, width: 1920, height: 1080};
    assert.deepEqual(companionPosition('edge-left', monitor, 80, 200, 0, 0, 30), [-1920, 440]);
    assert.deepEqual(companionPosition('edge-right', monitor, 80, 200, 0, 0, 30), [-80, 440]);
    assert.deepEqual(companionPosition('edge-bottom', monitor, 200, 80, 0, 0, 30), [-1060, 1000]);
    assert.deepEqual(companionPosition('orb', monitor, 80, 80, 2000, -200, 30), [-80, 30]);
});
