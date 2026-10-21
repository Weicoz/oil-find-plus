import { writeFile, rename, stat } from 'node:fs/promises';
import { createHash } from 'node:crypto';
import { createReadStream } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { releases } from '../site/content/releases.ts';

const [plist, archive, output, urlTemplate = 'https://github.com/Weicoz/oil-find-plus/releases/download/v{version}/OilFind-Plus-v{version}-macOS-arm64.zip'] = process.argv.slice(2);
if (!plist || !archive || !output) throw new Error('Usage: generate-update-manifest.mjs <Info.plist> <zip> <output> [urlTemplate]');
const value = key => execFileSync('/usr/libexec/PlistBuddy', ['-c', `Print :${key}`, plist], { encoding: 'utf8' }).trim();
const version = value('CFBundleShortVersionString');
// A "+plus" build may reuse the notes of the upstream release it is based on.
const base = version.replace(/-plus$/, '');
const release = releases.find(item => item.version === version) ?? releases.find(item => item.version === base);
if (release && release.version !== version) console.warn(`Notes for ${version} reused from ${release.version}.`);
if (!release || !release.notes.zh.length || !release.notes.en.length || [...release.notes.zh, ...release.notes.en].some(note => !note.trim())) {
  throw new Error(`Release notes for ${version} are missing in site/content/releases.ts. Packaging stopped.`);
}
const hash = createHash('sha256');
for await (const chunk of createReadStream(archive)) hash.update(chunk);
const manifest = {
  version, build: Number(value('CFBundleVersion')),
  url: urlTemplate.replaceAll('{version}', version),
  size: (await stat(archive)).size, sha256: hash.digest('hex'),
  minimumSystemVersion: value('LSMinimumSystemVersion'), published: release.date, notes: release.notes,
};
const temporary = `${output}.tmp`;
try {
  await writeFile(temporary, JSON.stringify(manifest, null, 2) + '\n');
  await rename(temporary, output);
} catch (error) {
  const { rm } = await import('node:fs/promises');
  await rm(temporary, { force: true });
  throw error;
}
console.log(`Manifest: ${output}`);
