import test from 'node:test';
import assert from 'node:assert/strict';
import {mkdtempSync, mkdirSync, writeFileSync, readFileSync, existsSync, statSync, rmSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {fileURLToPath} from 'node:url';
import {execFileSync, spawnSync} from 'node:child_process';

test('CLI preferences persist privately and disabling providers prevents CLI execution', () => {
    const home = mkdtempSync(join(tmpdir(), 'hotch-settings-test-'));
    const binary = fileURLToPath(new URL('../target/release/hotch', import.meta.url));
    const env = {...process.env, HOME: home, XDG_CONFIG_HOME: join(home, '.config'), PATH: join(home, '.local/bin')};
    const run = args => JSON.parse(execFileSync(binary, args, {env, timeout: 10000, encoding: 'utf8'}));
    try {
        mkdirSync(env.PATH, {recursive: true});
        for (const name of ['claude', 'codex'])
            writeFileSync(join(env.PATH, name), `#!/bin/sh\nprintf called > '${join(home, 'called')}'\nexit 1\n`, {mode: 0o755});
        const config = run(['settings', 'set', 'providers', '[]']);
        assert.deepEqual(config.settings.providers, []);
        assert.equal(statSync(config.path).mode & 0o777, 0o600);
        assert.equal(run(['settings', 'set', 'displayMode', 'remaining']).settings.displayMode, 'remaining');
        const saved = readFileSync(config.path, 'utf8');
        assert.equal(spawnSync(binary, ['settings', 'set', 'refreshSeconds', '0'], {env}).status, 2);
        assert.equal(readFileSync(config.path, 'utf8'), saved);
        const result = run(['all', '--json']);
        assert.deepEqual(result.usage, []);
        assert.deepEqual(result.sessions, []);
        assert.equal(existsSync(join(home, 'called')), false);
    } finally {
        rmSync(home, {recursive: true, force: true});
    }
});
