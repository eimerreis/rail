import { execFileSync } from 'node:child_process';
import { isDeepStrictEqual } from 'node:util';
import { parseChangesetFile as parse } from '@changesets/parse';

export const git = (cwd, ...args) => execFileSync('git', args, { cwd, encoding: 'utf8', maxBuffer: 16 * 1024 * 1024, stdio: ['ignore', 'pipe', 'pipe'] });
export const isChangeset = path => /^\.changeset\/[^/]+\.md$/.test(path) && path !== '.changeset/README.md';

export function readAt(cwd, ref, path) {
  try { return git(cwd, 'show', `${ref === 'index' ? '' : ref}:${path}`); }
  catch { return null; }
}

function filesAt(cwd, ref) {
  return (ref === 'index' ? git(cwd, 'ls-files', '-z') : git(cwd, 'ls-tree', '-rz', '--name-only', ref)).split('\0').filter(Boolean);
}

export function changeset(contents, path) {
  let result;
  try { result = parse(contents); } catch (error) { throw new Error(`${path}: ${error.message}`); }
  if (!result.summary.trim() || result.releases.length !== 1 || result.releases[0].name !== 'rail' ||
      !['patch', 'minor', 'major'].includes(result.releases[0].type))
    throw new Error(`${path} needs a summary and exactly one rail patch, minor, or major release. Run npm run changeset.`);
  return result;
}

export function bump(version, type) {
  if (!/^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$/.test(version)) throw new Error(`Unsupported app version: ${version}`);
  const [major, minor, patch] = version.split('.').map(Number);
  return type === 'major' ? `${major + 1}.0.0` : type === 'minor' ? `${major}.${minor + 1}.0` : `${major}.${minor}.${patch + 1}`;
}

