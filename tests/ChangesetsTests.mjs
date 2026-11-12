import assert from 'node:assert/strict';
import { execFileSync, spawnSync } from 'node:child_process';
import { copyFileSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, symlinkSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import test from 'node:test';
import { checkChange, checkRange, git, planRelease, releaseNotes } from '../scripts/changesets.mjs';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const read = (cwd, path) => readFileSync(join(cwd, path), 'utf8');
const json = (cwd, path) => JSON.parse(read(cwd, path));
function write(cwd, path, content) { mkdirSync(dirname(join(cwd, path)), { recursive: true }); writeFileSync(join(cwd, path), content); }
function commit(cwd, message) {
  git(cwd, 'add', '-A'); git(cwd, '-c', 'core.hooksPath=/dev/null', 'commit', '-qm', message);
  return git(cwd, 'rev-parse', 'HEAD').trim();
}
function fixture(t) {
  const cwd = mkdtempSync(join(tmpdir(), 'rail changesets '));
  t.after(() => rmSync(cwd, { recursive: true, force: true }));
  git(cwd, 'init', '-qb', 'main');
  git(cwd, 'config', 'user.email', 'test@example.invalid'); git(cwd, 'config', 'user.name', 'Rail Test');
  write(cwd, '.gitignore', '/node_modules/\n/build/\n');
  for (const path of ['package.json', 'package-lock.json', '.changeset/config.json', 'scripts/version-release.mjs', 'scripts/changesets.mjs', 'scripts/check-changesets.mjs', 'scripts/prepare-release.mjs']) {
    write(cwd, path, read(root, path));
  }
  // Tests retain their stable starting version when Rail itself is versioned later.
  for (const path of ['package.json', 'package-lock.json']) {
    const data = json(cwd, path); data.version = '0.1.0';
    if (data.packages) data.packages[''].version = '0.1.0';
    write(cwd, path, JSON.stringify(data, null, 2) + '\n');
  }
  symlinkSync(join(root, 'node_modules'), join(cwd, 'node_modules'), 'dir');
  commit(cwd, 'Baseline');
  return cwd;
}
function addChangeset(cwd, name = 'first', type = 'patch', summary = 'Improve Rail.') {
  write(cwd, `.changeset/${name}.md`, `---\n"rail": ${type}\n---\n\n${summary}\n`);
}
function version(cwd) {
  execFileSync(process.execPath, [join(cwd, 'scripts/version-release.mjs')], { cwd, env: { ...process.env, CI: 'true' }, stdio: 'pipe' });
}
function prepare(cwd, releases = []) {
  // An ignored fixture file supplies GitHub release state without dirtying the checkout.
  write(cwd, 'build/releases.json', JSON.stringify(releases));
  const output = execFileSync(process.execPath, [join(cwd, 'scripts/prepare-release.mjs'), '--releases', join(cwd, 'build/releases.json')], {
    cwd, env: { ...process.env, CI: 'true' }, encoding: 'utf8', stdio: 'pipe',
  });
  return JSON.parse(output.trim().split('\n').at(-1));
}
function versionedFixture(t) {
  const cwd = fixture(t), base = git(cwd, 'rev-parse', 'HEAD').trim();
  addChangeset(cwd, 'fix', 'patch', 'Fix a browser issue.'); commit(cwd, 'Fix');
  addChangeset(cwd, 'feature', 'minor', 'Add a browser feature.'); commit(cwd, 'Feature');
  version(cwd); const sha = commit(cwd, 'Version Rail');
  return { cwd, base, sha };
}

test('the staged index needs a new valid changeset; an unstaged changeset does not count', t => {
  const cwd = fixture(t);
  write(cwd, 'app.cpp', '// changed\n'); git(cwd, 'add', 'app.cpp');
  addChangeset(cwd);
  assert.throws(() => checkChange(cwd, 'HEAD', 'index'), /Every change commit needs/);
  git(cwd, 'add', '.changeset/first.md');
  assert.equal(checkChange(cwd, 'HEAD', 'index').kind, 'change');
});

test('empty, malformed, unknown-package, and summary-free changesets fail', t => {
  const cwd = fixture(t);
  for (const content of ['---\n---\n', 'not a changeset', '---\nother: patch\n---\nWrong package\n', '---\nrail: patch\n---\n', '---\nrail: banana\n---\nBad bump\n']) {
    write(cwd, '.changeset/invalid.md', content); git(cwd, 'add', '.changeset/invalid.md');
    assert.throws(() => checkChange(cwd, 'HEAD', 'index'));
  }
});

test('every commit is checked, so an earlier changeset cannot cover a later commit', t => {
  const cwd = fixture(t), base = git(cwd, 'rev-parse', 'HEAD').trim();
  addChangeset(cwd); commit(cwd, 'With changeset');
  write(cwd, 'app.cpp', '// missing changeset\n'); const head = commit(cwd, 'Without changeset');
  assert.throws(() => checkRange(cwd, base, head), /Every change commit needs/);
});

test('PR checks cover stacked branch bases while publication remains main-only', () => {
  const workflow = read(root, '.github/workflows/release.yml');
  assert.match(workflow, /^  pull_request: \{\}$/m);
  assert.match(workflow, /^  push:\n    branches: \[main\]$/m);
  assert.match(workflow, /if: github\.event_name == 'pull_request'/);
  assert.match(workflow, /if: github\.ref == 'refs\/heads\/main' && github\.event_name != 'pull_request'/);
});

test('a chore(deps) commit needs no changeset, but other commit types still do', t => {
  const cwd = fixture(t), base = git(cwd, 'rev-parse', 'HEAD').trim();
  write(cwd, 'deps.txt', 'bumped\n'); const head = commit(cwd, 'chore(deps): bump the npm-minor-and-patch group');
  assert.equal(checkRange(cwd, base, head), 1);
  for (const subject of ['chore: tidy up', 'chore(deps-dev): bump a', 'fix(deps): bump b', 'see chore(deps): bump c']) {
    const before = git(cwd, 'rev-parse', 'HEAD').trim();
    write(cwd, 'deps.txt', `${subject}\n`); const other = commit(cwd, subject);
    assert.throws(() => checkRange(cwd, before, other), /Every change commit needs/, subject);
    git(cwd, 'reset', '-q', '--hard', before);
  }
});

test('merging a chore(deps) branch needs no changeset, but a mixed branch still does', t => {
  const cwd = fixture(t), base = git(cwd, 'rev-parse', 'HEAD').trim();
  git(cwd, 'checkout', '-qb', 'deps');
  write(cwd, 'deps.txt', 'bumped\n'); commit(cwd, 'chore(deps): bump a');
  git(cwd, 'checkout', '-q', 'main');
  git(cwd, '-c', 'core.hooksPath=/dev/null', 'merge', '-q', '--no-ff', '-m', 'Merge pull request #1 from dependabot/a', 'deps');
  const merged = git(cwd, 'rev-parse', 'HEAD').trim();
  assert.equal(checkRange(cwd, base, merged), 2);

  git(cwd, 'checkout', '-qb', 'mixed');
  write(cwd, 'deps.txt', 'bumped again\n'); commit(cwd, 'chore(deps): bump b');
  write(cwd, 'app.cpp', '// feature\n'); addChangeset(cwd, 'mixed'); commit(cwd, 'Add a feature');
  git(cwd, 'checkout', '-q', 'main');
  git(cwd, '-c', 'core.hooksPath=/dev/null', 'merge', '-q', '--no-ff', '-m', 'Merge pull request #2 from a/mixed', 'mixed');
  assert.equal(checkChange(cwd, 'HEAD^1', 'HEAD').kind, 'change');

  git(cwd, 'checkout', '-qb', 'unlabelled', merged);
  write(cwd, 'app.cpp', '// no changeset\n'); commit(cwd, 'Add another feature');
  git(cwd, 'checkout', '-q', 'main'); git(cwd, 'reset', '-q', '--hard', merged);
  git(cwd, '-c', 'core.hooksPath=/dev/null', 'merge', '-q', '--no-ff', '-m', 'Merge pull request #3 from a/unlabelled', 'unlabelled');
  const head = git(cwd, 'rev-parse', 'HEAD').trim();
  assert.throws(() => checkChange(cwd, 'HEAD^1', 'HEAD'), /Every change commit needs/);
  assert.throws(() => checkRange(cwd, merged, head), /Every change commit needs/);
});

test('a chore(deps) commit cannot hand-edit the version or consume changesets', t => {
  const cwd = fixture(t); addChangeset(cwd); commit(cwd, 'With changeset');
  const before = git(cwd, 'rev-parse', 'HEAD').trim();
  git(cwd, 'rm', '-q', '.changeset/first.md'); const head = commit(cwd, 'chore(deps): bump a');
  assert.throws(() => checkRange(cwd, before, head), /Only version commits may consume/);
});

test('editing an existing changeset alone cannot cover another commit', t => {
  const cwd = fixture(t); addChangeset(cwd); commit(cwd, 'First change');
  addChangeset(cwd, 'first', 'minor'); git(cwd, 'add', '.changeset/first.md');
  assert.throws(() => checkChange(cwd, 'HEAD', 'index'), /new changeset/);
});

test('the actual CLI batches patch and minor changes into one native app version', t => {
  const { cwd, base, sha } = versionedFixture(t);
  assert.equal(json(cwd, 'package.json').version, '0.2.0');
  assert.equal(json(cwd, 'package-lock.json').packages[''].version, '0.2.0');
  assert.equal(existsSync(join(cwd, '.changeset/fix.md')), false);
  assert.equal(existsSync(join(cwd, '.changeset/feature.md')), false);
  const notes = releaseNotes(read(cwd, 'CHANGELOG.md'), '0.2.0');
  assert.match(notes, /Fix a browser issue/); assert.match(notes, /Add a browser feature/);
  assert.equal(checkRange(cwd, base, sha), 3);
  assert.equal(checkChange(cwd, `${sha}^`, sha).kind, 'version');
  // CMake consumes the version without running Node or maintaining a second version file.
  copyFileSync(join(root, 'CMakeLists.txt'), join(cwd, 'CMakeLists.txt'));
  for (const name of ['BrowserModel', 'History', 'Projects', 'Reading', 'TrackedRuns']) for (const ext of ['cpp', 'h']) {
    write(cwd, `src/${name}.${ext}`, read(root, `src/${name}.${ext}`));
  }
  const cmake = existsSync(join(root, '.tools/bin/cmake')) ? join(root, '.tools/bin/cmake') : 'cmake';
  execFileSync(cmake, ['-S', cwd, '-B', join(cwd, 'build'), '-DRAIL_BUILD_APP=OFF', '-DBUILD_TESTING=OFF'], { stdio: 'pipe' });
  assert.match(read(cwd, 'build/CMakeCache.txt'), /CMAKE_PROJECT_VERSION:STATIC=0\.2\.0/);
});

test('versioning refuses dirty work and no pending changesets', t => {
  const cwd = fixture(t);
  assert.throws(() => version(cwd), error => /No pending Rail changesets/.test(error.stderr.toString()));
  addChangeset(cwd);
  assert.throws(() => version(cwd), error => /Commit your changes/.test(error.stderr.toString()));
});

test('the real git hook rejects missing changesets and accepts feature and version commits', t => {
  const cwd = fixture(t);
  git(cwd, 'config', 'core.hooksPath', join(root, '.githooks'));
  write(cwd, 'app.cpp', '// changed\n'); git(cwd, 'add', 'app.cpp');
  const rejected = spawnSync('git', ['commit', '-qm', 'Missing changeset'], { cwd, encoding: 'utf8' });
  assert.notEqual(rejected.status, 0); assert.match(rejected.stderr, /Every change commit needs/);
  addChangeset(cwd); git(cwd, 'add', '.changeset/first.md');
  git(cwd, 'commit', '-qm', 'With changeset');
  version(cwd); git(cwd, 'add', '-A'); git(cwd, 'commit', '-qm', 'Version Rail');
  assert.equal(json(cwd, 'package.json').version, '0.1.1');
});

test('manual version edits, missing lock updates, and mixed app/version commits fail', t => {
  const cwd = fixture(t);
  const pkg = json(cwd, 'package.json'); pkg.version = '9.0.0';
  write(cwd, 'package.json', JSON.stringify(pkg)); git(cwd, 'add', 'package.json');
  assert.throws(() => checkChange(cwd, 'HEAD', 'index'), /package-lock/);
  const lock = json(cwd, 'package-lock.json'); lock.version = lock.packages[''].version = '9.0.0';
  write(cwd, 'package-lock.json', JSON.stringify(lock)); git(cwd, 'add', 'package-lock.json');
  assert.throws(() => checkChange(cwd, 'HEAD', 'index'), /consume pending changesets/);
  const release = versionedFixture(t);
  write(release.cwd, 'app.cpp', '// app edit during versioning\n'); git(release.cwd, 'add', 'app.cpp');
  assert.throws(() => checkChange(release.cwd, `${release.sha}^`, 'index'), /separately from app changes/);
});

test('consuming a changeset without versioning fails even when another one is added', t => {
  const cwd = fixture(t); addChangeset(cwd); commit(cwd, 'Change');
  rmSync(join(cwd, '.changeset/first.md')); addChangeset(cwd, 'second'); git(cwd, 'add', '-A');
  assert.throws(() => checkChange(cwd, 'HEAD', 'index'), /Only version commits/);
});

test('an empty changeset queue skips publication without creating a commit', t => {
  const cwd = fixture(t), base = git(cwd, 'rev-parse', 'HEAD').trim();
  assert.deepEqual(prepare(cwd), { publish: false, versioned: false });
  assert.equal(git(cwd, 'rev-parse', 'HEAD').trim(), base);
});

test('new changesets after a prepared version are included in a fresh automatic version', t => {
  const { cwd, base, sha } = versionedFixture(t);
  addChangeset(cwd, 'later'); write(cwd, 'app.cpp', '// not released yet\n'); const head = commit(cwd, 'Later change');
  const result = prepare(cwd);
  assert.equal(result.version, '0.2.1'); assert.equal(result.versioned, true); assert.equal(result.publish, true);
  assert.equal(git(cwd, 'rev-parse', `${result.sha}^`).trim(), head);
  assert.notEqual(result.sha, sha);
  assert.equal(checkRange(cwd, base, result.sha), 5);
});

test('published versions are skipped, drafts can retry, and older versions cannot supersede newer ones', t => {
  const { cwd, base, sha } = versionedFixture(t);
  assert.equal(planRelease(cwd, { base, head: sha, releases: [{ tagName: 'v0.2.0', isDraft: false }] }).publish, false);
  assert.equal(planRelease(cwd, { base, head: sha, releases: [{ tagName: 'v0.2.0', isDraft: true }] }).publish, true);
  assert.throws(() => planRelease(cwd, { base, head: sha, releases: [{ tagName: 'v0.3.0', isDraft: false }] }), /newer app version/);
});

test('the pipeline consumes accumulated changesets, commits the version, and selects it for release', t => {
  const cwd = fixture(t), base = git(cwd, 'rev-parse', 'HEAD').trim();
  addChangeset(cwd, 'fix', 'patch'); commit(cwd, 'Fix');
  addChangeset(cwd, 'feature', 'minor'); commit(cwd, 'Feature');
  const result = prepare(cwd);
  assert.deepEqual(result, { publish: true, sha: git(cwd, 'rev-parse', 'HEAD').trim(), version: '0.2.0', tag: 'v0.2.0', versioned: true });
  assert.equal(checkRange(cwd, base, result.sha), 3);
  assert.equal(git(cwd, 'status', '--porcelain').trim(), '');
  assert.match(git(cwd, 'log', '-1', '--format=%s'), /Version Rail 0\.2\.0/);
});

test('merging a PR with a changeset automatically prepares a release without a version PR', t => {
  const cwd = fixture(t);
  git(cwd, 'switch', '-qc', 'feature');
  addChangeset(cwd, 'feature', 'minor'); write(cwd, 'app.cpp', '// feature\n'); commit(cwd, 'Feature with changeset');
  git(cwd, 'switch', '-q', 'main'); git(cwd, 'merge', '--no-ff', '-qm', 'Merge feature PR', 'feature');
  const merged = git(cwd, 'rev-parse', 'HEAD').trim();
  const result = prepare(cwd);
  assert.equal(result.version, '0.2.0'); assert.equal(result.publish, true); assert.equal(result.versioned, true);
  assert.equal(git(cwd, 'rev-parse', `${result.sha}^`).trim(), merged);
  assert.match(git(cwd, 'show', `${result.sha}:app.cpp`), /feature/);
});

test('a failed release retries the same version and a published version is skipped', t => {
  const cwd = fixture(t); addChangeset(cwd); commit(cwd, 'Change');
  const first = prepare(cwd);
  assert.deepEqual(prepare(cwd), { ...first, versioned: false });
  assert.deepEqual(prepare(cwd, [{ tagName: first.tag, isDraft: false }]), { ...first, publish: false, versioned: false });
  assert.equal(git(cwd, 'rev-parse', 'HEAD').trim(), first.sha);
});

test('later merged changesets automatically create the next release version', t => {
  const cwd = fixture(t); addChangeset(cwd); commit(cwd, 'Change');
  const first = prepare(cwd);
  addChangeset(cwd, 'next'); commit(cwd, 'Next change');
  const next = prepare(cwd, [{ tagName: first.tag, isDraft: false }]);
  assert.equal(next.version, '0.1.2'); assert.equal(next.versioned, true); assert.equal(next.publish, true);
});

test('automatic versioning validates all unreleased commits, including ones from queued pushes', t => {
  const cwd = fixture(t); addChangeset(cwd); commit(cwd, 'Valid change');
  write(cwd, 'app.cpp', '// no changeset\n'); commit(cwd, 'Invalid later change');
  assert.throws(() => prepare(cwd), error => /Every change commit needs/.test(error.stderr.toString()));
  assert.equal(json(cwd, 'package.json').version, '0.1.0');
});

test('a concurrent main update rejects the pipeline push without losing the new commit', t => {
  const cwd = fixture(t); addChangeset(cwd); const source = commit(cwd, 'Change');
  const remote = mkdtempSync(join(tmpdir(), 'rail release remote '));
  t.after(() => rmSync(remote, { recursive: true, force: true }));
  git(remote, 'init', '--bare', '-q'); git(cwd, 'remote', 'add', 'origin', remote);
  git(cwd, 'push', '-q', 'origin', 'HEAD:refs/heads/main');
  git(cwd, 'switch', '-qc', 'later-main'); addChangeset(cwd, 'later'); const later = commit(cwd, 'Later merge');
  git(cwd, 'push', '-q', 'origin', 'HEAD:refs/heads/main');
  git(cwd, 'checkout', '--detach', source);
  prepare(cwd);
  assert.throws(() => git(cwd, 'push', 'origin', 'HEAD:refs/heads/main'));
  assert.match(git(cwd, 'ls-remote', 'origin', 'refs/heads/main'), new RegExp(`^${later}`));
});
