import { parseArgs } from 'node:util';
import { checkChange, checkRange } from './changesets.mjs';

try {
  const { values } = parseArgs({ options: { staged: { type: 'boolean' }, base: { type: 'string' }, head: { type: 'string' } } });
  if (values.staged) {
    const result = checkChange(process.cwd(), 'HEAD', 'index');
    console.log(`Changeset check passed (${result.kind}).`);
  } else if (values.base && values.head) {
    console.log(`Changeset check passed for ${checkRange(process.cwd(), values.base, values.head)} commits.`);
  } else throw new Error('Use --staged or --base <commit> --head <commit>.');
} catch (error) { console.error(error.message); process.exitCode = 1; }
