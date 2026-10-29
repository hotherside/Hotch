import test from 'node:test';
import assert from 'node:assert/strict';
import {mkdtempSync, mkdirSync, writeFileSync, rmSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {fileURLToPath} from 'node:url';
import {execFileSync} from 'node:child_process';

test('CLI reads Codex approval state and discovers an older resumed rollout', () => {
    const home = mkdtempSync(join(tmpdir(), 'hotch-cli-test-'));
    try {
        const bin = join(home, '.local/bin');
        mkdirSync(bin, {recursive: true});
        const thread = {id: 'server-thread', name: 'Approval fixture', updatedAt: 100,
            status: {type: 'active', activeFlags: ['waitingOnApproval']}};
        writeFileSync(join(bin, 'codex'), `#!/bin/sh
while IFS= read -r line; do
  case "$line" in
    *'"method":"initialize"'*) printf '%s\\n' '{"id":1,"result":{}}' ;;
    *'"method":"thread/list"'*) printf '%s\\n' '${JSON.stringify({id: 2, result: {data: [thread]}})}' ;;
  esac
done
`, {mode: 0o755});
        const dir = join(home, '.codex/sessions/2024/01/01');
        mkdirSync(dir, {recursive: true});
        writeFileSync(join(dir, 'rollout-old-00000000-0000-0000-0000-000000000001.jsonl'),
            '{"type":"event_msg","payload":{"type":"task_complete"}}\n');
        const binary = fileURLToPath(new URL('../target/release/hotch', import.meta.url));
        const result = JSON.parse(execFileSync(binary, ['sessions', '--json'], {
            env: {...process.env, HOME: home, XDG_CONFIG_HOME: join(home, '.config'), PATH: bin}, timeout: 10000, encoding: 'utf8',
        }));
        assert.equal(result.sessions.length, 2);
        assert.equal(result.sessions[0].activity, 'needs input');
        assert.equal(result.sessions[0].waitingFor, 'approval');
        assert.equal(result.sessions[1].activity, 'waiting');
    } finally {
        rmSync(home, {recursive: true, force: true});
    }
});
