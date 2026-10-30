// The update check through the release binary. A fake curl on PATH answers,
// so no request leaves the machine.
import test from 'node:test';
import assert from 'node:assert/strict';
import {mkdtempSync, mkdirSync, writeFileSync, readFileSync, existsSync, statSync, rmSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {fileURLToPath} from 'node:url';
import {execFileSync, spawnSync} from 'node:child_process';

const binary = fileURLToPath(new URL('../target/release/hotch', import.meta.url));
const debian = process.platform === 'linux' && ['x64', 'arm64'].includes(process.arch);
const deb = version => ['amd64', 'arm64'].map(arch => ({name: `hotch_${version}-1_${arch}.deb`, state: 'uploaded'}));
// The newest release changed only macOS; the one before it is the Linux update.
const RELEASES = [
    {tag_name: 'v99.1.0', assets: [{name: 'Hotch-99.1.0.dmg', state: 'uploaded'}]},
    {tag_name: 'v99.0.0', assets: [{name: 'Hotch-99.0.0.dmg', state: 'uploaded'}, ...deb('99.0.0')]},
    {tag_name: 'v1.0.0', assets: deb('1.0.0')},
];

// A scratch home whose PATH holds only the fake curl.
function sandbox() {
    const home = mkdtempSync(join(tmpdir(), 'hotch-update-test-'));
    const bin = join(home, 'bin');
    const calls = join(home, 'curl-calls');
    const env = {...process.env, HOME: home, XDG_CONFIG_HOME: join(home, '.config'),
        XDG_CACHE_HOME: join(home, '.cache'), PATH: bin};
    const run = args => execFileSync(binary, args, {env, timeout: 15000, encoding: 'utf8'});
    const json = args => JSON.parse(run([...args, '--json']));
    mkdirSync(bin, {recursive: true});
    json(['settings', 'set', 'providers', '[]']);
    return {home, env, calls, run, json,
        curl: answer => writeFileSync(join(bin, 'curl'),
            `#!/bin/sh\nprintf '%s\\n' "$@" >> '${calls}'\n${answer}\n`, {mode: 0o755}),
        requests: () => existsSync(calls)
            ? readFileSync(calls, 'utf8').split('\n').filter(arg => arg.startsWith('https://')).length : 0};
}

test('update check finds the newest Linux release, checks daily, and honours skip and the preference',
    {skip: !debian && 'update checks cover the amd64 and arm64 Linux packages'}, () => {
        const {home, env, calls, run, json, curl, requests} = sandbox();
        const cache = join(home, '.cache/hotch/update.json');
        try {
            const current = run(['version']).trim().split(' ')[1];
            curl(`printf '%s' '${JSON.stringify(RELEASES)}'`);

            const checked = json(['update-check']);
            assert.equal(checked.answered, true);
            assert.equal(checked.update.current, current);
            assert.equal(checked.update.latest, '99.0.0');
            assert.equal(checked.update.url, 'https://github.com/hotherside/Hotch/releases/tag/v99.0.0');
            assert.equal(checked.update.available, true);
            const args = readFileSync(calls, 'utf8').split('\n');
            assert.equal(args[args.indexOf('--user-agent') + 1], `Hotch/${current} (Linux)`);
            assert.ok(args.includes('https://api.github.com/repos/hotherside/Hotch/releases?per_page=20'));
            assert.equal(statSync(cache).mode & 0o777, 0o600);

            // The extension's poll reads the cached answer: one request a day.
            assert.equal(json(['all']).update.latest, '99.0.0');
            assert.match(run(['all']), /Hotch 99\.0\.0 is available: https:\/\/github\.com\/hotherside\/Hotch\/releases\/tag\/v99\.0\.0/);
            assert.equal(requests(), 1);

            json(['settings', 'set', 'updateSkipped', '99.0.0']);
            assert.equal(json(['all']).update.available, false);
            assert.doesNotMatch(run(['all']), /is available/);

            // Offline: silent, no error output, and the next poll waits.
            rmSync(cache);
            curl('exit 7');
            const offline = spawnSync(binary, ['all', '--json'], {env, timeout: 15000, encoding: 'utf8'});
            assert.equal(offline.status, 0);
            assert.equal(offline.stderr, '');
            assert.equal(JSON.parse(offline.stdout).update.latest, null);
            json(['all']);
            assert.equal(requests(), 2);
            const manual = spawnSync(binary, ['update-check'], {env, timeout: 15000, encoding: 'utf8'});
            assert.equal(manual.status, 1);
            assert.match(manual.stdout, /Could not check for updates right now/);
            assert.equal(requests(), 3);

            // Off: the automatic check never runs.
            rmSync(cache);
            json(['settings', 'set', 'updateChecks', 'false']);
            assert.equal(json(['all']).update.checkedAt, null);
            assert.equal(requests(), 3);
        } finally {
            rmSync(home, {recursive: true, force: true});
        }
    });

test('a cache that cannot be written stops the automatic check rather than asking on every poll',
    {skip: !debian && 'update checks cover the amd64 and arm64 Linux packages'}, () => {
        const {home, env, json, curl, requests} = sandbox();
        try {
            writeFileSync(join(home, 'not-a-directory'), '');
            env.XDG_CACHE_HOME = join(home, 'not-a-directory');
            curl(`printf '%s' '${JSON.stringify(RELEASES)}'`);
            for (let poll = 0; poll < 3; poll++)
                assert.equal(json(['all']).update.checkedAt, null);
            assert.equal(requests(), 0);
            // Asked for explicitly, it still answers.
            assert.equal(json(['update-check']).update.latest, '99.0.0');
            assert.equal(requests(), 1);
        } finally {
            rmSync(home, {recursive: true, force: true});
        }
    });