export function releaseNotes(changelog, version) {
  const sections = changelog.split(/^## /m).slice(1);
  const section = sections.find(text => text.split('\n')[0].trim() === version);
  if (!section || !section.slice(section.indexOf('\n') + 1).trim()) throw new Error(`Missing changelog entry for ${version}`);
  return section.slice(section.indexOf('\n') + 1).trim() + '\n';
}

// Validate the staged index or an actual commit, never unstaged working-tree files.
export function checkChange(cwd, base, head, { changesetOptional = false } = {}) {
  const paths = git(cwd, 'diff', '--no-renames', '--name-only', '-z', base, ...(head === 'index' ? ['--cached'] : [head])).split('\0').filter(Boolean);
  if (!paths.length) throw new Error('No staged changes.');
  const before = JSON.parse(readAt(cwd, base, 'package.json') || 'null');
  const after = JSON.parse(readAt(cwd, head, 'package.json') || 'null');
  if (!after || after.name !== 'rail' || !after.private) throw new Error('Rail must remain a private release-tooling package.');
  const lock = JSON.parse(readAt(cwd, head, 'package-lock.json') || 'null');
  if (lock?.version !== after.version || lock?.packages?.['']?.version !== after.version)
    throw new Error('package-lock.json must match the app version. Run npm run changeset:version.');

  if (before && before.version !== after.version) {
    const pending = filesAt(cwd, base).filter(isChangeset);
    if (!pending.length) throw new Error('A version commit must consume pending changesets.');
    const entries = pending.map(path => changeset(readAt(cwd, base, path), path));
    const type = entries.some(c => c.releases[0].type === 'major') ? 'major' : entries.some(c => c.releases[0].type === 'minor') ? 'minor' : 'patch';
    if (after.version !== bump(before.version, type)) throw new Error('Version must match the accumulated changesets. Run npm run changeset:version.');
    if (filesAt(cwd, head).some(isChangeset)) throw new Error('Version commits must consume all pending changesets.');
    const allowed = new Set(['package.json', 'package-lock.json', 'CHANGELOG.md', ...pending]);
    if (paths.some(path => !allowed.has(path))) throw new Error('Commit versioning separately from app changes.');
    if (!isDeepStrictEqual({ ...before, version: after.version }, after)) throw new Error('Version commits may only change the version in package.json.');
    const oldLock = JSON.parse(readAt(cwd, base, 'package-lock.json'));
    oldLock.version = after.version; oldLock.packages[''].version = after.version;
    if (!isDeepStrictEqual(oldLock, lock)) throw new Error('Version commits may only update the root version in package-lock.json.');
    releaseNotes(readAt(cwd, head, 'CHANGELOG.md') || '', after.version);
    return { kind: 'version', version: after.version };
  }

  const added = paths.filter(path => isChangeset(path) && readAt(cwd, base, path) === null && readAt(cwd, head, path) !== null);
  if (!added.length && !changesetOptional) throw new Error('Every change commit needs a new changeset. Run npm run changeset and stage the generated .changeset/*.md file.');
  for (const path of paths.filter(isChangeset)) {
    const content = readAt(cwd, head, path);
    if (content === null) throw new Error('Only version commits may consume changesets. Run npm run changeset:version.');
    changeset(content, path);
  }
  if (paths.includes('CHANGELOG.md')) throw new Error('CHANGELOG.md is generated by npm run changeset:version.');
  return { kind: 'change' };
}

// Dependabot commits as `chore(deps): ...`. These updates ship with the next release instead of forcing their own.
const isDependencyUpdateSubject = subject => /^chore\(deps\)!?:/.test(subject);
function isDependencyUpdate(cwd, commit) {
  const isMerge = git(cwd, 'rev-list', '--parents', '-n', '1', commit).trim().split(' ').length > 2;
  const range = isMerge ? [`${commit}^1..${commit}^2`] : ['-n', '1', commit];
  const subjects = git(cwd, 'log', '--format=%s', ...range).trim().split('\n').filter(Boolean);
  return subjects.length > 0 && subjects.every(isDependencyUpdateSubject);
}

export function checkRange(cwd, base, head) {
  const commits = git(cwd, 'rev-list', '--reverse', `${base}..${head}`).trim().split('\n').filter(Boolean);
  for (const commit of commits) {
    // Adoption starts when the configuration is introduced; do not police old history.
    if (readAt(cwd, commit, '.changeset/config.json') === null) continue;
    try { checkChange(cwd, `${commit}^1`, commit, { changesetOptional: isDependencyUpdate(cwd, commit) }); }
    catch (error) { throw new Error(`${commit.slice(0, 8)}: ${error.message}`); }
  }
  return commits.length;
}

export function releaseForVersion(version, sha, releases) {
  const tag = `v${version}`;
  const published = releases.some(release => release.tagName === tag && !release.isDraft);
  const newer = releases.some(release => {
    if (release.isDraft || !/^v\d+\.\d+\.\d+$/.test(release.tagName)) return false;
    const candidate = version.split('.').map(Number), released = release.tagName.slice(1).split('.').map(Number);
    const index = candidate.findIndex((value, i) => value !== released[i]);
    return index >= 0 && released[index] > candidate[index];
  });
  if (newer) throw new Error('A newer app version is already published; refusing to release an older version.');
  return { publish: !published, sha, version, tag };
}

export function planRelease(cwd, { base, head, manual = false, releases = [] }) {
  const revisions = manual ? [head] : [`${base}..${head}`];
  const commits = git(cwd, 'rev-list', '--first-parent', ...revisions).trim().split('\n').filter(Boolean);
  for (const sha of commits) {
    const pkg = readAt(cwd, sha, 'package.json');
    const previous = readAt(cwd, `${sha}^1`, 'package.json');
    if (!pkg || !previous || JSON.parse(pkg).version === JSON.parse(previous).version) continue;
    const result = checkChange(cwd, `${sha}^1`, sha);
    if (result.kind !== 'version') continue;
    return releaseForVersion(result.version, sha, releases);
  }
  return { publish: false };
}
