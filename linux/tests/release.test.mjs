// The release convention behind the update notice: a release whose Linux
// inputs differ only in the lockstep version fields from the last release with
// Linux packages attaches none (tools/linux_changed.py, release-linux.yml).
import test from 'node:test';
import assert from 'node:assert/strict';
import {mkdtempSync, mkdirSync, writeFileSync, rmSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {dirname, join} from 'node:path';
import {fileURLToPath} from 'node:url';
import {execFileSync} from 'node:child_process';

test('only releases that change Linux beyond the version fields publish Linux assets', () => {
    const repo = mkdtempSync(join(tmpdir(), 'hotch-release-test-'));
    const script = fileURLToPath(new URL('../tools/linux_changed.py', import.meta.url));
    const env = {...process.env, GIT_AUTHOR_NAME: 'Test', GIT_AUTHOR_EMAIL: 'test@example.com',
        GIT_COMMITTER_NAME: 'Test', GIT_COMMITTER_EMAIL: 'test@example.com', GITHUB_OUTPUT: ''};
    const git = (...args) => execFileSync('git', ['-c', 'commit.gpgsign=false', '-c', 'tag.gpgsign=false', ...args],
        {cwd: repo, env});
    const write = (path, text) => {
        mkdirSync(dirname(join(repo, path)), {recursive: true});
        writeFileSync(join(repo, path), text);
    };
    // GitHub's release list as the workflow fetches it. A release that changes
    // Linux gets its packages unless `packaged` is false (a failed build).
    const published = [];
    const release = (version, {ksni = '0.3.7', prerelease = false, packaged = true} = {}) => {
        write('Makefile', `VERSION := ${version}\n`);
        write('linux/Cargo.toml', `[package]\nname = "hotch"\nversion = "${version}"\nrust-version = "1.88"\n`);
        write('linux/Cargo.lock', `[[package]]\nname = "hotch"\nversion = "${version}"\n\n[[package]]\nname = "ksni"\nversion = "${ksni}"\n`);
        write('linux/gnome-extension/metadata.json', JSON.stringify({uuid: 'hotch@hotherside.com', 'version-name': version}, null, 2));
        git('add', '-A');
        git('commit', '-qm', version);
        git('tag', `v${version}`);
        const entry = {tag_name: `v${version}`, draft: false, prerelease, assets: [{name: `Hotch-${version}.dmg`}]};
        published.unshift(entry);
        writeFileSync(join(repo, 'releases.json'), JSON.stringify(published));
        // Run from outside the tag, as the workflow runs it from its own commit.
        const out = execFileSync('python3', [script, '--tag', `v${version}`, '--releases', join(repo, 'releases.json')],
            {cwd: join(repo, 'linux'), env, encoding: 'utf8'});
        const result = out.trim().split('\n').at(-1);
        if (result === 'linux=true' && packaged)
            entry.assets.push(...['amd64', 'arm64'].map(arch => ({name: `hotch_${version}-1_${arch}.deb`, state: 'uploaded'})));
        return result;
    };
    try {
        git('init', '-q', '-b', 'main');
        write('linux/src/main.rs', 'fn main() {}\n');
        assert.equal(release('2.3.0'), 'linux=true', 'first release');
        assert.equal(release('2.4.0'), 'linux=false', 'macOS-only: only version fields moved');
        write('linux/src/main.rs', 'fn main() { println!("hotch"); }\n');
        assert.equal(release('2.5.0'), 'linux=true');
        assert.equal(release('2.6.0', {ksni: '0.3.8'}), 'linux=true', 'a dependency bump changes the package');
        write('linux/gnome-extension/extension.js', '// new\n');
        assert.equal(release('2.7.0-beta.1', {prerelease: true}), 'linux=true');
        assert.equal(release('2.7.0'), 'linux=true', 'a stable release compares with the previous stable one');
        assert.equal(release('2.7.1'), 'linux=false');

        // Packaging failed, so the next release carries the change.
        write('linux/src/main.rs', 'fn main() { println!("hotch 2.8"); }\n');
        assert.equal(release('2.8.0', {packaged: false}), 'linux=true');
        assert.equal(release('2.8.1'), 'linux=true', 'compared with 2.7.0, the last release with packages');
        assert.equal(release('2.8.2'), 'linux=false');

        // Flagged a prerelease on GitHub without a suffix: stable users never got it.
        write('linux/gnome-extension/extension.js', '// newer\n');
        assert.equal(release('2.9.0', {prerelease: true}), 'linux=true');
        assert.equal(release('2.9.1'), 'linux=true', 'compared with 2.8.1, the last stable release with packages');
        assert.equal(release('2.9.2'), 'linux=false');
    } finally {
        rmSync(repo, {recursive: true, force: true});
    }
});
