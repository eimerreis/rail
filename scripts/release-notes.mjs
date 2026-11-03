import { readFileSync } from 'node:fs';
import { releaseNotes } from './changesets.mjs';

const { version } = JSON.parse(readFileSync('package.json', 'utf8'));
process.stdout.write(releaseNotes(readFileSync('CHANGELOG.md', 'utf8'), version));
